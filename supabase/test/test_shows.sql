-- Phase 3 (Shows, live) checks. Run after test_phase1/2/3 + migrations 0004-0007 on the same DB.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

reset role;
update profiles set active = true where username = 'ally';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000d', 'bea@staff.local') on conflict do nothing;
select tfd_create_profile('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000d', 'Bea', 'bea', 'streamer') where not exists (select 1 from profiles where username = 'bea');
select id as ally from profiles where username = 'ally' \gset
select id as bea from profiles where username = 'bea' \gset
select id as kenny from profiles where role = 'admin' order by id limit 1 \gset
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
-- whatnot fees so floors exist
select tfd_set_setting('platform.whatnot', '{"label":"Whatnot","pct_sale_bp":800,"pct_ship_bp":800,"fixed_cents":30,"typical_ship_cents":800}');
select tfd_list_save(null, 'Half stock', 'rule', '{}', 50, null) as half \gset

-- setup validation
select pg_temp.fails(format($f$select tfd_show_save(null, '{"type":"live","platform":"tiktok","people":[]}')$f$), 'needs a streamer', '%at least one streamer%');
select pg_temp.fails(format($f$select tfd_show_save(null, '{"type":"listed","platform":"tiktok","people":[{"profile_id":%s,"role":"streamer"}]}')$f$, :ally), 'listed = whatnot', '%Whatnot only%');
select pg_temp.fails(format($f$select tfd_show_save(null, '{"type":"live","platform":"tiktok","people":[{"profile_id":%s,"role":"streamer"},{"profile_id":%s,"role":"streamer"}]}')$f$, :ally, :bea), 'two streamers need split', '%Split evenly%');
select pg_temp.fails(format($f$select tfd_show_save(null, '{"type":"live","platform":"tiktok","people":[{"profile_id":%s,"role":"streamer"}]}')$f$, :kenny), 'admin only as assistant', '%assistant spot%');
select tfd_show_save(null, format('{"type":"live","platform":"whatnot","name":"Halloween $1 starts","list_id":%s,"split_mode":"lead",
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100,"lead":true},{"profile_id":%s,"role":"streamer","hourly_cents":2500,"commission_bp":100},{"profile_id":%s,"role":"assistant","hourly_cents":0}]}', :half, :ally, :bea, :kenny)::jsonb) as s1 \gset
select pg_temp.ok(jsonb_array_length((tfd_show(:s1))->'people') = 3, 'lineup saved');

-- start: % caps fixed from available units
select pg_temp.fails(format('select tfd_scan(%s, ''100001'')', :s1), 'no scans before start', '%Start live%');
select tfd_show_start(:s1);
reset role; select pg_temp.ok((select (caps->>'100001')::int from shows where id = :s1) = 6, '50% cap of 13 = 6');   -- 100001 has 13 on hand set role authenticated;
reset role; select pg_temp.ok((tfd_inv_lock())->>'state' = 'locked', 'inventory locked while live'); set role authenticated;
select pg_temp.fails($$select tfd_adjust('100001', 'in', 1, 'count correction')$$, 'adjust blocked while live', '%locked%');

