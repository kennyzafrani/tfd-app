-- TFD app — Shows flow v2 + lot unconfirm/delete (Kenny, Nov 11 2026).
-- Create show = live right away (no Start step, no clock), per-show platform fees, listed shows on both platforms,
-- no inventory lock, buyer's choice is a normal pull, listed-show wins by scanning the pick, post-show hours entry,
-- delete/restore shows (one or several), Whatnot export starting price, and confirmed lots can be unconfirmed or deleted.

alter table shows add column if not exists fees jsonb, add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by text, add column if not exists deleted_reason text;

create table if not exists show_shifts (
  id bigserial primary key, show_id bigint not null references shows(id), profile_id bigint not null references profiles(id),
  role text not null check (role in ('streamer','assistant')), start_at timestamptz not null, end_at timestamptz not null check (end_at > start_at),
  entered_by text not null, entered_at timestamptz not null default now());
alter table show_shifts enable row level security;
revoke all on show_shifts from anon, authenticated;

-- Whatnot export: a typed starting price (bids start at $1) replaces the price-source dropdown
update setting_defaults set value = value || '{"start_price_cents": 100}' where key = 'whatnot_export' and not (value ? 'start_price_cents');
insert into settings_history (key, value, effective_from, set_by, reason)
select 'whatnot_export', tfd_get_setting('whatnot_export') || '{"start_price_cents": 100}', now(), 'System', 'Starting price added ($1); the price dropdown is gone'
where not (tfd_get_setting('whatnot_export') ? 'start_price_cents');

-- the inventory lock is dropped: stock can be added or removed while a show is live
create or replace function tfd_inv_lock() returns jsonb language sql stable as $$ select jsonb_build_object('state', 'open') $$;

-- ---------------------------------------------------------------- per-show fees + floor
create or replace function tfd_show_fees(s shows) returns jsonb language sql stable security definer set search_path = public as
  $$ select coalesce(s.fees, tfd_get_setting('platform.' || s.platform)) $$;

create or replace function tfd_show_floor(p_sku text, s shows) returns int language sql stable security definer set search_path = public as $$
  select (tfd_floor(max(c.unit_cost_cents), tfd_show_fees(s),
            coalesce((select max(commission_bp) from show_people where show_id = s.id and role = 'streamer'), (select commission_bp from tfd_rate_for(null, 'streamer'))),
            (tfd_get_setting('pricing')->>'floor_profit_bp')::int)->>'rounded_cents')::int
  from cost_layers c where c.sku = p_sku and c.qty_remaining > 0 $$;

-- streamer-safe card using this show's fees for the floor
create or replace function tfd_scard(p_sku text, s shows) returns jsonb language sql stable security definer set search_path = public as
  $$ select tfd_card(p_sku, s.platform) || jsonb_build_object('floor_cents', tfd_show_floor(p_sku, s)) $$;

