-- 0013 checks: packages from finalize, packer flow (clock, scan, wrong/too many, undo, photo, finish, problem), queue, pick list,
-- stage sample, bins/stock count sold-not-packed, unpack, unfinalize blocked once packing starts, photo expiry. Synthetic data only.
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
insert into profiles (name, role, username, auth_id, active) values ('Pat', 'packer', 'pat', '00000000-0000-0000-0000-0000000000ff', true) on conflict do nothing;
update shows set status = 'ended', ended_at = now() where status in ('live','setup');
set role authenticated; select pg_temp.as_kenny();
select tfd_adjust('100001', 'in', 4, 'count correction', null, true);
select tfd_adjust('100003', 'in', 4, 'count correction', null, true);

select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Pack test","people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s \gset
select tfd_scan(:s, '100001'); select tfd_scan(:s, '100003'); select tfd_scan(:s, '100001');
select tfd_show_end(:s, 'SHOW OVER');
select tfd_show_import(:s, 'tt.csv', null, jsonb_build_array(
  jsonb_build_object('line',1,'order_id','P1','product_name','Part 1','part',1,'pull_no',1,'sale_cents',5000,'ship_cents',0,'tracking','9400111111111111111111','package_key','PKA','buyer','buyer_a','ship_name','Ann Lee'),
  jsonb_build_object('line',2,'order_id','P2','product_name','Part 1','part',1,'pull_no',2,'sale_cents',5000,'ship_cents',0,'tracking','9400111111111111111111','package_key','PKA','buyer','buyer_a','ship_name','Ann Lee'),
  jsonb_build_object('line',3,'order_id','P3','product_name','Part 1','part',1,'pull_no',3,'sale_cents',5000,'ship_cents',0,'tracking','9400222222222222222222','package_key','PKB','buyer','buyer_b','ship_name','Bo Kim')));
select tfd_show_hours_save(:s, now() - interval '1 hour', now() + interval '1 minute', '[]');
reset role; select tfd_on_hand('100001') oh1_before \gset
set role authenticated;
select tfd_show_finalize(:s);
reset role;
select pg_temp.ok((select count(*) from packages where show_id = :s) = 2, '2 packages: two orders share a tracking #');
select pg_temp.ok(tfd_to_pack('100001') = 2 and tfd_on_hand('100001') = :oh1_before - 2, '100001: 2 sold not packed, on hand down 2');
set role authenticated;
select pg_temp.ok((select (x->>'sold_not_packed')::int = 2 and (x->>'in_bin')::int = (x->>'on_hand')::int + 2 from jsonb_array_elements(tfd_stock()) x where x->>'sku' = '100001'), 'Stock shows sold-not-packed and in-bin');
select pg_temp.ok((select (x->>'need')::int from jsonb_array_elements(tfd_pick_list()) x where x->>'sku' = '100001') = 2, 'pick list: 2 x 100001');
select pg_temp.ok((tfd_pack_queue()->'by_show'->0->>'left')::int = 2, 'queue: 2 left for the show');

