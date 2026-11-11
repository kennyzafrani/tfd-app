-- Phase 2b (lots) checks. Run after test_phase1.sql + test_phase2.sql + migration 0003 on the same DB.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if not c then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;

reset role;
select pg_temp.ok((select name from receipts order by id limit 1) = 'Designer Eyes · INV-100 · 2026-11-10', 'existing lots named');
select pg_temp.ok((select count(*) from products p join bins b on b.id = p.bin_id) = (select count(*) from products), 'every SKU has a bin');
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

-- requirements: only cost + received qty
select pg_temp.ok((tfd_set_setting('inventory', '{"required_fields":["received_qty"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}'))->>'ok' = 'true', 'req: received only');
select pg_temp.ok((tfd_product_update('100001', '{"upc":"8053672000001"}'))->>'ok' = 'true', 'give 100001 a UPC');
select pg_temp.fails($$select tfd_product_update('100002', '{"upc":"8053672000001"}')$$, 'UPC unique on edit', '%already on SKU 100001%');
select pg_temp.fails($$select tfd_product_update('100003', '{"color_code":"001"}')$$, 'identity collision on edit', '%already belong to SKU 100001%');
select pg_temp.ok((tfd_product_update('100003', '{"model":"RB3025 ","name":"Aviator Black"}'))->>'ok' = 'true', 'edit identity fields');

