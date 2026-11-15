-- 0009 checks: CSV import, matching, fixes, review numbers, finalize / unfinalize, remove CSV. Synthetic data only.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;
-- local ET wall-clock text for "now + minutes", the way TikTok writes it
create or replace function pg_temp.et(mins int) returns text language sql as $$ select to_char((now() + make_interval(mins => mins)) at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI:SS') $$;

reset role;
select id as ally from profiles where username = 'ally' \gset
update shows set status = 'ended', ended_at = now() where status in ('live','setup');
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tfd_adjust('100001', 'in', 5, 'count correction', null, true);
select tfd_adjust('100003', 'in', 5, 'count correction', null, true);

-- ================= TikTok live mapping show
select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Import test","fees":{"pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0},
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s \gset
select tfd_scan(:s, '100001');   -- P1 #1
select tfd_scan(:s, '100001');   -- P1 #2
select tfd_scan(:s, '100003');   -- P1 #3
select tfd_show_new_part(:s);
select tfd_scan(:s, '100003');   -- P2 #1
select tfd_scan(:s, '100001');   -- P2 #2 (no order → released)
select pg_temp.fails(format('select tfd_show_import(%s, ''x.csv'', null, ''[{"line":1}]'')', :s), 'import needs a concluded show', '%Conclude%');
select tfd_show_end(:s, 'SHOW OVER');
reset role; select tfd_on_hand('100001') as oh1 \gset
select tfd_on_hand('100003') as oh3 \gset
set role authenticated;

select tfd_show_import(:s, 'To_Ship_test.csv', null, jsonb_build_array(
  jsonb_build_object('line',1,'order_id','A1','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',1,'sale_cents',5200,'ship_cents',429,'placed_local',pg_temp.et(1),'tracking','T1','package_key','PK1','buyer','b1'),
  jsonb_build_object('line',2,'order_id','A2','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',2,'sale_cents',1900,'ship_cents',130,'placed_local',pg_temp.et(1),'tracking','T2','package_key','PK2','buyer','b2'),
  jsonb_build_object('line',3,'order_id','A3','product_name','Part 2 Test - NO CANCELS','part',2,'pull_no',1,'sale_cents',2800,'ship_cents',0,'placed_local',pg_temp.et(2),'tracking','T2','package_key','PK2','buyer','b2'),
  jsonb_build_object('line',4,'order_id','A4','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',2,'sale_cents',1500,'ship_cents',0,'placed_local',pg_temp.et(2),'buyer','b3'),
  jsonb_build_object('line',5,'order_id','A5','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',3,'sale_cents',3000,'ship_cents',0,'placed_local',pg_temp.et(-5),'buyer','b4'),
  jsonb_build_object('line',6,'order_id','A6','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',1,'sale_cents',999,'ship_cents',0,'placed_local',pg_temp.et(-2880),'buyer','old'),
  jsonb_build_object('line',7,'order_id','A7','product_name','Part 1 Test - NO CANCELS','part',1,'pull_no',9,'sale_cents',2000,'ship_cents',0,'placed_local',pg_temp.et(3),'buyer','b5'))) as imp \gset
select pg_temp.ok(:'imp'::jsonb->>'tz' = 'America/New_York', 'file times read as Eastern: ' || :'imp');
select pg_temp.ok((:'imp'::jsonb->>'released')::int = 1, 'P2 #2 with no order released');
select tfd_show_review(:s) as rv \gset
create temp table rv as select :'rv'::jsonb j;
grant select on rv to authenticated;
create or replace function pg_temp.ord(t text) returns jsonb language sql as $$ select x from rv, jsonb_array_elements(j->'orders') x where x->>'order_id' = t $$;
select pg_temp.ok(pg_temp.ord('A1')->>'state' = 'matched' and pg_temp.ord('A1')->>'sku' = '100001', 'A1 matched to P1 #1');
select pg_temp.ok((pg_temp.ord('A1')->>'fee_cents')::int = 338, 'fee 6% of (52.00 + 4.29) = 3.38: ' || (pg_temp.ord('A1')->>'fee_cents'));
select pg_temp.ok((pg_temp.ord('A1')->>'commission_cents')::int = 49, 'commission 1% of (52.00 - 3.38) = 0.49');
select pg_temp.ok(pg_temp.ord('A3')->>'state' = 'matched' and (pg_temp.ord('A3')->>'pull_part')::int = 2, 'A3 matched to Part 2 #1');
select pg_temp.ok(pg_temp.ord('A4')->>'problem' = 'duplicate', 'second order on P1 #2 = duplicate');
select pg_temp.ok(pg_temp.ord('A5')->>'state' = 'matched' and pg_temp.ord('A5')->>'problem' is null, 'matched by number, time not checked');
select pg_temp.ok(pg_temp.ord('A6')->>'problem' = 'duplicate', 'second order on P1 #1 (any time) = duplicate');
select pg_temp.ok(pg_temp.ord('A7')->>'problem' = 'no_pull', 'no pull #9');
select pg_temp.ok(jsonb_array_length(j->'blockers') = 2, 'blockers: needs match + show times') from rv;
select pg_temp.fails(format('select tfd_show_finalize(%s)', :s), 'finalize blocked', '%need a match%');
-- edits after the import: fee change allowed
select pg_temp.fails(format('select tfd_pull_void(%s, ''x'')', (select (x->>'pull_id') from rv, jsonb_array_elements(j->'orders') x where x->>'order_id' = 'A1')), 'pull fixes locked once matched', '%live or ended%');

