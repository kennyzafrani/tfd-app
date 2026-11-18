-- 0016: packers don't have to clock in to pack (clock in/out is its own button); admins can mark packages packed in bulk;
-- inventory value for the Dashboard; an order whose Part/# was never scanned can be added as exactly that pull;
-- lot report (new arrivals for the streamers: image, name, floor, MSRP; never cost).

-- packing no longer requires being clocked in (pay still comes from the clock)
create or replace function tfd_pack_check(p_pkg bigint, p_need_open boolean) returns packages language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages;
begin
  select * into pk from packages where id = p_pkg for update;
  if pk.id is null then raise exception 'No such package'; end if;
  if pk.status = 'packed' then raise exception 'That package is already packed'; end if;
  if p_need_open and pk.status = 'problem' then raise exception 'This package is marked Problem. Kenny has to resolve it first'; end if;
  return pk;
end $$;

-- admins: mark many packages packed at once, without scans or photos
create or replace function tfd_pack_bulk(p_ids bigint[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); pk packages; n int := 0;
begin
  if p_ids is null or cardinality(p_ids) = 0 then raise exception 'Pick at least one package'; end if;
  for pk in select * from packages where id = any(p_ids) and status <> 'packed' order by id for update loop
    update packages set status = 'packed', packed_at = now(), packed_by = me.name, started_at = coalesce(started_at, now()) where id = pk.id;
    perform tfd_log(me.name, 'Fulfillment', 'package_packed', 'Marked packed by admin (no scan/photo): ' || coalesce(pk.tracking, pk.package_key, 'package #' || pk.id) || ' for ' || coalesce(pk.buyer, pk.ship_name, '?'),
      jsonb_build_object('package', pk.id, 'show', pk.show_id, 'bulk', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'packed', n);
end $$;

-- what's on the shelf right now, at FIFO cost (and retail)
create or replace function tfd_inventory_value() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin');
begin
  return (select jsonb_build_object('cost_cents', coalesce(sum(c.qty_remaining::bigint * c.unit_cost_cents), 0), 'units', coalesce(sum(c.qty_remaining), 0),
      'skus', count(distinct c.sku) filter (where c.qty_remaining > 0),
      'retail_cents', coalesce(sum(c.qty_remaining::bigint * coalesce(p.retail_cents, 0)), 0))
    from cost_layers c join products p on p.sku = c.sku);
end $$;

create or replace function tfd_order_resolve(p_order bigint, p_action text, p_pull bigint default null, p_sku text default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; o show_orders; s shows; pl pulls; sk text := trim(coalesce(p_sku, '')); np int; pp int; what text;
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
      -- the order names a Part and # that was never scanned: add it as exactly that pull (e.g. Part 1 #31); otherwise an extra pull under Part 0
      if o.part is not null and o.pull_no is not null and not exists (select 1 from pulls where show_id = s.id and part = o.part and pull_no = o.pull_no and status <> 'void' and kind <> 'win') then
        pp := o.part; np := o.pull_no;
      else
        pp := 0; select coalesce(max(pull_no), 0) + 1 into np from pulls where show_id = s.id and part = 0 and kind <> 'win';
      end if;
      insert into pulls (show_id, part, pull_no, sku, kind, outside_list, scanned_by, scanned_at, note, from_order)
        values (s.id, pp, np, sk, case when o.sale_cents = 0 and s.platform = 'whatnot' then 'giveaway' else 'normal' end,
                s.scope_skus is not null and not sk = any(s.scope_skus), me.name, coalesce(o.placed_at, now()), 'added from CSV order', o.id) returning * into pl;
    end if;
    update show_orders set state = 'matched', pull_id = pl.id, match_how = 'manual', resolved_by = me.name, problem = null, ack = false where id = o.id;
    what := 'matched to SKU ' || sk || ' (added as ' || case when s.type = 'listed' then 'win #' || pl.pull_no else 'Part ' || pl.part || ' #' || pl.pull_no end || ')';
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
-- lot report: what came in on a confirmed lot, streamer-safe (floor and MSRP only, never cost).
-- Floor = the same floor the live screen shows (highest cost still on the shelf); if it's all sold, this lot's cost.
create or replace function tfd_lot_report(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); r receipts;
begin
  select * into r from receipts where id = p_id;
  if r.id is null then raise exception 'No such lot'; end if;
  if r.status <> 'confirmed' then raise exception 'Confirm the lot first'; end if;
  return jsonb_build_object('id', r.id, 'name', r.name, 'received_date', r.received_date,
    'items', coalesce((select jsonb_agg(x order by x->>'brand', x->>'name', x->>'sku') from (
      select jsonb_build_object('sku', p.sku, 'brand', p.brand, 'model', p.model, 'name', p.name, 'color_name', p.color_name, 'color_code', p.color_code,
          'lens_size', p.lens_size, 'image_url', p.image_url, 'retail_cents', p.retail_cents, 'received', l.qty, 'available', tfd_available(p.sku),
          'floor_tiktok', (tfd_floor_for(coalesce(m.max_cost, l.cost), 'tiktok')->>'rounded_cents')::int,
          'floor_whatnot', (tfd_floor_for(coalesce(m.max_cost, l.cost), 'whatnot')->>'rounded_cents')::int) x
      from (select result_sku sku, sum(received_qty)::int qty, max(unit_cost_cents) cost from receipt_lines where receipt_id = r.id and result_sku is not null and received_qty > 0 group by result_sku) l
      join products p on p.sku = l.sku
      left join lateral (select max(unit_cost_cents) max_cost from cost_layers c where c.sku = l.sku and c.qty_remaining > 0) m on true) t), '[]'::jsonb));
end $$;

grant execute on function tfd_pack_bulk(bigint[]), tfd_inventory_value(), tfd_lot_report(bigint) to authenticated;
