-- TFD app — Phase 4b: show start/end times, floor recorded at each scan, ad spend, Dashboard + saved filters (Nov 15 2026).

alter table shows add column if not exists show_start_at timestamptz, add column if not exists show_end_at timestamptz,
  add column if not exists ad_spend_cents int not null default 0;
alter table pulls add column if not exists floor_cents int;
alter table show_orders add column if not exists floor_cents int;
create table if not exists dash_saved (id bigserial primary key, name text not null unique, filters jsonb not null, created_by text not null, created_at timestamptz not null default now());
alter table dash_saved enable row level security;
revoke all on dash_saved from anon, authenticated;

-- the floor the streamer saw: recorded when a pull is scanned (or its SKU is changed), never recalculated after
create or replace function tfd_pull_floor_trg() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.sku is distinct from old.sku then
    new.floor_cents := tfd_show_floor(new.sku, (select s from shows s where s.id = new.show_id));
  end if;
  return new;
end $$;
drop trigger if exists pulls_floor on pulls;
create trigger pulls_floor before insert or update of sku on pulls for each row execute function tfd_pull_floor_trg();
-- pulls scanned before today: record the floor once, from their show's fees
update pulls p set floor_cents = tfd_show_floor(p.sku, s) from shows s where s.id = p.show_id and p.floor_cents is null and p.status <> 'sold';

