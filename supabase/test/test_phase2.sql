-- Phase 2 (Inventory) checks. Run after test_phase1.sql on the same DB (needs Kenny + Marco logins).
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if not c then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok((tfd_set_setting('lists', '{"brands":["Ray-Ban","Prada"],"suppliers":["Designer Eyes"],"expense_categories":[]}'))->>'ok' = 'true', 'brands');
-- relax required fields for the test catalog except name/retail/bin
select pg_temp.ok((tfd_set_setting('inventory', '{"required_fields":["product_name","sku","cost","retail_price","bin","quantity"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}'))->>'ok' = 'true', 'req fields');

-- receipt 1: two new products, one short
select tfd_receipt_create('Designer Eyes', 'INV-100', '2026-11-10', '[
  {"brand":"Ray-Ban","model":"RB3025","color_code":"001","lens_size":"58","invoiced_qty":10,"unit_cost_cents":5000,"name":"Ray-Ban Aviator Gold","retail_cents":16300,"bin_code":"a4"},
  {"brand":"prada ","model":"PR 17WS","color_code":"1AB5S0","lens_size":"49","invoiced_qty":5,"received_qty":4,"unit_cost_cents":9000,"name":"Prada Symbole","retail_cents":43000,"bin_code":"A5"},
  {"brand":"Gucci","model":"GG0061S","color_code":"001","lens_size":"56","invoiced_qty":2,"unit_cost_cents":7000}
]') as r1 \gset
select pg_temp.ok(((tfd_receipt(:r1))->'lines'->2->'check'->'problems'->>0) like '%Gucci%isn''t in Settings%', 'unknown brand flagged');
select pg_temp.fails(format('select tfd_receipt_confirm(%s)', :r1), 'confirm blocked by problems', '%Line 3%');
reset role;
select id as gucci_line from receipt_lines where receipt_id = :r1 and line_no = 3 \gset
set role authenticated;
select pg_temp.ok(tfd_receipt_line_delete(:r1, :gucci_line)->>'ok' = 'true', 'delete line');
select tfd_receipt_confirm(:r1) as c1 \gset
select pg_temp.ok((:'c1'::jsonb->>'units')::int = 14 and (:'c1'::jsonb->>'new_skus')::int = 2 and (:'c1'::jsonb->>'cost_cents')::int = 86000, 'confirm totals: 14 units, $860');
select pg_temp.ok(jsonb_array_length(:'c1'::jsonb->'discrepancies') = 1, 'shortage flagged');
select pg_temp.fails(format('select tfd_receipt_confirm(%s)', :r1), 'no double confirm', '%already confirmed%');
reset role;
select pg_temp.ok((select string_agg(sku, ',' order by sku) from products) = '100001,100002', 'SKUs auto-assigned from 100001');
select pg_temp.ok((select code from bins b join products p on p.bin_id = b.id where p.sku = '100001') = 'A4', 'bin uppercased + created');
set role authenticated;