-- scans hold units, number pulls, track on-air
select (tfd_scan(:s1, '100001', 'aaaaaaaa-0000-0000-0000-000000000001')) as r1 \gset
select pg_temp.ok((:'r1'::jsonb->'pull'->>'pull_no')::int = 1 and (:'r1'::jsonb->'card'->>'available')::int = 12 and :'r1'::jsonb->'card' ? 'floor_cents' and not (:'r1'::jsonb->'card' ? 'cost'), 'pull #1 held, card has floor not cost');
select pg_temp.ok((tfd_scan(:s1, '100001', 'aaaaaaaa-0000-0000-0000-000000000001'))->>'repeat' = 'true', 'offline resend is idempotent');
reset role; select pg_temp.ok((select count(*) from pulls where show_id = :s1) = 1, 'still one pull'); set role authenticated;
select pg_temp.ok((select (r->>'held')::int = 1 and (r->>'available')::int = 12 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'stock shows held');
select tfd_show_on_air(:s1, array[:bea]::bigint[]);
select (tfd_scan(:s1, '100002', null, 'giveaway')) as r2 \gset
select pg_temp.ok((:'r2'::jsonb->'pull'->>'kind') = 'giveaway' and (:'r2'::jsonb->'pull'->'on_air'->>0)::bigint = :bea, 'giveaway, Bea on air');

-- cap: 6 for 100001; 5 more ok then blocked
select tfd_scan(:s1, '100001') from generate_series(1, 5);
select pg_temp.ok((tfd_scan(:s1, '100001'))->>'blocked' = 'cap', '% cap blocks the 7th');

-- outside list needs confirm; out of stock blocked
reset role; insert into products (sku, brand, model, color_code, lens_size, ident, name, bin_id) values ('100099', 'Gucci', 'GG9', '1', '50', tfd_ident('Gucci','GG9','1','50'), 'No stock', (select id from bins where code = 'NOT_ASSIGNED')); set role authenticated;
select pg_temp.ok((tfd_scan(:s1, '100099'))->>'blocked' = 'out', 'out of stock blocked');

-- buyer's choice: shown items hold; pick one, others released
select tfd_bc_open(:s1) as g1 \gset
select pg_temp.fails(format('select tfd_scan(%s, ''100002'')', :s1), 'no normal scans during bc', '%buyer''s choice is open%');
select tfd_bc_add(:g1, '100002'); select tfd_bc_add(:g1, '100003') as bi \gset
reset role; select pg_temp.ok(tfd_held('100003') = 1, 'shown item held'); set role authenticated;
select (tfd_bc_pick(:g1, (:'bi'::jsonb->>'item_id')::bigint)) as pick \gset
reset role; select pg_temp.ok(tfd_held('100002') = 1 and tfd_held('100003') = 1, 'picked held, other released (100002 only holds the giveaway)'); set role authenticated;
select pg_temp.ok((:'pick'::jsonb->'pull'->>'pull_no')::int = 8, 'bc winner gets next pull #');

-- fixes
select pg_temp.ok((tfd_pull_undo_last(:s1))->>'ok' = 'true', 'undo last');
reset role; select pg_temp.ok((select next_pull from shows where id = :s1) = 8, 'undo frees the number'); set role authenticated;
reset role;
select id as p1 from pulls where show_id = :s1 and pull_no = 1 \gset
set role authenticated;
select pg_temp.fails(format($f$select tfd_pull_void(%s, '')$f$, :p1), 'void needs reason', '%reason%');
select tfd_pull_edit(:p1, '100003', 'scanned wrong bag');
reset role; select pg_temp.ok((select sku from pulls where id = :p1) = '100003', 'pull SKU edited'); set role authenticated;
select tfd_show_new_part(:s1);
reset role; select pg_temp.ok((tfd_scan(:s1, '100002'))->'pull'->>'pull_no' = '1' and (select part from shows where id = :s1) = 2, 'Part 2 restarts at #1'); set role authenticated;
select pg_temp.fails(format($f$select tfd_show_set_pull(%s, 1, 'x')$f$, :s1), 'override cannot collide', '%already has%');
select tfd_show_set_pull(:s1, 10, 'restream picked up at 10');

-- pause: adding OK, removing needs confirm, scanning blocked
select tfd_show_pause(:s1, true);
select pg_temp.fails(format('select tfd_scan(%s, ''100003'')', :s1), 'no scans while paused', '%paused%');
select pg_temp.ok((tfd_adjust('100001', 'in', 1, 'count correction'))->>'ok' = 'true', 'paused: adding allowed');
select pg_temp.ok((tfd_adjust('100001', 'out', 1, 'damaged'))->>'needs_confirm' = 'true', 'paused: removing needs confirm');
select tfd_show_pause(:s1, false);

-- streamer can run it but never sees cost or other shows' pay
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
select pg_temp.ok(((tfd_show(:s1))->'people'->0->>'hourly_cents') is null, 'streamer does not see pay');
select pg_temp.ok((tfd_scan(:s1, '100002')) ? 'card', 'streamer can scan (this one hits the % cap)');
select pg_temp.fails($$select tfd_stock()$$, 'streamer no stock/cost', '%Admins only%');
select pg_temp.fails(format('select tfd_show_reopen(%s, ''x'')', :s1), 'reopen admin only', '%Admins only%');

-- end needs SHOW OVER
select pg_temp.fails(format($f$select tfd_show_end(%s, 'done')$f$, :s1), 'end needs phrase', '%SHOW OVER%');
select tfd_show_end(:s1, 'show over');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
reset role; select pg_temp.ok((tfd_inv_lock())->>'state' = 'open', 'lock released after end'); set role authenticated;
reset role; select pg_temp.ok((select status from shows where id = :s1) = 'ended' and tfd_held('100001') >= 1, 'ended; holds stay'); set role authenticated;
select tfd_show_reopen(:s1, 'ended by mistake');
reset role; select pg_temp.ok((select count(*) from show_events where show_id = :s1 and kind = 'reopen') = 1, 'reopened'); set role authenticated;
select tfd_show_end(:s1, 'SHOW OVER');
select pg_temp.ok(jsonb_array_length((tfd_show_mapping(:s1))->'rows') = 9, 'mapping file rows (incl. voided)');

-- listed show: export with oversell warning, lookup holds nothing, live-map wins numbered
select tfd_show_save(null, format('{"type":"listed","platform":"whatnot","people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s2 \gset
select pg_temp.ok((tfd_show_export(:s2))->>'needs_confirm' = 'true', 'oversell warns (held units from show 1)');
select pg_temp.ok(jsonb_array_length((tfd_show_export(:s2, true))->'rows') >= 3, 'export with Yes, I understand');
select tfd_show_start(:s2);
select pg_temp.fails(format('select tfd_scan(%s, ''100001'')', :s2), 'listed scans are lookups', '%lookups%');
select (tfd_lookup(:s2, '100001')) ? 'floor_cents' as lk \gset
reset role; select pg_temp.ok(:'lk'::boolean and tfd_held('100001') = (select count(*) from pulls where sku = '100001' and status = 'held'), 'lookup holds nothing'); set role authenticated;
select tfd_bc_open(:s2) as g2 \gset
select (tfd_bc_add(:g2, '100001'))->>'item_id' as w1 \gset
select pg_temp.ok((tfd_bc_pick(:g2, :w1))->'pull'->>'pull_no' = '1', 'win #1');
select tfd_show_end(:s2, 'SHOW OVER');

-- packer locked out of shows
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.fails($$select tfd_shows()$$, 'packer no shows', '%access to shows%');
reset role;
\echo 'ALL SHOWS DATABASE CHECKS PASSED'
