-- TFD app — Phase 6: Payroll (Nov 16 2026).
-- Hours: show shifts (entered at show Step 2; count once the show is finalized) and packer clock-in/out. Commission from finalized shows.
-- Manual entries: other paid time, bonuses, adjustments. Payments (Zelle) per period; a paid period locks its entries, and a later
-- correction becomes an adjustment on the person's next pay. Packer overtime per workweek (Settings → Overtime). Admins are unpaid.

create table if not exists pay_entries (
  id bigserial primary key, profile_id bigint not null references profiles(id),
  kind text not null check (kind in ('hours','bonus','adjustment')), work_date date not null,
  minutes int, rate_cents int, amount_cents int not null, reason text not null, source jsonb,
  created_by text not null, created_at timestamptz not null default now(), deleted_at timestamptz, deleted_by text, deleted_reason text);
create table if not exists pay_payments (
  id bigserial primary key, profile_id bigint not null references profiles(id), period_from date not null, period_to date not null check (period_to >= period_from),
  paid_on date not null, amount_cents int not null check (amount_cents > 0), method text not null default 'Zelle', note text,
  created_by text not null, created_at timestamptz not null default now(), deleted_at timestamptz, deleted_by text, deleted_reason text);
alter table pay_entries enable row level security; alter table pay_payments enable row level security;
revoke all on pay_entries, pay_payments from anon, authenticated;

create or replace function tfd_et_date(t timestamptz) returns date language sql immutable as $$ select (t at time zone 'America/New_York')::date $$;

-- is this person's day inside a period that has a payment recorded?
create or replace function tfd_pay_locked(p_profile bigint, p_day date) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from pay_payments where profile_id = p_profile and deleted_at is null and p_day between period_from and period_to) $$;

