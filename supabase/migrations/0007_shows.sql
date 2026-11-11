-- TFD app — Phase 3: Shows (live). Setup, lineup, clock, streamer switch, live mapping with holds,
-- buyer's choice, giveaways, fixes, parts, % caps, end/reopen, listed-show export + lookup + live-map wins,
-- and the inventory lock while a show is live. Import / review / finalize come in Phase 4.

-- ---------------------------------------------------------------- tables
create table if not exists shows (
  id bigserial primary key,
  type text not null check (type in ('live','listed')),
  platform text not null check (platform in ('tiktok','whatnot')),
  name text,
  list_id bigint references inv_lists(id),
  list_name text not null default 'Full inventory',
  list_pct int,
  status text not null default 'setup' check (status in ('setup','live','ended','matched','finalized','cancelled')),
  split_mode text check (split_mode in ('even','lead')),
  paused boolean not null default false,
  part int not null default 1,
  next_pull int not null default 1,
  next_win int not null default 1,
  scope_skus char(6)[],          -- SKUs in the chosen list at Start live (null = full inventory)
  caps jsonb,                    -- % list: sku -> max units this show (fixed at Start live)
  export_qty jsonb,              -- listed show: sku -> qty exported for listing
  started_at timestamptz, ended_at timestamptz,
  created_by text not null, created_at timestamptz not null default now());

create table if not exists show_people (
  id bigserial primary key, show_id bigint not null references shows(id), profile_id bigint not null references profiles(id),
  role text not null check (role in ('streamer','assistant')), hourly_cents int not null check (hourly_cents >= 0),
  commission_bp int not null default 0 check (commission_bp >= 0), lead boolean not null default false, unique (show_id, profile_id));

create table if not exists show_events (
  id bigserial primary key, show_id bigint not null references shows(id), kind text not null, at timestamptz not null default now(),
  actor text not null, detail jsonb);
create index if not exists show_events_show on show_events (show_id, at, id);

create table if not exists bc_groups (
  id bigserial primary key, show_id bigint not null references shows(id), part int not null,
  status text not null default 'open' check (status in ('open','picked','cancelled')),
  opened_at timestamptz not null default now(), closed_at timestamptz, pull_id bigint);

create table if not exists pulls (
  id bigserial primary key, show_id bigint not null references shows(id), part int not null, pull_no int not null,
  sku char(6) not null references products(sku),
  kind text not null default 'normal' check (kind in ('normal','giveaway','win')),
  status text not null default 'held' check (status in ('held','void','released','sold')),
  bc_group_id bigint references bc_groups(id), outside_list boolean not null default false,
  on_air bigint[] not null default '{}', client_id uuid unique,
  scanned_at timestamptz not null default now(), scanned_by text not null, note text);
create unique index if not exists pulls_num on pulls (show_id, part, pull_no) where status <> 'void' and kind <> 'win';
create unique index if not exists pulls_win on pulls (show_id, pull_no) where status <> 'void' and kind = 'win';
create index if not exists pulls_sku on pulls (sku) where status = 'held';

create table if not exists bc_items (
  id bigserial primary key, group_id bigint not null references bc_groups(id), sku char(6) not null references products(sku),
  status text not null default 'shown' check (status in ('shown','picked','returned')), outside_list boolean not null default false,
  scanned_at timestamptz not null default now());

alter table shows enable row level security; alter table show_people enable row level security; alter table show_events enable row level security;
alter table bc_groups enable row level security; alter table pulls enable row level security; alter table bc_items enable row level security;
revoke all on shows, show_people, show_events, bc_groups, pulls, bc_items from anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function tfd_live_require() returns profiles language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('any');
  if me.role <> 'admin' and coalesce((select perms->>'live_mapping' from roles where name = me.role), 'none') = 'none' then
    raise exception 'You don''t have access to shows' using errcode = '42501';
  end if;
  return me;
end $$;

-- units promised to shows but not yet finalized: held pulls + items being shown in an open buyer's choice
create or replace function tfd_held(p_sku text) returns int language sql stable security definer set search_path = public as $$
  select ((select count(*) from pulls where sku = p_sku and status = 'held')
        + (select count(*) from bc_items i join bc_groups g on g.id = i.group_id where i.sku = p_sku and i.status = 'shown' and g.status = 'open'))::int $$;

create or replace function tfd_available(p_sku text) returns int language sql stable security definer set search_path = public as
  $$ select tfd_on_hand(p_sku) - tfd_held(p_sku) $$;

-- streamer-safe product card: no cost, only the rounded floor for this platform
create or replace function tfd_card(p_sku text, p_platform text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('sku', p.sku, 'brand', p.brand, 'model', p.model, 'color_code', p.color_code, 'lens_size', p.lens_size, 'name', p.name,
      'color_name', p.color_name, 'retail_cents', p.retail_cents, 'specs', p.specs, 'image_url', p.image_url, 'upc', p.upc,
      'bin', (select code from bins where id = p.bin_id),
      'floor_cents', (select (tfd_floor_for(max(unit_cost_cents), p_platform)->>'rounded_cents')::int from cost_layers c where c.sku = p.sku and c.qty_remaining > 0),
      'on_hand', tfd_on_hand(p.sku), 'held', tfd_held(p.sku), 'available', tfd_available(p.sku),
      'low_stock', coalesce(p.low_stock, (tfd_get_setting('inventory')->>'low_stock_default')::int))
  from products p where p.sku = p_sku $$;

-- seconds on the paid clock: from Start (or Reopen) to End; pauses keep running
create or replace function tfd_show_seconds(p_show bigint) returns int language plpgsql stable security definer set search_path = public as $$
declare e record; since timestamptz; total numeric := 0;
begin
  for e in select kind, at from show_events where show_id = p_show and kind in ('start','reopen','end') order by at, id loop
    if e.kind in ('start','reopen') then since := e.at;
    elsif since is not null then total := total + extract(epoch from e.at - since); since := null; end if;
  end loop;
  if since is not null then total := total + extract(epoch from now() - since); end if;
  return total::int;
end $$;

-- inventory lock while any show is live: unpaused = locked; paused = adding OK, removing needs a confirm
create or replace function tfd_inv_lock() returns jsonb language sql stable security definer set search_path = public as $$
  select case when not coalesce((tfd_get_setting('rules')->>'inventory_locked_live')::boolean, true) then jsonb_build_object('state', 'open')
    when exists (select 1 from shows where status = 'live' and not paused) then
      jsonb_build_object('state', 'locked', 'show', (select coalesce(name, 'Show #' || id) from shows where status = 'live' and not paused order by id limit 1))
    when exists (select 1 from shows where status = 'live') then
      jsonb_build_object('state', 'paused', 'show', (select coalesce(name, 'Show #' || id) from shows where status = 'live' order by id limit 1))
    else jsonb_build_object('state', 'open') end $$;

create or replace function tfd_show_get(p_id bigint) returns shows language plpgsql stable security definer set search_path = public as $$
declare s shows;
begin
  select * into s from shows where id = p_id;
  if s.id is null then raise exception 'No such show'; end if;
  return s;
end $$;

create or replace function tfd_show_label(s shows) returns text language sql immutable as
  $$ select coalesce(nullif(s.name, ''), case s.platform when 'tiktok' then 'TikTok' else 'Whatnot' end || ' ' || case when s.type = 'listed' then 'listed show' else 'show' end || ' #' || s.id) $$;

-- ---------------------------------------------------------------- setup (admins)
create or replace function tfd_lineup_options() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return jsonb_build_object(
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
        'streamer', (select to_jsonb(x) from tfd_rate_for(p.id, 'streamer') x), 'assistant', (select to_jsonb(x) from tfd_rate_for(p.id, 'assistant') x))
      order by array_position(array['streamer','assistant','admin'], p.role), p.name) from profiles p where p.active and p.role in ('streamer','assistant','admin')), '[]'),
    'lists', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'pct', l.pct) order by l.name) from inv_lists l), '[]'),
    'platforms', jsonb_build_object('tiktok', tfd_get_setting('platform.tiktok'), 'whatnot', tfd_get_setting('platform.whatnot')));
