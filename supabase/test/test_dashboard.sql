-- 0011 checks: show times, floor recorded at scan and locked, ad spend, Dashboard numbers. Synthetic data only.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

reset role;
select id as ally from profiles where username = 'ally' \gset
select id as bea from profiles where username = 'bea' \gset
update profiles set role = 'streamer' where id = :bea;
select date_trunc('hour', now()) - interval '10 hours' as st \gset
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tfd_adjust('100001', 'in', 3, 'count correction', null, true);
select tfd_adjust('100003', 'in', 3, 'count correction', null, true);
select tfd_set_setting('platform.tiktok', '{"label":"TikTok","pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":800}', null, 'test');

select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Dash test","split_mode":"even",
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100},{"profile_id":%s,"role":"streamer","hourly_cents":2000,"commission_bp":0}]}', :ally, :bea)::jsonb) as s \gset
select tfd_scan(:s, '100001') as p1 \gset
select tfd_scan(:s, '100003') as p2 \gset
reset role;
select pg_temp.ok((select floor_cents from pulls where id = (:'p1'::jsonb->'pull'->>'id')::bigint) = (:'p1'::jsonb->'card'->>'floor_cents')::int, 'floor recorded at scan = floor shown');
update pulls set scanned_at = :'st'::timestamptz + interval '1 hour' where id = (:'p1'::jsonb->'pull'->>'id')::bigint;
update pulls set scanned_at = :'st'::timestamptz + interval '6 hours' where id = (:'p2'::jsonb->'pull'->>'id')::bigint;
update shows set started_at = :'st'::timestamptz where id = :s;
select (:'p1'::jsonb->'card'->>'floor_cents')::int as f1 \gset
set role authenticated;
select tfd_show_end(:s, 'SHOW OVER');
select tfd_show_import(:s, 'tt.csv', null, jsonb_build_array(
  jsonb_build_object('line',1,'order_id','D1','product_name','Part 1 x','part',1,'pull_no',1,'sale_cents',:f1 - 100,'ship_cents',0,'tracking','K1','package_key','K1'),
  jsonb_build_object('line',2,'order_id','D2','product_name','Part 1 x','part',1,'pull_no',2,'sale_cents',30000,'ship_cents',0,'tracking','K2','package_key','K2')));
-- the floor setting changes after the scan: the recorded floor doesn't
select tfd_set_setting('pricing', '{"floor_profit_bp":5000,"near_floor_bp":500}', null, 'test');
reset role; select pg_temp.ok((select floor_cents from pulls where id = (:'p1'::jsonb->'pull'->>'id')::bigint) = :f1, 'floor setting change leaves the recorded floor alone'); set role authenticated;
select pg_temp.ok((select (x->>'below_floor')::boolean from jsonb_array_elements(tfd_show_review(:s)->'orders') x where x->>'order_id' = 'D1'), 'D1 sold $1 under the floor it showed → below floor');

-- Step 2: show times; a streamer outside them is flagged
select pg_temp.fails(format($f$select tfd_show_hours_save(%s, '%s', '%s', '[{"profile_id":%s,"start_at":"%s","end_at":"%s"}]')$f$,
  :s, :'st', (:'st'::timestamptz + interval '10 hours'), :bea, (:'st'::timestamptz + interval '5 hours'), (:'st'::timestamptz + interval '11 hours')), 'Bea past the show end is flagged', '%Outside the show%');
select tfd_show_hours_save(:s, :'st', :'st'::timestamptz + interval '10 hours', format('[{"profile_id":%s,"start_at":"%s","end_at":"%s"},{"profile_id":%s,"start_at":"%s","end_at":"%s"}]',
  :ally, :'st', :'st'::timestamptz + interval '5 hours', :bea, :'st'::timestamptz + interval '5 hours', :'st'::timestamptz + interval '10 hours')::jsonb);
select tfd_show_ad_spend(:s, 1000);
select tfd_show_finalize(:s);
reset role;
select pg_temp.ok((select floor_cents from show_orders where order_id = 'D1' and show_id = :s) = :f1, 'floor locked on the order at finalize');
set role authenticated;
select pg_temp.fails(format('select tfd_show_ad_spend(%s, 5)', :s), 'ad spend locked after finalize', '%finalized%');