-- ---------------------------------------------------------------- one person's pay for a date range (all lines, with sources)
create or replace function tfd_pay_calc(p_profile bigint, p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pr profiles; shows_ jsonb; comm jsonb; clocks jsonb; weeks jsonb; entries jsonb; ot jsonb := tfd_get_setting('overtime');
  wk_start int; thr numeric; mult numeric; t jsonb;
begin
  select * into pr from profiles where id = p_profile;
  wk_start := array_position(array['sunday','monday','tuesday','wednesday','thursday','friday','saturday'], coalesce(ot->>'week_start', 'sunday')) - 1;
  thr := coalesce((ot->>'threshold_hours')::numeric, 40); mult := coalesce((ot->>'multiplier_bp')::numeric, 15000) / 10000.0;
  -- show shifts (finalized shows only), at the show's rate for that person
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'show_id', s.id, 'show', tfd_show_label(s), 'role', h.role, 'start_at', h.start_at, 'end_at', h.end_at,
      'date', tfd_et_date(h.start_at), 'minutes', m.mins, 'rate_cents', sp.hourly_cents, 'pay_cents', round(m.mins * sp.hourly_cents / 60.0)::int,
      'locked', tfd_pay_locked(p_profile, tfd_et_date(h.start_at)), 'show_start_at', s.show_start_at, 'show_end_at', s.show_end_at) order by h.start_at), '[]')
    into shows_ from show_shifts h join shows s on s.id = h.show_id join show_people sp on sp.show_id = h.show_id and sp.profile_id = h.profile_id
    cross join lateral (select round(extract(epoch from h.end_at - h.start_at) / 60.0)::int mins) m
    where h.profile_id = p_profile and s.status = 'finalized' and s.deleted_at is null and tfd_et_date(h.start_at) between p_from and p_to;
  -- commission: finalized shows dated in the range, each order rounded to the cent (same as the show review)
  select coalesce(jsonb_agg(jsonb_build_object('show_id', s.id, 'show', tfd_show_label(s), 'date', tfd_et_date(coalesce(s.show_start_at, s.started_at, s.created_at)),
      'commission_bp', sp.commission_bp, 'orders', x.n, 'sales_after_fees_cents', x.base, 'commission_cents', x.c) order by coalesce(s.show_start_at, s.started_at)), '[]')
    into comm from shows s join show_people sp on sp.show_id = s.id and sp.profile_id = p_profile and sp.role = 'streamer' and sp.commission_bp > 0
    cross join lateral (select count(*) n, coalesce(sum(o.sale_cents - coalesce(o.fee_cents, 0)), 0) base,
        coalesce(sum(round(sp.commission_bp * (o.sale_cents - coalesce(o.fee_cents, 0)) / 10000.0)), 0)::int c
      from show_orders o where o.show_id = s.id and o.state = 'matched') x
    where s.status = 'finalized' and s.deleted_at is null and tfd_et_date(coalesce(s.show_start_at, s.started_at, s.created_at)) between p_from and p_to;
  -- packer clock (closed rows), at the packer rate in effect that day
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'clock_in', c.clock_in, 'clock_out', c.clock_out, 'date', tfd_et_date(c.clock_in), 'minutes', m.mins,
      'rate_cents', r.hourly_cents, 'pay_cents', round(m.mins * r.hourly_cents / 60.0)::int, 'locked', tfd_pay_locked(p_profile, tfd_et_date(c.clock_in)),
      'edited_by', c.edited_by, 'note', c.note, 'week', tfd_et_date(c.clock_in) - ((extract(dow from tfd_et_date(c.clock_in))::int - wk_start + 7) % 7)) order by c.clock_in), '[]')
    into clocks from pack_clock c cross join lateral (select round(extract(epoch from c.clock_out - c.clock_in) / 60.0)::int mins) m
    cross join lateral tfd_rate_for(p_profile, 'packer', c.clock_in) r
    where c.profile_id = p_profile and c.clock_out is not null and tfd_et_date(c.clock_in) between p_from and p_to;
  -- packer overtime per workweek: hours over the threshold get the extra (multiplier − 1) on top
  select coalesce(jsonb_agg(jsonb_build_object('week_of', w.wk, 'minutes', w.mins, 'ot_minutes', greatest(w.mins - thr * 60, 0),
      'premium_cents', round(greatest(w.mins - thr * 60, 0) * w.rate / 60.0 * (mult - 1))::int) order by w.wk), '[]')
    into weeks from (select (x->>'week')::date wk, sum((x->>'minutes')::int) mins, max((x->>'rate_cents')::int) rate from jsonb_array_elements(clocks) x group by 1) w;
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'date', e.work_date, 'minutes', e.minutes, 'rate_cents', e.rate_cents, 'amount_cents', e.amount_cents,
      'reason', e.reason, 'by', e.created_by, 'at', e.created_at, 'locked', tfd_pay_locked(p_profile, e.work_date)) order by e.work_date, e.id), '[]')
    into entries from pay_entries e where e.profile_id = p_profile and e.deleted_at is null and e.work_date between p_from and p_to;
  t := jsonb_build_object(
    'show_minutes', (select coalesce(sum((x->>'minutes')::int), 0) from jsonb_array_elements(shows_) x),
    'show_pay_cents', (select coalesce(sum((x->>'pay_cents')::int), 0) from jsonb_array_elements(shows_) x),
    'pack_minutes', (select coalesce(sum((x->>'minutes')::int), 0) from jsonb_array_elements(clocks) x),
    'pack_pay_cents', (select coalesce(sum((x->>'pay_cents')::int), 0) from jsonb_array_elements(clocks) x),
    'ot_minutes', (select coalesce(sum((x->>'ot_minutes')::numeric), 0) from jsonb_array_elements(weeks) x),
    'ot_premium_cents', (select coalesce(sum((x->>'premium_cents')::int), 0) from jsonb_array_elements(weeks) x),
    'commission_cents', (select coalesce(sum((x->>'commission_cents')::int), 0) from jsonb_array_elements(comm) x),
    'other_minutes', (select coalesce(sum((x->>'minutes')::int), 0) from jsonb_array_elements(entries) x where x->>'kind' = 'hours'),
    'other_pay_cents', (select coalesce(sum((x->>'amount_cents')::int), 0) from jsonb_array_elements(entries) x where x->>'kind' = 'hours'),
    'bonus_cents', (select coalesce(sum((x->>'amount_cents')::int), 0) from jsonb_array_elements(entries) x where x->>'kind' = 'bonus'),
    'adjustment_cents', (select coalesce(sum((x->>'amount_cents')::int), 0) from jsonb_array_elements(entries) x where x->>'kind' = 'adjustment'));
  t := t || jsonb_build_object('minutes', (t->>'show_minutes')::int + (t->>'pack_minutes')::int + (t->>'other_minutes')::int,
    'earned_cents', (t->>'show_pay_cents')::int + (t->>'pack_pay_cents')::int + (t->>'ot_premium_cents')::int + (t->>'commission_cents')::int
      + (t->>'other_pay_cents')::int + (t->>'bonus_cents')::int + (t->>'adjustment_cents')::int);
  return jsonb_build_object('profile_id', pr.id, 'name', pr.name, 'role', pr.role, 'active', pr.active,
    'shifts', shows_, 'commission', comm, 'clocks', clocks, 'weeks', weeks, 'entries', entries, 'totals', t);