end $$;

create or replace function tfd_show_save(p_id bigint, p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; id_ bigint := p_id; person jsonb; nstream int; nassist int; nlead int; lst inv_lists; lbl text;
begin
  me := tfd_require('admin');
  if p->>'type' not in ('live','listed') then raise exception 'Pick a show type'; end if;
  if p->>'platform' not in ('tiktok','whatnot') then raise exception 'Pick a platform'; end if;
  if p->>'type' = 'listed' and p->>'platform' <> 'whatnot' then raise exception 'Listed shows are Whatnot only'; end if;
  if nullif(p->>'list_id', '') is not null then
    select * into lst from inv_lists where id = (p->>'list_id')::bigint;
    if lst.id is null then raise exception 'That inventory list no longer exists'; end if;
  end if;
  select count(*) filter (where x->>'role' = 'streamer'), count(*) filter (where x->>'role' = 'assistant'), count(*) filter (where (x->>'lead')::boolean)
    into nstream, nassist, nlead from jsonb_array_elements(coalesce(p->'people', '[]')) x;
  if nstream = 0 then raise exception 'Add at least one streamer'; end if;
  if nassist > 1 then raise exception 'Only one assistant per show'; end if;
  if nstream >= 2 and coalesce(p->>'split_mode', '') not in ('even','lead') then raise exception 'With two streamers, pick Split evenly or Lead + support'; end if;
  if nstream >= 2 and p->>'split_mode' = 'lead' and nlead <> 1 then raise exception 'Pick exactly one lead streamer'; end if;
  if (select count(distinct x->>'profile_id') from jsonb_array_elements(p->'people') x) <> jsonb_array_length(p->'people') then raise exception 'Each person can only be in the lineup once'; end if;
  for person in select * from jsonb_array_elements(p->'people') loop
    if not exists (select 1 from profiles where id = (person->>'profile_id')::bigint and active and role in ('streamer','assistant','admin')) then raise exception 'Lineup has someone who can''t be on a show'; end if;
    if (person->>'role') = 'streamer' and (select role from profiles where id = (person->>'profile_id')::bigint) = 'admin' then raise exception 'Admins can only fill the assistant spot'; end if;
  end loop;
  if id_ is null then
    insert into shows (type, platform, name, list_id, list_name, list_pct, split_mode, created_by)
      values (p->>'type', p->>'platform', nullif(trim(p->>'name'), ''), lst.id, coalesce(lst.name, 'Full inventory'), lst.pct,
              case when nstream >= 2 then p->>'split_mode' end, me.name) returning id into id_;
  else
    select * into s from shows where id = id_ for update;
    if s.status <> 'setup' then raise exception 'Setup can only be changed before the show starts'; end if;
    update shows set type = p->>'type', platform = p->>'platform', name = nullif(trim(p->>'name'), ''), list_id = lst.id, list_name = coalesce(lst.name, 'Full inventory'),
      list_pct = lst.pct, split_mode = case when nstream >= 2 then p->>'split_mode' end, export_qty = case when s.list_id is distinct from lst.id then null else export_qty end
      where id = id_;
    delete from show_people where show_id = id_;
  end if;
  insert into show_people (show_id, profile_id, role, hourly_cents, commission_bp, lead)
    select id_, (x->>'profile_id')::bigint, x->>'role', coalesce((x->>'hourly_cents')::int, 0),
           case when x->>'role' = 'assistant' then 0 else coalesce((x->>'commission_bp')::int, 0) end, coalesce((x->>'lead')::boolean, false)
    from jsonb_array_elements(p->'people') x;
  select * into s from shows where id = id_;
  lbl := tfd_show_label(s);
  perform tfd_log(me.name, 'Shows', case when p_id is null then 'show_create' else 'show_edit' end,
    case when p_id is null then 'Show set up: ' else 'Show setup edited: ' end || lbl || ' (' || case s.platform when 'tiktok' then 'TikTok' else 'Whatnot' end || ', ' || s.list_name || ', ' ||
      (select string_agg(pr.name || ' ' || sp.role || ' $' || to_char(sp.hourly_cents / 100.0, 'FM999990.00') || '/hr' ||
         case when sp.commission_bp > 0 then ' + ' || to_char(sp.commission_bp / 100.0, 'FM990.##') || '%' else '' end, ', ' order by sp.role desc, pr.name)
       from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = id_) || ')',
    jsonb_build_object('show', id_));
  return id_;
end $$;

create or replace function tfd_show_cancel(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows;
begin
  me := tfd_require('admin');
  s := tfd_show_get(p_id);
  if s.status <> 'setup' then raise exception 'Only a show that hasn''t started can be cancelled'; end if;
  update shows set status = 'cancelled' where id = p_id;
  perform tfd_log(me.name, 'Shows', 'show_cancel', 'Show cancelled before starting: ' || tfd_show_label(s), jsonb_build_object('show', p_id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- reading shows
create or replace function tfd_shows() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', tfd_show_label(s), 'name', s.name, 'type', s.type, 'platform', s.platform,
      'status', s.status, 'list_name', s.list_name, 'created_at', s.created_at, 'started_at', s.started_at, 'ended_at', s.ended_at,
      'lineup', (select coalesce(jsonb_agg(pr.name || case when sp.role = 'assistant' then ' (assistant)' else '' end order by sp.role desc, sp.lead desc, pr.name), '[]')
                 from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = s.id),
      'pulls', (select count(*) from pulls where show_id = s.id and status <> 'void'),
      'seconds', tfd_show_seconds(s.id))
    order by (s.status = 'live') desc, coalesce(s.started_at, s.created_at) desc, s.id desc)
    from shows s where s.status <> 'cancelled' and (me.role = 'admin' or s.status in ('setup','live','ended'))), '[]');
