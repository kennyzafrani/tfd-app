-- Run against a throwaway DB after supabase_stub.sql + migrations. Every check raises on failure.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if not c then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

-- logins (normally created by Supabase Auth)
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-00000000000a', 'kenny@example.com'),
 ('00000000-0000-0000-0000-00000000000b', 'ally@staff.local'),
 ('00000000-0000-0000-0000-00000000000c', 'marco@staff.local');

-- floor math (spec example: $50 cost, $10 shipping -> $59.74 shown as $60)
select pg_temp.ok((tfd_floor(5000, '{"pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":1000}', 100, 1000)) = '{"exact_cents":5974,"rounded_cents":6000,"flags":[]}'::jsonb, 'floor example');
select pg_temp.ok((tfd_floor(5000, '{"pct_sale_bp":null,"pct_ship_bp":null,"fixed_cents":null,"typical_ship_cents":null}', 100, 1000))->'flags' = '["fees_not_set"]', 'whatnot unset');

-- server creates first admin (service role)
set role service_role;
select pg_temp.fails($$select tfd_create_profile(null, '00000000-0000-0000-0000-00000000000b', 'Ally', 'ally', 'streamer')$$, 'first person must be admin', '%first person%');
select pg_temp.ok(tfd_create_profile(null, '00000000-0000-0000-0000-00000000000a', 'Kenny', null, 'admin') > 0, 'first admin');
select pg_temp.fails($$select tfd_create_profile('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000c', 'X', 'x', 'packer')$$, 'non-admin cannot add', '%Admins only%');
select pg_temp.ok(tfd_create_profile('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'Ally', 'ally', 'streamer') > 0, 'add streamer');
select pg_temp.ok(tfd_create_profile('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000c', 'Marco', 'marco', 'packer') > 0, 'add packer');
reset role;

-- anonymous: no access
set role anon;
select pg_temp.fails($$select tfd_settings()$$, 'anon blocked', '%permission denied%');
select pg_temp.fails($$select * from profiles$$, 'anon cannot read tables', '%permission denied%');
reset role;

select id as marco_id from profiles where name='Marco' \gset
select id as kenny_id from profiles where name='Kenny' \gset
-- as Kenny
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select pg_temp.fails($$select * from settings_history$$, 'tables locked even for signed-in users', '%permission denied%');
select pg_temp.fails($$select tfd_log('Kenny','x','x','fake')$$, 'helpers not callable', '%permission denied%');
select pg_temp.ok((tfd_state())->'me'->>'role' = 'admin', 'state');
select pg_temp.ok((tfd_settings())->'settings'->'platform.tiktok'->>'pct_sale_bp' = '600', 'tiktok 6%');
select pg_temp.ok((tfd_settings())->'roleRates'->'packer'->>'hourly_cents' = '1600', 'packer $16');
select pg_temp.ok((tfd_settings())->'roleRates'->'streamer'->>'commission_bp' = '100', 'streamer 1%');
select pg_temp.ok((tfd_set_setting('platform.tiktok', '{"label":"TikTok","pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":1000}'))->>'ok' = 'true', 'set shipping');
select pg_temp.ok((tfd_floor_preview(5000, 'tiktok'))->>'rounded_cents' = '6000', 'floor preview $60');
select pg_temp.ok((tfd_floor_preview(5000, 'whatnot'))->'flags' = '["fees_not_set"]', 'whatnot preview not set');
select pg_temp.fails($$select tfd_set_setting('platform.tiktok', '{"label":"TikTok","pct_sale_bp":10000,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":1000}')$$, '100% blocked', '%under 100%');
select pg_temp.fails($$select tfd_set_setting('pricing', '{"floor_profit_bp":1500,"near_floor_bp":500}', '2020-01-01')$$, 'past date blocked', '%past%');
select pg_temp.fails($$select tfd_set_setting('pricing', '{"floor_profit_bp":1500}')$$, 'missing field', '%Missing field%');
select pg_temp.fails($$select tfd_set_setting('pricing', '{"floor_profit_bp":15.5,"near_floor_bp":500}')$$, 'decimal bp blocked', '%whole%');
select pg_temp.ok((tfd_set_setting('lists', '{"brands":[" Ray-Ban ","Prada","Ray-Ban",""],"suppliers":[],"expense_categories":[]}'))->>'ok' = 'true', 'lists');
select pg_temp.ok((tfd_settings())->'settings'->'lists'->'brands' = '["Ray-Ban","Prada"]', 'lists trimmed + deduped, order kept');
select pg_temp.ok(jsonb_array_length(tfd_setting_history('platform.tiktok')) = 2, 'history kept');
select pg_temp.ok((tfd_set_rate('user', :'marco_id', 1800, null))->>'ok' = 'true', 'person rate');
select pg_temp.ok((select (u->'rate'->>'hourly_cents')::int = 1800 and u->'rate'->>'source' = 'person' from jsonb_array_elements(tfd_users()) u where u->>'name' = 'Marco'), 'person beats role');
select pg_temp.ok((select (u->'rate'->>'hourly_cents')::int = 3000 from jsonb_array_elements(tfd_users()) u where u->>'name' = 'Ally'), 'role default kept');
select pg_temp.fails(format($f$select tfd_update_user(%s, 'Kenny', 'admin', false)$f$, :kenny_id), 'last admin', '%at least one active admin%');
select pg_temp.fails($$select tfd_set_role('admin', '{"dashboard":"all","cost_profit":true,"inventory_edit":true,"live_mapping":"full","fulfillment":true,"payroll":"all","settings":"no","activity_log":true}')$$, 'admin keeps settings', '%Admins must keep%');
select pg_temp.ok((tfd_set_role('packer', '{"dashboard":"none","cost_profit":false,"inventory_edit":false,"live_mapping":"none","fulfillment":true,"payroll":"own","settings":"no","activity_log":false}'))->>'ok' = 'true', 'role change');

-- activity + undo
reset role;
select max(id) as role_entry from activity_log where action='role_change' \gset
select max(id) as rate_entry from activity_log where action='rate_change' \gset
set role authenticated;
select pg_temp.ok((select count(*) from jsonb_array_elements((tfd_activity())->'rows')) >= 7, 'logged');
select pg_temp.ok(exists (select 1 from jsonb_array_elements((tfd_activity())->'rows') r where r->>'summary' = 'TikTok: typical shipping: not set → $10.00'), 'readable summary');
select pg_temp.fails(format($f$select tfd_undo(%s, '', true)$f$, :role_entry), 'undo needs reason', '%reason%');
select pg_temp.ok((tfd_undo(:role_entry, 'test', true))->>'ok' = 'true', 'undo role');
reset role;
select pg_temp.ok((select perms->>'payroll' from roles where name='packer') = 'none', 'role restored');
set role authenticated;
select pg_temp.fails(format($f$select tfd_undo(%s, 'again', true)$f$, :role_entry), 'no double undo', '%Already undone%');
select pg_temp.ok((tfd_undo(:rate_entry, 'test', true))->>'ok' = 'true', 'undo rate');
select pg_temp.ok((select (u->'rate'->>'hourly_cents')::int = 1600 from jsonb_array_elements(tfd_users()) u where u->>'name' = 'Marco'), 'rate restored to role default');

-- as packer: blocked from admin functions
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok((tfd_state())->'perms'->>'cost_profit' = 'false', 'packer perms');
select pg_temp.fails($$select tfd_settings()$$, 'packer no settings', '%Admins only%');
select pg_temp.fails($$select tfd_activity()$$, 'packer no log', '%Admins only%');
reset role;
\echo 'ALL PHASE 1 DATABASE CHECKS PASSED'