-- ---------------------------------------------------------------- Step 2: show start/end + everyone's hours (inside the show)
create or replace function tfd_show_hours_save(p_show bigint, p_start timestamptz, p_end timestamptz, p_shifts jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; bad text;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status = 'finalized' then raise exception 'This show is finalized. Unfinalize it to change hours'; end if;
  if p_start is null or p_end is null then raise exception 'Enter when the show started and ended'; end if;
  if p_end <= p_start then raise exception 'The show''s end must be after its start'; end if;
  if p_end - p_start > interval '24 hours' then raise exception 'A show can''t be longer than 24 hours. Check the dates'; end if;
  select string_agg(pr.name || ' (' || to_char((x->>'start_at')::timestamptz at time zone 'America/New_York', 'Mon DD HH12:MI AM') || ' – ' ||
                    to_char((x->>'end_at')::timestamptz at time zone 'America/New_York', 'Mon DD HH12:MI AM') || ')', ', ')
    into bad from jsonb_array_elements(coalesce(p_shifts, '[]')) x join profiles pr on pr.id = (x->>'profile_id')::bigint
    where nullif(x->>'start_at', '') is not null and nullif(x->>'end_at', '') is not null
      and ((x->>'start_at')::timestamptz < p_start or (x->>'end_at')::timestamptz > p_end);
  if bad is not null then
    raise exception 'Outside the show''s time (% – %): %', to_char(p_start at time zone 'America/New_York', 'Mon DD HH12:MI AM'), to_char(p_end at time zone 'America/New_York', 'Mon DD HH12:MI AM'), bad;
  end if;
  update shows set show_start_at = p_start, show_end_at = p_end where id = p_show;
  perform tfd_show_shifts_save(p_show, p_shifts);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_ad_spend(p_show bigint, p_cents int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null then raise exception 'No such show'; end if;
  if s.status = 'finalized' then raise exception 'This show is finalized. Unfinalize it to change ad spend'; end if;
  if p_cents is null or p_cents < 0 then raise exception 'Ad spend must be 0 or more'; end if;
  update shows set ad_spend_cents = p_cents where id = p_show;
  perform tfd_log(me.name, 'Shows', 'ad_spend', 'Ad spend for ' || tfd_show_label(s) || ': $' || to_char(s.ad_spend_cents / 100.0, 'FM999990.00') || ' → $' || to_char(p_cents / 100.0, 'FM999990.00'), jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- Dashboard
-- does a moment pass the time filters? (dates, days of week, hour slot; all in Eastern)
create or replace function tfd_dash_t_ok(ts timestamptz, p jsonb) returns boolean language plpgsql immutable as $$
declare l timestamp := ts at time zone 'America/New_York'; hf int := nullif(p->>'hour_from', '')::int; ht int := nullif(p->>'hour_to', '')::int; h int;
begin
  if nullif(p->>'from', '') is not null and l::date < (p->>'from')::date then return false; end if;
  if nullif(p->>'to', '') is not null and l::date > (p->>'to')::date then return false; end if;
  if jsonb_array_length(coalesce(p->'dows', '[]')) > 0 and not (p->'dows') @> to_jsonb(extract(dow from l)::int) then return false; end if;
  if hf is not null and ht is not null and hf <> ht then
    h := extract(hour from l)::int;
    if hf < ht then return h >= hf and h < ht; else return h >= hf or h < ht; end if;
  end if;
  return true;
end $$;

-- hours of [a, b) that pass the time filters (split on hour boundaries)
create or replace function tfd_dash_hours(a timestamptz, b timestamptz, p jsonb) returns numeric language sql immutable as $$
  select coalesce(sum(extract(epoch from least(b, c + interval '1 hour') - greatest(a, c))), 0) / 3600.0
  from generate_series(date_trunc('hour', a), b, interval '1 hour') c where c < b and a < b and tfd_dash_t_ok(greatest(a, c), p) $$;

create or replace function tfd_dash_calc(p jsonb, p_breakdowns boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  arr_b bigint[] := array(select jsonb_array_elements_text(coalesce(p->'shows', '[]'))::bigint);
  arr_pl text[] := array(select jsonb_array_elements_text(coalesce(p->'platforms', '[]')));
  arr_pt int[] := array(select jsonb_array_elements_text(coalesce(p->'parts', '[]'))::int);
  arr_pp bigint[] := array(select jsonb_array_elements_text(coalesce(p->'people', '[]'))::bigint);
  arr_sk text[] := array(select jsonb_array_elements_text(coalesce(p->'skus', '[]')));
  arr_br text[] := array(select lower(jsonb_array_elements_text(coalesce(p->'brands', '[]'))));
  arr_su text[] := array(select lower(jsonb_array_elements_text(coalesce(p->'suppliers', '[]'))));
  arr_lt bigint[] := array(select jsonb_array_elements_text(coalesce(p->'lots', '[]'))::bigint);
  pmin int := nullif(p->>'price_min', '')::int; pmax int := nullif(p->>'price_max', '')::int;
  prod boolean; nb int := coalesce((tfd_get_setting('pricing')->>'near_floor_bp')::int, 500);
  tot jsonb; hrs numeric; hpay numeric; ad numeric; out jsonb;
begin
  prod := cardinality(arr_sk) + cardinality(arr_br) + cardinality(arr_su) + cardinality(arr_lt) + cardinality(arr_pt) > 0 or pmin is not null or pmax is not null;
  -- shows in scope (CSV imported; finalized numbers are final, matched ones are estimates)
  drop table if exists dash_s; drop table if exists dash_o; drop table if exists dash_w;
  create temp table dash_s on commit drop as
    select s.*, tfd_show_fees(s) f, tfd_show_comm_bp(s) cbp from shows s
    where s.deleted_at is null and s.status in ('matched','finalized')
      and (cardinality(arr_b) = 0 or s.id = any(arr_b)) and (cardinality(arr_pl) = 0 or s.platform = any(arr_pl));
  create temp table dash_o on commit drop as
    select so.id, so.show_id, ds.status, ds.platform, pl.part, pl.kind, pl.sku, pr.brand,
      case when ds.type = 'listed' then coalesce(so.placed_at, pl.scanned_at) else pl.scanned_at end at,
      so.sale_cents sale, coalesce(so.floor_cents, pl.floor_cents) flr,
      coalesce(nullif(so.package_key, ''), so.order_id, so.id::text) pkg,
      case when ds.status = 'finalized' then so.fee_cents else tfd_order_fee(so, ds.f, ds.platform) end fee,
      ds.cbp, so.commission_cents locked_comm, so.cost_cents locked_cost, so.fifo,
      lyr.unit_cost_cents est_cost, lyr.supplier, lyr.receipt_id
    from show_orders so join dash_s ds on ds.id = so.show_id join pulls pl on pl.id = so.pull_id join products pr on pr.sku = pl.sku
    left join lateral (
      select cl.unit_cost_cents, r.supplier, r.id receipt_id from cost_layers cl left join receipt_lines rl on rl.id = cl.receipt_line_id left join receipts r on r.id = rl.receipt_id
      where cl.id = coalesce((so.fifo->0->>'layer')::bigint,
        (select c2.id from cost_layers c2 where c2.sku = pl.sku and c2.qty_remaining > 0 order by c2.created_at, c2.id limit 1),
        (select c3.id from cost_layers c3 where c3.sku = pl.sku order by c3.created_at desc, c3.id desc limit 1))) lyr on true
    where so.state = 'matched';
  delete from dash_o where not tfd_dash_t_ok(at, p)
    or (cardinality(arr_pt) > 0 and not part = any(arr_pt)) or (cardinality(arr_sk) > 0 and not sku = any(arr_sk))
    or (cardinality(arr_br) > 0 and not lower(coalesce(brand, '')) = any(arr_br)) or (cardinality(arr_su) > 0 and not lower(coalesce(supplier, '')) = any(arr_su))
    or (cardinality(arr_lt) > 0 and not coalesce(receipt_id, 0) = any(arr_lt)) or (pmin is not null and sale < pmin) or (pmax is not null and sale > pmax);
  alter table dash_o add column comm numeric, add column cost numeric, add column w numeric not null default 1;
  update dash_o set comm = case when status = 'finalized' then locked_comm when fee is null then null else round(cbp * (sale - fee) / 10000.0) end,
                    cost = case when status = 'finalized' then locked_cost else est_cost end
    where true;   -- Supabase refuses an UPDATE with no WHERE
  -- who sold it: the streamer(s) working when it was scanned (split if two); no hours entered → the show's streamers
  create temp table dash_w on commit drop as
    select o.id, x.profile_id, 1.0 / count(*) over (partition by o.id) w from dash_o o
    cross join lateral (
      select h.profile_id from show_shifts h where h.show_id = o.show_id and h.role = 'streamer' and o.at >= h.start_at and o.at < h.end_at
      union select sp.profile_id from show_people sp where sp.show_id = o.show_id and sp.role = 'streamer'
        and not exists (select 1 from show_shifts h where h.show_id = o.show_id and h.role = 'streamer' and o.at >= h.start_at and o.at < h.end_at)) x;
  if cardinality(arr_pp) > 0 then
    update dash_o o set w = coalesce((select sum(w.w) from dash_w w where w.id = o.id and w.profile_id = any(arr_pp)), 0) where true;
    delete from dash_o where w = 0;
  end if;

  -- hours, hourly pay and ad spend (not shown with product/Part filters)
  if not prod then
    if cardinality(arr_pp) > 0 then
      select coalesce(sum(tfd_dash_hours(h.start_at, h.end_at, p)), 0), coalesce(sum(tfd_dash_hours(h.start_at, h.end_at, p) * sp.hourly_cents), 0),
             coalesce(sum(case when ds.show_end_at > ds.show_start_at then ds.ad_spend_cents * tfd_dash_hours(h.start_at, h.end_at, p) / (extract(epoch from ds.show_end_at - ds.show_start_at) / 3600.0) end), 0)
        into hrs, hpay, ad
        from show_shifts h join dash_s ds on ds.id = h.show_id join show_people sp on sp.show_id = h.show_id and sp.profile_id = h.profile_id where h.profile_id = any(arr_pp);
    else
      select coalesce(sum(tfd_dash_hours(ds.show_start_at, ds.show_end_at, p)), 0),
             coalesce(sum(case when ds.show_end_at > ds.show_start_at then ds.ad_spend_cents * tfd_dash_hours(ds.show_start_at, ds.show_end_at, p) / (extract(epoch from ds.show_end_at - ds.show_start_at) / 3600.0)
                          when exists (select 1 from dash_o o where o.show_id = ds.id) then ds.ad_spend_cents else 0 end), 0)
        into hrs, ad from dash_s ds;
      select coalesce(sum(tfd_dash_hours(h.start_at, h.end_at, p) * sp.hourly_cents), 0) into hpay
        from show_shifts h join dash_s ds on ds.id = h.show_id join show_people sp on sp.show_id = h.show_id and sp.profile_id = h.profile_id;
    end if;
  end if;

  select jsonb_build_object(
      'revenue_cents', round(coalesce(sum(w * sale) filter (where kind <> 'giveaway'), 0)),
      'fees_cents', round(coalesce(sum(w * fee), 0)),
      'commission_cents', case when cardinality(arr_pp) > 0 then
          round(coalesce((select sum(round(sp.commission_bp * (o2.sale - coalesce(o2.fee, 0)) / 10000.0)) from dash_o o2 join show_people sp on sp.show_id = o2.show_id and sp.role = 'streamer' and sp.profile_id = any(arr_pp)), 0))
        else round(coalesce(sum(w * comm), 0)) end,
      'cost_cents', round(coalesce(sum(w * cost) filter (where kind <> 'giveaway'), 0)),
      'giveaway_cost_cents', round(coalesce(sum(w * cost) filter (where kind = 'giveaway'), 0)),
      'item_profit_cents', round(coalesce(sum(w * (sale - coalesce(fee, 0) - coalesce(comm, 0))), 0) - coalesce(sum(w * cost) filter (where kind <> 'giveaway'), 0)),
      'orders', round(coalesce(sum(w) filter (where kind <> 'giveaway'), 0), 2), 'giveaways', round(coalesce(sum(w) filter (where kind = 'giveaway'), 0), 2),
      'packages', count(distinct show_id::text || '|' || pkg), 'unique_skus', count(distinct sku),
      'below_floor', round(coalesce(sum(w) filter (where kind <> 'giveaway' and flr is not null and sale < flr), 0), 2),
      'near_floor', round(coalesce(sum(w) filter (where kind <> 'giveaway' and flr is not null and sale >= flr and sale < round(flr * (10000 + nb) / 10000.0)), 0), 2),
      'with_floor', round(coalesce(sum(w) filter (where kind <> 'giveaway' and flr is not null), 0), 2),
      'estimate', bool_or(status <> 'finalized'), 'missing_cost', count(*) filter (where cost is null), 'shows', count(distinct show_id))
    into tot from dash_o;
  tot := tot || jsonb_build_object('product_filter', prod, 'near_floor_bp', nb,
    'hours', case when prod then null else round(hrs, 2) end, 'hourly_pay_cents', case when prod then null else round(hpay) end,
    'ad_spend_cents', case when prod then null else round(ad) end,
    'refunds', 0, 'refunds_cents', 0,
    'net_profit_cents', case when prod then null else (tot->>'item_profit_cents')::numeric - round(hpay) - round(ad) - (tot->>'giveaway_cost_cents')::numeric end);
  out := jsonb_build_object('totals', tot);
  if not p_breakdowns then return out; end if;

  out := out || jsonb_build_object(
    'by_streamer', (select coalesce(jsonb_agg(x order by (x->>'revenue_cents')::numeric desc), '[]') from (
        select jsonb_build_object('id', pr.id, 'name', pr.name,
          'revenue_cents', round(coalesce((select sum(w.w * o.sale) from dash_w w join dash_o o on o.id = w.id where w.profile_id = pr.id and o.kind <> 'giveaway'), 0)),
          'orders', round(coalesce((select sum(w.w) from dash_w w join dash_o o on o.id = w.id where w.profile_id = pr.id and o.kind <> 'giveaway'), 0), 2),
          'item_profit_cents', round(coalesce((select sum(w.w * (o.sale - coalesce(o.fee, 0) - coalesce(o.comm, 0) - case when o.kind = 'giveaway' then 0 else coalesce(o.cost, 0) end)) from dash_w w join dash_o o on o.id = w.id where w.profile_id = pr.id), 0)),
          'hours', case when prod then null else round((select coalesce(sum(tfd_dash_hours(h.start_at, h.end_at, p)), 0) from show_shifts h join dash_s ds on ds.id = h.show_id where h.profile_id = pr.id and h.role = 'streamer'), 2) end) x
        from profiles pr where pr.id in (select sp.profile_id from show_people sp join dash_s ds on ds.id = sp.show_id where sp.role = 'streamer')
          and (cardinality(arr_pp) = 0 or pr.id = any(arr_pp))) t),
    'by_sku', (select coalesce(jsonb_agg(x order by (x->>'revenue_cents')::numeric desc), '[]') from (
        select jsonb_build_object('sku', o.sku, 'name', coalesce(max(pr.name), max(concat_ws(' ', pr.brand, pr.model))), 'brand', max(pr.brand),
          'orders', round(sum(o.w) filter (where o.kind <> 'giveaway'), 2), 'revenue_cents', round(coalesce(sum(o.w * o.sale) filter (where o.kind <> 'giveaway'), 0)),
          'item_profit_cents', round(sum(o.w * (o.sale - coalesce(o.fee, 0) - coalesce(o.comm, 0) - case when o.kind = 'giveaway' then 0 else coalesce(o.cost, 0) end))),
          'below_floor', round(coalesce(sum(o.w) filter (where o.kind <> 'giveaway' and o.flr is not null and o.sale < o.flr), 0), 2)) x
        from dash_o o join products pr on pr.sku = o.sku group by o.sku order by sum(o.w * o.sale) desc limit 200) t),
    'by_brand', (select coalesce(jsonb_agg(x order by (x->>'revenue_cents')::numeric desc), '[]') from (
        select jsonb_build_object('brand', coalesce(o.brand, '(none)'), 'orders', round(sum(o.w) filter (where o.kind <> 'giveaway'), 2),
          'revenue_cents', round(coalesce(sum(o.w * o.sale) filter (where o.kind <> 'giveaway'), 0)),
          'item_profit_cents', round(sum(o.w * (o.sale - coalesce(o.fee, 0) - coalesce(o.comm, 0) - case when o.kind = 'giveaway' then 0 else coalesce(o.cost, 0) end)))) x
        from dash_o o group by o.brand) t),
    'by_show', (select coalesce(jsonb_agg(x order by (x->>'at') desc), '[]') from (
        select jsonb_build_object('id', ds.id, 'label', tfd_show_label((select s2 from shows s2 where s2.id = ds.id)), 'platform', ds.platform, 'status', ds.status,
          'at', coalesce(ds.show_start_at, ds.started_at, ds.created_at),
          'streamers', (select coalesce(jsonb_agg(pr.name order by pr.name), '[]') from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = ds.id and sp.role = 'streamer'),
          'hours', case when prod then null else round(tfd_dash_hours(ds.show_start_at, ds.show_end_at, p), 2) end,
          'orders', round(coalesce((select sum(o.w) from dash_o o where o.show_id = ds.id and o.kind <> 'giveaway'), 0), 2),
          'revenue_cents', round(coalesce((select sum(o.w * o.sale) from dash_o o where o.show_id = ds.id and o.kind <> 'giveaway'), 0)),
          'item_profit_cents', round(coalesce((select sum(o.w * (o.sale - coalesce(o.fee, 0) - coalesce(o.comm, 0) - case when o.kind = 'giveaway' then 0 else coalesce(o.cost, 0) end)) from dash_o o where o.show_id = ds.id), 0)),
          'net_profit_cents', case when prod or cardinality(arr_pp) > 0 then null else round(
              coalesce((select sum(o.w * (o.sale - coalesce(o.fee, 0) - coalesce(o.comm, 0) - coalesce(o.cost, 0))) from dash_o o where o.show_id = ds.id), 0)
            - coalesce((select sum(tfd_dash_hours(h.start_at, h.end_at, p) * sp.hourly_cents) from show_shifts h join show_people sp on sp.show_id = h.show_id and sp.profile_id = h.profile_id where h.show_id = ds.id), 0)
            - case when ds.show_end_at > ds.show_start_at then ds.ad_spend_cents * tfd_dash_hours(ds.show_start_at, ds.show_end_at, p) / (extract(epoch from ds.show_end_at - ds.show_start_at) / 3600.0) else ds.ad_spend_cents end) end) x
        from dash_s ds where exists (select 1 from dash_o o where o.show_id = ds.id) or (not prod and tfd_dash_hours(ds.show_start_at, ds.show_end_at, p) > 0)) t),
    'pending_shows', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', tfd_show_label(s), 'platform', s.platform, 'status', s.status,
          'at', coalesce(s.show_start_at, s.started_at, s.created_at)) order by coalesce(s.show_start_at, s.started_at, s.created_at) desc), '[]')
        from shows s where s.deleted_at is null and s.status in ('setup','live','ended')
          and (cardinality(arr_b) = 0 or s.id = any(arr_b)) and (cardinality(arr_pl) = 0 or s.platform = any(arr_pl))));
  return out;