-- packer
select pg_temp.as_pat();
select pg_temp.fails('select tfd_pack_queue()', 'packer cannot open the admin queue', '%Admins only%');
reset role; select id as pa from packages where show_id = :s and tracking = '9400111111111111111111' \gset
select id as pb from packages where show_id = :s and tracking = '9400222222222222222222' \gset
set role authenticated;
select pg_temp.fails(format('select tfd_pack_scan(%s, ''100001'')', :pa), 'must clock in', '%Clock in%');
select tfd_pack_clock(true);
select pg_temp.ok(jsonb_array_length(tfd_pack_data()->'packages') >= 2, 'packer sees the packages');
select pg_temp.ok(not (tfd_pack_data()::text ~ 'sale_cents|cost|price'), 'no prices or costs in packer data');
select pg_temp.ok((tfd_pack_scan(:pa, '100001', 'cccccccc-0000-0000-0000-000000000001'))->>'ok' = 'true', 'scan item 1');
select pg_temp.ok((tfd_pack_scan(:pa, '100001', 'cccccccc-0000-0000-0000-000000000001'))->>'repeat' = 'true', 'resent scan not double-counted');
select pg_temp.ok((tfd_pack_scan(:pa, '100001'))->>'error' like 'TOO MANY%', 'one too many blocked');
select pg_temp.ok((tfd_pack_scan(:pa, '100002'))->>'error' like 'WRONG ITEM%', 'wrong SKU blocked');
reset role; update products set upc = '889652000003' where sku = '100003' and upc is null; select upc as u3 from products where sku = '100003' \gset
set role authenticated;
select pg_temp.ok((tfd_pack_scan(:pa, :'u3'))->>'ok' = 'true', 'scan by UPC works');
select pg_temp.fails(format('select tfd_pack_finish(%s)', :pa), 'finish needs a photo', '%photo%');
select tfd_pack_undo(:pa);
select pg_temp.fails(format('select tfd_pack_finish(%s)', :pa), 'finish needs every item', '%Not every item%');
select tfd_pack_scan(:pa, '100003');
select tfd_pack_photo_add(:pa, 'pkg-1/a.jpg', 150000);
select tfd_pack_finish(:pa);
reset role;
select pg_temp.ok((select status from packages where id = :pa) = 'packed', 'package A packed');
select pg_temp.ok(tfd_to_pack('100001') = 1, '100001: 1 left to pack');
set role authenticated;
-- problem on B
select tfd_pack_problem(:pb, 'Item damaged');
select pg_temp.fails(format('select tfd_pack_scan(%s, ''100001'')', :pb), 'problem package locked', '%Problem%');
select tfd_pack_clock(false);

-- admin: resolve, unfinalize blocked, unpack, lookup, stage sample, photo expiry
select pg_temp.as_kenny();
select pg_temp.fails(format('select tfd_show_unfinalize(%s, ''x'')', :s), 'unfinalize blocked once packing started', '%Packing has started%');
select tfd_pack_resolve(:pb, 'Swapped for a new unit');
reset role; select pg_temp.ok((select status from packages where id = :pb) = 'todo', 'resolved back to the queue'); set role authenticated;
select pg_temp.ok(jsonb_array_length(tfd_pack_lookup('9400111111111111111111')) = 1, 'lookup by tracking');
select pg_temp.ok(jsonb_array_length(tfd_pack_lookup('420100019400111111111111111111')) = 1, 'lookup by a scanned label (prefix + tracking)');
select pg_temp.ok(jsonb_array_length(tfd_pack_lookup('P3')) = 1, 'lookup by order #');
select pg_temp.ok(jsonb_array_length(tfd_pack_lookup('bokim')) = 1, 'lookup by name');
select tfd_pack_unpack(:pa, 'finished by mistake');
reset role; select pg_temp.ok((select status from packages where id = :pa) = 'in_progress', 'unpacked back to the queue'); set role authenticated;
select tfd_set_on_stage('100001', true);
select pg_temp.ok((select (x->>'stage_note')::boolean from jsonb_array_elements(tfd_pick_list()) x where x->>'sku' = '100001') is not null, 'pick list has the stage flag');
select tfd_set_on_stage('100001', false);
reset role; update pack_photos set taken_at = now() - interval '61 days' where path = 'pkg-1/a.jpg'; set role authenticated;
select pg_temp.ok((tfd_photos_expired()->0->>'path') = 'pkg-1/a.jpg', 'photo past 60 days listed for deletion');
select tfd_photos_mark_deleted(array[(tfd_photos_expired()->0->>'id')::bigint], null);
select pg_temp.ok(jsonb_array_length(tfd_photos_expired()) = 0, 'expired photo marked deleted');
-- clean up: finish both so later suites aren't affected
select pg_temp.as_pat(); select tfd_pack_clock(true);
select tfd_pack_photo_add(:pa, 'pkg-1/b.jpg', 1000); select tfd_pack_finish(:pa);
select tfd_pack_scan(:pb, '100001'); select tfd_pack_photo_add(:pb, 'pkg-2/a.jpg', 1000); select tfd_pack_finish(:pb); select tfd_pack_clock(false);
select pg_temp.as_kenny();
reset role; select pg_temp.ok(tfd_to_pack('100001') = 0 and tfd_to_pack('100003') = 0, 'all packed'); set role authenticated;
select 'ALL FULFILLMENT CHECKS PASSED';