end $$;

create or replace function tfd_show(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_id); g bc_groups; onair bigint[];
begin
  select detail into onair from (select (select array_agg(x::bigint) from jsonb_array_elements_text(detail->'ids') x) detail from show_events
    where show_id = p_id and kind = 'on_air' order by at desc, id desc limit 1) z;
  select * into g from bc_groups where show_id = p_id and status = 'open' order by id desc limit 1;
  return to_jsonb(s) - 'caps' - 'scope_skus' || jsonb_build_object(
    'label', tfd_show_label(s), 'is_admin', me.role = 'admin',
    'seconds', tfd_show_seconds(p_id), 'on_air', to_jsonb(coalesce(onair, '{}')),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('profile_id', sp.profile_id, 'name', pr.name, 'role', sp.role, 'lead', sp.lead,
        'hourly_cents', case when me.role = 'admin' then sp.hourly_cents end, 'commission_bp', case when me.role = 'admin' then sp.commission_bp end)
        order by sp.role desc, sp.lead desc, pr.name), '[]') from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = p_id),
    'counts', jsonb_build_object('part', (select count(*) from pulls where show_id = p_id and part = s.part and status <> 'void' and kind <> 'win'),
       'total', (select count(*) from pulls where show_id = p_id and status <> 'void'),
       'giveaways', (select count(*) from pulls where show_id = p_id and status <> 'void' and kind = 'giveaway'),
       'wins', (select count(*) from pulls where show_id = p_id and status <> 'void' and kind = 'win'),
       'void', (select count(*) from pulls where show_id = p_id and status = 'void')),
    'pulls', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'part', pl.part, 'pull_no', pl.pull_no, 'sku', pl.sku, 'kind', pl.kind, 'status', pl.status,
        'at', pl.scanned_at, 'by', pl.scanned_by, 'outside_list', pl.outside_list, 'bc', pl.bc_group_id is not null, 'note', pl.note,
        'name', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)), 'brand', pr.brand, 'model', pr.model, 'color_code', pr.color_code, 'lens_size', pr.lens_size,
        'on_air', (select coalesce(jsonb_agg(pf.name), '[]') from profiles pf where pf.id = any(pl.on_air)))
        order by pl.id desc), '[]') from pulls pl join products pr on pr.sku = pl.sku where pl.show_id = p_id),
    'bc', case when g.id is null then null else jsonb_build_object('id', g.id, 'items',
        (select coalesce(jsonb_agg(tfd_card(i.sku, s.platform) || jsonb_build_object('item_id', i.id, 'outside_list', i.outside_list) order by i.id), '[]')
         from bc_items i where i.group_id = g.id and i.status = 'shown')) end,
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', e.actor, 'detail', e.detail) order by e.at desc, e.id desc), '[]')
               from show_events e where e.show_id = p_id),
    'lock', tfd_inv_lock());
end $$;

-- everything the live screen needs to keep scanning offline: the SKUs in scope with streamer-safe cards and live availability
create or replace function tfd_show_catalog(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_id);
begin
  return jsonb_build_object('scope', to_jsonb(s.scope_skus), 'caps', s.caps,
    'used', (select coalesce(jsonb_object_agg(sku, n), '{}') from (select sku, count(*) n from pulls where show_id = p_id and status = 'held' group by sku) u),
    'items', (select coalesce(jsonb_agg(tfd_card(p.sku, s.platform)), '[]') from products p where tfd_on_hand(p.sku) > 0 or p.sku in (select sku from pulls where show_id = p_id)));
end $$;