create or replace function tfd_fees_clean(p jsonb, p_platform text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d jsonb := tfd_get_setting('platform.' || p_platform); k text; out jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return d; end if;
  out := d;
  foreach k in array array['pct_sale_bp','pct_ship_bp','fixed_cents','typical_ship_cents'] loop
    if p ? k then
      if jsonb_typeof(p->k) = 'null' then out := out || jsonb_build_object(k, null);
      elsif jsonb_typeof(p->k) <> 'number' or (p->>k)::numeric < 0 or (p->>k)::numeric <> trunc((p->>k)::numeric) then raise exception 'Show fees must be whole numbers, 0 or more';
      elsif k like 'pct%' and (p->>k)::int >= 10000 then raise exception 'A fee %% must be under 100%%';
      else out := out || jsonb_build_object(k, (p->>k)::int); end if;
    end if;
  end loop;
  return out;
end $$;

-- ---------------------------------------------------------------- create = live; edit until finalized
-- the show's inventory scope (SKUs in its list) and % caps, from units available right now
create or replace function tfd_show_scope(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare s shows; lst inv_lists; scope char(6)[]; cap_map jsonb;
begin
  select * into s from shows where id = p_id;
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
  update shows set scope_skus = scope, caps = cap_map where id = p_id;
end $$;

-- a show is live from the moment it's created (also used for shows set up before this update)
create or replace function tfd_show_golive(p_id bigint, p_actor text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform tfd_show_scope(p_id);
  update shows set status = 'live', started_at = coalesce(started_at, now()), paused = false where id = p_id and status = 'setup';
  insert into show_events (show_id, kind, actor) values (p_id, 'start', p_actor);
end $$;

create or replace function tfd_show_save(p_id bigint, p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; id_ bigint := p_id; person jsonb; nstream int; nassist int; nlead int; lst inv_lists; lbl text; npulls int; v_fees jsonb;
begin
  me := tfd_require('admin');
  if p->>'type' not in ('live','listed') then raise exception 'Pick a show type'; end if;
  if p->>'platform' not in ('tiktok','whatnot') then raise exception 'Pick a platform'; end if;
  if nullif(p->>'list_id', '') is not null then
    select * into lst from inv_lists where id = (p->>'list_id')::bigint;
    if lst.id is null then raise exception 'That inventory list no longer exists'; end if;
  end if;
  select count(*) filter (where x->>'role' = 'streamer'), count(*) filter (where x->>'role' = 'assistant'), count(*) filter (where (x->>'lead')::boolean)
    into nstream, nassist, nlead from jsonb_array_elements(coalesce(p->'people', '[]')) x;
  if nstream = 0 then raise exception 'Add at least one streamer'; end if;
  if nstream >= 2 and coalesce(p->>'split_mode', '') not in ('even','lead') then raise exception 'With two streamers, pick Split evenly or Lead + support'; end if;
  if nstream >= 2 and p->>'split_mode' = 'lead' and nlead <> 1 then raise exception 'Pick exactly one lead streamer'; end if;
  if (select count(distinct x->>'profile_id') from jsonb_array_elements(p->'people') x) <> jsonb_array_length(p->'people') then raise exception 'Each person can only be in the lineup once'; end if;
  for person in select * from jsonb_array_elements(p->'people') loop
    if not exists (select 1 from profiles where id = (person->>'profile_id')::bigint and active and role in ('streamer','assistant','admin')) then raise exception 'Lineup has someone who can''t be on a show'; end if;
    if (person->>'role') = 'streamer' and (select role from profiles where id = (person->>'profile_id')::bigint) = 'admin' then raise exception 'Admins can only fill the assistant spot'; end if;
  end loop;
  v_fees := tfd_fees_clean(p->'fees', p->>'platform');
  if id_ is null then
    insert into shows (type, platform, name, list_id, list_name, list_pct, split_mode, fees, created_by)
      values (p->>'type', p->>'platform', nullif(trim(p->>'name'), ''), lst.id, coalesce(lst.name, 'Full inventory'), lst.pct,
              case when nstream >= 2 then p->>'split_mode' end, v_fees, me.name) returning id into id_;
  else
    select * into s from shows where id = id_ for update;
    if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
    if s.status in ('matched','finalized') then raise exception 'This show is finalized. Unfinalize it to change setup'; end if;
    select count(*) into npulls from pulls where show_id = id_ and status <> 'void';
    if npulls > 0 and (p->>'type' <> s.type or p->>'platform' <> s.platform or lst.id is distinct from s.list_id) then
      raise exception 'Type, platform and inventory can''t change once the show has pulls'; end if;
    update shows set type = p->>'type', platform = p->>'platform', name = nullif(trim(p->>'name'), ''), list_id = lst.id, list_name = coalesce(lst.name, 'Full inventory'),
      list_pct = lst.pct, split_mode = case when nstream >= 2 then p->>'split_mode' end, fees = v_fees,
      export_qty = case when s.list_id is distinct from lst.id then null else export_qty end
      where id = id_;
    delete from show_people where show_id = id_;
  end if;
  insert into show_people (show_id, profile_id, role, hourly_cents, commission_bp, lead)
    select id_, (x->>'profile_id')::bigint, x->>'role', coalesce((x->>'hourly_cents')::int, 0),
           case when x->>'role' = 'assistant' then 0 else coalesce((x->>'commission_bp')::int, 0) end, coalesce((x->>'lead')::boolean, false)
    from jsonb_array_elements(p->'people') x;
  if p_id is null or s.status = 'setup' then perform tfd_show_golive(id_, me.name);
  elsif lst.id is distinct from s.list_id then perform tfd_show_scope(id_); end if;
  select * into s from shows where id = id_;
  lbl := tfd_show_label(s);
  perform tfd_log(me.name, 'Shows', case when p_id is null then 'show_create' else 'show_edit' end,
    case when p_id is null then 'Show created: ' else 'Show setup edited: ' end || lbl || ' (' || case s.platform when 'tiktok' then 'TikTok' else 'Whatnot' end ||
      ' fee ' || coalesce(to_char((v_fees->>'pct_sale_bp')::numeric / 100, 'FM990.##') || '%', 'not set') || ', ' || s.list_name || ', ' ||
      (select string_agg(pr.name || ' ' || sp.role || ' $' || to_char(sp.hourly_cents / 100.0, 'FM999990.00') || '/hr' ||
         case when sp.commission_bp > 0 then ' + ' || to_char(sp.commission_bp / 100.0, 'FM990.##') || '%' else '' end, ', ' order by sp.role desc, pr.name)
       from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = id_) || ')',
    jsonb_build_object('show', id_));
  return id_;
end $$;

-- ---------------------------------------------------------------- lists + reading
create or replace function tfd_shows_q(me profiles, p_deleted boolean) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', tfd_show_label(s), 'name', s.name, 'type', s.type, 'platform', s.platform,
      'status', s.status, 'list_name', s.list_name, 'created_at', s.created_at, 'started_at', s.started_at, 'ended_at', s.ended_at,
      'deleted_at', s.deleted_at, 'deleted_by', s.deleted_by, 'deleted_reason', s.deleted_reason,
      'lineup', (select coalesce(jsonb_agg(pr.name || case when sp.role = 'assistant' then ' (assistant)' else '' end order by sp.role desc, sp.lead desc, pr.name), '[]')
                 from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = s.id),
      'pulls', (select count(*) from pulls where show_id = s.id and status in ('held','sold')),
      'fee_bp', (tfd_show_fees(s)->>'pct_sale_bp')::int,
      'hours', (select round(coalesce(sum(extract(epoch from end_at - start_at)), 0) / 3600.0, 2) from show_shifts where show_id = s.id))
    order by (s.status = 'live') desc, coalesce(s.started_at, s.created_at) desc, s.id desc)
    from shows s where s.status <> 'cancelled' and (case when p_deleted then s.deleted_at is not null else s.deleted_at is null end)
      and (me.role = 'admin' or s.status in ('setup','live','ended'))), '[]');
