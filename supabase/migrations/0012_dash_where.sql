-- Supabase's safe-update guard refuses an UPDATE without WHERE: add WHERE true to the Dashboard's two temp-table updates.
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