-- fixes
select pg_temp.fails(format('select tfd_order_resolve(%s, ''ignore'')', (pg_temp.ord('A4')->>'id')), 'ignore needs reason', '%reason%');
select tfd_order_resolve((pg_temp.ord('A4')->>'id')::bigint, 'ignore', null, null, 'double order, refunded');
select tfd_order_resolve((pg_temp.ord('A6')->>'id')::bigint, 'ignore', null, null, 'test');
select tfd_order_resolve((pg_temp.ord('A7')->>'id')::bigint, 'sku', null, '100003');
-- the released pull can be matched back by hand: unmatch A3 then match it to the released P2 #2? (wrong on purpose, then undo)
reset role; select id as p22 from pulls where show_id = :s and part = 2 and pull_no = 2 \gset
set role authenticated;
select tfd_order_resolve((pg_temp.ord('A3')->>'id')::bigint, 'unmatch');
select tfd_order_resolve((pg_temp.ord('A3')->>'id')::bigint, 'pull', :p22);
reset role; select pg_temp.ok((select status from pulls where id = :p22) = 'held', 'released pull held again when matched');
select pg_temp.ok((select status from pulls where show_id = :s and part = 2 and pull_no = 1) = 'released', 'unmatched pull released'); set role authenticated;
select tfd_order_resolve((pg_temp.ord('A3')->>'id')::bigint, 'unmatch');
reset role; select id as p21 from pulls where show_id = :s and part = 2 and pull_no = 1 \gset
set role authenticated;
select tfd_order_resolve((pg_temp.ord('A3')->>'id')::bigint, 'pull', :p21);

truncate rv; insert into rv select tfd_show_review(:s);
select pg_temp.ok(jsonb_array_length(j->'blockers') = 1, 'only show times left: ' || (j->'blockers')::text) from rv;
select pg_temp.ok((j->'totals'->>'units')::int = 5, '5 matched units') from rv;
select pg_temp.ok((j->'totals'->>'sales_cents')::int = 5200 + 1900 + 2800 + 3000 + 2000, 'sales total') from rv;
select pg_temp.ok((select (x->>'hours')::numeric from jsonb_array_elements(j->'pay') x where x->>'name' = 'Ally') = 0, 'no hours yet') from rv;

-- finalize
select pg_temp.fails(format($f$select tfd_show_hours_save(%s, now() - interval '3 hours', now() - interval '1 hour', '[{"profile_id":%s,"start_at":"%s","end_at":"%s"}]')$f$, :s, :ally, now() - interval '2 hours', now()), 'streamer hours past the show end flagged', '%Outside the show%');
select tfd_show_hours_save(:s, now() - interval '3 hours', now() + interval '1 minute', format('[{"profile_id":%s,"start_at":"%s","end_at":"%s"}]', :ally, now() - interval '2 hours', now())::jsonb);
select tfd_show_finalize(:s) as fin \gset
select pg_temp.ok((:'fin'::jsonb->>'units')::int = 5, 'finalized 5 units');
reset role;
select pg_temp.ok(tfd_on_hand('100001') = :oh1 - 2 and tfd_on_hand('100003') = :oh3 - 3, 'inventory deducted: 2 + 3');
select pg_temp.ok((select status from shows where id = :s) = 'finalized' and (select fees->>'pct_sale_bp' from shows where id = :s) = '600', 'fees locked on the show');
select pg_temp.ok((select count(*) from pulls where show_id = :s and status = 'sold') = 5, '5 pulls sold');
select pg_temp.ok((select count(*) from pulls where show_id = :s and status = 'held') = 0, 'nothing held');
select pg_temp.ok((select count(*) from stock_moves where kind = 'show_sale' and (detail->>'show')::bigint = :s) = 2, 'one sale line per SKU in history');
select pg_temp.ok((select (totals->'pay'->0->>'hourly_pay_cents')::int from shows where id = :s) = 6000, '2h x $30 = $60 locked');
set role authenticated;
select pg_temp.fails(format('select tfd_show_delete(array[%s]::bigint[], ''x'')', :s), 'finalized delete blocked', '%Unfinalize%');
select pg_temp.fails(format('select tfd_show_remove_csv(%s, ''x'')', :s), 'remove CSV blocked when finalized', '%matched show%');
-- settings change never touches a finalized show
reset role; select (tfd_show_review(:s)->'totals'->>'fees_cents') as fees_before \gset
set role authenticated;
select tfd_set_setting('platform.tiktok', '{"label":"TikTok","pct_sale_bp":900,"pct_ship_bp":900,"fixed_cents":0,"typical_ship_cents":800}', null, 'test');
reset role; select pg_temp.ok((tfd_show_review(:s)->'totals'->>'fees_cents') = :'fees_before', 'fees unchanged after Settings change'); set role authenticated;