end $$;

create or replace function tfd_shows() returns jsonb language sql stable security definer set search_path = public as $$ select tfd_shows_q(tfd_live_require(), false) $$;
create or replace function tfd_shows_deleted() returns jsonb language sql stable security definer set search_path = public as $$ select tfd_shows_q(tfd_require('admin'), true) $$;

create or replace function tfd_show(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_id);
begin
  if s.deleted_at is not null then raise exception 'This show was deleted. Restore it from Shows → Deleted'; end if;
  return to_jsonb(s) - 'caps' - 'scope_skus' || jsonb_build_object(
    'label', tfd_show_label(s), 'is_admin', me.role = 'admin', 'fees', tfd_show_fees(s), 'default_fees', tfd_get_setting('platform.' || s.platform),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('profile_id', sp.profile_id, 'name', pr.name, 'role', sp.role, 'lead', sp.lead,
        'hourly_cents', case when me.role = 'admin' then sp.hourly_cents end, 'commission_bp', case when me.role = 'admin' then sp.commission_bp end)
        order by sp.role desc, sp.lead desc, pr.name), '[]') from show_people sp join profiles pr on pr.id = sp.profile_id where sp.show_id = p_id),
    'shifts', case when me.role = 'admin' then (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'profile_id', h.profile_id, 'name', pr.name, 'role', h.role,
        'start_at', h.start_at, 'end_at', h.end_at) order by h.start_at, h.id), '[]') from show_shifts h join profiles pr on pr.id = h.profile_id where h.show_id = p_id) end,
    'counts', jsonb_build_object('part', (select count(*) from pulls where show_id = p_id and part = s.part and status = 'held' and kind <> 'win'),
       'total', (select count(*) from pulls where show_id = p_id and status = 'held'),
       'giveaways', (select count(*) from pulls where show_id = p_id and status = 'held' and kind = 'giveaway'),
       'wins', (select count(*) from pulls where show_id = p_id and status = 'held' and kind = 'win'),
       'void', (select count(*) from pulls where show_id = p_id and status = 'void')),
    'pulls', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'part', pl.part, 'pull_no', pl.pull_no, 'sku', pl.sku, 'kind', pl.kind, 'status', pl.status,
        'at', pl.scanned_at, 'by', pl.scanned_by, 'outside_list', pl.outside_list, 'note', pl.note,
        'name', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)), 'brand', pr.brand, 'model', pr.model, 'color_code', pr.color_code, 'lens_size', pr.lens_size)
        order by pl.id desc), '[]') from pulls pl join products pr on pr.sku = pl.sku where pl.show_id = p_id));
