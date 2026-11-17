-- 0015 checks: payroll from finalized show shifts + commission, packer clock with overtime, manual entries, pay/lock/adjustment,
-- edits with reasons, carried balance, person page (no profit). Synthetic data only. Week of Sun Oct 4 – Sat Oct 10, 2026.
\set ON_ERROR_STOP on
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$ begin if c is not true then raise exception 'FAILED: %', m; end if; end $$;
create or replace function pg_temp.fails(sql text, m text, pattern text default '%') returns void language plpgsql as $$
begin execute sql; raise exception 'FAILED (expected an error): %', m;
exception when others then if sqlerrm like 'FAILED%' then raise; end if;
  if sqlerrm not like pattern then raise exception 'FAILED: % (wrong error: %)', m, sqlerrm; end if; end $$;
create temp table pr as select null::jsonb j where false; grant all on pr to authenticated;
create or replace function pg_temp.p(n text) returns jsonb language sql as $$ select x from pr, jsonb_array_elements(j->'people') x where x->>'name' = n $$;

reset role;
select id as ally from profiles where username = 'ally' \gset
select id as pat from profiles where username = 'pat' \gset
select hourly_cents as pat_rate from tfd_rate_for(:pat, 'packer', '2026-10-05 12:00-04') \gset
update shows set status = 'ended', ended_at = now() where status in ('live','setup');
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tfd_adjust('100001', 'in', 2, 'count correction', null, true);

