-- TFD app — matching is by number only (Kenny, Nov 15 2026): every CSV holds exactly that show's orders,
-- so no time-window filtering and no "placed before its scan" check. Duplicate # and never-scanned # are still caught.

create or replace function tfd_match_one(p_order bigint, p_skip_window boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare o show_orders; s shows; pl pulls; maxpart int; lo timestamptz; hi timestamptz;
begin
  select * into o from show_orders where id = p_order for update;
  select * into s from shows where id = o.show_id;
  if o.status <> 'paid' then update show_orders set state = 'failed', problem = null where id = o.id; return; end if;
  if s.type = 'listed' then
    if o.file_sku ~ '^\d{6}$' then
      select * into pl from pulls p where p.show_id = s.id and p.kind = 'win' and p.status = 'held' and p.sku = o.file_sku
        and not exists (select 1 from show_orders x where x.pull_id = p.id and x.state = 'matched') order by p.pull_no limit 1;
      if pl.id is null then update show_orders set state = 'needs_match', problem = 'no_win' where id = o.id; return; end if;
    elsif o.sale_cents = 0 and coalesce(o.tracking, '') = '' then update show_orders set state = 'ignored', problem = 'no_item' where id = o.id; return;
    else update show_orders set state = 'needs_match', problem = 'no_sku' where id = o.id; return; end if;
  else
    if o.product_name ~* 'giveaway' then update show_orders set state = 'needs_match', problem = 'giveaway_line' where id = o.id; return; end if;
    if o.pull_no is null then
      if o.sale_cents = 0 and coalesce(o.tracking, '') = '' then update show_orders set state = 'ignored', problem = 'no_item' where id = o.id;
      else update show_orders set state = 'needs_match', problem = 'no_pull_number' where id = o.id; end if;
      return;
    end if;
    if o.part is null then
      select coalesce(max(part), 1) into maxpart from pulls where show_id = s.id and kind <> 'win' and part > 0 and status <> 'void';
      if maxpart > 1 then update show_orders set state = 'needs_match', problem = 'part_unknown' where id = o.id; return; end if;
    end if;
    select * into pl from pulls where show_id = s.id and kind <> 'win' and status in ('held','released') and part = coalesce(o.part, 1) and pull_no = o.pull_no;
    if pl.id is null then update show_orders set state = 'needs_match', problem = 'no_pull' where id = o.id; return; end if;
    if exists (select 1 from show_orders x where x.pull_id = pl.id and x.state = 'matched' and x.id <> o.id) then
      update show_orders set state = 'needs_match', problem = 'duplicate' where id = o.id; return; end if;
  end if;
  update show_orders set state = 'matched', pull_id = pl.id, match_how = 'auto',
    problem = null, ack = false where id = o.id;
end $$;

create or replace function tfd_order_resolve(p_order bigint, p_action text, p_pull bigint default null, p_sku text default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; o show_orders; s shows; pl pulls; sk text := trim(coalesce(p_sku, '')); np int; what text;
begin
  me := tfd_require('admin');
  select * into o from show_orders where id = p_order for update;
  if o.id is null then raise exception 'No such order'; end if;
  select * into s from shows where id = o.show_id for update;
  if s.status <> 'matched' then raise exception 'Orders can only be fixed after the CSV import and before finalize'; end if;
  if p_action = 'pull' then
    if o.state not in ('needs_match','ignored') or o.status <> 'paid' then raise exception 'That order doesn''t need a match'; end if;
    select * into pl from pulls where id = p_pull and show_id = s.id for update;
    if pl.id is null or pl.status not in ('held','released') then raise exception 'Pick a pull from this show'; end if;
    if exists (select 1 from show_orders x where x.pull_id = pl.id and x.state = 'matched') then raise exception 'That pull already has an order'; end if;
    if pl.status = 'released' then
      if tfd_available(pl.sku) < 1 then raise exception 'SKU % has no available unit to hold again', pl.sku; end if;
      update pulls set status = 'held', released_import = null, note = null where id = pl.id;
    end if;
    update show_orders set state = 'matched', pull_id = pl.id, match_how = 'manual', resolved_by = me.name,
      problem = null, ack = false where id = o.id;
    what := 'matched to ' || case when pl.kind = 'win' then 'win #' else 'Part ' || pl.part || ' pull #' end || pl.pull_no || ' (SKU ' || pl.sku || ')';
  elsif p_action = 'sku' then
    if o.state not in ('needs_match','ignored') or o.status <> 'paid' then raise exception 'That order doesn''t need a match'; end if;
    if not exists (select 1 from products where sku = sk) then raise exception 'Unknown SKU %', sk; end if;
    if tfd_available(sk) < 1 then raise exception 'SKU % has no available unit', sk; end if;
    if s.type = 'listed' then
      insert into pulls (show_id, part, pull_no, sku, kind, outside_list, scanned_by, scanned_at, note, from_order)
        values (s.id, 0, s.next_win, sk, 'win', s.scope_skus is not null and not sk = any(s.scope_skus), me.name, coalesce(o.placed_at, now()), 'added from CSV order', o.id) returning * into pl;
      update shows set next_win = next_win + 1 where id = s.id;
    else
      select coalesce(max(pull_no), 0) + 1 into np from pulls where show_id = s.id and part = 0 and kind <> 'win';
      insert into pulls (show_id, part, pull_no, sku, kind, outside_list, scanned_by, scanned_at, note, from_order)
        values (s.id, 0, np, sk, case when o.sale_cents = 0 and s.platform = 'whatnot' then 'giveaway' else 'normal' end,
                s.scope_skus is not null and not sk = any(s.scope_skus), me.name, coalesce(o.placed_at, now()), 'added from CSV order', o.id) returning * into pl;
    end if;
    update show_orders set state = 'matched', pull_id = pl.id, match_how = 'manual', resolved_by = me.name, problem = null, ack = false where id = o.id;
    what := 'matched to SKU ' || sk || ' (pull added)';
  elsif p_action = 'ignore' then
    if o.state = 'matched' then raise exception 'Unmatch it first'; end if;
    if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
    update show_orders set state = 'ignored', problem = 'ignored_manual', note = trim(p_reason), resolved_by = me.name where id = o.id;
    what := 'marked not part of this show';
  elsif p_action = 'include' then
    if o.state <> 'ignored' then raise exception 'Only an ignored row can be included'; end if;
    update show_orders set state = 'pending', problem = null, note = null where id = o.id;
    perform tfd_match_one(o.id, true);
    what := 'included';
  elsif p_action = 'unmatch' then
    if o.state <> 'matched' then raise exception 'That order isn''t matched'; end if;
    select * into pl from pulls where id = o.pull_id for update;
    update show_orders set state = 'needs_match', problem = 'unmatched', pull_id = null, match_how = null, resolved_by = me.name, ack = false where id = o.id;
    if pl.from_order = o.id then update pulls set status = 'void', note = 'unmatched from CSV order' where id = pl.id;
    else update pulls set status = 'released', released_import = o.import_id, note = 'no order in the CSV' where id = pl.id; end if;
    what := 'unmatched';
  elsif p_action = 'ack' then
    if o.problem <> 'before_scan' then raise exception 'Nothing to OK on that order'; end if;
    update show_orders set ack = true, resolved_by = me.name where id = o.id;
    what := 'early order time OK''d';
  else raise exception 'Unknown action'; end if;
  perform tfd_log(me.name, 'Shows', 'order_fix', 'Order ' || coalesce(o.order_id, 'row ' || o.line_no) || ' ' || what || ' (' || tfd_show_label(s) || ')',
    jsonb_build_object('show', s.id, 'order', o.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;