-- Dashboard, scoped to this show
create temp table d as select tfd_dashboard(jsonb_build_object('shows', jsonb_build_array(:s))) j;
grant select on d to authenticated;
select pg_temp.ok((j->'totals'->>'revenue_cents')::int = :f1 - 100 + 30000, 'revenue') from d;
select pg_temp.ok((j->'totals'->>'hours')::numeric = 10, 'show hours = 10 (from the show times)') from d;
select pg_temp.ok((j->'totals'->>'hourly_pay_cents')::int = 5 * 3000 + 5 * 2000, 'hourly pay 5h x $30 + 5h x $20') from d;
select pg_temp.ok((j->'totals'->>'ad_spend_cents')::int = 1000, 'ad spend') from d;
select pg_temp.ok((j->'totals'->>'below_floor')::numeric = 1 and (j->'totals'->>'orders')::numeric = 2 and (j->'totals'->>'packages')::int = 2, 'orders, packages, below floor') from d;
select pg_temp.ok((j->'totals'->>'net_profit_cents')::numeric = (j->'totals'->>'item_profit_cents')::numeric - 25000 - 1000 - (j->'totals'->>'giveaway_cost_cents')::numeric, 'net = item − hourly − ad − giveaways') from d;
select pg_temp.ok(not (j->'totals'->>'estimate')::boolean, 'finalized → not an estimate') from d;
select pg_temp.ok((select (x->>'revenue_cents')::int from jsonb_array_elements(j->'by_streamer') x where (x->>'id')::bigint = :ally) = :f1 - 100, 'Ally gets the sale scanned in her hours') from d;
select pg_temp.ok((select (x->>'revenue_cents')::int from jsonb_array_elements(j->'by_streamer') x where (x->>'id')::bigint = :bea) = 30000, 'Bea gets hers') from d;
-- one streamer
truncate d; insert into d select tfd_dashboard(jsonb_build_object('shows', jsonb_build_array(:s), 'people', jsonb_build_array(:ally)));
select pg_temp.ok((j->'totals'->>'revenue_cents')::int = :f1 - 100 and (j->'totals'->>'hours')::numeric = 5 and (j->'totals'->>'hourly_pay_cents')::int = 15000 and (j->'totals'->>'ad_spend_cents')::int = 500,
  'Ally: her sale, 5h, $150 pay, half the ad spend: ' || (j->'totals')::text) from d;
-- hour slot: first 2 hours of the show
truncate d; insert into d select tfd_dashboard(jsonb_build_object('shows', jsonb_build_array(:s),
  'hour_from', extract(hour from :'st'::timestamptz at time zone 'America/New_York')::int, 'hour_to', extract(hour from (:'st'::timestamptz + interval '2 hours') at time zone 'America/New_York')::int));
select pg_temp.ok((j->'totals'->>'hours')::numeric = 2 and (j->'totals'->>'revenue_cents')::int = :f1 - 100, 'time slot: 2 hours inside it, only the sale in it: ' || (j->'totals')::text) from d;
-- product filter: hours and net hidden
truncate d; insert into d select tfd_dashboard(jsonb_build_object('shows', jsonb_build_array(:s), 'skus', jsonb_build_array('100003')));
select pg_temp.ok((j->'totals'->>'hours') is null and (j->'totals'->>'net_profit_cents') is null and (j->'totals'->>'revenue_cents')::int = 30000, 'SKU filter: product numbers only') from d;
-- date range → previous period
truncate d; insert into d select tfd_dashboard(jsonb_build_object('from', (current_date - 6)::text, 'to', current_date::text));
select pg_temp.ok(j->'previous' is not null and j->'previous_range'->>0 = (current_date - 13)::text, 'previous 7 days compared') from d;
-- saved filters
select tfd_dash_save('Ally last 30', '{"preset":"last30","people":[1]}');
select pg_temp.ok(jsonb_array_length(tfd_dashboard('{}')->'saved') = 1, 'saved filter listed');
select tfd_dash_delete((tfd_dashboard('{}')->'saved'->0->>'id')::bigint);
-- unfinalize keeps the floor from the scan
select tfd_show_unfinalize(:s, 'test');
reset role; select pg_temp.ok((select floor_cents from pulls where id = (:'p1'::jsonb->'pull'->>'id')::bigint) = :f1, 'floor from the scan kept after unfinalize');
set role authenticated;
select tfd_set_setting('pricing', '{"floor_profit_bp":1000,"near_floor_bp":500}', null, 'test');
select 'ALL DASHBOARD CHECKS PASSED';