-- lot with no supplier, a UPC returning piece, a brand-new partial-identity piece, a near match
select tfd_receipt_create('', '', '2026-11-12', '[
  {"upc":"8053672000001","received_qty":3,"unit_cost_cents":5200},
  {"brand":"Oakley","model":"OO9208","received_qty":2,"unit_cost_cents":7000},
  {"brand":"Ray-Ban","model":"RB3025","color_code":"004","lens_size":"58","received_qty":1,"unit_cost_cents":5000},
  {"brand":"Gucci","model":"GG1","received_qty":1}
]') as r3 \gset
select pg_temp.ok((tfd_receipt(:r3))->>'name' = '2026-11-12', 'name from date only');
select pg_temp.ok((tfd_receipt(:r3))->'lines'->0->'check'->>'status' = 'suggest', 'UPC -> suggest');
select pg_temp.ok((tfd_receipt(:r3))->'lines'->1->'check'->>'status' = 'new', 'partial identity -> new');
select pg_temp.ok((tfd_receipt(:r3))->'lines'->2->'check'->>'status' = 'suggest', 'same brand+model -> suggest');
select pg_temp.ok(((tfd_receipt(:r3))->'lines'->3->'check'->'problems'->0->>'f') = 'unit_cost_cents', 'cost always required');
select pg_temp.ok(jsonb_array_length((tfd_receipt(:r3))->'issues') = 3, 'three issues listed');
select pg_temp.fails(format('select tfd_receipt_confirm(%s)', :r3), 'confirm blocked', '%Row 1%');
select pg_temp.ok((tfd_lot_match_all(:r3))->>'matched' = '1', 'match all = UPC rows only');
select pg_temp.ok((tfd_receipt(:r3))->'lines'->0->'check'->>'status' = 'existing', 'matched');
reset role;
select id as l3 from receipt_lines where receipt_id = :r3 and line_no = 3 \gset
select id as l4 from receipt_lines where receipt_id = :r3 and line_no = 4 \gset
set role authenticated;
select tfd_receipt_line_save(:r3, :l3, '{"brand":"Ray-Ban","model":"RB3025","color_code":"004","lens_size":"58","received_qty":1,"unit_cost_cents":5000,"confirmed_new":true,"bin_code":"c1"}');
select tfd_receipt_line_save(:r3, :l4, '{"brand":"Gucci","model":"GG1","received_qty":1,"unit_cost_cents":6000,"upc":"8053672000001","confirmed_new":true}');
select pg_temp.ok(exists (select 1 from jsonb_array_elements_text((tfd_receipt(:r3))->'issues') x where x like 'Row 4: UPC is already on SKU 100001%'), 'new with taken UPC blocked');
select pg_temp.ok(exists (select 1 from jsonb_array_elements_text((tfd_receipt(:r3))->'issues') x where x like 'Row 4: Same UPC as row 1%'), 'dup UPC inside lot');
select tfd_receipt_line_save(:r3, :l4, '{"brand":"Gucci","model":"GG1","received_qty":1,"unit_cost_cents":6000,"upc":"0000000000777"}');
-- required toggles: make image + lot photo required
select pg_temp.ok((tfd_set_setting('inventory', '{"required_fields":["received_qty","image_url","lot_photo","supplier"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}'))->>'ok' = 'true', 'req: image + photo + supplier');
select pg_temp.ok((select count(*) from jsonb_array_elements_text((tfd_receipt(:r3))->'issues') x where x like '%Image URL is required%') = 3, 'image required on the 3 new rows only');
select pg_temp.ok((select count(*) from jsonb_array_elements_text((tfd_receipt(:r3))->'issues') x where x in ('Supplier is required', 'At least one lot photo is required')) = 2, 'lot-level requirements');
select pg_temp.fails(format($f$select tfd_lot_photo_add(%s, 'lot-999/x.jpg')$f$, :r3), 'photo path must match lot', '%doesn''t belong%');
select tfd_lot_photo_add(:r3, 'lot-' || :r3 || '/box.jpg', 'box');
select tfd_receipt_header(:r3, 'Designer Eyes', 'INV-102', '2026-11-12');
select pg_temp.ok((tfd_receipt(:r3))->>'name' = 'Designer Eyes · INV-102 · 2026-11-12', 'auto name follows header');
select tfd_receipt_header(:r3, 'Designer Eyes', 'INV-102', '2026-11-12', 'Big Nov drop');
select tfd_receipt_header(:r3, 'Designer Eyes', 'INV-103', '2026-11-12');
select pg_temp.ok((tfd_receipt(:r3))->>'name' = 'Big Nov drop', 'custom name kept');
select pg_temp.ok((select count(*) from jsonb_array_elements_text((tfd_receipt(:r3))->'issues')) = 3, 'only image issues left');
select pg_temp.ok((tfd_set_setting('inventory', '{"required_fields":["received_qty"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}'))->>'ok' = 'true', 'req back');
select tfd_receipt_confirm(:r3) as c3 \gset
select pg_temp.ok((:'c3'::jsonb->>'new_skus')::int = 3 and (:'c3'::jsonb->>'units')::int = 7, 'confirm: 3 new SKUs, 7 units');
select pg_temp.ok((select (r->>'on_hand')::int = 16 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'returning piece added to 100001');
select pg_temp.ok((select r->>'bin' from jsonb_array_elements(tfd_stock()) r where r->>'brand' = 'Oakley') = 'NOT_ASSIGNED', 'no bin -> NOT_ASSIGNED');
select pg_temp.ok((select r->>'bin' from jsonb_array_elements(tfd_stock()) r where r->>'color_code' = '004') = 'C1', 'bin set');
select pg_temp.ok(jsonb_array_length((tfd_bin_detail('NOT_ASSIGNED'))->'history') >= 1, 'bin history shows arrival');
select pg_temp.ok((select (r->>'skus')::int from jsonb_array_elements(tfd_receipts()) r where r->>'name' = 'Big Nov drop') = 4, 'lot list: 4 SKUs');
select pg_temp.ok((select r->>'search' ilike '%OO9208%' from jsonb_array_elements(tfd_receipts()) r where r->>'name' = 'Big Nov drop'), 'lot search text');
select pg_temp.ok(jsonb_array_length((tfd_field_values())->'brand') >= 3 and (tfd_field_values())->'bin'->>0 = 'NOT_ASSIGNED', 'dropdown values');
select pg_temp.fails(format($f$select tfd_receipt_header(%s, 'X', 'Y', '2026-01-01')$f$, :r3), 'confirmed lot only renames', '%Only the lot name%');

-- alerts: dismiss until stock changes
select set_config('tfd.oak', (select r->>'sku' from jsonb_array_elements(tfd_stock()) r where r->>'brand' = 'Oakley'), false);
select tfd_alert_dismiss(current_setting('tfd.oak'), 'low');
select pg_temp.ok((select (r->>'low_dismissed')::boolean from jsonb_array_elements(tfd_stock()) r where r->>'sku' = current_setting('tfd.oak')), 'dismissed');
select tfd_adjust(current_setting('tfd.oak'), 'out', 1, 'damaged');
select pg_temp.ok((select not (r->>'low_dismissed')::boolean from jsonb_array_elements(tfd_stock()) r where r->>'sku' = current_setting('tfd.oak')), 'comes back when it drops further');

-- versions + restore
reset role;
select max(tx) as tx_confirm from activity_log where action = 'receipt_confirm' \gset
set role authenticated;
select pg_temp.ok(jsonb_array_length(tfd_versions()) >= 3, 'versions listed');
select tfd_move_sku('100001', 'Z9');
select tfd_adjust('100001', 'out', 5, 'lost', null, true);
select pg_temp.fails(format($f$select tfd_version_restore(%s, 'oops', 'yes')$f$, :tx_confirm), 'must type RESTORE', '%Type RESTORE%');
select tfd_version_restore(:tx_confirm, 'oops', 'RESTORE') as rs \gset
select pg_temp.ok((:'rs'::jsonb->>'actions')::int >= 4, 'reversed later actions');
select pg_temp.ok((select (r->>'on_hand')::int = 16 and r->>'bin' = 'A4' from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'stock + bin back to right after confirm');
select pg_temp.ok((select (r->>'on_hand')::int = 2 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = current_setting('tfd.oak')), 'oakley back to 2');
-- restore the restore: go back to just before it (the adjust of 5)
reset role;
select max(tx) as tx_adj from activity_log where action = 'adjust_out' and summary like '%5 × SKU 100001%' \gset
set role authenticated;
select tfd_version_restore(:tx_adj, 'undo the restore', 'RESTORE');
select pg_temp.ok((select (r->>'on_hand')::int = 11 and r->>'bin' = 'Z9' from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), 'restore is itself reversible');
-- restore to before the lot existed removes its SKUs, lines and the lot itself
reset role;
select min(tx) as tx_before from inv_changes where tx > (select max(tx) from activity_log where action = 'product_edit') - 0 and tbl = 'products' and op = 'U' \gset
select max(id) as pre_lot from activity_log where action = 'product_edit' \gset
select tx as tx_edit from activity_log where id = :pre_lot \gset
set role authenticated;
select tfd_version_restore(:tx_edit, 'back to before the lot', 'RESTORE');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(tfd_receipts()) r where r->>'name' = 'Big Nov drop'), 'lot gone');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(tfd_stock()) r where r->>'brand' = 'Oakley'), 'new SKUs gone');
select pg_temp.ok((select (r->>'on_hand')::int = 13 from jsonb_array_elements(tfd_stock()) r where r->>'sku' = '100001'), '100001 back to 13');

-- packer locked out
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.fails($$select tfd_versions()$$, 'packer no versions', '%Admins only%');
select pg_temp.ok(not tfd_is_admin(), 'packer not admin for storage');
reset role;
\echo 'ALL PHASE 2b (LOTS) DATABASE CHECKS PASSED'