end $$;

-- the Dashboard: filtered totals, the same for the period right before (when a date range is set), breakdowns, filter choices
create or replace function tfd_dashboard(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; cur jsonb; prev jsonb; d1 date := nullif(p->>'from', '')::date; d2 date := nullif(p->>'to', '')::date; n int;
begin
  me := tfd_require('admin');
  cur := tfd_dash_calc(coalesce(p, '{}'), true);
  if d1 is not null and d2 is not null and d2 >= d1 then
    n := d2 - d1 + 1;
    prev := tfd_dash_calc(coalesce(p, '{}') || jsonb_build_object('from', (d1 - n)::text, 'to', (d1 - 1)::text), false);
  end if;
  return cur || jsonb_build_object('previous', prev->'totals', 'previous_range', case when prev is not null then jsonb_build_array((d1 - n)::text, (d1 - 1)::text) end,
    'choices', jsonb_build_object(
      'shows', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', tfd_show_label(s), 'at', coalesce(s.show_start_at, s.started_at, s.created_at), 'status', s.status)
                 order by coalesce(s.show_start_at, s.started_at, s.created_at) desc), '[]') from shows s where s.deleted_at is null and s.status not in ('cancelled')),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name) order by pr.name), '[]') from profiles pr
                 where pr.id in (select profile_id from show_people where role = 'streamer')),
      'brands', (select coalesce(jsonb_agg(b order by b), '[]') from (select distinct brand b from products where brand is not null) x),
      'suppliers', (select coalesce(jsonb_agg(b order by b), '[]') from (select distinct supplier b from receipts where supplier is not null and status = 'confirmed') x),
      'lots', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by id desc), '[]') from receipts where status = 'confirmed')),
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'filters', filters) order by name), '[]') from dash_saved));
end $$;

