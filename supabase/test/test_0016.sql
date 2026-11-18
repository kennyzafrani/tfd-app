-- 0016 checks: pack without clocking in, admin bulk pack (packers can't), inventory value, an order for a never-scanned # added as that exact pull,
-- delete (ignore) an order. Synthetic data only.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;
create or replace function pg_temp.as_kenny() returns void language sql as $$ select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) $$;
create or replace function pg_temp.as_pat() returns void language sql as $$ select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000ff', false) $$;

reset role;
select id as ally from profiles where username = 'ally' \gset
update shows set status = 'ended', ended_at = now() where status in ('live','setup');
update pack_clock set clock_out = now() where clock_out is null;
set role authenticated; select pg_temp.as_kenny();
select tfd_adjust('100001', 'in', 5, 'count correction', null, true);

-- inventory value = Σ remaining × FIFO cost
reset role; select coalesce(sum(qty_remaining::bigint * unit_cost_cents), 0) as iv, coalesce(sum(qty_remaining), 0) as iu from cost_layers \gset
set role authenticated;
select pg_temp.ok((tfd_inventory_value()->>'cost_cents')::bigint = :iv and (tfd_inventory_value()->>'units')::bigint = :iu, 'inventory value at cost');

select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Bulk test","people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s \gset
select tfd_scan(:s, '100001'); select tfd_scan(:s, '100001');
select tfd_show_end(:s, 'SHOW OVER');
select tfd_show_import(:s, 'tt.csv', null, jsonb_build_array(
  jsonb_build_object('line',1,'order_id','B1','product_name','Part 1','part',1,'pull_no',1,'sale_cents',5000,'ship_cents',0,'tracking','9400333333333333333331','package_key','K1','buyer','b1','ship_name','One'),
  jsonb_build_object('line',2,'order_id','B2','product_name','Part 1','part',1,'pull_no',2,'sale_cents',5000,'ship_cents',0,'tracking','9400333333333333333332','package_key','K2','buyer','b2','ship_name','Two'),
  jsonb_build_object('line',3,'order_id','B3','product_name','Part 1','part',1,'pull_no',3,'sale_cents',5000,'ship_cents',0,'tracking','9400333333333333333333','package_key','K3','buyer','b3','ship_name','Three'),
  jsonb_build_object('line',4,'order_id','B4','product_name','Part 1','part',1,'pull_no',4,'sale_cents',5000,'ship_cents',0,'tracking','9400333333333333333334','package_key','K4','buyer','b4','ship_name','Four')));
reset role;
select id as o3 from show_orders where show_id = :s and order_id = 'B3' \gset
select id as o4 from show_orders where show_id = :s and order_id = 'B4' \gset
select pg_temp.ok((select problem from show_orders where id = :o3) = 'no_pull', '#3 never scanned: needs attention');
set role authenticated;
-- #3 was sold but not scanned: add it as Part 1 #3
select tfd_order_resolve(:o3, 'sku', null, '100001', null);
reset role;
select pg_temp.ok((select pl.part = 1 and pl.pull_no = 3 from show_orders o join pulls pl on pl.id = o.pull_id where o.id = :o3), 'added as Part 1 #3 (not Part 0)');
set role authenticated;
-- #4 isn't a real sale: delete it
select pg_temp.fails(format('select tfd_order_resolve(%s, ''ignore'', null, null, '''')', :o4), 'delete needs a reason', '%reason%');
select tfd_order_resolve(:o4, 'ignore', null, null, 'Not a real sale');
select tfd_show_hours_save(:s, now() - interval '1 hour', now() + interval '1 minute', '[]');
select tfd_show_finalize(:s);
reset role;
select pg_temp.ok((select count(*) from packages where show_id = :s) = 3, '3 packages (deleted order left out)');
select id as k1 from packages where show_id = :s and package_key = 'K1' \gset
select id as k2 from packages where show_id = :s and package_key = 'K2' \gset
select id as k3 from packages where show_id = :s and package_key = 'K3' \gset

-- packer packs without clocking in
set role authenticated; select pg_temp.as_pat();
select pg_temp.ok((tfd_pack_data()->>'clock_in') is null, 'Pat not clocked in');
select pg_temp.ok((tfd_pack_scan(:k1, '100001')->>'ok')::boolean, 'scan works without clocking in');
select tfd_pack_photo_add(:k1, 'pkg-x/a.jpg', 1000); select tfd_pack_finish(:k1);
select pg_temp.fails(format('select tfd_pack_bulk(array[%s]::bigint[])', :k2), 'packer cannot bulk pack', '%Admins only%');
-- admin bulk pack
select pg_temp.as_kenny();
select pg_temp.fails('select tfd_pack_bulk(array[]::bigint[])', 'nothing picked', '%Pick at least one%');
select pg_temp.ok((tfd_pack_bulk(array[:k1, :k2, :k3]::bigint[])->>'packed')::int = 2, 'bulk: 2 packed, the already-packed one skipped');
reset role;
select pg_temp.ok((select count(*) from packages where show_id = :s and status = 'packed') = 3, 'all 3 packed');
select pg_temp.ok((select packed_by from packages where id = :k2) = 'Kenny', 'packed by Kenny');
select pg_temp.ok(exists (select 1 from activity_log where summary like 'Marked packed by admin%'), 'bulk pack logged');
-- lot report: confirmed lots only, floor + MSRP, never cost
select id as lot from receipts where status = 'confirmed' order by id limit 1 \gset
set role authenticated; select pg_temp.as_kenny();
create temp table lr as select tfd_lot_report(:lot) j; 
select pg_temp.ok(jsonb_array_length(j->'items') > 0, 'lot report lists the lot''s SKUs') from lr;
select pg_temp.ok((j->'items'->0->>'floor_tiktok')::int > 0, 'TikTok floor on each SKU') from lr;
select pg_temp.ok(not (j::text ~ 'cost'), 'no cost in the lot report') from lr;
reset role;
select pg_temp.ok((select (x->>'floor_tiktok')::int = (tfd_card(x->>'sku', 'tiktok')->>'floor_cents')::int from lr, jsonb_array_elements(j->'items') x where (tfd_card(x->>'sku','tiktok')->>'floor_cents') is not null limit 1), 'same floor as the live screen');
set role authenticated; select pg_temp.as_pat();
select pg_temp.fails(format('select tfd_lot_report(%s)', :lot), 'packer cannot open the lot report', '%Admins only%');
select pg_temp.as_kenny();
select 'ALL 0016 CHECKS PASSED';
