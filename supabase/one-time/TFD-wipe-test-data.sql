-- ONE-TIME WIPE of all test data (approved by Kenny, Nov 16, 2026). Runs all-or-nothing: if any step fails, nothing is deleted.
-- Deletes: lots, products and stock, cost history, lists, shows (pulls, orders, CSV imports, hours), packages, scans, photo records,
--          payroll entries and payments, packing clock, saved dashboard views, alerts, the Activity Log, and the test logins Streamer1 and testpacker.
-- Keeps:   Kenny, Oshri and Claude logins; roles and access; every setting and pay rate (with their history); bins Q/R/S/T-01..40 and NOT_ASSIGNED.
-- SKUs restart at 100001, and show, lot and package numbers restart at 1.
begin;

truncate table
  pack_scans, pack_photos, pack_clock, packages,
  show_orders, show_imports, pulls, bc_items, bc_groups, show_events, show_shifts, show_people, shows,
  pay_entries, pay_payments,
  alert_dismissals, stock_moves, cost_layers, lot_photos, receipt_lines, receipts, inv_changes, inv_lists,
  products, sku_retired, dash_saved, activity_log
restart identity;

-- test bins made while testing (e.g. A4); the standard Q/R/S/T bins and NOT_ASSIGNED stay
delete from bins where code !~ '^[QRST]-[0-9]{2}$' and code <> 'NOT_ASSIGNED';

-- test logins
delete from auth.users where id in (select auth_id from profiles where username in ('streamer1', 'testpacker') and role in ('streamer', 'packer'));
delete from profiles where username in ('streamer1', 'testpacker') and role in ('streamer', 'packer');

-- what's left (should read: 0 products, 0 shows, 0 lots, people = Claude, Kenny, Oshri)
select (select count(*) from products) products, (select count(*) from shows) shows, (select count(*) from receipts) lots,
       (select count(*) from packages) packages, (select count(*) from bins) bins,
       (select string_agg(name, ', ' order by id) from profiles) people;

commit;