-- receipt 2: same Ray-Ban at a new cost (different spacing/case) -> same SKU, new FIFO layer; near-match for new color
select tfd_receipt_create('Designer Eyes', 'INV-101', '2026-11-11', '[
  {"brand":"RAY-BAN","model":"rb3025","color_code":"001","lens_size":" 58 ","invoiced_qty":5,"unit_cost_cents":6000,"name":"Ray-Ban Aviator GOLD"},
  {"brand":"Ray-Ban","model":"RB3025","color_code":"002","lens_size":"58","invoiced_qty":3,"unit_cost_cents":5500,"name":"Ray-Ban Aviator Black","retail_cents":16300,"bin_code":"A4"}
]') as r2 \gset
select pg_temp.ok((tfd_receipt(:r2))->'lines'->0->'check'->>'status' = 'existing', 'reorder recognized');
select pg_temp.ok((tfd_receipt(:r2))->'lines'->0->'check'->'conflicts'->0->>'field' = 'name', 'name conflict shown');
select pg_temp.ok((tfd_receipt(:r2))->'lines'->1->'check'->>'status' = 'near', 'near-match flagged');
select pg_temp.fails(format('select tfd_receipt_confirm(%s)', :r2), 'near-match must be resolved', '%looks like an existing product%');
reset role;
select id as near_line from receipt_lines where receipt_id = :r2 and line_no = 2 \gset
set role authenticated;
select tfd_receipt_line_save(:r2, :near_line, '{"brand":"Ray-Ban","model":"RB3025","color_code":"002","lens_size":"58","invoiced_qty":3,"unit_cost_cents":5500,"name":"Ray-Ban Aviator Black","retail_cents":16300,"bin_code":"A4","confirmed_new":true}');
select pg_temp.ok((tfd_receipt_confirm(:r2))->>'new_skus' = '1', 'confirmed new color = new SKU');
select pg_temp.ok((select (r->>'on_hand')::int = 15 and (r->>'value_cents')::int = 80000 and (r->>'max_cost_cents')::int = 6000 and r->>'name' = 'Ray-Ban Aviator Gold' from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'stock: 15 units, $800, catalog name kept');

-- floor uses highest cost in stock: $60 cost, $10 shipping (set in phase 1 test) -> (6666.67+60)/0.94 = 71.56 -> $72
select pg_temp.ok((select (r->>'floor_tiktok')::int = 7200 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'floor from highest cost');
select pg_temp.ok((select r->'floor_whatnot' = 'null' from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'whatnot floor not set');

reset role;
select pg_temp.ok((tfd_floor(5000, '{"pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":null}', 100, 1000))->'flags' = '["shipping_not_set"]', 'floor works with shipping not set');
set role authenticated;
-- adjustments: FIFO out takes the $50 layer first
select pg_temp.ok((tfd_adjust('100001', 'out', 2, 'damaged', 'cracked lens'))->>'value_cents' = '10000', 'FIFO out = 2 x $50');
select pg_temp.fails($$select tfd_adjust('100001', 'out', 1, 'bored')$$, 'reason from list', '%Pick a reason%');
select pg_temp.fails($$select tfd_adjust('100001', 'out', 1, '')$$, 'reason required', '%reason is required%');
select pg_temp.ok((tfd_adjust('100001', 'out', 11, 'lost'))->>'needs_confirm' = 'true', 'large adjustment needs confirm');
select pg_temp.fails($$select tfd_adjust('100001', 'out', 99, 'lost', null, true)$$, 'cannot remove more than on hand', '%available to remove%');
select pg_temp.ok((tfd_adjust('100001', 'in', 1, 'count correction'))->>'on_hand' = '14', 'count up at latest cost');

-- bins: move + verify
select pg_temp.ok((tfd_move_sku('100002', 'B1'))->>'ok' = 'true', 'move SKU');
select pg_temp.ok((select jsonb_array_length(b->'skus') from jsonb_array_elements(tfd_bins()) b where b->>'code' = 'B1') = 1, 'bin B1 has the SKU');
select pg_temp.fails($$select tfd_bin_verify('A4', '{"100001": 14}')$$, 'verify needs every SKU', '%missing 100003%');
select pg_temp.ok(jsonb_array_length((tfd_bin_verify('A4', '{"100001": 13, "100003": 3}'))->'differences') = 1, 'verify shows difference');
select pg_temp.ok((tfd_bin_verify('A4', '{"100001": 13, "100003": 3}', true))->>'applied' = 'true', 'verify applies');
select pg_temp.ok((select (r->>'on_hand')::int = 13 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'corrected to 13');

-- lists: manual, rule, % of inventory
select tfd_list_save(null, 'Prada only', 'rule', '{"brands":["prada"]}', null, null) as lp \gset
select tfd_list_save(null, 'Half of everything', 'rule', '{}', 50, null) as lh \gset
select tfd_list_save(null, 'Picks', 'manual', '{}', null, '{100001}') as lm \gset
select pg_temp.ok((select (l->>'count')::int = 1 from jsonb_array_elements(tfd_lists()) l where l->>'name' = 'Prada only'), 'rule list');
select pg_temp.ok((select (l->>'units')::int = 6 + 2 + 1 from jsonb_array_elements(tfd_lists()) l where l->>'name' = 'Half of everything'), '50%: floor(13/2)+floor(4/2)+floor(3/2) = 9');
select pg_temp.fails($$select tfd_list_save(null, 'Picks', 'manual', '{}', null, '{100001}')$$, 'unique list name', '%already exists%');
select pg_temp.fails($$select tfd_list_save(null, 'X', 'manual', '{}', null, '{999999}')$$, 'unknown sku', '%Unknown SKU%');
select pg_temp.ok(jsonb_array_length((tfd_whatnot_export(:lh))->'rows') = 3, 'export rows');
select pg_temp.ok(((tfd_whatnot_export(:lh))->'rows'->0->>'qty')::int = 6, 'export qty = list share');

-- catalog edit
select pg_temp.ok((tfd_product_update('100001', '{"retail_cents":"17000","image_url":"https://example.com/a.jpg"}'))->>'ok' = 'true', 'edit catalog');
select pg_temp.fails($$select tfd_product_update('100001', '{"brand":"Oakley"}')$$, 'identity locked', '%define the product%');

-- undo: receipt 2 blocked (units left stock), adjustment undo works, bin move undo works
reset role;
select id as r2_entry from activity_log where action = 'receipt_confirm' and details->>'receipt' = :'r2' \gset
select id as move_entry from activity_log where action = 'bin_move' \gset
select max(id) as r1_entry from activity_log where action = 'receipt_confirm' and details->>'receipt' = :'r1' \gset
set role authenticated;
select pg_temp.fails(format($f$select tfd_undo(%s, 'test', true)$f$, :r1_entry), 'receipt undo blocked once units left', '%already left stock%');
select pg_temp.ok((tfd_undo(:move_entry, 'test', true))->>'ok' = 'true', 'undo bin move');
select pg_temp.ok((select b->>'code' from jsonb_array_elements(tfd_bins()) b where exists (select 1 from jsonb_array_elements(b->'skus') s where s->>'sku' = '100002')) = 'A5', 'back in A5');
select pg_temp.ok(jsonb_array_length((tfd_sku_history('100001'))->'moves') >= 5, 'sku history');

-- packer locked out
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.fails($$select tfd_stock()$$, 'packer no stock', '%Admins only%');
select pg_temp.fails($$select tfd_adjust('100001', 'out', 1, 'lost')$$, 'packer no adjust', '%Admins only%');
reset role;
select pg_temp.fails($$select * from products$$, 'tables locked', '%permission denied%') from (select set_config('role', 'authenticated', true)) x;
\echo 'ALL PHASE 2 DATABASE CHECKS PASSED'
