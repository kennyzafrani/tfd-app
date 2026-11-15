-- TFD app — Phase 4a: import the platform CSV, match orders to pulls, review, finalize / unfinalize, remove CSV (Nov 15 2026).
-- TikTok "To Ship": Part from the listing name ("Part 1 …"), pull # from Seller SKU. Whatnot: pull # from "… #N" in product_name;
-- Whatnot listed shows match by the 6-digit TFD SKU in the sku column. Money is in cents.

alter table shows add column if not exists finalized_at timestamptz, add column if not exists finalized_by text, add column if not exists totals jsonb;
alter table pulls add column if not exists released_import bigint, add column if not exists from_order bigint;

create table if not exists show_imports (
  id bigserial primary key, show_id bigint not null references shows(id), platform text not null, file_name text not null, file_path text,
  tz text not null, row_count int not null, uploaded_by text not null, uploaded_at timestamptz not null default now(),
  removed_at timestamptz, removed_by text, removed_reason text);
create table if not exists show_orders (
  id bigserial primary key, import_id bigint not null references show_imports(id), show_id bigint not null references shows(id), line_no int not null,
  order_id text, status text not null check (status in ('paid','failed','cancelled')), product_name text, part int, pull_no int, file_sku text,
  sale_cents int not null default 0, ship_cents int, coupon_cents int, placed_local text, placed_at timestamptz,
  tracking text, package_key text, buyer text, ship_name text, raw jsonb,
  state text not null default 'pending' check (state in ('pending','matched','needs_match','ignored','failed')),
  problem text, pull_id bigint references pulls(id), match_how text, ack boolean not null default false, note text, resolved_by text,
  fee_cents int, commission_cents int, cost_cents int, fifo jsonb);
create index if not exists show_orders_show on show_orders (show_id, state);
create index if not exists show_orders_pull on show_orders (pull_id) where pull_id is not null;
alter table show_imports enable row level security; alter table show_orders enable row level security;
revoke all on show_imports, show_orders from anon, authenticated;

