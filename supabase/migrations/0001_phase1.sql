-- TFD app — Phase 1: people, roles, settings (effective-dated), pay rates, activity log.
-- All tables are locked (RLS on, no policies). The app reads and writes only through the
-- tfd_* functions below, which check who is signed in and log every change.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables
create table if not exists profiles (
  id          bigserial primary key,
  auth_id     uuid unique,              -- null for Claude (it signs in through the API, not a login)
  name        text not null,
  username    text unique,
  role        text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create table if not exists roles (name text primary key, label text not null, perms jsonb not null);
create table if not exists setting_defaults (key text primary key, label text not null, value jsonb not null);
create table if not exists settings_history (
  id bigserial primary key, key text not null references setting_defaults(key), value jsonb not null,
  effective_from timestamptz not null, set_by text not null, reason text, created_at timestamptz not null default now());
create index if not exists settings_history_key on settings_history (key, effective_from desc, id desc);
create table if not exists rate_history (
  id bigserial primary key, scope text not null check (scope in ('role','user')), target text not null,
  hourly_cents int check (hourly_cents >= 0), commission_bp int check (commission_bp >= 0 and commission_bp < 10000),
  effective_from timestamptz not null, set_by text not null, reason text, created_at timestamptz not null default now());
create index if not exists rate_history_target on rate_history (scope, target, effective_from desc, id desc);
create table if not exists activity_log (
  id bigserial primary key, at timestamptz not null default now(), actor text not null, tab text not null,
  action text not null, summary text not null, details jsonb, reason text, file text, request text,
  undo jsonb, undone_by bigint, undo_of bigint);
create index if not exists activity_log_at on activity_log (at desc);

alter table profiles enable row level security;
alter table roles enable row level security;
alter table setting_defaults enable row level security;
alter table settings_history enable row level security;
alter table rate_history enable row level security;
alter table activity_log enable row level security;
revoke all on profiles, roles, setting_defaults, settings_history, rate_history, activity_log from anon, authenticated;

-- ---------------------------------------------------------------- seed
insert into roles values
 ('admin','Admin','{"dashboard":"all","cost_profit":true,"inventory_edit":true,"live_mapping":"full","fulfillment":true,"payroll":"all","settings":"yes","activity_log":true}'),
 ('streamer','Streamer','{"dashboard":"own","cost_profit":false,"inventory_edit":false,"live_mapping":"streamer_safe","fulfillment":false,"payroll":"own","settings":"no","activity_log":false}'),
 ('assistant','Assistant','{"dashboard":"own","cost_profit":false,"inventory_edit":false,"live_mapping":"streamer_safe","fulfillment":false,"payroll":"own","settings":"no","activity_log":false}'),
 ('packer','Packer','{"dashboard":"none","cost_profit":false,"inventory_edit":false,"live_mapping":"none","fulfillment":true,"payroll":"none","settings":"no","activity_log":false}'),
 ('claude','Claude','{"dashboard":"all","cost_profit":true,"inventory_edit":true,"live_mapping":"none","fulfillment":true,"payroll":"all","settings":"confirm","activity_log":true}')
on conflict (name) do nothing;

insert into setting_defaults values
 ('platform.tiktok','TikTok','{"label":"TikTok","pct_sale_bp":600,"pct_ship_bp":600,"fixed_cents":0,"typical_ship_cents":null}'),
 ('platform.whatnot','Whatnot','{"label":"Whatnot","pct_sale_bp":null,"pct_ship_bp":null,"fixed_cents":null,"typical_ship_cents":null}'),
 ('pricing','Pricing','{"floor_profit_bp":1000,"near_floor_bp":500}'),
 ('rules','Rules','{"photo_required":true,"all_items_scanned":true,"label_scan_required":true,"adjust_reason_required":true,"adjust_confirm_enabled":true,"adjust_confirm_units":10,"adjust_confirm_cents":50000,"unmatched_must_match":true,"inventory_locked_live":true,"claude_confirm_settings":true,"oversell_warnings":true}'),
 ('inventory','Inventory','{"required_fields":["product_name","sku","cost","brand","retail_price","weight","image","bin","quantity","category","subcategory"],"show_suggest_max_units":5,"show_suggest_min_shows":8,"low_stock_default":2}'),
 ('photos','Packing photos','{"retention_days":90}'),
 ('overtime','Overtime','{"threshold_hours":40,"multiplier_bp":15000,"week_start":"sunday"}'),
 ('security','Security','{"idle_signout_minutes":15}'),
 ('whatnot_export','Whatnot export','{"category":"Bags & Accessories","subcategory":"Sunglasses"}'),
 ('lists','Lists','{"brands":[],"suppliers":[],"expense_categories":[]}')
on conflict (key) do nothing;

insert into settings_history (key, value, effective_from, set_by, reason)
select d.key, d.value, '2000-01-01', 'System', 'Default' from setting_defaults d
where not exists (select 1 from settings_history h where h.key = d.key);

insert into rate_history (scope, target, hourly_cents, commission_bp, effective_from, set_by, reason)
select 'role', r, h, c, '2000-01-01', 'System', 'Default'
from (values ('streamer',3000,100), ('assistant',2000,0), ('packer',1600,0), ('admin',0,0)) v(r,h,c)
where not exists (select 1 from rate_history where scope = 'role');

insert into profiles (name, role) select 'Claude','claude' where not exists (select 1 from profiles where role = 'claude');

-- ---------------------------------------------------------------- helpers
create or replace function tfd_me() returns profiles language sql stable security definer set search_path = public as
  $$ select * from profiles where auth_id = auth.uid() and active $$;

create or replace function tfd_require(p_need text) returns profiles language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where auth_id = auth.uid() and active;
  if me.id is null then raise exception 'Sign in required' using errcode = '28000'; end if;
  if p_need = 'admin' and me.role <> 'admin' then raise exception 'Admins only' using errcode = '42501'; end if;
  return me;
end $$;

create or replace function tfd_get_setting(p_key text, p_at timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public as
  $$ select value from settings_history where key = p_key and effective_from <= p_at order by effective_from desc, id desc limit 1 $$;

create or replace function tfd_log(p_actor text, p_tab text, p_action text, p_summary text, p_details jsonb default null,
  p_reason text default null, p_undo jsonb default null, p_undo_of bigint default null, p_file text default null, p_request text default null)
returns bigint language sql security definer set search_path = public as $$
  insert into activity_log (actor, tab, action, summary, details, reason, undo, undo_of, file, request)
  values (p_actor, p_tab, p_action, p_summary, p_details, nullif(trim(p_reason), ''), p_undo, p_undo_of, p_file, p_request) returning id $$;

-- Rate in effect: person rate (if set) beats role default. Show overrides arrive with Shows.
create or replace function tfd_rate_for(p_user_id bigint, p_role text, p_at timestamptz default now())
returns table (hourly_cents int, commission_bp int, source text)
language plpgsql stable security definer set search_path = public as $$
declare rr rate_history; pr rate_history;
begin
  select * into rr from rate_history where scope = 'role' and target = p_role and effective_from <= p_at order by effective_from desc, id desc limit 1;
  if p_user_id is not null then
    select * into pr from rate_history where scope = 'user' and target = p_user_id::text and effective_from <= p_at order by effective_from desc, id desc limit 1;
  end if;
  hourly_cents := coalesce(pr.hourly_cents, rr.hourly_cents, 0);
  commission_bp := coalesce(pr.commission_bp, rr.commission_bp, 0);
  source := case when pr.hourly_cents is not null or pr.commission_bp is not null then 'person' else 'role' end;
  return next;
end $$;

create or replace function tfd_effective(p timestamptz) returns timestamptz language plpgsql as $$
begin
  if p is null then return now(); end if;
  if p < now() - interval '1 minute' then
    raise exception 'Effective date cannot be in the past. Past shows keep the rates they ran under; use a show override at review instead.';
  end if;
  return p;
end $$;

-- Human-readable values for the Activity Log.
create or replace function tfd_fmt(k text, v jsonb) returns text language plpgsql immutable as $$
begin
  if v is null or jsonb_typeof(v) = 'null' then return 'not set'; end if;
  if jsonb_typeof(v) = 'boolean' then return case when v::boolean then 'on' else 'off' end; end if;
  if jsonb_typeof(v) = 'array' then return coalesce(nullif((select string_agg(x, ', ') from jsonb_array_elements_text(v) x), ''), 'none'); end if;
  if k = 'multiplier_bp' then return trim(to_char((v::text)::numeric / 10000, 'FM990.99')) || '×'; end if;
  if k like '%\_bp' then return trim(to_char((v::text)::numeric / 100, 'FM9990.99')) || '%'; end if;
  if k like '%\_cents' then return '$' || to_char((v::text)::numeric / 100, 'FM999999990.00'); end if;
  if jsonb_typeof(v) = 'string' then return coalesce(nullif(v #>> '{}', ''), 'blank'); end if;
  return v::text;
end $$;

create or replace function tfd_field_label(k text) returns text language sql immutable as $$
  select coalesce(jsonb_build_object(
    'pct_sale_bp','fee % of sale','pct_ship_bp','fee % of shipping','fixed_cents','fixed fee per order','typical_ship_cents','typical shipping',
    'floor_profit_bp','floor profit','near_floor_bp','near-floor threshold','retention_days','photo days','idle_signout_minutes','sign-out after idle (minutes)',
    'threshold_hours','overtime after (hours)','multiplier_bp','overtime multiplier','week_start','workweek start',
    'show_suggest_max_units','suggest under (units)','show_suggest_min_shows','suggest after (shows)','low_stock_default','low-stock threshold',
    'required_fields','required fields','adjust_confirm_units','confirm adjustments over (units)','adjust_confirm_cents','confirm adjustments over ($)') ->> k,
    replace(k, '_', ' ')) $$;

-- Validate a whole setting object against the default's shape.
create or replace function tfd_validate_setting(p_key text, p_value jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare def jsonb; k text; dv jsonb; v jsonb; out jsonb := '{}';
  nullable text[] := array['pct_sale_bp','pct_ship_bp','fixed_cents','typical_ship_cents'];
  pct text[] := array['pct_sale_bp','pct_ship_bp','floor_profit_bp','near_floor_bp'];
begin
  select value into def from setting_defaults where key = p_key;
  if def is null then raise exception 'Unknown setting: %', p_key; end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' then raise exception 'Setting value must be an object'; end if;
  for k, dv in select * from jsonb_each(def) loop
    if not p_value ? k then raise exception 'Missing field %', k; end if;
    v := p_value -> k;
    if jsonb_typeof(dv) = 'boolean' then
      if jsonb_typeof(v) <> 'boolean' then raise exception '% must be on or off', tfd_field_label(k); end if;
    elsif jsonb_typeof(dv) = 'array' then
      if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements(v) e where jsonb_typeof(e) <> 'string') then raise exception '% must be a list', tfd_field_label(k); end if;
      v := coalesce((select jsonb_agg(t order by o) from (select distinct on (trim(e)) trim(e) t, o from jsonb_array_elements_text(v) with ordinality x(e, o) where trim(e) <> '' order by trim(e), o) s), '[]');
    elsif jsonb_typeof(dv) = 'string' then
      if jsonb_typeof(v) <> 'string' then raise exception '% must be text', tfd_field_label(k); end if;
      v := to_jsonb(trim(v #>> '{}'));
    else
      if jsonb_typeof(v) = 'null' then
        if not k = any(nullable) then raise exception '% is required', tfd_field_label(k); end if;
      elsif jsonb_typeof(v) <> 'number' or (v::text)::numeric <> trunc((v::text)::numeric) or (v::text)::numeric < 0 then
        raise exception '% must be a whole, non-negative number', tfd_field_label(k);
      elsif k = any(pct) and (v::text)::numeric >= 10000 then
        raise exception '% must be under 100%%', tfd_field_label(k);
      end if;
    end if;
    out := out || jsonb_build_object(k, v);
  end loop;
  if p_key = 'overtime' and not (out->>'week_start') = any(array['sunday','monday','tuesday','wednesday','thursday','friday','saturday']) then
    raise exception 'Workweek start must be a weekday'; end if;
  if p_key = 'overtime' and (out->>'multiplier_bp')::int < 10000 then raise exception 'Overtime multiplier must be at least 1×'; end if;
  if p_key = 'security' and (out->>'idle_signout_minutes')::int < 1 then raise exception 'Sign-out must be at least 1 minute'; end if;
  return out;
end $$;

-- Floor price: lowest price where item profit >= floor profit % of cost (spec: Core definitions).
create or replace function tfd_floor(p_cost_cents int, p_platform jsonb, p_commission_bp int, p_floor_profit_bp int)
returns jsonb language plpgsql immutable as $$
declare a numeric; b numeric; f numeric; s numeric; c numeric; r numeric; exact numeric; flags text[] := '{}';
begin
  if jsonb_typeof(p_platform->'pct_sale_bp') = 'null' or jsonb_typeof(p_platform->'pct_ship_bp') = 'null' or jsonb_typeof(p_platform->'fixed_cents') = 'null' then
    return jsonb_build_object('exact_cents', null, 'rounded_cents', null, 'flags', jsonb_build_array('fees_not_set'));
  end if;
  a := (p_platform->>'pct_sale_bp')::numeric / 10000; b := (p_platform->>'pct_ship_bp')::numeric / 10000; f := (p_platform->>'fixed_cents')::numeric;
  if jsonb_typeof(p_platform->'typical_ship_cents') = 'null' then s := 0; flags := flags || 'shipping_not_set'; else s := (p_platform->>'typical_ship_cents')::numeric; end if;
  c := p_commission_bp::numeric / 10000; r := p_floor_profit_bp::numeric / 10000;
  exact := ceil((p_cost_cents * (1 + r) / (1 - c) + b * s + f) / (1 - a) - 0.000001);
  return jsonb_build_object('exact_cents', exact, 'rounded_cents', ceil(exact / 100) * 100, 'flags', to_jsonb(flags));
end $$;

-- ---------------------------------------------------------------- API (called from the website)
create or replace function tfd_state() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where auth_id = auth.uid() and active;
  if me.id is null then return jsonb_build_object('me', null); end if;
  return jsonb_build_object('me', jsonb_build_object('id', me.id, 'name', me.name, 'role', me.role),
    'perms', (select perms from roles where name = me.role),
    'idle_signout_minutes', (tfd_get_setting('security')->>'idle_signout_minutes')::int);
end $$;

create or replace function tfd_settings() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return jsonb_build_object(
    'settings', (select jsonb_object_agg(key, tfd_get_setting(key)) from setting_defaults),
    'roleRates', (select jsonb_object_agg(r, (select to_jsonb(x) from tfd_rate_for(null, r) x)) from unnest(array['streamer','assistant','packer','admin']) r),
    'roles', (select jsonb_agg(jsonb_build_object('name', name, 'label', label, 'perms', perms) order by array_position(array['admin','streamer','assistant','packer','claude'], name)) from roles));
end $$;

create or replace function tfd_setting_history(p_key text) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(to_jsonb(h) order by effective_from desc, id desc) from settings_history h where key = p_key), '[]');
end $$;

create or replace function tfd_set_setting(p_key text, p_value jsonb, p_effective timestamptz default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; v jsonb; prev jsonb; eff timestamptz; parts text[] := '{}'; k text;
begin
  me := tfd_require('admin');
  v := tfd_validate_setting(p_key, p_value);
  prev := tfd_get_setting(p_key);
  for k in select jsonb_object_keys(v) loop
    if prev -> k is distinct from v -> k then parts := parts || (tfd_field_label(k) || ': ' || tfd_fmt(k, prev -> k) || ' → ' || tfd_fmt(k, v -> k)); end if;
  end loop;
  if cardinality(parts) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  eff := tfd_effective(p_effective);
  insert into settings_history (key, value, effective_from, set_by, reason) values (p_key, v, eff, me.name, nullif(trim(p_reason), ''));
  perform tfd_log(me.name, 'Settings', 'setting_change', (select label from setting_defaults where key = p_key) || ': ' || array_to_string(parts, '; '),
    jsonb_build_object('key', p_key, 'previous', prev, 'next', v, 'effective_from', eff), p_reason,
    jsonb_build_object('type', 'setting', 'key', p_key, 'previous', prev));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_set_rate(p_scope text, p_target text, p_hourly_cents int, p_commission_bp int, p_effective timestamptz default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; label text; prev_h int; prev_c int; eff timestamptz; u profiles;
begin
  me := tfd_require('admin');
  if p_scope = 'role' then
    if p_target not in ('streamer','assistant','packer','admin') then raise exception 'Unknown role'; end if;
    if p_hourly_cents is null or p_commission_bp is null then raise exception 'Role defaults need both an hourly rate and a commission'; end if;
    label := p_target || ' default';
    select hourly_cents, commission_bp into prev_h, prev_c from tfd_rate_for(null, p_target);
  elsif p_scope = 'user' then
    select * into u from profiles where id = p_target::bigint and role <> 'claude';
    if u.id is null then raise exception 'Unknown person'; end if;
    label := u.name;
    select hourly_cents, commission_bp into prev_h, prev_c from rate_history where scope = 'user' and target = p_target order by effective_from desc, id desc limit 1;
  else raise exception 'scope must be role or user'; end if;
  if p_hourly_cents < 0 or p_commission_bp < 0 then raise exception 'Rates must be non-negative'; end if;
  if p_commission_bp >= 10000 then raise exception 'Commission must be under 100%%'; end if;
  if prev_h is not distinct from p_hourly_cents and prev_c is not distinct from p_commission_bp then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  eff := tfd_effective(p_effective);
  insert into rate_history (scope, target, hourly_cents, commission_bp, effective_from, set_by, reason) values (p_scope, p_target, p_hourly_cents, p_commission_bp, eff, me.name, nullif(trim(p_reason), ''));
  perform tfd_log(me.name, 'Settings', 'rate_change',
    'Pay rate for ' || label || ': ' ||
      case when prev_h is null then 'role default hourly' else tfd_fmt('x_cents', to_jsonb(prev_h)) || '/hr' end || ', ' ||
      case when prev_c is null then 'role default commission' else tfd_fmt('x_bp', to_jsonb(prev_c)) end || ' → ' ||
      case when p_hourly_cents is null then 'role default hourly' else tfd_fmt('x_cents', to_jsonb(p_hourly_cents)) || '/hr' end || ', ' ||
      case when p_commission_bp is null then 'role default commission' else tfd_fmt('x_bp', to_jsonb(p_commission_bp)) end,
    jsonb_build_object('scope', p_scope, 'target', p_target, 'effective_from', eff), p_reason,
    jsonb_build_object('type', 'rate', 'scope', p_scope, 'target', p_target, 'hourly_cents', prev_h, 'commission_bp', prev_c));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_set_role(p_name text, p_perms jsonb, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; prev jsonb; nxt jsonb := '{}'; k text; v jsonb; parts text[] := '{}';
  choices jsonb := '{"dashboard":["all","own","none"],"live_mapping":["full","streamer_safe","none"],"payroll":["all","own","none"],"settings":["yes","confirm","no"]}';
begin
  me := tfd_require('admin');
  select perms into prev from roles where name = p_name;
  if prev is null then raise exception 'Unknown role'; end if;
  for k in select jsonb_object_keys(prev) loop
    v := p_perms -> k;
    if choices ? k then
      if v is null or not (choices -> k) ? (v #>> '{}') then raise exception '%: pick one of %', k, choices -> k; end if;
    elsif v is null or jsonb_typeof(v) <> 'boolean' then raise exception '% must be on or off', k; end if;
    nxt := nxt || jsonb_build_object(k, v);
    if prev -> k is distinct from v then parts := parts || (replace(k, '_', ' ') || ': ' || tfd_fmt(k, prev -> k) || ' → ' || tfd_fmt(k, v)); end if;
  end loop;
  if p_name = 'admin' and (nxt->>'settings' <> 'yes' or not (nxt->>'activity_log')::boolean) then
    raise exception 'Admins must keep Settings and Activity Log access, or nobody could change them back'; end if;
  if cardinality(parts) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update roles set perms = nxt where name = p_name;
  perform tfd_log(me.name, 'Settings', 'role_change', (select label from roles where name = p_name) || ' access: ' || array_to_string(parts, '; '),
    null, p_reason, jsonb_build_object('type', 'role', 'name', p_name, 'previous', prev));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_users() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'username', p.username, 'role', p.role, 'active', p.active,
      'rate', case when p.role = 'claude' then null else (select to_jsonb(x) from tfd_rate_for(p.id, p.role) x) end,
      'personal', (select jsonb_build_object('hourly_cents', hourly_cents, 'commission_bp', commission_bp) from rate_history
                   where scope = 'user' and target = p.id::text and effective_from <= now() order by effective_from desc, id desc limit 1))
    order by p.active desc, array_position(array['admin','streamer','assistant','packer','claude'], p.role), p.name) from profiles p), '[]');
end $$;

-- Called only by the website's server (service role) after it creates the login.
create or replace function tfd_create_profile(p_actor_auth uuid, p_auth_id uuid, p_name text, p_username text, p_role text) returns bigint
language plpgsql security definer set search_path = public as $$
declare actor profiles; id_ bigint; first_admin boolean;
begin
  first_admin := not exists (select 1 from profiles where role = 'admin');
  if first_admin then
    if p_role <> 'admin' then raise exception 'The first person must be an admin'; end if;
  else
    select * into actor from profiles where auth_id = p_actor_auth and active and role = 'admin';
    if actor.id is null then raise exception 'Admins only' using errcode = '42501'; end if;
  end if;
  if p_role not in ('admin','streamer','assistant','packer') then raise exception 'Pick a role'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'Name is required'; end if;
  if exists (select 1 from profiles where lower(name) = lower(trim(p_name)) and active) then raise exception 'Someone active already has that name'; end if;
  insert into profiles (auth_id, name, username, role) values (p_auth_id, trim(p_name), lower(nullif(trim(p_username), '')), p_role) returning id into id_;
  perform tfd_log(coalesce(actor.name, trim(p_name)), 'Settings', 'user_create',
    case when first_admin then 'First admin created: ' || trim(p_name) else 'Added ' || trim(p_name) || ' as ' || p_role end,
    jsonb_build_object('id', id_), null, case when first_admin then null else jsonb_build_object('type', 'user', 'id', id_, 'name', trim(p_name), 'role', p_role, 'active', false) end);
  return id_;
end $$;

create or replace function tfd_update_user(p_id bigint, p_name text, p_role text, p_active boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; u profiles; parts text[] := '{}';
begin
  me := tfd_require('admin');
  select * into u from profiles where id = p_id;
  if u.id is null then raise exception 'Unknown person'; end if;
  if u.role = 'claude' then raise exception 'Claude''s user can''t be edited'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'Name is required'; end if;
  if p_role not in ('admin','streamer','assistant','packer') then raise exception 'Pick a role'; end if;
  if u.role = 'admin' and u.active and (p_role <> 'admin' or not p_active)
     and not exists (select 1 from profiles where role = 'admin' and active and id <> u.id) then
    raise exception 'There must always be at least one active admin'; end if;
  if trim(p_name) <> u.name then parts := parts || ('name ' || u.name || ' → ' || trim(p_name)); end if;
  if p_role <> u.role then parts := parts || ('role ' || u.role || ' → ' || p_role); end if;
  if p_active <> u.active then parts := parts || (case when p_active then 'reactivated' else 'deactivated' end); end if;
  if cardinality(parts) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update profiles set name = trim(p_name), role = p_role, active = p_active where id = u.id;
  perform tfd_log(me.name, 'Settings', 'user_change', u.name || ': ' || array_to_string(parts, ', '), null, p_reason,
    jsonb_build_object('type', 'user', 'id', u.id, 'name', u.name, 'role', u.role, 'active', u.active));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_floor_preview(p_cost_cents int, p_platform text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pl jsonb;
begin
  perform tfd_require('admin');
  pl := tfd_get_setting('platform.' || p_platform);
  if pl is null then raise exception 'Unknown platform'; end if;
  return jsonb_build_object('cost_cents', p_cost_cents) ||
    tfd_floor(p_cost_cents, pl, (select commission_bp from tfd_rate_for(null, 'streamer')), (tfd_get_setting('pricing')->>'floor_profit_bp')::int);
end $$;

create or replace function tfd_activity(p_filters jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', at, 'actor', actor, 'tab', tab, 'action', action, 'summary', summary,
        'reason', reason, 'file', file, 'request', request, 'undone_by', undone_by, 'can_undo', undo is not null and undone_by is null) order by id desc)
      from (select * from activity_log a
        where (p_filters->>'from' is null or a.at >= (p_filters->>'from')::date)
          and (p_filters->>'to' is null or a.at < (p_filters->>'to')::date + 1)
          and (p_filters->>'actor' is null or a.actor = p_filters->>'actor')
          and (p_filters->>'tab' is null or a.tab = p_filters->>'tab')
          and (p_filters->>'action' is null or a.action = p_filters->>'action')
          and (p_filters->>'q' is null or a.summary ilike '%' || (p_filters->>'q') || '%' or a.details::text ilike '%' || (p_filters->>'q') || '%')
        order by id desc limit 500) x), '[]'),
    'facets', jsonb_build_object(
      'actors', (select coalesce(jsonb_agg(distinct actor), '[]') from activity_log),
      'tabs', (select coalesce(jsonb_agg(distinct tab), '[]') from activity_log),
      'actions', (select coalesce(jsonb_agg(distinct action), '[]') from activity_log)));
end $$;

create or replace function tfd_undo(p_id bigint, p_reason text, p_confirm boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; e activity_log; u jsonb; summ text; new_id bigint;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_confirm is not true then raise exception 'Undo needs a confirm'; end if;
  select * into e from activity_log where id = p_id for update;
  if e.id is null then raise exception 'No such entry'; end if;
  if e.undo is null then raise exception 'This action cannot be undone from the log'; end if;
  if e.undone_by is not null then raise exception 'Already undone'; end if;
  u := e.undo;
  if u->>'type' = 'setting' then
    insert into settings_history (key, value, effective_from, set_by, reason) values (u->>'key', u->'previous', now(), me.name, 'Undo #' || e.id || ': ' || p_reason);
    summ := 'Undid setting change #' || e.id;
  elsif u->>'type' = 'rate' then
    insert into rate_history (scope, target, hourly_cents, commission_bp, effective_from, set_by, reason)
      values (u->>'scope', u->>'target', (u->>'hourly_cents')::int, (u->>'commission_bp')::int, now(), me.name, 'Undo #' || e.id || ': ' || p_reason);
    summ := 'Undid rate change #' || e.id;
  elsif u->>'type' = 'user' then
    update profiles set name = u->>'name', role = u->>'role', active = (u->>'active')::boolean where id = (u->>'id')::bigint;
    if not exists (select 1 from profiles where role = 'admin' and active) then raise exception 'There must always be at least one active admin'; end if;
    summ := 'Undid change #' || e.id || ' to ' || (u->>'name');
  elsif u->>'type' = 'role' then
    update roles set perms = u->'previous' where name = u->>'name';
    summ := 'Undid access change #' || e.id;
  else raise exception 'This action cannot be undone';
  end if;
  new_id := tfd_log(me.name, e.tab, 'undo', summ, null, p_reason, null, e.id);
  update activity_log set undone_by = new_id where id = e.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_log_from_server(p_actor_auth uuid, p_action text, p_summary text) returns void
language plpgsql security definer set search_path = public as $$
declare actor profiles;
begin
  select * into actor from profiles where auth_id = p_actor_auth;
  perform tfd_log(coalesce(actor.name, 'System'), 'Settings', p_action, p_summary);
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function tfd_state(), tfd_settings(), tfd_setting_history(text), tfd_set_setting(text, jsonb, timestamptz, text),
  tfd_set_rate(text, text, int, int, timestamptz, text), tfd_set_role(text, jsonb, text), tfd_users(),
  tfd_update_user(bigint, text, text, boolean, text), tfd_floor_preview(int, text), tfd_activity(jsonb), tfd_undo(bigint, text, boolean)
  to authenticated;
grant execute on function tfd_create_profile(uuid, uuid, text, text, text), tfd_log_from_server(uuid, text, text) to service_role;
grant select on profiles to service_role;