-- unfinalize
select pg_temp.fails(format('select tfd_show_unfinalize(%s, '''')', :s), 'unfinalize needs reason', '%reason%');
select tfd_show_unfinalize(:s, 'fix a price');
reset role;
select pg_temp.ok(tfd_on_hand('100001') = :oh1 and tfd_on_hand('100003') = :oh3, 'units back after unfinalize');
select pg_temp.ok((select count(*) from pulls where show_id = :s and status = 'held') = 5, 'holds back');
select pg_temp.ok((select status from shows where id = :s) = 'matched', 'back to matched');
set role authenticated;
-- refinalize then unfinalize again (round trip is stable)
select tfd_show_finalize(:s);
select tfd_show_unfinalize(:s, 'again');
reset role; select pg_temp.ok(tfd_on_hand('100001') = :oh1 and tfd_on_hand('100003') = :oh3, 'round trip stable'); set role authenticated;

-- remove CSV: back to Concluded, holds as before the import (manual SKU pull voided)
select tfd_show_remove_csv(:s, 'wrong file');
reset role;
select pg_temp.ok((select status from shows where id = :s) = 'ended', 'back to concluded');
select pg_temp.ok((select count(*) from pulls where show_id = :s and status = 'held') = 5, 'all 5 scanned pulls held again');
select pg_temp.ok((select count(*) from pulls where show_id = :s and from_order is null and part = 0 and status <> 'void') = 0, 'pull added from the CSV voided');
select pg_temp.ok(not exists (select 1 from show_orders where show_id = :s), 'orders cleared');
set role authenticated;

-- ================= Whatnot listed show
select tfd_show_save(null, format('{"type":"listed","platform":"whatnot","fees":{"pct_sale_bp":800,"pct_ship_bp":0,"fixed_cents":30,"typical_ship_cents":800},
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as w \gset
select tfd_record_win(:w, '100003');
select tfd_show_end(:w, 'SHOW OVER');
select tfd_show_import(:w, 'whatnot.csv', null, jsonb_build_array(
  jsonb_build_object('line',1,'order_id','W1','status','paid','product_name','Gucci Square #1','sku','100003','sale_cents',4000,'placed_local',to_char(now() at time zone 'UTC','YYYY-MM-DD HH24:MI:SS'),'tracking','9400','package_key','S1'),
  jsonb_build_object('line',2,'order_id','W2','status','paid','product_name','Aviator #1','sku','100001','sale_cents',3000,'placed_local',to_char(now() at time zone 'UTC','YYYY-MM-DD HH24:MI:SS'),'tracking','9401','package_key','S2'),
  jsonb_build_object('line',3,'order_id','W3','status','paid','product_name','$25 Gift Card','sale_cents',0,'placed_local',to_char(now() at time zone 'UTC','YYYY-MM-DD HH24:MI:SS')),
  jsonb_build_object('line',4,'order_id','W4','status','failed','product_name','Aviator #2','sku','100001','sale_cents',2500))) as wi \gset
truncate rv; insert into rv select tfd_show_review(:w);
select pg_temp.ok(pg_temp.ord('W1')->>'state' = 'matched', 'listed: matched to the win by SKU');
select pg_temp.ok(pg_temp.ord('W2')->>'problem' = 'no_win', 'listed: order with no recorded win');
select pg_temp.ok(pg_temp.ord('W3')->>'problem' = 'no_item', 'gift card row ignored');
select pg_temp.ok(pg_temp.ord('W4')->>'state' = 'failed', 'failed order listed, not a sale');
select pg_temp.ok((pg_temp.ord('W1')->>'fee_cents')::int = 4000 * 8 / 100 + 30, 'whatnot fee 8% + $0.30');
select tfd_order_resolve((pg_temp.ord('W2')->>'id')::bigint, 'sku', null, '100001');
select tfd_show_hours_save(:w, now() - interval '1 hour', now() + interval '1 minute', '[]');
select tfd_show_finalize(:w);
reset role; select pg_temp.ok((select count(*) from pulls where show_id = :w and status = 'sold') = 2, 'listed: 2 sold'); set role authenticated;
select tfd_show_unfinalize(:w, 'test cleanup');
select tfd_show_remove_csv(:w, 'test cleanup');
select 'ALL SHOW IMPORT CHECKS PASSED';