end $$;

create or replace function tfd_show_catalog(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_id);
begin
  return jsonb_build_object('scope', to_jsonb(s.scope_skus), 'caps', s.caps,
    'used', (select coalesce(jsonb_object_agg(sku, n), '{}') from (select sku, count(*) n from pulls where show_id = p_id and status = 'held' group by sku) u),
    'items', (select coalesce(jsonb_agg(tfd_scard(p.sku, s)), '[]') from products p where tfd_on_hand(p.sku) > 0 or p.sku in (select sku from pulls where show_id = p_id)));
end $$;

-- ---------------------------------------------------------------- scanning (a buyer's choice is just a normal pull)
create or replace function tfd_scan(p_show bigint, p_sku text, p_client_id uuid default null, p_kind text default 'normal', p_confirm_outside boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; chk jsonb; pl pulls; card jsonb; sk text := trim(p_sku);
begin
  if p_client_id is not null then
    select * into pl from pulls where client_id = p_client_id;
    if pl.id is not null then select * into s from shows where id = pl.show_id; return jsonb_build_object('ok', true, 'repeat', true, 'pull', to_jsonb(pl), 'card', tfd_scard(pl.sku, s)); end if;
  end if;
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status = 'setup' then perform tfd_show_golive(p_show, me.name); select * into s from shows where id = p_show; end if;
  if s.status <> 'live' then raise exception 'This show is concluded. Reopen it to scan'; end if;
  if s.type <> 'live' then raise exception 'This is a listed show. Scans are lookups; turn on Record win to log a buyer''s pick'; end if;
  if p_kind not in ('normal','giveaway') then raise exception 'Unknown pull type'; end if;
  if p_kind = 'giveaway' and s.platform <> 'whatnot' then raise exception 'Giveaways are Whatnot only'; end if;
  chk := tfd_scan_check(s, sk, p_confirm_outside);
  if chk ? 'needs_confirm' then return chk; end if;
  if chk ? 'error' then return jsonb_build_object('ok', false) || chk || jsonb_build_object('card', tfd_scard(sk, s)); end if;
  insert into pulls (show_id, part, pull_no, sku, kind, outside_list, client_id, scanned_by)
    values (p_show, s.part, s.next_pull, sk, p_kind, s.scope_skus is not null and not sk = any(s.scope_skus), p_client_id, me.name) returning * into pl;
  update shows set next_pull = next_pull + 1 where id = p_show;
  card := tfd_scard(sk, s);
  return jsonb_build_object('ok', true, 'pull', to_jsonb(pl), 'card', card, 'low', (card->>'available')::int <= (card->>'low_stock')::int);
end $$;

create or replace function tfd_lookup(p_show bigint, p_sku text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows := tfd_show_get(p_show);
begin
  if not exists (select 1 from products where sku = trim(p_sku)) then raise exception 'Unknown SKU %', trim(p_sku); end if;
  return tfd_scard(trim(p_sku), s) || jsonb_build_object('in_scope', s.scope_skus is null or trim(p_sku) = any(s.scope_skus),
    'listed_qty', (s.export_qty->>trim(p_sku))::int);
end $$;

-- listed shows: scanning the item the buyer picked records the next win (#1, #2...)
create or replace function tfd_record_win(p_show bigint, p_sku text, p_client_id uuid default null, p_confirm_outside boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_live_require(); s shows; chk jsonb; pl pulls; sk text := trim(p_sku);
begin
  if p_client_id is not null then
    select * into pl from pulls where client_id = p_client_id;
    if pl.id is not null then select * into s from shows where id = pl.show_id; return jsonb_build_object('ok', true, 'repeat', true, 'pull', to_jsonb(pl), 'card', tfd_scard(pl.sku, s)); end if;
  end if;
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status = 'setup' then perform tfd_show_golive(p_show, me.name); select * into s from shows where id = p_show; end if;
  if s.status <> 'live' then raise exception 'This show is concluded. Reopen it to record wins'; end if;
  if s.type <> 'listed' then raise exception 'Wins are for listed shows; live mapping just scans'; end if;
  chk := tfd_scan_check(s, sk, p_confirm_outside);
  if chk ? 'needs_confirm' then return chk; end if;
  if chk ? 'error' then return jsonb_build_object('ok', false) || chk || jsonb_build_object('card', tfd_scard(sk, s)); end if;
  insert into pulls (show_id, part, pull_no, sku, kind, outside_list, client_id, scanned_by)
    values (p_show, 0, s.next_win, sk, 'win', s.scope_skus is not null and not sk = any(s.scope_skus), p_client_id, me.name) returning * into pl;
  update shows set next_win = next_win + 1 where id = p_show;
  perform tfd_log(me.name, 'Shows', 'win', 'Win #' || pl.pull_no || ': SKU ' || sk || ' (' || tfd_show_label(s) || ')', jsonb_build_object('show', p_show, 'pull', pl.id));
  return jsonb_build_object('ok', true, 'pull', to_jsonb(pl), 'card', tfd_scard(sk, s));
end $$;

-- ---------------------------------------------------------------- hours entered after the show
create or replace function tfd_show_shifts_save(p_show bigint, p_shifts jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; x jsonb; summary text;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status in ('matched','finalized') then raise exception 'This show is finalized. Unfinalize it to change hours'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_shifts, '[]')) loop
    if not exists (select 1 from show_people where show_id = p_show and profile_id = (x->>'profile_id')::bigint) then
      raise exception 'Add % to the lineup first (Edit setup)', coalesce((select name from profiles where id = (x->>'profile_id')::bigint), 'that person'); end if;
    if nullif(x->>'start_at', '') is null or nullif(x->>'end_at', '') is null then raise exception 'Every row needs a start and an end (date and time)'; end if;
    if (x->>'end_at')::timestamptz <= (x->>'start_at')::timestamptz then
      raise exception '%: the end must be after the start', (select name from profiles where id = (x->>'profile_id')::bigint); end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(coalesce(p_shifts, '[]')) a, jsonb_array_elements(coalesce(p_shifts, '[]')) b
             where a <> b and a->>'profile_id' = b->>'profile_id' and (a->>'start_at')::timestamptz < (b->>'end_at')::timestamptz
               and (b->>'start_at')::timestamptz < (a->>'end_at')::timestamptz) then
    raise exception 'The same person has two time ranges that overlap'; end if;
  delete from show_shifts where show_id = p_show;
  insert into show_shifts (show_id, profile_id, role, start_at, end_at, entered_by)
    select p_show, (j->>'profile_id')::bigint, (select sp.role from show_people sp where sp.show_id = p_show and sp.profile_id = (j->>'profile_id')::bigint),
           (j->>'start_at')::timestamptz, (j->>'end_at')::timestamptz, me.name
    from jsonb_array_elements(coalesce(p_shifts, '[]')) j;
  select string_agg(pr.name || ' ' || to_char(sum_h, 'FM990.00') || 'h', ', ' order by pr.name) into summary
    from (select profile_id, sum(extract(epoch from end_at - start_at)) / 3600.0 sum_h from show_shifts where show_id = p_show group by profile_id) t join profiles pr on pr.id = t.profile_id;
  perform tfd_log(me.name, 'Shows', 'show_hours', 'Hours entered for ' || tfd_show_label(s) || ': ' || coalesce(summary, 'none'), jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- delete / restore shows (restorable; held units are freed)
create or replace function tfd_show_delete(p_ids bigint[], p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; n int := 0; freed int := 0; k int;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  for s in select * from shows where id = any(p_ids) and deleted_at is null order by id for update loop
    if s.status in ('matched','finalized') then raise exception '% is finalized. Unfinalize it before deleting', tfd_show_label(s); end if;
    update pulls set status = 'released', note = 'show deleted' where show_id = s.id and status = 'held';
    get diagnostics k = row_count; freed := freed + k;
    update shows set deleted_at = now(), deleted_by = me.name, deleted_reason = trim(p_reason) where id = s.id;
    perform tfd_log(me.name, 'Shows', 'show_delete', 'Show deleted: ' || tfd_show_label(s) || ' (' || k || ' held unit(s) freed; restorable)', jsonb_build_object('show', s.id), p_reason);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Nothing to delete'; end if;
  return jsonb_build_object('ok', true, 'deleted', n, 'freed', freed);
end $$;

create or replace function tfd_show_restore(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; bad text;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_id for update;
  if s.id is null or s.deleted_at is null then raise exception 'That show isn''t deleted'; end if;
  select string_agg(x.sku || ' (needs ' || x.n || ', ' || greatest(tfd_available(x.sku), 0) || ' available)', ', ') into bad
    from (select sku, count(*) n from pulls where show_id = p_id and status = 'released' and note = 'show deleted' group by sku) x where x.n > tfd_available(x.sku);
  if bad is not null then raise exception 'Can''t restore: not enough stock to hold its pulls again: %', bad; end if;
  update pulls set status = 'held', note = null where show_id = p_id and status = 'released' and note = 'show deleted';
  update shows set deleted_at = null, deleted_by = null, deleted_reason = null where id = p_id;
  perform tfd_log(me.name, 'Shows', 'show_restore', 'Show restored: ' || tfd_show_label(s), jsonb_build_object('show', p_id), p_reason);
  return jsonb_build_object('ok', true);
end $$;


-- ---------------------------------------------------------------- lots: unconfirm (back to draft) and delete
-- SKU numbers are never handed out twice, even after a lot that created them is deleted
create table if not exists sku_retired (sku char(6) primary key, retired_at timestamptz not null default now(), note text);
alter table sku_retired enable row level security;
revoke all on sku_retired from anon, authenticated;
create or replace function tfd_next_sku() returns char(6) language sql volatile security definer set search_path = public as $$
  select lpad((greatest(coalesce((select max(sku::int) from products), 100000), coalesce((select max(sku::int) from sku_retired), 100000), 100000) + 1)::text, 6, '0')::char(6) $$;

-- Unconfirm: the lot's units come back out of stock (history shows a reversing line) and it returns to draft.
-- SKUs it created stay in the catalog at 0 so re-confirming lands on the same SKU numbers.
-- Catalog field updates and bin moves the confirm made are not reversed (edit those in Stock).
create or replace function tfd_lot_unconfirm_core(p_id bigint, p_actor text, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r receipts; bad text; units int; x record;
begin
  select * into r from receipts where id = p_id for update;
  if r.id is null then raise exception 'No such lot'; end if;
  if r.status <> 'confirmed' then raise exception 'Only a confirmed lot can be unconfirmed'; end if;
  select string_agg(t.sku || ' (' || t.gone || ' of ' || t.q || ')', ', ') into bad
    from (select c.sku, sum(c.qty_in - c.qty_remaining) gone, sum(c.qty_in) q from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id
          where rl.receipt_id = p_id group by c.sku having sum(c.qty_in - c.qty_remaining) > 0) t;
  if bad is not null then raise exception 'Can''t unconfirm "%": some of its units already left stock: SKU %. Fix single SKUs in Adjustments instead', r.name, bad; end if;
  select string_agg(t.sku || ' (' || tfd_held(t.sku) || ' held)', ', ') into bad
    from (select c.sku, sum(c.qty_in) q from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id where rl.receipt_id = p_id group by c.sku) t
    where tfd_on_hand(t.sku) - t.q < tfd_held(t.sku);
  if bad is not null then raise exception 'Can''t unconfirm "%": shows are holding units it brought in: SKU %. Void those pulls or delete the show first', r.name, bad; end if;
  units := 0;
  for x in select c.sku, sum(c.qty_in)::int q, sum(c.qty_in::bigint * c.unit_cost_cents) v from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id
           where rl.receipt_id = p_id group by c.sku order by c.sku loop
    insert into stock_moves (sku, kind, qty, value_cents, reason, receipt_id, actor, detail)
      values (x.sku, 'lot_unconfirm', -x.q, -x.v, p_reason, p_id, p_actor, jsonb_build_object('lot', r.name));
    units := units + x.q;
  end loop;
  delete from cost_layers where receipt_line_id in (select id from receipt_lines where receipt_id = p_id);
  update receipt_lines set result_sku = null where receipt_id = p_id and result_sku is not null;
  update receipts set status = 'draft', confirmed_by = null, confirmed_at = null where id = p_id;
  perform tfd_log(p_actor, 'Inventory', 'lot_unconfirm', 'Lot unconfirmed (back to draft): ' || r.name || ', ' || units || ' unit(s) taken back out of stock',
    jsonb_build_object('receipt', p_id), p_reason);
  return jsonb_build_object('ok', true, 'units', units);
end $$;

create or replace function tfd_lot_unconfirm(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  return tfd_lot_unconfirm_core(p_id, me.name, trim(p_reason));
end $$;

-- Delete: confirmed lots are unconfirmed first (same checks). SKUs the lot created that have nothing else
-- (no stock, no other lot, no show pulls) are removed and their numbers retired. Restorable from Versions.
create or replace function tfd_lot_delete(p_ids bigint[], p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts; n int := 0; sk char(6); created char(6)[]; removed int; was text;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  for r in select * from receipts where id = any(p_ids) order by id for update loop
    was := r.status;
    if r.status = 'undone' then raise exception 'Lot "%" was undone from the Activity Log; it can''t be deleted', r.name; end if;
    if r.status = 'confirmed' then perform tfd_lot_unconfirm_core(r.id, me.name, trim(p_reason)); end if;
    select coalesce(array_agg(distinct m.sku), '{}') into created from stock_moves m
      where m.receipt_id = r.id and m.kind = 'receipt' and coalesce((m.detail->>'new')::boolean, false);
    update stock_moves set receipt_id = null, detail = coalesce(detail, '{}') || jsonb_build_object('lot', r.name, 'lot_deleted', true) where receipt_id = r.id;
    removed := 0;
    foreach sk in array created loop
      if not exists (select 1 from cost_layers where sku = sk) and not exists (select 1 from pulls where sku = sk) and not exists (select 1 from bc_items where sku = sk)
         and not exists (select 1 from receipt_lines where receipt_id <> r.id and (result_sku = sk or map_sku = sk)) then
        delete from alert_dismissals where sku = sk;
        delete from stock_moves where sku = sk;
        update inv_lists set skus = array_remove(skus, sk) where sk = any(skus);
        update receipt_lines set map_sku = null where receipt_id = r.id and map_sku = sk;
        delete from products where sku = sk;
        insert into sku_retired (sku, note) values (sk, 'Created by deleted lot ' || r.name) on conflict do nothing;
        removed := removed + 1;
      end if;
    end loop;
    delete from lot_photos where receipt_id = r.id;
    delete from receipt_lines where receipt_id = r.id;
    delete from receipts where id = r.id;
    perform tfd_log(me.name, 'Inventory', 'lot_delete', 'Lot deleted: ' || r.name ||
      case when was = 'confirmed' then ' (was confirmed; its units were taken back out of stock)' else '' end ||
      case when removed > 0 then ', ' || removed || ' unused SKU(s) it created removed' else '' end, jsonb_build_object('receipt', r.id), p_reason);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Nothing to delete'; end if;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;

-- shows set up before this update go live now (there's no Start step anymore)
do $$ declare x record; begin
  for x in select id from shows where status = 'setup' loop
    begin perform tfd_show_golive(x.id, 'System'); exception when others then null; end;
  end loop;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_show_fees(shows), tfd_show_floor(text, shows), tfd_scard(text, shows), tfd_fees_clean(jsonb, text), tfd_show_scope(bigint),
  tfd_show_golive(bigint, text), tfd_shows_q(profiles, boolean), tfd_lot_unconfirm_core(bigint, text, text), tfd_shows_deleted(), tfd_record_win(bigint, text, uuid, boolean),
  tfd_show_shifts_save(bigint, jsonb), tfd_show_delete(bigint[], text), tfd_show_restore(bigint, text), tfd_lot_unconfirm(bigint, text), tfd_lot_delete(bigint[], text)
  from public, anon;
revoke execute on function tfd_show_fees(shows), tfd_show_floor(text, shows), tfd_scard(text, shows), tfd_fees_clean(jsonb, text), tfd_show_scope(bigint),
  tfd_show_golive(bigint, text), tfd_shows_q(profiles, boolean), tfd_lot_unconfirm_core(bigint, text, text) from authenticated;
grant execute on function tfd_shows_deleted(), tfd_record_win(bigint, text, uuid, boolean), tfd_show_shifts_save(bigint, jsonb), tfd_show_delete(bigint[], text),
  tfd_show_restore(bigint, text), tfd_lot_unconfirm(bigint, text), tfd_lot_delete(bigint[], text) to authenticated;

-- several shows can be live at once now, so reopening no longer waits for another show to end
create or replace function tfd_show_reopen(p_show bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.id is null or s.deleted_at is not null then raise exception 'No such show'; end if;
  if s.status <> 'ended' then raise exception 'Only a concluded show can be reopened'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  update shows set status = 'live', ended_at = null where id = p_show;
  insert into show_events (show_id, kind, actor, detail) values (p_show, 'reopen', me.name, jsonb_build_object('reason', p_reason));
  perform tfd_log(me.name, 'Shows', 'show_reopen', 'Show reopened for more scanning: ' || tfd_show_label(s), jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true);
end $$;