-- original CSVs (private, admins only)
insert into storage.buckets (id, name, public) values ('show-files', 'show-files', false) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tfd show files read') then
    create policy "tfd show files read" on storage.objects for select to authenticated using (bucket_id = 'show-files' and public.tfd_is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tfd show files add') then
    create policy "tfd show files add" on storage.objects for insert to authenticated with check (bucket_id = 'show-files' and public.tfd_is_admin());
  end if;
end $$;

-- two streamers: Kenny enters each one's share (0.5% + 0.5%), so the floor uses the total
create or replace function tfd_show_comm_bp(s shows) returns int language sql stable security definer set search_path = public as
  $$ select coalesce((select sum(commission_bp)::int from show_people where show_id = s.id and role = 'streamer'), 0) $$;
create or replace function tfd_show_floor(p_sku text, s shows) returns int language sql stable security definer set search_path = public as $$
  select (tfd_floor(max(c.unit_cost_cents), tfd_show_fees(s), tfd_show_comm_bp(s), (tfd_get_setting('pricing')->>'floor_profit_bp')::int)->>'rounded_cents')::int
  from cost_layers c where c.sku = p_sku and c.qty_remaining > 0 $$;

-- fee on one order with this show's fees. Whatnot's file has no shipping, so the typical shipping from the fee settings is used.
create or replace function tfd_order_fee(o show_orders, f jsonb, p_platform text) returns int language sql immutable as $$
  select case when f is null or jsonb_typeof(f->'pct_sale_bp') is distinct from 'number' then null
    else round(o.sale_cents * (f->>'pct_sale_bp')::numeric / 10000
      + coalesce(case when p_platform = 'whatnot' then (f->>'typical_ship_cents')::int else o.ship_cents end, 0) * coalesce((f->>'pct_ship_bp')::numeric, 0) / 10000
      + coalesce((f->>'fixed_cents')::int, 0))::int end $$;

-- the next n FIFO unit costs for a SKU (estimate before finalize)
create or replace function tfd_fifo_costs(p_sku text, p_n int) returns int[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(c order by o), '{}') from (
    select l.unit_cost_cents c, row_number() over (order by l.created_at, l.id, g) o
    from cost_layers l, generate_series(1, l.qty_remaining) g where l.sku = p_sku and l.qty_remaining > 0) x where o <= p_n $$;

-- ---------------------------------------------------------------- matching
create or replace function tfd_match_one(p_order bigint, p_skip_window boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare o show_orders; s shows; pl pulls; maxpart int; lo timestamptz; hi timestamptz;
begin
  select * into o from show_orders where id = p_order for update;
  select * into s from shows where id = o.show_id;
  if o.status <> 'paid' then update show_orders set state = 'failed', problem = null where id = o.id; return; end if;
  lo := coalesce(s.started_at, s.created_at) - interval '15 minutes'; hi := coalesce(s.ended_at, now()) + interval '3 hours';
  if not p_skip_window and o.placed_at is not null and (o.placed_at < lo or o.placed_at > hi) then
    update show_orders set state = 'ignored', problem = 'outside_window' where id = o.id; return; end if;
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
    problem = case when o.placed_at < pl.scanned_at - interval '60 seconds' then 'before_scan' end, ack = false where id = o.id;
end $$;

-- pick how the file's times are read: the zone where orders land closest after their own pull's scan
-- (an auction sells within minutes of the scan); with nothing to compare (listed shows), the zone that puts the most orders inside the show
create or replace function tfd_pick_tz(p_show bigint) returns text language plpgsql security definer set search_path = public as $$
declare tz text; best text; best_gap numeric; best_in bigint := -1; gap numeric; inwin bigint; s shows;
begin
  select * into s from shows where id = p_show;
  foreach tz in array array['America/New_York','UTC','America/Chicago','America/Denver','America/Los_Angeles'] loop
    select percentile_cont(0.5) within group (order by abs(extract(epoch from (o.placed_local::timestamp at time zone tz) - p.scanned_at)))
      into gap from show_orders o join pulls p on p.show_id = p_show and p.status <> 'void' and p.kind <> 'win' and p.part = coalesce(o.part, 1) and p.pull_no = o.pull_no
      where o.show_id = p_show and o.state = 'pending' and o.placed_local is not null;
    select count(*) into inwin from show_orders o where o.show_id = p_show and o.state = 'pending' and o.placed_local is not null
      and (o.placed_local::timestamp at time zone tz) between coalesce(s.started_at, s.created_at) - interval '15 minutes' and coalesce(s.ended_at, now()) + interval '3 hours';
    if (gap is not null and (best_gap is null or gap < best_gap)) or (gap is null and best_gap is null and inwin > best_in) then
      best := tz; best_gap := gap; best_in := inwin; end if;
  end loop;
  return best;
end $$;

create or replace function tfd_show_import(p_show bigint, p_file_name text, p_file_path text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; imp bigint; v_tz text; r jsonb; x record; n int; rel int;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status <> 'ended' then raise exception 'Conclude the show first (it must be Concluded with no CSV yet)'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'The file has no orders'; end if;
  insert into show_imports (show_id, platform, file_name, file_path, tz, row_count, uploaded_by)
    values (p_show, s.platform, coalesce(nullif(trim(p_file_name), ''), 'upload.csv'), p_file_path, 'UTC', jsonb_array_length(p_rows), me.name) returning id into imp;
  insert into show_orders (import_id, show_id, line_no, order_id, status, product_name, part, pull_no, file_sku, sale_cents, ship_cents, coupon_cents,
      placed_local, tracking, package_key, buyer, ship_name, raw)
    select imp, p_show, (j->>'line')::int, nullif(j->>'order_id', ''), coalesce(nullif(j->>'status', ''), 'paid'), j->>'product_name', (j->>'part')::int, (j->>'pull_no')::int,
      nullif(j->>'sku', ''), coalesce((j->>'sale_cents')::int, 0), (j->>'ship_cents')::int, (j->>'coupon_cents')::int, nullif(j->>'placed_local', ''),
      nullif(j->>'tracking', ''), nullif(j->>'package_key', ''), nullif(j->>'buyer', ''), nullif(j->>'ship_name', ''), j->'raw'
    from jsonb_array_elements(p_rows) j;
  v_tz := tfd_pick_tz(p_show);
  update show_imports set tz = v_tz where id = imp;
  update show_orders set placed_at = placed_local::timestamp at time zone v_tz where import_id = imp and placed_local is not null;
  for x in select id from show_orders where import_id = imp order by line_no loop perform tfd_match_one(x.id); end loop;
  -- mapped pulls with no paid order: the sale didn't go through, so the hold is released
  update pulls p set status = 'released', released_import = imp, note = 'no order in the CSV'
    where p.show_id = p_show and p.status = 'held' and not exists (select 1 from show_orders o where o.pull_id = p.id and o.state = 'matched');
  get diagnostics rel = row_count;
  update shows set status = 'matched' where id = p_show;
  select count(*) into n from show_orders where import_id = imp and state = 'matched';
  perform tfd_log(me.name, 'Shows', 'csv_import', 'CSV imported for ' || tfd_show_label(s) || ': ' || p_file_name || ', ' || jsonb_array_length(p_rows) || ' rows, ' || n || ' matched, ' ||
    (select count(*) from show_orders where import_id = imp and state = 'needs_match') || ' need a match, ' || rel || ' pull(s) with no order released (times read as ' || v_tz || ')',
    jsonb_build_object('show', p_show, 'import', imp));
  return jsonb_build_object('ok', true, 'import', imp, 'tz', v_tz, 'matched', n, 'released', rel);
end $$;

-- a fix on one order: match to a pull, match to a SKU (adds a pull), ignore, include (an ignored row), unmatch, OK an early order
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
      problem = case when o.placed_at < pl.scanned_at - interval '60 seconds' then 'before_scan' end, ack = false where id = o.id;
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

-- ---------------------------------------------------------------- review (everything the review screen shows)
create or replace function tfd_show_review(p_show bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles; s shows; f jsonb; cbp int; fp int; imp show_imports; orders jsonb; pay jsonb; tot jsonb; fin boolean;
begin
  me := tfd_require('admin');
  s := tfd_show_get(p_show);
  f := tfd_show_fees(s); cbp := tfd_show_comm_bp(s); fp := (tfd_get_setting('pricing')->>'floor_profit_bp')::int; fin := s.status = 'finalized';
  select * into imp from show_imports where show_id = p_show and removed_at is null order by id desc limit 1;
  if imp.id is null then return jsonb_build_object('import', null); end if;
  with o as (
    select o.*, pl.sku, pl.kind, pl.part pl_part, pl.pull_no pl_no, pl.scanned_at, pl.from_order = o.id added,
      coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)) product,
      case when fin then o.fee_cents else tfd_order_fee(o, f, s.platform) end fee
    from show_orders o left join pulls pl on pl.id = o.pull_id left join products pr on pr.sku = pl.sku where o.import_id = imp.id),
  est as (   -- estimated FIFO cost before finalize: the next units in line, per SKU, in pull order
    select o.id, case when fin then o.cost_cents
      else (tfd_fifo_costs(o.sku, (count(*) over (partition by o.sku))::int))[row_number() over (partition by o.sku order by o.pl_part, o.pl_no, o.id)] end cost
    from o where o.state = 'matched'),
  m as (
    select o.*, e.cost, case when fin then o.commission_cents when o.fee is null then null else round(cbp * (o.sale_cents - o.fee) / 10000.0)::int end comm
    from o left join est e on e.id = o.id)
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'line', m.line_no, 'order_id', m.order_id, 'status', m.status, 'state', m.state, 'problem', m.problem, 'ack', m.ack,
      'note', m.note, 'product_name', m.product_name, 'part', m.part, 'pull_no', m.pull_no, 'file_sku', m.file_sku, 'placed_at', m.placed_at, 'buyer', m.buyer,
      'tracking', m.tracking, 'package_key', m.package_key, 'sale_cents', m.sale_cents, 'ship_cents', m.ship_cents, 'coupon_cents', m.coupon_cents,
      'pull_id', m.pull_id, 'sku', m.sku, 'kind', m.kind, 'pull_part', m.pl_part, 'pull_no_matched', m.pl_no, 'scanned_at', m.scanned_at, 'added', m.added, 'how', m.match_how, 'product', m.product,
      'fee_cents', case when m.state = 'matched' then m.fee end, 'commission_cents', case when m.state = 'matched' then m.comm end, 'cost_cents', m.cost,
      'profit_cents', case when m.state = 'matched' and m.fee is not null and m.cost is not null then m.sale_cents - m.fee - m.comm - m.cost end,
      'below_floor', m.state = 'matched' and m.kind <> 'giveaway' and m.sale_cents > 0 and m.fee is not null and m.cost is not null
                     and (m.sale_cents - m.fee - m.comm - m.cost) < round(m.cost * fp / 10000.0))
    order by m.line_no), '[]') into orders from m;
  tot := (select jsonb_build_object(
      'sales_cents', coalesce(sum((x->>'sale_cents')::int) filter (where x->>'state' = 'matched'), 0),
      'ship_cents', coalesce(sum((x->>'ship_cents')::int) filter (where x->>'state' = 'matched'), 0),
      'fees_cents', sum((x->>'fee_cents')::int) filter (where x->>'state' = 'matched'),
      'commission_cents', sum((x->>'commission_cents')::int) filter (where x->>'state' = 'matched'),
      'cost_cents', coalesce(sum((x->>'cost_cents')::int) filter (where x->>'state' = 'matched' and x->>'kind' <> 'giveaway'), 0),
      'giveaway_cost_cents', coalesce(sum((x->>'cost_cents')::int) filter (where x->>'state' = 'matched' and x->>'kind' = 'giveaway'), 0),
      'profit_cents', sum((x->>'profit_cents')::int) filter (where x->>'state' = 'matched'),
      'units', count(*) filter (where x->>'state' = 'matched'),
      'below_floor', count(*) filter (where (x->>'below_floor')::boolean),
      'needs_match', count(*) filter (where x->>'state' = 'needs_match'),
      'unacked', count(*) filter (where x->>'state' = 'matched' and x->>'problem' = 'before_scan' and not (x->>'ack')::boolean),
      'ignored', count(*) filter (where x->>'state' = 'ignored'), 'failed', count(*) filter (where x->>'state' = 'failed'),
      'rows', count(*)) from jsonb_array_elements(orders) x);
  pay := (select coalesce(jsonb_agg(jsonb_build_object('profile_id', sp.profile_id, 'name', pr.name, 'role', sp.role, 'hourly_cents', sp.hourly_cents, 'commission_bp', sp.commission_bp,
      'hours', h.hrs, 'hourly_pay_cents', round(h.hrs * sp.hourly_cents)::int,
      'commission_cents', case when sp.role = 'streamer' then round(sp.commission_bp * coalesce((tot->>'sales_cents')::int - (tot->>'fees_cents')::int, 0) / 10000.0)::int else 0 end)
      order by sp.role desc, pr.name), '[]')
    from show_people sp join profiles pr on pr.id = sp.profile_id
    cross join lateral (select round(coalesce(sum(extract(epoch from end_at - start_at)), 0) / 3600.0, 2) hrs from show_shifts where show_id = p_show and profile_id = sp.profile_id) h
    where sp.show_id = p_show);
  return jsonb_build_object('status', s.status, 'fees', f, 'commission_bp', cbp,
    'import', jsonb_build_object('id', imp.id, 'file_name', imp.file_name, 'file_path', imp.file_path, 'tz', imp.tz, 'rows', imp.row_count, 'by', imp.uploaded_by, 'at', imp.uploaded_at),
    'orders', orders, 'totals', tot, 'pay', pay,
    'released', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'part', pl.part, 'pull_no', pl.pull_no, 'kind', pl.kind, 'sku', pl.sku,
        'product', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model))) order by pl.part, pl.pull_no), '[]')
      from pulls pl join products pr on pr.sku = pl.sku where pl.show_id = p_show and pl.status = 'released' and pl.released_import = imp.id),
    'open_pulls', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'part', pl.part, 'pull_no', pl.pull_no, 'kind', pl.kind, 'sku', pl.sku, 'status', pl.status,
        'product', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model))) order by pl.kind = 'win', pl.part, pl.pull_no), '[]')
      from pulls pl join products pr on pr.sku = pl.sku where pl.show_id = p_show and pl.status in ('held','released')
        and not exists (select 1 from show_orders x where x.pull_id = pl.id and x.state = 'matched')),
    'hours_entered', exists (select 1 from show_shifts where show_id = p_show),
    'blockers', to_jsonb(array_remove(array[
      case when (tot->>'needs_match')::int > 0 then (tot->>'needs_match') || ' order(s) need a match' end,
      case when (tot->>'unacked')::int > 0 then (tot->>'unacked') || ' order(s) placed before their scan need an OK' end,
      case when jsonb_typeof(f->'pct_sale_bp') is distinct from 'number' then 'This show''s platform fee isn''t set (Edit setup)' end], null)),
    'finalized_at', s.finalized_at, 'finalized_by', s.finalized_by);