end $$;

-- everyone's pay for a range: earned, carried in from before, paid for periods ending in the range, balance
create or replace function tfd_payroll(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); ot jsonb := tfd_get_setting('overtime'); wk_start int;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Pick a start and end date'; end if;
  wk_start := array_position(array['sunday','monday','tuesday','wednesday','thursday','friday','saturday'], coalesce(ot->>'week_start', 'sunday')) - 1;
  return jsonb_build_object('from', p_from, 'to', p_to,
    'people', coalesce((select jsonb_agg(x order by x->>'role' desc, x->>'name') from (
        select tfd_pay_calc(pr.id, p_from, p_to) || jsonb_build_object(
          'carried_cents', (tfd_pay_calc(pr.id, '2000-01-01', p_from - 1)->'totals'->>'earned_cents')::int
                           - coalesce((select sum(amount_cents) from pay_payments where profile_id = pr.id and deleted_at is null and period_to < p_from), 0),
          'paid_cents', coalesce((select sum(amount_cents) from pay_payments where profile_id = pr.id and deleted_at is null and period_to between p_from and p_to), 0),
          'payments', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'period_from', period_from, 'period_to', period_to, 'paid_on', paid_on, 'amount_cents', amount_cents,
              'method', method, 'note', note, 'by', created_by) order by paid_on, id) from pay_payments where profile_id = pr.id and deleted_at is null and period_to between p_from and p_to), '[]'),
          'open_clock', (select jsonb_build_object('id', c.id, 'clock_in', c.clock_in) from pack_clock c where c.profile_id = pr.id and c.clock_out is null order by c.id desc limit 1)) x
        from profiles pr where pr.role in ('streamer','assistant','packer')
          and (pr.active or exists (select 1 from show_shifts where profile_id = pr.id) or exists (select 1 from pack_clock where profile_id = pr.id)
               or exists (select 1 from pay_entries where profile_id = pr.id and deleted_at is null))) t), '[]'),
    'pending_shows', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', tfd_show_label(s), 'status', s.status, 'at', coalesce(s.show_start_at, s.started_at, s.created_at))
        order by coalesce(s.show_start_at, s.started_at, s.created_at)) from shows s where s.deleted_at is null and s.status in ('live','ended','matched')
        and tfd_et_date(coalesce(s.show_start_at, s.started_at, s.created_at)) between p_from and p_to), '[]'),
    'week_cut', ((extract(dow from p_from)::int - wk_start + 7) % 7) <> 0 or ((extract(dow from p_to)::int - wk_start + 7) % 7) <> 6,
    'week_start', coalesce(ot->>'week_start', 'sunday'));
end $$;

-- the person page: pay lines plus, for streamers and assistants, sales per show and per hour (never profit or cost)
create or replace function tfd_pay_person(p_profile bigint, p_from date, p_to date) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); d jsonb; pr profiles;
begin
  select * into pr from profiles where id = p_profile;
  if pr.id is null then raise exception 'No such person'; end if;
  if pr.role = 'streamer' then
    d := tfd_dash_calc(jsonb_build_object('from', p_from, 'to', p_to, 'people', jsonb_build_array(p_profile)), true);
  end if;
  return tfd_pay_calc(p_profile, p_from, p_to) || jsonb_build_object(
    'sales', case when d is null then null else jsonb_build_object('revenue_cents', d->'totals'->'revenue_cents', 'orders', d->'totals'->'orders',
       'packages', d->'totals'->'packages', 'hours', d->'totals'->'hours', 'estimate', d->'totals'->'estimate',
       'by_show', (select coalesce(jsonb_agg(x - 'item_profit_cents' - 'net_profit_cents'), '[]') from jsonb_array_elements(d->'by_show') x)) end,
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'period_from', period_from, 'period_to', period_to, 'paid_on', paid_on, 'amount_cents', amount_cents,
        'method', method, 'note', note, 'by', created_by) order by paid_on desc, id desc) from pay_payments where profile_id = p_profile and deleted_at is null), '[]'));
end $$;