-- ---------------------------------------------------------------- clock + lineup on air
create or replace function tfd_show_start(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; lst inv_lists; scope char(6)[]; cap_map jsonb;
begin
  select * into s from shows where id = p_id for update;
  if s.id is null then raise exception 'No such show'; end if;
  if s.status <> 'setup' then raise exception 'This show already started'; end if;
  if exists (select 1 from shows where status = 'live' and id <> p_id) then raise exception 'Another show is live. End it first'; end if;
  if s.list_id is not null then
    select * into lst from inv_lists where id = s.list_id;
    if lst.id is null then raise exception 'The show''s inventory list was deleted. Edit setup and pick another'; end if;
    lst.pct := null;   -- scope = every SKU in the list; the % is applied below to available units
    select array_agg(sku) into scope from tfd_list_skus(lst);
    scope := coalesce(scope, '{}');
    if s.list_pct is not null and s.type = 'live' then
      select coalesce(jsonb_object_agg(x, floor(greatest(tfd_available(x), 0) * s.list_pct / 100.0)::int), '{}') into cap_map from unnest(scope) x;
    end if;
  end if;
  update shows set status = 'live', started_at = now(), paused = false, scope_skus = scope, caps = cap_map where id = p_id;
  insert into show_events (show_id, kind, actor, detail) values (p_id, 'start', me.name, null);
  insert into show_events (show_id, kind, actor, detail)
    values (p_id, 'on_air', me.name, jsonb_build_object('ids', (select jsonb_agg(profile_id order by lead desc, id) from show_people where show_id = p_id and role = 'streamer')));
  perform tfd_log(me.name, 'Shows', 'show_start', 'Show started: ' || tfd_show_label(s) ||
    case when cap_map is not null then ' (' || s.list_pct || '% list caps fixed)' else '' end, jsonb_build_object('show', p_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_pause(p_id bigint, p_paused boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows;
begin
  select * into s from shows where id = p_id for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if s.paused = p_paused then return jsonb_build_object('ok', true); end if;
  if p_paused and exists (select 1 from bc_groups where show_id = p_id and status = 'open') then raise exception 'Finish or cancel the buyer''s choice first'; end if;
  update shows set paused = p_paused where id = p_id;
  insert into show_events (show_id, kind, actor) values (p_id, case when p_paused then 'pause' else 'resume' end, me.name);
  perform tfd_log(me.name, 'Shows', case when p_paused then 'show_pause' else 'show_resume' end,
    case when p_paused then 'Mapping paused (clock keeps running; inventory can be added)' else 'Mapping resumed' end || ': ' || tfd_show_label(s), jsonb_build_object('show', p_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_on_air(p_id bigint, p_ids bigint[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_id);
begin
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if cardinality(coalesce(p_ids, '{}')) = 0 then raise exception 'Someone has to be on air'; end if;
  if exists (select 1 from unnest(p_ids) x where not exists (select 1 from show_people where show_id = p_id and profile_id = x and role = 'streamer')) then
    raise exception 'Only this show''s streamers can be on air'; end if;
  insert into show_events (show_id, kind, actor, detail) values (p_id, 'on_air', me.name, jsonb_build_object('ids', to_jsonb(p_ids)));
  perform tfd_log(me.name, 'Shows', 'on_air', 'On air: ' || (select string_agg(name, ' + ') from profiles where id = any(p_ids)) || ' (' || tfd_show_label(s) || ')', jsonb_build_object('show', p_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_on_air_now(p_id bigint) returns bigint[] language sql stable security definer set search_path = public as $$
  select coalesce((select (select array_agg(x::bigint) from jsonb_array_elements_text(detail->'ids') x) from show_events
    where show_id = p_id and kind = 'on_air' order by at desc, id desc limit 1), '{}') $$;

-- ---------------------------------------------------------------- scanning
-- common checks for anything that takes a unit (pull or buyer's-choice item). Returns null if OK, or {needs_confirm|error}.
create or replace function tfd_scan_check(s shows, p_sku text, p_confirm_outside boolean) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare used int; cap int;
begin
  if not exists (select 1 from products where sku = p_sku) then return jsonb_build_object('error', 'Unknown SKU ' || p_sku); end if;
  if tfd_available(p_sku) <= 0 then return jsonb_build_object('error', 'Out of stock — unable to run', 'blocked', 'out'); end if;
  if s.caps is not null and s.caps ? p_sku then
    cap := (s.caps->>p_sku)::int;
    select count(*) into used from pulls where show_id = s.id and sku = p_sku and status = 'held';
    used := used + (select count(*) from bc_items i join bc_groups g on g.id = i.group_id where g.show_id = s.id and g.status = 'open' and i.status = 'shown' and i.sku = p_sku);
    if used >= cap then return jsonb_build_object('error', 'List limit reached (' || cap || ' for this show) — unable to run', 'blocked', 'cap'); end if;
  end if;
  if s.scope_skus is not null and not p_sku = any(s.scope_skus) and not coalesce(p_confirm_outside, false) then
    return jsonb_build_object('needs_confirm', true, 'message', 'SKU ' || p_sku || ' isn''t in this show''s inventory (' || s.list_name || '). Run it anyway?');
  end if;
  return null;
end $$;

create or replace function tfd_scan(p_show bigint, p_sku text, p_client_id uuid default null, p_kind text default 'normal', p_confirm_outside boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; chk jsonb; pl pulls; card jsonb; sk text := trim(p_sku);
begin
  if p_client_id is not null then
    select * into pl from pulls where client_id = p_client_id;
    if pl.id is not null then return jsonb_build_object('ok', true, 'repeat', true, 'pull', to_jsonb(pl), 'card', tfd_card(pl.sku, (select platform from shows where id = pl.show_id))); end if;
  end if;
  select * into s from shows where id = p_show for update;
  if s.id is null then raise exception 'No such show'; end if;
  if s.status <> 'live' then raise exception 'The show isn''t live. Start live to scan'; end if;
  if s.type <> 'live' then raise exception 'This is a listed show. Scans are lookups; use Live map for buyer''s choice'; end if;
  if s.paused then raise exception 'Mapping is paused. Resume to scan'; end if;
  if p_kind not in ('normal','giveaway') then raise exception 'Unknown pull type'; end if;
  if p_kind = 'giveaway' and s.platform <> 'whatnot' then raise exception 'Giveaways are Whatnot only'; end if;
  if exists (select 1 from bc_groups where show_id = p_show and status = 'open') then raise exception 'A buyer''s choice is open. Pick the winner''s item or cancel it first'; end if;
  chk := tfd_scan_check(s, sk, p_confirm_outside);
  if chk ? 'needs_confirm' then return chk; end if;
  if chk ? 'error' then return jsonb_build_object('ok', false) || chk || jsonb_build_object('card', tfd_card(sk, s.platform)); end if;
  insert into pulls (show_id, part, pull_no, sku, kind, outside_list, on_air, client_id, scanned_by)
    values (p_show, s.part, s.next_pull, sk, p_kind, s.scope_skus is not null and not sk = any(s.scope_skus), tfd_on_air_now(p_show), p_client_id, me.name) returning * into pl;
  update shows set next_pull = next_pull + 1 where id = p_show;
  card := tfd_card(sk, s.platform);
  return jsonb_build_object('ok', true, 'pull', to_jsonb(pl), 'card', card, 'low', (card->>'available')::int <= (card->>'low_stock')::int);
end $$;

create or replace function tfd_lookup(p_show bigint, p_sku text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_show);
begin
  if not exists (select 1 from products where sku = trim(p_sku)) then raise exception 'Unknown SKU %', trim(p_sku); end if;
  return tfd_card(trim(p_sku), s.platform) || jsonb_build_object('in_scope', s.scope_skus is null or trim(p_sku) = any(s.scope_skus),
    'listed_qty', (s.export_qty->>trim(p_sku))::int);
end $$;

-- ---------------------------------------------------------------- buyer's choice (live mapping) / Live map (listed shows)
create or replace function tfd_bc_open(p_show bigint) returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; gid bigint;
begin
  select * into s from shows where id = p_show for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if s.paused then raise exception 'Mapping is paused. Resume first'; end if;
  if exists (select 1 from bc_groups where show_id = p_show and status = 'open') then raise exception 'A buyer''s choice is already open'; end if;
  insert into bc_groups (show_id, part) values (p_show, s.part) returning id into gid;
  return gid;
end $$;

create or replace function tfd_bc_add(p_group bigint, p_sku text, p_confirm_outside boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); g bc_groups; s shows; chk jsonb; iid bigint; sk text := trim(p_sku);
begin
  select * into g from bc_groups where id = p_group for update;
  if g.status is distinct from 'open' then raise exception 'This buyer''s choice is closed'; end if;
  select * into s from shows where id = g.show_id for update;
  chk := tfd_scan_check(s, sk, p_confirm_outside);
  if chk ? 'needs_confirm' then return chk; end if;
  if chk ? 'error' then return jsonb_build_object('ok', false) || chk || jsonb_build_object('card', tfd_card(sk, s.platform)); end if;
  insert into bc_items (group_id, sku, outside_list) values (p_group, sk, s.scope_skus is not null and not sk = any(s.scope_skus)) returning id into iid;
  return jsonb_build_object('ok', true, 'item_id', iid, 'card', tfd_card(sk, s.platform));
end $$;

create or replace function tfd_bc_remove(p_item bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require();
begin
  update bc_items i set status = 'returned' from bc_groups g where i.id = p_item and g.id = i.group_id and g.status = 'open' and i.status = 'shown';
  if not found then raise exception 'That item isn''t in an open buyer''s choice'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_bc_pick(p_group bigint, p_item bigint, p_client_id uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); g bc_groups; s shows; it bc_items; pl pulls; n int;
begin
  select * into g from bc_groups where id = p_group for update;
  if g.status is distinct from 'open' then raise exception 'This buyer''s choice is closed'; end if;
  select * into it from bc_items where id = p_item and group_id = p_group and status = 'shown';
  if it.id is null then raise exception 'Pick one of the items shown'; end if;
  select * into s from shows where id = g.show_id for update;
  if s.type = 'listed' then
    insert into pulls (show_id, part, pull_no, sku, kind, bc_group_id, outside_list, on_air, client_id, scanned_by)
      values (s.id, 0, s.next_win, it.sku, 'win', g.id, it.outside_list, tfd_on_air_now(s.id), p_client_id, me.name) returning * into pl;
    update shows set next_win = next_win + 1 where id = s.id;
  else
    insert into pulls (show_id, part, pull_no, sku, kind, bc_group_id, outside_list, on_air, client_id, scanned_by)
      values (s.id, s.part, s.next_pull, it.sku, 'normal', g.id, it.outside_list, tfd_on_air_now(s.id), p_client_id, me.name) returning * into pl;
    update shows set next_pull = next_pull + 1 where id = s.id;
  end if;
  update bc_items set status = case when id = p_item then 'picked' else 'returned' end where group_id = p_group and status = 'shown';
  update bc_groups set status = 'picked', closed_at = now(), pull_id = pl.id where id = p_group;
  select count(*) into n from bc_items where group_id = p_group;
  perform tfd_log(me.name, 'Shows', 'buyers_choice', case when s.type = 'listed' then 'Live map win #' else 'Buyer''s choice pull #' end || pl.pull_no ||
    ': SKU ' || pl.sku || ' picked from ' || n || ' shown (' || tfd_show_label(s) || ')', jsonb_build_object('show', s.id, 'pull', pl.id));
  return jsonb_build_object('ok', true, 'pull', to_jsonb(pl), 'card', tfd_card(pl.sku, s.platform));
end $$;

create or replace function tfd_bc_cancel(p_group bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require();
begin
  update bc_groups set status = 'cancelled', closed_at = now() where id = p_group and status = 'open';
  if not found then raise exception 'No open buyer''s choice'; end if;
  update bc_items set status = 'returned' where group_id = p_group and status = 'shown';
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- fixes (all logged)
create or replace function tfd_pull_undo_last(p_show bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; pl pulls;
begin
  select * into s from shows where id = p_show for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  select * into pl from pulls where show_id = p_show and status = 'held' order by id desc limit 1;
  if pl.id is null then raise exception 'Nothing to undo'; end if;
  update pulls set status = 'void', note = 'Undone' where id = pl.id;
  if pl.kind = 'win' and pl.pull_no = s.next_win - 1 then update shows set next_win = next_win - 1 where id = p_show;
  elsif pl.kind <> 'win' and pl.part = s.part and pl.pull_no = s.next_pull - 1 then update shows set next_pull = next_pull - 1 where id = p_show; end if;
  perform tfd_log(me.name, 'Shows', 'pull_undo', 'Undid ' || case when pl.kind = 'win' then 'win #' else 'Part ' || pl.part || ' pull #' end || pl.pull_no || ' (SKU ' || pl.sku || ', ' || tfd_show_label(s) || ')',
    jsonb_build_object('show', p_show, 'pull', pl.id));
  return jsonb_build_object('ok', true, 'pull', to_jsonb(pl));
end $$;

create or replace function tfd_pull_void(p_pull bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); pl pulls; s shows;
begin
  select * into pl from pulls where id = p_pull for update;
  if pl.id is null then raise exception 'No such pull'; end if;
  select * into s from shows where id = pl.show_id;
  if s.status not in ('live','ended') then raise exception 'Pulls can only be fixed while the show is live or ended'; end if;
  if pl.status <> 'held' then raise exception 'That pull is already void'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  update pulls set status = 'void', note = trim(p_reason) where id = p_pull;
  perform tfd_log(me.name, 'Shows', 'pull_void', 'Voided ' || case when pl.kind = 'win' then 'win #' else 'Part ' || pl.part || ' pull #' end || pl.pull_no || ' (SKU ' || pl.sku || ', ' || tfd_show_label(s) || ')',
    jsonb_build_object('show', s.id, 'pull', p_pull), p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pull_edit(p_pull bigint, p_sku text, p_reason text, p_confirm_outside boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); pl pulls; s shows; chk jsonb; sk text := trim(p_sku);
begin
  select * into pl from pulls where id = p_pull for update;
  if pl.id is null then raise exception 'No such pull'; end if;
  select * into s from shows where id = pl.show_id for update;
  if s.status not in ('live','ended') then raise exception 'Pulls can only be fixed while the show is live or ended'; end if;
  if pl.status <> 'held' then raise exception 'That pull is void'; end if;
  if sk = pl.sku then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  chk := tfd_scan_check(s, sk, p_confirm_outside);
  if chk ? 'needs_confirm' then return chk; end if;
  if chk ? 'error' then raise exception '%', chk->>'error'; end if;
  update pulls set sku = sk, outside_list = s.scope_skus is not null and not sk = any(s.scope_skus) where id = p_pull;
  perform tfd_log(me.name, 'Shows', 'pull_edit', case when pl.kind = 'win' then 'Win #' else 'Part ' || pl.part || ' pull #' end || pl.pull_no || ': SKU ' || pl.sku || ' → ' || sk || ' (' || tfd_show_label(s) || ')',
    jsonb_build_object('show', s.id, 'pull', p_pull, 'from', pl.sku, 'to', sk), p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pull_kind(p_pull bigint, p_kind text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); pl pulls; s shows;
begin
  select * into pl from pulls where id = p_pull for update;
  select * into s from shows where id = pl.show_id;
  if pl.status <> 'held' or s.status not in ('live','ended') then raise exception 'That pull can''t be changed'; end if;
  if p_kind not in ('normal','giveaway') or pl.kind = 'win' then raise exception 'Unknown pull type'; end if;
  if p_kind = 'giveaway' and s.platform <> 'whatnot' then raise exception 'Giveaways are Whatnot only'; end if;
  update pulls set kind = p_kind where id = p_pull;
  perform tfd_log(me.name, 'Shows', 'pull_kind', 'Part ' || pl.part || ' pull #' || pl.pull_no || ' marked ' || case when p_kind = 'giveaway' then 'as a giveaway' else 'as a normal pull' end || ' (' || tfd_show_label(s) || ')',
    jsonb_build_object('show', s.id, 'pull', p_pull));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_new_part(p_show bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows;
begin
  select * into s from shows where id = p_show for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if exists (select 1 from bc_groups where show_id = p_show and status = 'open') then raise exception 'Finish or cancel the buyer''s choice first'; end if;
  update shows set part = part + 1, next_pull = 1 where id = p_show;
  insert into show_events (show_id, kind, actor, detail) values (p_show, 'new_part', me.name, jsonb_build_object('part', s.part + 1));
  perform tfd_log(me.name, 'Shows', 'new_part', 'Part ' || (s.part + 1) || ' started, pulls restart at #1 (' || tfd_show_label(s) || ')', jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true, 'part', s.part + 1);
end $$;

create or replace function tfd_show_set_pull(p_show bigint, p_next int, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows;
begin
  select * into s from shows where id = p_show for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if p_next is null or p_next < 1 then raise exception 'Pull # must be 1 or more'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if exists (select 1 from pulls where show_id = p_show and part = s.part and pull_no = p_next and status <> 'void' and kind <> 'win') then
    raise exception 'Part % already has a pull #%', s.part, p_next; end if;
  update shows set next_pull = p_next where id = p_show;
  insert into show_events (show_id, kind, actor, detail) values (p_show, 'pull_override', me.name, jsonb_build_object('part', s.part, 'from', s.next_pull, 'to', p_next));
  perform tfd_log(me.name, 'Shows', 'pull_override', 'Next pull # changed ' || s.next_pull || ' → ' || p_next || ' in Part ' || s.part || ' (' || tfd_show_label(s) || ')',
    jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- end / reopen
create or replace function tfd_show_end(p_show bigint, p_confirm text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows;
begin
  select * into s from shows where id = p_show for update;
  if s.status <> 'live' then raise exception 'The show isn''t live'; end if;
  if upper(trim(coalesce(p_confirm, ''))) <> 'SHOW OVER' then raise exception 'Type SHOW OVER to end the show'; end if;
  if exists (select 1 from bc_groups where show_id = p_show and status = 'open') then raise exception 'Finish or cancel the buyer''s choice first'; end if;
  update shows set status = 'ended', ended_at = now(), paused = false where id = p_show;
  insert into show_events (show_id, kind, actor) values (p_show, 'end', me.name);
  perform tfd_log(me.name, 'Shows', 'show_end', 'Show ended: ' || tfd_show_label(s) || ' (' || (select count(*) from pulls where show_id = p_show and status = 'held') || ' pulls held, ' ||
    to_char(make_interval(secs => tfd_show_seconds(p_show)), 'HH24"h "MI"m"') || ' live)', jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_show_reopen(p_show bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'ended' then raise exception 'Only an ended show can be reopened'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if exists (select 1 from shows where status = 'live' and id <> p_show) then raise exception 'Another show is live. End it first'; end if;
  update shows set status = 'live', ended_at = null where id = p_show;
  insert into show_events (show_id, kind, actor, detail) values (p_show, 'reopen', me.name, jsonb_build_object('reason', p_reason));
  perform tfd_log(me.name, 'Shows', 'show_reopen', 'Show reopened: ' || tfd_show_label(s) || ' (clock resumes now; the gap is unpaid unless edited at review)',
    jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- listed show: export with oversell check
create or replace function tfd_show_export(p_show bigint, p_confirm boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; ex jsonb; warn jsonb := '[]'; r jsonb; other int; held int; oh int; q int;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.type <> 'listed' then raise exception 'Only listed shows export a listing'; end if;
  if s.status not in ('setup','live') then raise exception 'The listing can only be exported before or during the show'; end if;
  ex := tfd_whatnot_export(s.list_id);
  for r in select * from jsonb_array_elements(ex->'rows') loop
    q := (r->>'qty')::int; oh := tfd_on_hand(r->>'sku'); held := tfd_held(r->>'sku');
    select coalesce(sum((o.export_qty->>(r->>'sku'))::int), 0) into other from shows o
      where o.id <> p_show and o.type = 'listed' and o.status in ('setup','live','ended','matched') and o.export_qty ? (r->>'sku');
    if q + other + held > oh then
      warn := warn || jsonb_build_object('sku', r->>'sku', 'name', coalesce(r->>'name', concat_ws(' ', r->>'brand', r->>'model')), 'exporting', q, 'other_shows', other, 'held', held, 'on_hand', oh);
    end if;
  end loop;
  if jsonb_array_length(warn) > 0 and not p_confirm then
    return jsonb_build_object('needs_confirm', true, 'warnings', warn);
  end if;
  update shows set export_qty = (select coalesce(jsonb_object_agg(x->>'sku', (x->>'qty')::int), '{}') from jsonb_array_elements(ex->'rows') x) where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_export', 'Listing exported for ' || tfd_show_label(s) || ': ' || jsonb_array_length(ex->'rows') || ' SKUs' ||
    case when jsonb_array_length(warn) > 0 then ', ' || jsonb_array_length(warn) || ' oversell warning(s) accepted ("Yes, I understand")' else '' end,
    jsonb_build_object('show', p_show, 'warnings', warn));
  return ex || jsonb_build_object('warnings', warn, 'list', tfd_show_label(s) || ' (' || s.list_name || ')');
end $$;

-- mapping file (download any time): every pull with its status
create or replace function tfd_show_mapping(p_show bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_show);
begin
  return jsonb_build_object('label', tfd_show_label(s), 'rows', coalesce((select jsonb_agg(jsonb_build_object('part', pl.part, 'pull_no', pl.pull_no, 'kind', pl.kind, 'status', pl.status,
      'sku', pl.sku, 'product', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)), 'brand', pr.brand, 'model', pr.model, 'color_code', pr.color_code, 'lens_size', pr.lens_size,
      'scanned_at', pl.scanned_at, 'scanned_by', pl.scanned_by, 'on_air', (select string_agg(name, ' + ') from profiles where id = any(pl.on_air)),
      'buyers_choice', pl.bc_group_id is not null, 'outside_list', pl.outside_list, 'note', pl.note) order by pl.kind = 'win', pl.part, pl.pull_no, pl.id)
    from pulls pl join products pr on pr.sku = pl.sku where pl.show_id = p_show), '[]'));
end $$;

-- ---------------------------------------------------------------- stock now shows held units; adjustments respect the live lock
create or replace function tfd_stock() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare low_default int := (tfd_get_setting('inventory')->>'low_stock_default')::int;
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(row order by row->>'sku') from (
    select to_jsonb(p) || jsonb_build_object(
      'bin', b.code, 'on_hand', s.on_hand, 'held', h.held, 'sold_not_packed', 0, 'available', s.on_hand - h.held,
      'value_cents', s.value_cents, 'max_cost_cents', s.max_cost, 'low_stock_effective', coalesce(p.low_stock, low_default),
      'low_dismissed', tfd_alert_dismissed(p.sku, 'low', s.on_hand), 'out_dismissed', tfd_alert_dismissed(p.sku, 'out', s.on_hand),
      'floor_tiktok', case when s.max_cost is null then null else (tfd_floor_for(s.max_cost, 'tiktok')->>'rounded_cents')::int end,
      'floor_whatnot', case when s.max_cost is null then null else (tfd_floor_for(s.max_cost, 'whatnot')->>'rounded_cents')::int end,
      'last_received', (select max(r.received_date) from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku),
      'suppliers', (select coalesce(jsonb_agg(distinct r.supplier) filter (where r.supplier is not null), '[]') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku),
      'lots', (select coalesce(jsonb_agg(distinct r.name), '[]') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku),
      'receipts', (select coalesce(jsonb_agg(distinct r.id), '[]') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku and c.qty_remaining > 0),
      'sold_30', 0) as row
    from products p left join bins b on b.id = p.bin_id
    cross join lateral (select coalesce(sum(qty_remaining), 0)::int on_hand, coalesce(sum(qty_remaining::bigint * unit_cost_cents), 0) value_cents,
                               max(unit_cost_cents) filter (where qty_remaining > 0) max_cost from cost_layers c where c.sku = p.sku) s
    cross join lateral (select tfd_held(p.sku) held) h) x), '[]');
end $$;

create or replace function tfd_adjust(p_sku text, p_direction text, p_qty int, p_reason text, p_note text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; p products; rules jsonb := tfd_get_setting('rules'); tk record; v bigint; cost int; lid bigint; mid bigint; ok_reasons text[]; lk jsonb := tfd_inv_lock(); avail int;
begin
  me := tfd_require('admin');
  select * into p from products where sku = p_sku;
  if p.sku is null then raise exception 'No such SKU: %', p_sku; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be at least 1'; end if;
  if lk->>'state' = 'locked' then raise exception 'Inventory is locked while "%" is live. Pause mapping to make changes', lk->>'show'; end if;
  if (rules->>'adjust_reason_required')::boolean and trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_direction = 'out' then
    ok_reasons := array['damaged','lost','theft','personal/sample','return to supplier','count correction'];
    if trim(coalesce(p_reason, '')) <> '' and not p_reason = any(ok_reasons) then raise exception 'Pick a reason from the list'; end if;
    avail := tfd_available(p_sku);
    if p_qty > avail then raise exception 'Only % unit(s) of SKU % available to remove (% on hand, % held by shows)', greatest(avail, 0), p_sku, tfd_on_hand(p_sku), tfd_held(p_sku); end if;
    if lk->>'state' = 'paused' and p_confirm is not true then
      return jsonb_build_object('needs_confirm', true, 'message', '"' || (lk->>'show') || '" is live (paused). Removing units during a show needs a confirm.');
    end if;
    select max(unit_cost_cents) into cost from cost_layers where sku = p_sku and qty_remaining > 0;
  elsif p_direction = 'in' then
    select unit_cost_cents into cost from cost_layers where sku = p_sku order by created_at desc, id desc limit 1;
    if cost is null then raise exception 'SKU % has never been received, so it has no cost. Receive it instead.', p_sku; end if;
  else raise exception 'Direction must be in or out'; end if;
  if (rules->>'adjust_confirm_enabled')::boolean and p_confirm is not true
     and (p_qty > (rules->>'adjust_confirm_units')::int or p_qty::bigint * cost > (rules->>'adjust_confirm_cents')::bigint) then
    return jsonb_build_object('needs_confirm', true, 'message', 'This is a large adjustment: ' || p_qty || ' unit(s), about ' || tfd_fmt('x_cents', to_jsonb(p_qty::bigint * cost)) || ' at cost. Confirm to continue.');
  end if;
  if p_direction = 'out' then
    select * into tk from tfd_take_fifo(p_sku, p_qty);
    insert into stock_moves (sku, kind, qty, value_cents, reason, note, actor, detail) values (p_sku, 'adjust_out', -p_qty, -tk.value_cents, p_reason, nullif(trim(p_note), ''), me.name, jsonb_build_object('taken', tk.taken)) returning id into mid;
    v := tk.value_cents;
    perform tfd_log(me.name, 'Inventory', 'adjust_out', 'Removed ' || p_qty || ' × SKU ' || p_sku || ' (' || p_reason || '), ' || tfd_fmt('x_cents', to_jsonb(v)) || ' at cost',
      jsonb_build_object('sku', p_sku, 'move', mid), nullif(trim(coalesce(p_reason, '') || coalesce(': ' || nullif(trim(p_note), ''), '')), ''), jsonb_build_object('type', 'adjust', 'move', mid));
  else
    insert into cost_layers (sku, unit_cost_cents, qty_in, qty_remaining) values (p_sku, cost, p_qty, p_qty) returning id into lid;
    insert into stock_moves (sku, kind, qty, value_cents, reason, note, actor, detail) values (p_sku, 'adjust_in', p_qty, p_qty::bigint * cost, p_reason, nullif(trim(p_note), ''), me.name, jsonb_build_object('layer', lid)) returning id into mid;
    v := p_qty::bigint * cost;
    perform tfd_log(me.name, 'Inventory', 'adjust_in', 'Added ' || p_qty || ' × SKU ' || p_sku || ' (' || coalesce(p_reason, 'count correction') || ') at ' || tfd_fmt('x_cents', to_jsonb(cost)) || ' each',
      jsonb_build_object('sku', p_sku, 'move', mid), nullif(trim(coalesce(p_reason, '') || coalesce(': ' || nullif(trim(p_note), ''), '')), ''), jsonb_build_object('type', 'adjust', 'move', mid));
  end if;
  return jsonb_build_object('ok', true, 'value_cents', v, 'on_hand', tfd_on_hand(p_sku));
end $$;

-- receiving adds stock: blocked while a show is live and not paused
create or replace function tfd_lot_issues(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r receipts; req text[] := tfd_req(); out jsonb := '[]'; l receipt_lines; chk jsonb; pr jsonb; lk jsonb := tfd_inv_lock();
begin
  select * into r from receipts where id = p_id;
  if lk->>'state' = 'locked' then out := out || to_jsonb('Inventory is locked while "' || (lk->>'show') || '" is live. Pause mapping to confirm a lot'); end if;
  if 'supplier' = any(req) and r.supplier is null then out := out || to_jsonb('Supplier is required'::text); end if;
  if 'invoice_no' = any(req) and r.invoice_no is null then out := out || to_jsonb('Invoice # is required'::text); end if;
  if 'received_date' = any(req) and r.received_date is null then out := out || to_jsonb('Date is required'::text); end if;
  if not exists (select 1 from receipt_lines where receipt_id = p_id) then out := out || to_jsonb('Add at least one SKU row'::text); end if;
  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    chk := tfd_line_check(l);
    for pr in select * from jsonb_array_elements(chk->'problems') loop
      out := out || to_jsonb('Row ' || l.line_no || ': ' || (pr->>'m'));
    end loop;
    if chk->>'status' = 'existing' and l.bin_code is null and tfd_on_hand(chk->'product'->>'sku') = 0 then
      out := out || to_jsonb('Row ' || l.line_no || ': SKU ' || (chk->'product'->>'sku') || ' is sold out. Pick the bin it goes in');
    end if;
    if l.bin_code is not null and not exists (select 1 from bins where code = l.bin_code)
       and (chk->>'status' <> 'existing' or tfd_on_hand(chk->'product'->>'sku') = 0) then
      out := out || to_jsonb('Row ' || l.line_no || ': Bin "' || l.bin_code || '" doesn''t exist. Pick a bin from the list');
    end if;
    if 'lot_photo' = any(req) and not exists (select 1 from lot_photos where line_id = l.id) then
      out := out || to_jsonb('Row ' || l.line_no || ': Lot image is required');
    end if;
  end loop;
  return out;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_live_require(), tfd_held(text), tfd_available(text), tfd_card(text, text), tfd_show_seconds(bigint), tfd_inv_lock(),
  tfd_show_get(bigint), tfd_show_label(shows), tfd_lineup_options(), tfd_show_save(bigint, jsonb), tfd_show_cancel(bigint, text), tfd_shows(), tfd_show(bigint),
  tfd_show_catalog(bigint), tfd_show_start(bigint), tfd_show_pause(bigint, boolean), tfd_show_on_air(bigint, bigint[]), tfd_on_air_now(bigint),
  tfd_scan_check(shows, text, boolean), tfd_scan(bigint, text, uuid, text, boolean), tfd_lookup(bigint, text), tfd_bc_open(bigint), tfd_bc_add(bigint, text, boolean),
  tfd_bc_remove(bigint), tfd_bc_pick(bigint, bigint, uuid), tfd_bc_cancel(bigint), tfd_pull_undo_last(bigint), tfd_pull_void(bigint, text),
  tfd_pull_edit(bigint, text, text, boolean), tfd_pull_kind(bigint, text), tfd_show_new_part(bigint), tfd_show_set_pull(bigint, int, text),
  tfd_show_end(bigint, text), tfd_show_reopen(bigint, text), tfd_show_export(bigint, boolean), tfd_show_mapping(bigint) from public, anon;
grant execute on function tfd_lineup_options(), tfd_show_save(bigint, jsonb), tfd_show_cancel(bigint, text), tfd_shows(), tfd_show(bigint),
  tfd_show_catalog(bigint), tfd_show_start(bigint), tfd_show_pause(bigint, boolean), tfd_show_on_air(bigint, bigint[]),
  tfd_scan(bigint, text, uuid, text, boolean), tfd_lookup(bigint, text), tfd_bc_open(bigint), tfd_bc_add(bigint, text, boolean),
  tfd_bc_remove(bigint), tfd_bc_pick(bigint, bigint, uuid), tfd_bc_cancel(bigint), tfd_pull_undo_last(bigint), tfd_pull_void(bigint, text),
  tfd_pull_edit(bigint, text, text, boolean), tfd_pull_kind(bigint, text), tfd_show_new_part(bigint), tfd_show_set_pull(bigint, int, text),
  tfd_show_end(bigint, text), tfd_show_reopen(bigint, text), tfd_show_export(bigint, boolean), tfd_show_mapping(bigint) to authenticated;
revoke execute on function tfd_live_require(), tfd_held(text), tfd_available(text), tfd_show_seconds(bigint), tfd_inv_lock(), tfd_show_get(bigint),
  tfd_show_label(shows), tfd_on_air_now(bigint), tfd_scan_check(shows, text, boolean) from authenticated;