end $$;

-- ---------------------------------------------------------------- remove CSV (back to Concluded)
create or replace function tfd_show_remove_csv(p_show bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; imp show_imports; bad text;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'matched' then raise exception 'Only a matched show (CSV imported, not finalized) can have its CSV removed'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  select * into imp from show_imports where show_id = p_show and removed_at is null order by id desc limit 1;
  select string_agg(x.sku || ' (needs ' || x.n || ', ' || greatest(tfd_available(x.sku), 0) || ' available)', ', ') into bad
    from (select sku, count(*) n from pulls where show_id = p_show and status = 'released' and released_import = imp.id group by sku) x where x.n > tfd_available(x.sku);
  if bad is not null then raise exception 'Can''t put the released pulls back on hold, the units were used elsewhere: %', bad; end if;
  update pulls set status = 'void', note = 'CSV removed' where show_id = p_show and from_order in (select id from show_orders where import_id = imp.id) and status = 'held';
  update pulls set status = 'held', released_import = null, note = null where show_id = p_show and status = 'released' and released_import = imp.id;
  update show_orders set pull_id = null where import_id = imp.id;
  update pulls set from_order = null where show_id = p_show and from_order in (select id from show_orders where import_id = imp.id);
  delete from show_orders where import_id = imp.id;
  update show_imports set removed_at = now(), removed_by = me.name, removed_reason = trim(p_reason) where id = imp.id;
  update shows set status = 'ended' where id = p_show;
  perform tfd_log(me.name, 'Shows', 'csv_remove', 'CSV removed from ' || tfd_show_label(s) || ' (' || imp.file_name || '); back to Concluded, holds restored', jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- finalize / unfinalize
create or replace function tfd_show_finalize(p_show bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; r jsonb; f jsonb; cbp int; o record; tk record; bl jsonb; units int := 0; cost bigint := 0; x record;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'matched' then raise exception 'Import the CSV first'; end if;
  r := tfd_show_review(p_show);
  bl := r->'blockers';
  if jsonb_array_length(bl) > 0 then raise exception 'Can''t finalize yet: %', (select string_agg(v, '; ') from jsonb_array_elements_text(bl) v); end if;
  f := tfd_show_fees(s); cbp := tfd_show_comm_bp(s);
  for o in select so.*, pl.sku from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' order by pl.part, pl.pull_no, so.id for update of so loop
    select * into tk from tfd_take_fifo(o.sku, 1);
    update show_orders so set cost_cents = tk.value_cents, fifo = tk.taken, fee_cents = tfd_order_fee(so, f, s.platform) where so.id = o.id;
    update show_orders set commission_cents = round(cbp * (sale_cents - fee_cents) / 10000.0)::int where id = o.id;
    units := units + 1; cost := cost + tk.value_cents;
  end loop;
  for x in select pl.sku, count(*)::int n, sum(so.cost_cents) v from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' group by pl.sku loop
    insert into stock_moves (sku, kind, qty, value_cents, actor, detail) values (x.sku, 'show_sale', -x.n, -x.v, me.name, jsonb_build_object('show', p_show, 'label', tfd_show_label(s)));
  end loop;
  update pulls set status = 'sold' where id in (select pull_id from show_orders where show_id = p_show and state = 'matched');
  r := tfd_show_review(p_show);   -- re-read with the locked numbers
  update shows set status = 'finalized', fees = f, finalized_at = now(), finalized_by = me.name,
    totals = (r->'totals') || jsonb_build_object('pay', r->'pay') where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_finalize', 'Show finalized: ' || tfd_show_label(s) || ' (' || units || ' unit(s) out of inventory at $' || to_char(cost / 100.0, 'FM999999990.00') ||
    ' cost, sales $' || to_char((r->'totals'->>'sales_cents')::numeric / 100, 'FM999999990.00') || ', fee ' || coalesce(((f->>'pct_sale_bp')::numeric / 100)::text || '%', '?') || ')', jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true, 'units', units, 'cost_cents', cost);
end $$;

create or replace function tfd_show_unfinalize(p_show bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; o record; t jsonb; x record; units int := 0;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'finalized' then raise exception 'That show isn''t finalized'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  for x in select pl.sku, count(*)::int n, sum(so.cost_cents) v from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' and so.fifo is not null group by pl.sku loop
    insert into stock_moves (sku, kind, qty, value_cents, reason, actor, detail) values (x.sku, 'show_unfinalize', x.n, x.v, trim(p_reason), me.name, jsonb_build_object('show', p_show, 'label', tfd_show_label(s)));
  end loop;
  for o in select * from show_orders where show_id = p_show and state = 'matched' and fifo is not null for update loop
    for t in select * from jsonb_array_elements(o.fifo) loop
      update cost_layers set qty_remaining = qty_remaining + (t->>'qty')::int where id = (t->>'layer')::bigint;
    end loop;
    units := units + 1;
  end loop;
  update show_orders set cost_cents = null, fifo = null, fee_cents = null, commission_cents = null where show_id = p_show;
  update pulls set status = 'held' where show_id = p_show and status = 'sold';
  update shows set status = 'matched', finalized_at = null, finalized_by = null, totals = null where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_unfinalize', 'Show unfinalized: ' || tfd_show_label(s) || ' (' || units || ' unit(s) back in inventory; fees stay at this show''s rate)', jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true, 'units', units);
end $$;


-- fees, lineup and hours can still change after the CSV import (they lock at finalize)
create or replace function tfd_show_save(p_id bigint, p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; id_ bigint := p_id; person jsonb; nstream int; nassist int; nlead int; lst inv_lists; lbl text; npulls int; v_fees jsonb;
begin
  me := tfd_require('admin');
  if p->>'type' not in ('live','listed') then raise exception 'Pick a show type'; end if;
  if p->>'platform' not in ('tiktok','whatnot') then raise exception 'Pick a platform'; end if;
  if nullif(p->>'list_id', '') is not null then
    select * into lst from inv_lists where id = (p->>'list_id')::bigint;
    if lst.id is null then raise exception 'That inventory list no longer exists'; end if;
  end if;
  select count(*) filter (where x->>'role' = 'streamer'), count(*) filter (where x->>'role' = 'assistant'), count(*) filter (where (x->>'lead')::boolean)
    into nstream, nassist, nlead from jsonb_array_elements(coalesce(p->'people', '[]')) x;
  if nstream = 0 then raise exception 'Add at least one streamer'; end if;
  if nstream >= 2 and coalesce(p->>'split_mode', '') not in ('even','lead') then raise exception 'With two streamers, pick Split evenly or Lead + support'; end if;
  if nstream >= 2 and p->>'split_mode' = 'lead' and nlead <> 1 then raise exception 'Pick exactly one lead streamer'; end if;
  if (select count(distinct x->>'profile_id') from jsonb_array_elements(p->'people') x) <> jsonb_array_length(p->'people') then raise exception 'Each person can only be in the lineup once'; end if;
  for person in select * from jsonb_array_elements(p->'people') loop
    if not exists (select 1 from profiles where id = (person->>'profile_id')::bigint and active and role in ('streamer','assistant','admin')) then raise exception 'Lineup has someone who can''t be on a show'; end if;
    if (person->>'role') = 'streamer' and (select role from profiles where id = (person->>'profile_id')::bigint) = 'admin' then raise exception 'Admins can only fill the assistant spot'; end if;
  end loop;
  v_fees := tfd_fees_clean(p->'fees', p->>'platform');
  if id_ is null then
    insert into shows (type, platform, name, list_id, list_name, list_pct, split_mode, fees, created_by)
      values (p->>'type', p->>'platform', nullif(trim(p->>'name'), ''), lst.id, coalesce(lst.name, 'Full inventory'), lst.pct,
              case when nstream >= 2 then p->>'split_mode' end, v_fees, me.name) returning id into id_;
  else
    select * into s from shows where id = id_ for update;
    if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
    if s.status = 'finalized' then raise exception 'This show is finalized. Unfinalize it to change setup'; end if;
    select count(*) into npulls from pulls where show_id = id_ and status <> 'void';
    if npulls > 0 and (p->>'type' <> s.type or p->>'platform' <> s.platform or lst.id is distinct from s.list_id) then
      raise exception 'Type, platform and inventory can''t change once the show has pulls'; end if;
    update shows set type = p->>'type', platform = p->>'platform', name = nullif(trim(p->>'name'), ''), list_id = lst.id, list_name = coalesce(lst.name, 'Full inventory'),
      list_pct = lst.pct, split_mode = case when nstream >= 2 then p->>'split_mode' end, fees = v_fees,
      export_qty = case when s.list_id is distinct from lst.id then null else export_qty end
      where id = id_;
    delete from show_people where show_id = id_;
  end if;
  insert into show_people (show_id, profile_id, role, hourly_cents, commission_bp, lead)
    select id_, (x->>'profile_id')::bigint, x->>'role', coalesce((x->>'hourly_cents')::int, 0),
           case when x->>'role' = 'assistant' then 0 else coalesce((x->>'commission_bp')::int, 0) end, coalesce((x->>'lead')::boolean, false)
    from jsonb_array_elements(p->'people') x;
  if p_id is null or s.status = 'setup' then perform tfd_show_golive(id_, me.name);
  elsif lst.id is distinct from s.list_id then perform tfd_show_scope(id_); end if;
  select * into s from shows where id = id_;
  lbl := tfd_show_label(s);
  perform tfd_log(me.name, 'Shows', case when p_id is null then 'show_create' else 'show_edit' end,
    case when p_id is null then 'Show created: ' else 'Show setup edited: ' end || lbl || ' (' || case s.platform when 'tiktok' then 'TikTok' else 'Whatnot' end ||
      ' fee ' || coalesce(to_char((v_fees->>'pct_sale_bp')::numeric / 100, 'FM990.##') || '%', 'not set') || ', ' || s.list_name || ', ' ||
      (select string_agg(pr.name || ' ' || sp.role || ' $' || to_char(sp.hourly_cents / 100.0, 'FM999990.00') || '/hr' ||
         case when sp.commission_bp > 0 then ' + ' || to_char(sp.commission_bp / 100.0, 'FM990.##') || '%' else '' end, ', ' order by sp.role desc, pr.name)
       from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = id_) || ')',
    jsonb_build_object('show', id_));
  return id_;
end $$;

create or replace function tfd_show_shifts_save(p_show bigint, p_shifts jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; x jsonb; summary text;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status = 'finalized' then raise exception 'This show is finalized. Unfinalize it to change hours'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_shifts, '[]')) loop
    if not exists (select 1 from show_people where show_id = p_show and profile_id = (x->>'profile_id')::bigint) then
      raise exception 'Add % to the lineup first (Edit setup)', coalesce((select name from profiles where id = (x->>'profile_id')::bigint), 'that person'); end if;
    if nullif(x->>'start_at', '') is null or nullif(x->>'end_at', '') is null then raise exception 'Every row needs a start and an end (date and time)'; end if;
    if (x->>'end_at')::timestamptz <= (x->>'start_at')::timestamptz then
      raise exception '%: the end must be after the start', (select name from profiles where id = (x->>'profile_id')::bigint); end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(coalesce(p_shifts, '[]')) a, jsonb_array_elements(coalesce(p_shifts, '[]')) b
             where a <> b and a->>'profile_id' = b->>'profile_id' and (a->>'start_at')::timestamptz < (b->>'end_at')::timestamptz
               and (b->>'start_at')::timestamptz < (a->>'end_at')::timestamptz) then
    raise exception 'The same person has two time ranges that overlap'; end if;
  delete from show_shifts where show_id = p_show;
  insert into show_shifts (show_id, profile_id, role, start_at, end_at, entered_by)
    select p_show, (j->>'profile_id')::bigint, (select sp.role from show_people sp where sp.show_id = p_show and sp.profile_id = (j->>'profile_id')::bigint),
           (j->>'start_at')::timestamptz, (j->>'end_at')::timestamptz, me.name
    from jsonb_array_elements(coalesce(p_shifts, '[]')) j;
  select string_agg(pr.name || ' ' || to_char(sum_h, 'FM990.00') || 'h', ', ' order by pr.name) into summary
    from (select profile_id, sum(extract(epoch from end_at - start_at)) / 3600.0 sum_h from show_shifts where show_id = p_show group by profile_id) t join profiles pr on pr.id = t.profile_id;
  perform tfd_log(me.name, 'Shows', 'show_hours', 'Hours entered for ' || tfd_show_label(s) || ': ' || coalesce(summary, 'none'), jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_delete(p_ids bigint[], p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; n int := 0; freed int := 0; k int;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  for s in select * from shows where id = any(p_ids) and deleted_at is null order by id for update loop
    if s.status = 'finalized' then raise exception '% is finalized. Unfinalize it before deleting', tfd_show_label(s); end if;
    if s.status = 'matched' then raise exception '% has a CSV imported. Remove the CSV before deleting', tfd_show_label(s); end if;
    update pulls set status = 'released', note = 'show deleted' where show_id = s.id and status = 'held';
    get diagnostics k = row_count; freed := freed + k;
    update shows set deleted_at = now(), deleted_by = me.name, deleted_reason = trim(p_reason) where id = s.id;
    perform tfd_log(me.name, 'Shows', 'show_delete', 'Show deleted: ' || tfd_show_label(s) || ' (' || k || ' held unit(s) freed; restorable)', jsonb_build_object('show', s.id), p_reason);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Nothing to delete'; end if;
  return jsonb_build_object('ok', true, 'deleted', n, 'freed', freed);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_show_comm_bp(shows), tfd_order_fee(show_orders, jsonb, text), tfd_fifo_costs(text, int), tfd_match_one(bigint, boolean), tfd_pick_tz(bigint),
  tfd_show_import(bigint, text, text, jsonb), tfd_order_resolve(bigint, text, bigint, text, text), tfd_show_review(bigint), tfd_show_remove_csv(bigint, text),
  tfd_show_finalize(bigint), tfd_show_unfinalize(bigint, text) from public, anon;
revoke execute on function tfd_show_comm_bp(shows), tfd_order_fee(show_orders, jsonb, text), tfd_fifo_costs(text, int), tfd_match_one(bigint, boolean), tfd_pick_tz(bigint) from authenticated;
grant execute on function tfd_show_import(bigint, text, text, jsonb), tfd_order_resolve(bigint, text, bigint, text, text), tfd_show_review(bigint), tfd_show_remove_csv(bigint, text),
  tfd_show_finalize(bigint), tfd_show_unfinalize(bigint, text) to authenticated;