-- ---------------------------------------------------------------- edits (reason required, logged; paid periods turn into adjustments)
create or replace function tfd_pay_adjust_for(p_profile bigint, p_old_cents int, p_new_cents int, p_what text, p_reason text, p_actor text, p_src jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_new_cents = p_old_cents then return; end if;
  insert into pay_entries (profile_id, kind, work_date, amount_cents, reason, source, created_by)
    values (p_profile, 'adjustment', tfd_et_date(now()), p_new_cents - p_old_cents, p_what || ' (that period was already paid): ' || p_reason, p_src, p_actor);
end $$;

create or replace function tfd_pay_shift_edit(p_shift bigint, p_start timestamptz, p_end timestamptz, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); h show_shifts; s shows; sp show_people; pr profiles; old_c int; new_c int; del boolean := p_start is null and p_end is null;
begin
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  select * into h from show_shifts where id = p_shift for update;
  if h.id is null then raise exception 'No such shift'; end if;
  select * into s from shows where id = h.show_id; select * into sp from show_people where show_id = h.show_id and profile_id = h.profile_id; select * into pr from profiles where id = h.profile_id;
  if not del then
    if p_end <= p_start then raise exception 'The end must be after the start'; end if;
    if s.show_start_at is not null and (p_start < s.show_start_at or p_end > s.show_end_at) then
      raise exception 'Outside the show''s time (% – %)', to_char(s.show_start_at at time zone 'America/New_York', 'Mon DD HH12:MI AM'), to_char(s.show_end_at at time zone 'America/New_York', 'Mon DD HH12:MI AM'); end if;
    if exists (select 1 from show_shifts x where x.show_id = h.show_id and x.profile_id = h.profile_id and x.id <> h.id and x.start_at < p_end and p_start < x.end_at) then
      raise exception '% already has time on this show that overlaps', pr.name; end if;
  end if;
  old_c := round(extract(epoch from h.end_at - h.start_at) / 60.0 * sp.hourly_cents / 60.0)::int;
  new_c := case when del then 0 else round(extract(epoch from p_end - p_start) / 60.0 * sp.hourly_cents / 60.0)::int end;
  if s.status = 'finalized' and tfd_pay_locked(h.profile_id, tfd_et_date(h.start_at)) then
    perform tfd_pay_adjust_for(h.profile_id, old_c, new_c, 'Hours ' || case when del then 'removed' else 'corrected' end || ' on ' || tfd_show_label(s), p_reason, me.name, jsonb_build_object('shift', h.id));
  elsif del then delete from show_shifts where id = h.id;
  else update show_shifts set start_at = p_start, end_at = p_end where id = h.id; end if;
  perform tfd_log(me.name, 'Payroll', 'hours_edit', pr.name || ' on ' || tfd_show_label(s) || ': ' ||
    to_char(h.start_at at time zone 'America/New_York', 'Mon DD HH12:MI AM') || '–' || to_char(h.end_at at time zone 'America/New_York', 'HH12:MI AM') || ' → ' ||
    case when del then 'removed' else to_char(p_start at time zone 'America/New_York', 'Mon DD HH12:MI AM') || '–' || to_char(p_end at time zone 'America/New_York', 'HH12:MI AM') end ||
    case when s.status = 'finalized' and tfd_pay_locked(h.profile_id, tfd_et_date(h.start_at)) then ' (paid period: adjustment of $' || to_char((new_c - old_c) / 100.0, 'FM999990.00') || ' added)' else '' end,
    jsonb_build_object('shift', h.id, 'show', s.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pay_clock_save(p_id bigint, p_profile bigint, p_in timestamptz, p_out timestamptz, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); c pack_clock; pr profiles; old_c int := 0; new_c int := 0; rate int; del boolean := p_in is null and p_out is null; d date; locked boolean;
begin
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_id is not null then
    select * into c from pack_clock where id = p_id for update;
    if c.id is null then raise exception 'No such clock entry'; end if;
    p_profile := c.profile_id;
  end if;
  select * into pr from profiles where id = p_profile;
  if pr.id is null or pr.role <> 'packer' then raise exception 'Pick a packer'; end if;
  if not del then
    if p_in is null or p_out is null then raise exception 'Enter the clock-in and clock-out time'; end if;
    if p_out <= p_in then raise exception 'Clock-out must be after clock-in'; end if;
    if p_out - p_in > interval '16 hours' then raise exception 'That''s over 16 hours. Check the dates'; end if;
    if exists (select 1 from pack_clock x where x.profile_id = p_profile and x.id is distinct from p_id and x.clock_in < p_out and p_in < coalesce(x.clock_out, now())) then
      raise exception '% already has clock time that overlaps', pr.name; end if;
  end if;
  d := tfd_et_date(coalesce(c.clock_in, p_in));
  locked := tfd_pay_locked(p_profile, d) or (p_in is not null and tfd_pay_locked(p_profile, tfd_et_date(p_in)));
  if c.id is not null and c.clock_out is not null then
    select hourly_cents into rate from tfd_rate_for(p_profile, 'packer', c.clock_in);
    old_c := round(extract(epoch from c.clock_out - c.clock_in) / 60.0 * rate / 60.0)::int;
  end if;
  if not del then select hourly_cents into rate from tfd_rate_for(p_profile, 'packer', p_in); new_c := round(extract(epoch from p_out - p_in) / 60.0 * rate / 60.0)::int; end if;
  if locked then
    perform tfd_pay_adjust_for(p_profile, old_c, new_c, 'Packing hours ' || case when del then 'removed' when c.id is null then 'added' else 'corrected' end || ' for ' || to_char(d, 'Mon DD'), p_reason, me.name, jsonb_build_object('clock', c.id));
  elsif del then delete from pack_clock where id = c.id;
  elsif c.id is null then insert into pack_clock (profile_id, clock_in, clock_out, edited_by, note) values (p_profile, p_in, p_out, me.name, trim(p_reason));
  else update pack_clock set clock_in = p_in, clock_out = p_out, edited_by = me.name, note = trim(p_reason) where id = c.id; end if;
  perform tfd_log(me.name, 'Payroll', 'clock_edit', pr.name || ' packing ' ||
    case when c.id is null then 'added ' else coalesce(to_char(c.clock_in at time zone 'America/New_York', 'Mon DD HH12:MI AM'), '') || '–' || coalesce(to_char(c.clock_out at time zone 'America/New_York', 'HH12:MI AM'), 'open') || ' → ' end ||
    case when del then 'removed' else to_char(p_in at time zone 'America/New_York', 'Mon DD HH12:MI AM') || '–' || to_char(p_out at time zone 'America/New_York', 'HH12:MI AM') end ||
    case when locked then ' (paid period: adjustment of $' || to_char((new_c - old_c) / 100.0, 'FM999990.00') || ' added)' else '' end, jsonb_build_object('clock', c.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- other paid time (hours at the person's rate that day), bonuses, adjustments
create or replace function tfd_pay_entry_add(p_profile bigint, p_kind text, p_date date, p_minutes int, p_amount_cents int, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); pr profiles; rate int; amt int;
begin
  select * into pr from profiles where id = p_profile;
  if pr.id is null or pr.role not in ('streamer','assistant','packer') then raise exception 'Pick a paid team member'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_date is null then raise exception 'Pick the date'; end if;
  if tfd_pay_locked(p_profile, p_date) then raise exception '% is in a period that''s already paid. Put it on a later date (it lands on the next pay)', to_char(p_date, 'Mon DD'); end if;
  if p_kind = 'hours' then
    if coalesce(p_minutes, 0) <= 0 then raise exception 'Enter the hours'; end if;
    select hourly_cents into rate from tfd_rate_for(p_profile, pr.role, (p_date + time '12:00') at time zone 'America/New_York');
    amt := round(p_minutes * rate / 60.0)::int;
  elsif p_kind in ('bonus','adjustment') then
    if p_amount_cents is null or p_amount_cents = 0 then raise exception 'Enter the amount'; end if;
    if p_kind = 'bonus' and p_amount_cents < 0 then raise exception 'A bonus must be positive (use an adjustment to take money off)'; end if;
    amt := p_amount_cents;
  else raise exception 'Unknown entry type'; end if;
  insert into pay_entries (profile_id, kind, work_date, minutes, rate_cents, amount_cents, reason, created_by)
    values (p_profile, p_kind, p_date, case when p_kind = 'hours' then p_minutes end, rate, amt, trim(p_reason), me.name);
  perform tfd_log(me.name, 'Payroll', 'pay_entry', pr.name || ': ' || case p_kind when 'hours' then to_char(p_minutes / 60.0, 'FM990.00') || ' h other paid time' else p_kind end ||
    ' on ' || to_char(p_date, 'Mon DD') || ' = $' || to_char(amt / 100.0, 'FM999990.00'), jsonb_build_object('profile', p_profile), p_reason);
  return jsonb_build_object('ok', true, 'amount_cents', amt);
end $$;

create or replace function tfd_pay_entry_delete(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); e pay_entries;
begin
  select * into e from pay_entries where id = p_id and deleted_at is null for update;
  if e.id is null then raise exception 'No such entry'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if tfd_pay_locked(e.profile_id, e.work_date) then raise exception 'That entry is in a paid period. Add an adjustment instead'; end if;
  update pay_entries set deleted_at = now(), deleted_by = me.name, deleted_reason = trim(p_reason) where id = e.id;
  perform tfd_log(me.name, 'Payroll', 'pay_entry_delete', 'Removed ' || e.kind || ' of $' || to_char(e.amount_cents / 100.0, 'FM999990.00') || ' for ' || (select name from profiles where id = e.profile_id),
    jsonb_build_object('entry', e.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- paying
create or replace function tfd_pay_mark_paid(p_profile bigint, p_from date, p_to date, p_paid_on date, p_amount_cents int, p_method text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); pr profiles;
begin
  select * into pr from profiles where id = p_profile;
  if pr.id is null then raise exception 'No such person'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Pick the pay period'; end if;
  if coalesce(p_amount_cents, 0) <= 0 then raise exception 'Enter the amount paid'; end if;
  if p_paid_on is null then raise exception 'Enter the date it was paid'; end if;
  insert into pay_payments (profile_id, period_from, period_to, paid_on, amount_cents, method, note, created_by)
    values (p_profile, p_from, p_to, p_paid_on, p_amount_cents, coalesce(nullif(trim(p_method), ''), 'Zelle'), nullif(trim(p_note), ''), me.name);
  perform tfd_log(me.name, 'Payroll', 'paid', 'Paid ' || pr.name || ' $' || to_char(p_amount_cents / 100.0, 'FM999990.00') || ' by ' || coalesce(nullif(trim(p_method), ''), 'Zelle') ||
    ' on ' || to_char(p_paid_on, 'Mon DD') || ' for ' || to_char(p_from, 'Mon DD') || '–' || to_char(p_to, 'Mon DD') || ' (that period is now locked)', jsonb_build_object('profile', p_profile));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pay_payment_delete(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); p pay_payments;
begin
  select * into p from pay_payments where id = p_id and deleted_at is null for update;
  if p.id is null then raise exception 'No such payment'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  update pay_payments set deleted_at = now(), deleted_by = me.name, deleted_reason = trim(p_reason) where id = p.id;
  perform tfd_log(me.name, 'Payroll', 'paid_delete', 'Removed payment of $' || to_char(p.amount_cents / 100.0, 'FM999990.00') || ' to ' || (select name from profiles where id = p.profile_id) ||
    ' (' || to_char(p.period_from, 'Mon DD') || '–' || to_char(p.period_to, 'Mon DD') || ' unlocked)', jsonb_build_object('payment', p.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_et_date(timestamptz), tfd_pay_locked(bigint, date), tfd_pay_calc(bigint, date, date), tfd_payroll(date, date), tfd_pay_person(bigint, date, date),
  tfd_pay_adjust_for(bigint, int, int, text, text, text, jsonb), tfd_pay_shift_edit(bigint, timestamptz, timestamptz, text), tfd_pay_clock_save(bigint, bigint, timestamptz, timestamptz, text),
  tfd_pay_entry_add(bigint, text, date, int, int, text), tfd_pay_entry_delete(bigint, text), tfd_pay_mark_paid(bigint, date, date, date, int, text, text), tfd_pay_payment_delete(bigint, text) from public, anon;
revoke execute on function tfd_pay_locked(bigint, date), tfd_pay_calc(bigint, date, date), tfd_pay_adjust_for(bigint, int, int, text, text, text, jsonb) from authenticated;
grant execute on function tfd_payroll(date, date), tfd_pay_person(bigint, date, date), tfd_pay_shift_edit(bigint, timestamptz, timestamptz, text),
  tfd_pay_clock_save(bigint, bigint, timestamptz, timestamptz, text), tfd_pay_entry_add(bigint, text, date, int, int, text), tfd_pay_entry_delete(bigint, text),
  tfd_pay_mark_paid(bigint, date, date, date, int, text, text), tfd_pay_payment_delete(bigint, text) to authenticated;