-- a finalized show on Mon Oct 5, 7pm–midnight; Ally 7–12 at $30/hr + 1%
select tfd_show_save(null, format('{"type":"live","platform":"tiktok","name":"Pay test","fees":{"pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0},
  "people":[{"profile_id":%s,"role":"streamer","hourly_cents":3000,"commission_bp":100}]}', :ally)::jsonb) as s \gset
select tfd_scan(:s, '100001');
reset role; update pulls set scanned_at = '2026-10-05 20:00-04' where show_id = :s; set role authenticated;
select tfd_show_end(:s, 'SHOW OVER');
select tfd_show_import(:s, 'x.csv', null, '[{"line":1,"order_id":"PAY1","product_name":"Part 1","part":1,"pull_no":1,"sale_cents":10000,"ship_cents":0,"tracking":"T9","package_key":"T9"}]');
select tfd_show_hours_save(:s, '2026-10-05 19:00-04', '2026-10-06 00:00-04', format('[{"profile_id":%s,"start_at":"2026-10-05T19:00:00-04:00","end_at":"2026-10-06T00:00:00-04:00"}]', :ally)::jsonb);
-- pending before finalize: not counted
insert into pr select tfd_payroll('2026-10-04', '2026-10-10');
select pg_temp.ok(pg_temp.p('Ally') is null or (pg_temp.p('Ally')->'totals'->>'show_minutes')::int = 0, 'unfinalized show not counted');
select pg_temp.ok(jsonb_array_length(j->'pending_shows') >= 1, 'listed as pending') from pr;
select tfd_show_finalize(:s);

-- Pat packs 9h a day Sun–Thu = 45h → 5h overtime
select tfd_pay_clock_save(null, :pat, ('2026-10-0' || d || ' 08:00-04')::timestamptz, ('2026-10-0' || d || ' 17:00-04')::timestamptz, 'paper timesheet') from generate_series(4, 8) d;
select pg_temp.fails(format($f$select tfd_pay_clock_save(null, %s, '2026-10-05 16:00-04', '2026-10-05 18:00-04', 'x')$f$, :pat), 'overlapping clock time refused', '%overlaps%');
select pg_temp.fails(format($f$select tfd_pay_clock_save(null, %s, '2026-10-09 08:00-04', '2026-10-09 17:00-04', '')$f$, :pat), 'reason required', '%reason%');
-- other paid time + bonus
select tfd_pay_entry_add(:ally, 'hours', '2026-10-07', 120, null, 'inventory count');
select tfd_pay_entry_add(:ally, 'bonus', '2026-10-08', null, 2500, 'great show');

truncate pr; insert into pr select tfd_payroll('2026-10-04', '2026-10-10');
select pg_temp.ok((pg_temp.p('Ally')->'totals'->>'show_minutes')::int = 300 and (pg_temp.p('Ally')->'totals'->>'show_pay_cents')::int = 15000, 'Ally 5h x $30 = $150');
select pg_temp.ok((pg_temp.p('Ally')->'totals'->>'commission_cents')::int = 94, 'commission 1% of (100 - 6) = $0.94: ' || (pg_temp.p('Ally')->'totals'->>'commission_cents'));
select pg_temp.ok((pg_temp.p('Ally')->'totals'->>'other_pay_cents')::int = 6000 and (pg_temp.p('Ally')->'totals'->>'bonus_cents')::int = 2500, '2h other time at $30 + $25 bonus');
select pg_temp.ok((pg_temp.p('Ally')->'totals'->>'earned_cents')::int = 15000 + 94 + 6000 + 2500, 'Ally earned');
select pg_temp.ok((pg_temp.p('Pat')->'totals'->>'pack_minutes')::int = 2700, 'Pat 45h');
select pg_temp.ok((pg_temp.p('Pat')->'totals'->>'ot_premium_cents')::int = round(300 * :pat_rate / 60.0 * 0.5), 'Pat 5h overtime at +0.5x');
select pg_temp.ok((pg_temp.p('Pat')->'totals'->>'earned_cents')::int = round(2700 * :pat_rate / 60.0) + round(300 * :pat_rate / 60.0 * 0.5), 'Pat earned = 45h + OT premium');
select pg_temp.ok(not (j->>'week_cut')::boolean, 'Sun–Sat range is whole weeks') from pr;
select pg_temp.ok((tfd_payroll('2026-10-05', '2026-10-10')->>'week_cut')::boolean, 'Mon–Sat cuts a week: warned');
select pg_temp.ok(not exists (select 1 from pr, jsonb_array_elements(j->'people') x where x->>'role' = 'admin'), 'admins not listed');

-- edit a shift (unpaid period): changes the hours
reset role; select id as sh from show_shifts where show_id = :s and profile_id = :ally \gset
set role authenticated;
select pg_temp.fails(format($f$select tfd_pay_shift_edit(%s, '2026-10-05 18:00-04', '2026-10-06 00:00-04', 'x')$f$, :sh), 'shift outside the show refused', '%Outside the show%');
select tfd_pay_shift_edit(:sh, '2026-10-05 19:00-04', '2026-10-05 23:00-04', 'left early');
truncate pr; insert into pr select tfd_payroll('2026-10-04', '2026-10-10');
select pg_temp.ok((pg_temp.p('Ally')->'totals'->>'show_pay_cents')::int = 12000, 'now 4h = $120');

-- pay Ally part: balance carries; the period locks
select pg_temp.fails(format($f$select tfd_pay_mark_paid(%s, '2026-10-04', '2026-10-10', '2026-10-12', 0, 'Zelle', null)$f$, :ally), 'amount required', '%amount%');
select tfd_pay_mark_paid(:ally, '2026-10-04', '2026-10-10', '2026-10-12', 15000, 'Zelle', null);
truncate pr; insert into pr select tfd_payroll('2026-10-04', '2026-10-10');
select pg_temp.ok((pg_temp.p('Ally')->>'paid_cents')::int = 15000, 'paid shows in the period');
select pg_temp.ok((tfd_payroll('2026-10-11', '2026-10-17')->'people') @> jsonb_build_array(jsonb_build_object('name', 'Ally', 'carried_cents', 12000 + 94 + 6000 + 2500 - 15000)), 'unpaid part carries to the next week');
select pg_temp.fails(format($f$select tfd_pay_entry_add(%s, 'bonus', '2026-10-09', null, 100, 'x')$f$, :ally), 'paid period locked for new entries', '%already paid%');
-- correcting a paid shift becomes an adjustment dated today; the shift itself stays
select tfd_pay_shift_edit(:sh, '2026-10-05 19:00-04', '2026-10-06 00:00-04', 'actually stayed to the end');
reset role;
select pg_temp.ok((select end_at from show_shifts where id = :sh) = '2026-10-05 23:00-04', 'paid shift unchanged');
select pg_temp.ok((select amount_cents from pay_entries where kind = 'adjustment' and profile_id = :ally and deleted_at is null order by id desc limit 1) = 3000, '+1h = $30 adjustment');
select pg_temp.ok((select work_date from pay_entries where kind = 'adjustment' and profile_id = :ally order by id desc limit 1) = (now() at time zone 'America/New_York')::date, 'adjustment lands on today');
set role authenticated;
-- removing the payment unlocks
select tfd_pay_payment_delete((pg_temp.p('Ally')->'payments'->0->>'id')::bigint, 'entered twice');
select tfd_pay_entry_add(:ally, 'bonus', '2026-10-09', null, 100, 'after unlock');
-- packer forgot to clock out: open clock is flagged and not counted
select tfd_pack_clock(true) from (select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000ff', false)) x;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok((select x->'open_clock' is not null from jsonb_array_elements(tfd_payroll('2026-10-04', '2026-10-10')->'people') x where x->>'name' = 'Pat'), 'open clock flagged');
reset role; select id as oc from pack_clock where profile_id = :pat and clock_out is null \gset
set role authenticated;
select tfd_pay_clock_save(:oc, null, now() - interval '2 hours', now() - interval '1 hour', 'forgot to clock out');
reset role; select pg_temp.ok((select clock_out is not null and edited_by is not null from pack_clock where id = :oc), 'closed by Kenny with a note'); set role authenticated;
-- person page: sales for a streamer, never profit or cost
select pg_temp.ok((tfd_pay_person(:ally, '2026-10-04', '2026-10-10')->'sales'->>'revenue_cents')::int = 10000, 'person page: Ally''s sales');
select pg_temp.ok(not (tfd_pay_person(:ally, '2026-10-04', '2026-10-10')::text ~ 'profit|cost_cents'), 'person page: no profit or cost');
-- staff can't open payroll
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000ff', false);
select pg_temp.fails('select tfd_payroll(''2026-10-04'', ''2026-10-10'')', 'packer cannot open payroll', '%Admins only%');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select 'ALL PAYROLL CHECKS PASSED';