create or replace function tfd_dash_save(p_name text, p_filters jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_name, '')) = '' then raise exception 'Give the filter a name'; end if;
  insert into dash_saved (name, filters, created_by) values (trim(p_name), coalesce(p_filters, '{}'), me.name)
    on conflict (name) do update set filters = excluded.filters, created_by = excluded.created_by, created_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_dash_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('admin');
  delete from dash_saved where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- review / finalize: floor recorded at scan, show times, ad spend
create or replace function tfd_show_review(p_show bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles; s shows; f jsonb; cbp int; fp int; nb int := coalesce((tfd_get_setting('pricing')->>'near_floor_bp')::int, 500); imp show_imports; orders jsonb; pay jsonb; tot jsonb; fin boolean;
begin
  me := tfd_require('admin');
  s := tfd_show_get(p_show);
  f := tfd_show_fees(s); cbp := tfd_show_comm_bp(s); fp := (tfd_get_setting('pricing')->>'floor_profit_bp')::int; fin := s.status = 'finalized';
  select * into imp from show_imports where show_id = p_show and removed_at is null order by id desc limit 1;
  if imp.id is null then return jsonb_build_object('import', null); end if;
  with o as (
    select o.*, coalesce(o.floor_cents, pl.floor_cents) flr, pl.sku, pl.kind, pl.part pl_part, pl.pull_no pl_no, pl.scanned_at, pl.from_order = o.id added,
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
      'floor_cents', m.flr,
      'below_floor', m.state = 'matched' and m.kind <> 'giveaway' and m.flr is not null and m.sale_cents < m.flr,
      'near_floor', m.state = 'matched' and m.kind <> 'giveaway' and m.flr is not null and m.sale_cents >= m.flr and m.sale_cents < round(m.flr * (10000 + nb) / 10000.0))
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
      'near_floor', count(*) filter (where (x->>'near_floor')::boolean),
      'needs_match', count(*) filter (where x->>'state' = 'needs_match'),
      'unacked', count(*) filter (where x->>'state' = 'matched' and x->>'problem' = 'before_scan' and not (x->>'ack')::boolean),
      'ignored', count(*) filter (where x->>'state' = 'ignored'), 'failed', count(*) filter (where x->>'state' = 'failed'),
      'rows', count(*)) from jsonb_array_elements(orders) x);
  pay := (select coalesce(jsonb_agg(jsonb_build_object('profile_id', sp.profile_id, 'name', pr.name, 'role', sp.role, 'hourly_cents', sp.hourly_cents, 'commission_bp', sp.commission_bp,
      'hours', h.hrs, 'hourly_pay_cents', round(h.hrs * sp.hourly_cents)::int,
      'commission_cents', case when sp.role = 'streamer' then coalesce((select sum(round(sp.commission_bp * ((x->>'sale_cents')::int - (x->>'fee_cents')::int) / 10000.0))::int
          from jsonb_array_elements(orders) x where x->>'state' = 'matched' and x->>'fee_cents' is not null), 0) else 0 end)
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
    'show_start_at', s.show_start_at, 'show_end_at', s.show_end_at, 'ad_spend_cents', s.ad_spend_cents, 'near_floor_bp', nb,
    'show_hours', case when s.show_end_at is not null then round(extract(epoch from s.show_end_at - s.show_start_at) / 3600.0, 2) end,
    'blockers', to_jsonb(array_remove(array[
      case when (tot->>'needs_match')::int > 0 then (tot->>'needs_match') || ' order(s) need a match' end,
      case when (tot->>'unacked')::int > 0 then (tot->>'unacked') || ' order(s) placed before their scan need an OK' end,
      case when jsonb_typeof(f->'pct_sale_bp') is distinct from 'number' then 'This show''s platform fee isn''t set (Edit setup)' end,
      case when s.show_start_at is null then 'Enter the show''s start and end time (Step 2)' end], null)),
    'finalized_at', s.finalized_at, 'finalized_by', s.finalized_by);
end $$;

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
  -- lock the floor each pull showed when it was scanned (later floor changes never touch this show)
  update show_orders so set floor_cents = pl.floor_cents from pulls pl where pl.id = so.pull_id and so.show_id = p_show and so.state = 'matched';
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
    totals = (r->'totals') || jsonb_build_object('pay', r->'pay', 'ad_spend_cents', s.ad_spend_cents) where id = p_show;
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
  update show_orders set cost_cents = null, fifo = null, fee_cents = null, commission_cents = null, floor_cents = null where show_id = p_show;
  update pulls set status = 'held' where show_id = p_show and status = 'sold';
  update shows set status = 'matched', finalized_at = null, finalized_by = null, totals = null where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_unfinalize', 'Show unfinalized: ' || tfd_show_label(s) || ' (' || units || ' unit(s) back in inventory; fees stay at this show''s rate)', jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true, 'units', units);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_pull_floor_trg(), tfd_dash_t_ok(timestamptz, jsonb), tfd_dash_hours(timestamptz, timestamptz, jsonb), tfd_dash_calc(jsonb, boolean),
  tfd_show_hours_save(bigint, timestamptz, timestamptz, jsonb), tfd_show_ad_spend(bigint, int), tfd_dashboard(jsonb), tfd_dash_save(text, jsonb), tfd_dash_delete(bigint) from public, anon;
revoke execute on function tfd_pull_floor_trg(), tfd_dash_t_ok(timestamptz, jsonb), tfd_dash_hours(timestamptz, timestamptz, jsonb), tfd_dash_calc(jsonb, boolean) from authenticated;
grant execute on function tfd_show_hours_save(bigint, timestamptz, timestamptz, jsonb), tfd_show_ad_spend(bigint, int), tfd_dashboard(jsonb), tfd_dash_save(text, jsonb), tfd_dash_delete(bigint) to authenticated;
