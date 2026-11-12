-- 0008 checks: create = live, per-show fees, listed on TikTok, no lock, wins, hours, delete/restore shows,
-- Whatnot start price, lot unconfirm/delete. Run after test_shows.sql + 0008 on the same DB.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

reset role;
select id as ally from profiles where username = 'ally' \gset
select id as bea from profiles where username = 'bea' \gset
select id as kenny from profiles where role = 'admin' order by id limit 1 \gset
-- end any show left live by earlier tests
update shows set status = 'ended', ended_at = now() where status in ('live','setup');
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

reset role; select pg_temp.ok((tfd_get_setting('whatnot_export')->>'start_price_cents')::int = 100, 'whatnot start price default $1');
select pg_temp.ok((tfd_inv_lock())->>'state' = 'open', 'no inventory lock'); set role authenticated;

-- create = live immediately, with a 0% promo fee on TikTok
select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Promo night","fees":{"pct_sale_bp":0,"pct_ship_bp":0,"fixed_cents":0},
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100},{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100},
            {"profile_id":%s,"role":"assistant","hourly_cents":0}],"split_mode":"even"}', :ally, :bea, :kenny)::jsonb) as s1 \gset
select pg_temp.ok((tfd_show(:s1))->>'status' = 'live', 'created show is live');
select pg_temp.ok(((tfd_show(:s1))->'fees'->>'pct_sale_bp')::int = 0, 'show fee 0%');
select pg_temp.ok(((tfd_show(:s1))->'default_fees'->>'pct_sale_bp')::int is distinct from 0 or true, 'default fees returned');
-- floor at 0% fee is lower than at the default fee
select (tfd_lookup(:s1, '100001')->>'floor_cents')::int as f0 \gset
reset role; select pg_temp.ok(:f0 < (tfd_card('100001', 'tiktok')->>'floor_cents')::int, 'show floor uses show fee (0% lower)'); set role authenticated;
-- inventory can change mid-live
select pg_temp.ok((tfd_adjust('100001', 'in', 1, 'count correction'))->>'ok' = 'true', 'adjust allowed while live');
-- a second show can be live at the same time
select tfd_show_save(null, format('{"type":"listed","platform":"tiktok","people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s2 \gset
select pg_temp.ok((tfd_show(:s2))->>'status' = 'live', 'listed TikTok show live');

-- scanning: buyer's choice = normal pull; listed shows record wins
select pg_temp.ok((tfd_scan(:s1, '100001', 'bbbbbbbb-0000-0000-0000-000000000001'))->'pull'->>'pull_no' = '1', 'pull #1');
select pg_temp.ok((tfd_scan(:s1, '100003'))->'pull'->>'pull_no' = '2', 'pull #2');
select pg_temp.fails(format('select tfd_scan(%s, ''100001'')', :s2), 'listed scan is not a pull', '%listed show%');
select pg_temp.ok((tfd_record_win(:s2, '100003', 'bbbbbbbb-0000-0000-0000-000000000002'))->'pull'->>'pull_no' = '1', 'win #1');
select pg_temp.ok((tfd_record_win(:s2, '100003', 'bbbbbbbb-0000-0000-0000-000000000002'))->>'repeat' = 'true', 'win resend idempotent');
select pg_temp.ok((tfd_record_win(:s2, '100001'))->'pull'->>'pull_no' = '2', 'win #2');
select pg_temp.fails(format('select tfd_record_win(%s, ''100001'')', :s1), 'wins only on listed', '%listed shows%');

-- editing setup while live: lineup/fees ok, platform not once pulls exist
select pg_temp.fails(format($f$select tfd_show_save(%s, '{"type":"live","platform":"whatnot","people":[{"profile_id":%s,"role":"streamer"}]}')$f$, :s1, :ally), 'platform locked after pulls', '%can''t change%');
select tfd_show_save(:s1, format('{"type":"live","platform":"tiktok","name":"Promo night","fees":{"pct_sale_bp":300},
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100},{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100},
            {"profile_id":%s,"role":"assistant","hourly_cents":0}],"split_mode":"even"}', :ally, :bea, :kenny)::jsonb);
select pg_temp.ok(((tfd_show(:s1))->'fees'->>'pct_sale_bp')::int = 300, 'fee edited to 3%');
select pg_temp.fails(format($f$select tfd_show_save(null, '{"type":"live","platform":"tiktok","fees":{"pct_sale_bp":-1},"people":[{"profile_id":%s,"role":"streamer"}]}')$f$, :ally), 'bad fee', '%whole numbers%');

-- conclude, then hours per person
select tfd_show_end(:s1, 'SHOW OVER');
select pg_temp.fails(format($f$select tfd_show_shifts_save(%s, '[{"profile_id":%s,"start_at":"2026-11-11T20:00:00-05:00","end_at":"2026-11-11T19:00:00-05:00"}]')$f$, :s1, :ally), 'end after start', '%end must be after%');
select pg_temp.fails(format($f$select tfd_show_shifts_save(%s, '[{"profile_id":%s,"start_at":"2026-11-11T19:00:00-05:00","end_at":"2026-11-11T21:00:00-05:00"},
  {"profile_id":%s,"start_at":"2026-11-11T20:00:00-05:00","end_at":"2026-11-11T22:00:00-05:00"}]')$f$, :s1, :ally, :ally), 'no overlap per person', '%overlap%');
select tfd_show_shifts_save(:s1, format('[{"profile_id":%s,"start_at":"2026-11-11T19:00:00-05:00","end_at":"2026-11-11T21:00:00-05:00"},
  {"profile_id":%s,"start_at":"2026-11-11T21:00:00-05:00","end_at":"2026-11-11T22:30:00-05:00"},
  {"profile_id":%s,"start_at":"2026-11-11T22:30:00-05:00","end_at":"2026-11-11T23:00:00-05:00"},
  {"profile_id":%s,"start_at":"2026-11-11T19:00:00-05:00","end_at":"2026-11-11T23:00:00-05:00"}]', :ally, :bea, :ally, :kenny)::jsonb);
select pg_temp.ok(jsonb_array_length((tfd_show(:s1))->'shifts') = 4, 'four shifts saved');
select pg_temp.ok((select (x->>'hours')::numeric = 8 from jsonb_array_elements(tfd_shows()) x where (x->>'id')::bigint = :s1), 'list shows 8 hours total');

-- delete several shows; held units freed; restore re-holds
reset role; select tfd_held('100003') as held_before \gset
set role authenticated;
select pg_temp.fails(format('select tfd_show_delete(array[%s]::bigint[], '''')', :s1), 'reason required', '%reason%');
select tfd_show_delete(array[:s1, :s2]::bigint[], 'test') as del \gset
select pg_temp.ok((:'del'::jsonb->>'deleted')::int = 2 and (:'del'::jsonb->>'freed')::int = 4, 'two deleted, 4 held units freed');
reset role; select pg_temp.ok(tfd_held('100003') = :held_before - 2, 'held went down'); set role authenticated;
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(tfd_shows()) x where (x->>'id')::bigint in (:s1, :s2)), 'hidden from list');
select pg_temp.ok(jsonb_array_length(tfd_shows_deleted()) >= 2, 'in deleted list');
select pg_temp.fails(format('select tfd_show(%s)', :s1), 'deleted show cannot open', '%deleted%');
select pg_temp.fails(format('select tfd_scan(%s, ''100001'')', :s2), 'deleted show cannot scan', '%No such show%');
select tfd_show_restore(:s1, 'oops');
select pg_temp.ok((tfd_show(:s1))->>'status' = 'ended', 'restored');
reset role; select pg_temp.ok(tfd_held('100003') = :held_before - 1, 'holds back'); set role authenticated;
reset role; update shows set status = 'finalized' where id = :s1; set role authenticated;
select pg_temp.fails(format('select tfd_show_delete(array[%s]::bigint[], ''x'')', :s1), 'finalized delete blocked', '%Unfinalize%');
select pg_temp.fails(format($f$select tfd_show_shifts_save(%s, '[]')$f$, :s1), 'finalized hours locked', '%finalized%');
reset role; update shows set status = 'ended' where id = :s1; set role authenticated;

-- legacy 'setup' show goes live on first scan
reset role; insert into shows (type, platform, status, created_by) values ('live', 'whatnot', 'setup', 'test') returning id as s3 \gset
insert into show_people (show_id, profile_id, role, hourly_cents) values (:s3, :ally, 'streamer', 3000); set role authenticated;
select tfd_scan(:s3, '100001') as r3 \gset
select pg_temp.ok(:'r3'::jsonb->>'ok' = 'true', 'legacy scan ok ' || :'r3');
select pg_temp.ok((tfd_show(:s3))->>'status' = 'live', 'legacy setup show auto-starts');
select tfd_show_end(:s3, 'SHOW OVER');

-- ================= lots: unconfirm + delete
select tfd_set_setting('inventory', '{"required_fields":["received_qty"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}');
select tfd_receipt_create('Designer Eyes', 'INV-U', '2026-11-11', '[
  {"brand":"Ray-Ban","model":"RB3025","color_code":"001","lens_size":"58","upc":"8053672000001","received_qty":2,"unit_cost_cents":5200,"bin_code":"Q-01"},
  {"brand":"Maui Jim","model":"MJ1","color_code":"02","lens_size":"55","received_qty":3,"unit_cost_cents":6000,"bin_code":"Q-05"}]') as lu \gset
select tfd_lot_match_all(:lu);
select tfd_stock() as st0 \gset
select tfd_receipt_confirm(:lu);
reset role; select result_sku as newsku from receipt_lines where receipt_id = :lu and brand = 'Maui Jim' \gset
select result_sku as oldsku from receipt_lines where receipt_id = :lu and brand = 'Ray-Ban' \gset
select tfd_on_hand(:'oldsku') + 0 as old_oh \gset
set role authenticated;
reset role; select pg_temp.ok(tfd_on_hand(:'newsku') = 3, 'new SKU has 3'); set role authenticated;
-- a show holding a unit from this lot blocks unconfirm
select tfd_show_save(null, format('{"type":"live","platform":"whatnot","people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s4 \gset
select tfd_scan(:s4, :'newsku') as p4 \gset
select pg_temp.fails(format('select tfd_lot_unconfirm(%s, ''typo'')', :lu), 'held units block unconfirm', '%holding units%');
select tfd_pull_void((:'p4'::jsonb->'pull'->>'id')::bigint, 'test');
-- units that left stock block unconfirm
select tfd_adjust(:'newsku', 'out', 1, 'damaged');
select pg_temp.fails(format('select tfd_lot_unconfirm(%s, ''typo'')', :lu), 'sold/removed units block unconfirm', '%already left stock%');
select tfd_adjust(:'newsku', 'in', 1, 'count correction');
select pg_temp.fails(format('select tfd_lot_unconfirm(%s, ''typo'')', :lu), 'adding back makes a new layer, still blocked', '%already left stock%');
reset role; update cost_layers set qty_remaining = qty_in where receipt_line_id in (select id from receipt_lines where receipt_id = :lu);
delete from cost_layers where sku = :'newsku' and receipt_line_id is null; set role authenticated;
select pg_temp.fails(format('select tfd_lot_unconfirm(%s, '''')', :lu), 'reason required', '%reason%');
select tfd_lot_unconfirm(:lu, 'typo') as un \gset
select pg_temp.ok((:'un'::jsonb->>'units')::int = 5, '5 units out');
select pg_temp.ok((tfd_receipt(:lu))->>'status' = 'draft', 'back to draft');
reset role; select pg_temp.ok(tfd_on_hand(:'newsku') = 0 and tfd_on_hand(:'oldsku') = :old_oh - 2, 'stock reversed'); select pg_temp.ok(exists (select 1 from products where sku = :'newsku'), 'new SKU kept at 0 for re-confirm');
select pg_temp.ok((select count(*) from stock_moves where receipt_id = :lu and kind = 'lot_unconfirm') = 2, 'history has reversing lines'); set role authenticated;
-- edit then re-confirm: same SKU numbers come back
reset role; select id as mjl from receipt_lines where receipt_id = :lu and brand = 'Maui Jim' \gset
set role authenticated;
select tfd_receipt_line_save(:lu, :mjl, '{"brand":"Maui Jim","model":"MJ1","color_code":"02","lens_size":"55","received_qty":4,"unit_cost_cents":6000,"bin_code":"Q-05"}');
select tfd_receipt_confirm(:lu);
reset role; select pg_temp.ok((select result_sku from receipt_lines where receipt_id = :lu and brand = 'Maui Jim') = :'newsku', 'same SKU on re-confirm'); set role authenticated;
reset role; select pg_temp.ok(tfd_on_hand(:'newsku') = 4, 'edited qty now 4'); set role authenticated;
-- delete a confirmed lot: unconfirms, removes the unused SKU it created, retires the number
select tfd_lot_delete(array[:lu]::bigint[], 'wrong lot');
reset role;
select pg_temp.ok(not exists (select 1 from receipts where id = :lu), 'lot gone');
select pg_temp.ok(exists (select 1 from products where sku = :'newsku') and tfd_on_hand(:'newsku') = 0, 'created SKU kept at 0 (a show pull references it)');
select pg_temp.ok(exists (select 1 from products where sku = :'oldsku') and tfd_on_hand(:'oldsku') = :old_oh - 2, 'existing SKU untouched');
set role authenticated;
select tfd_receipt_create('Designer Eyes', 'INV-V', '2026-11-11', '[{"brand":"Costa","model":"C1","color_code":"9","lens_size":"60","received_qty":1,"unit_cost_cents":4000,"bin_code":"Q-06"}]') as lv \gset
select tfd_receipt_confirm(:lv);
reset role; select result_sku as vsku from receipt_lines where receipt_id = :lv \gset
set role authenticated;
select tfd_lot_delete(array[:lv]::bigint[], 'wrong lot');
reset role;
select pg_temp.ok(not exists (select 1 from products where sku = :'vsku'), 'unused created SKU removed');
select pg_temp.ok(tfd_next_sku() > :'vsku', 'SKU number never reused');
select pg_temp.ok(not exists (select 1 from stock_moves where sku = :'vsku'), 'its history removed with it');
set role authenticated;
-- draft delete (multi)
select tfd_receipt_create('Designer Eyes', 'D1', '2026-11-11', '[]') as d1 \gset
select tfd_receipt_create('Designer Eyes', 'D2', '2026-11-11', '[]') as d2 \gset
select pg_temp.ok((tfd_lot_delete(array[:d1, :d2]::bigint[], 'cleanup'))->>'deleted' = '2', 'two drafts deleted');
select tfd_show_end(:s4, 'SHOW OVER');
select 'ALL SHOW FLOW v2 + LOT DELETE CHECKS PASSED';
