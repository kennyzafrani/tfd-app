-- TFD app — Phase 5: Fulfillment (Nov 15 2026). Online packing (no AirDrop): each packer signs in with their own account and clocks in,
-- scans the label, scans each item, takes a photo, finishes. Packages come from finalized shows. Units already left stock at finalize,
-- so packing marks them shipped; Stock and Bins count sold-but-not-packed units that are still physically in the bin.

alter table products add column if not exists on_stage boolean not null default false;

create table if not exists packages (
  id bigserial primary key, show_id bigint not null references shows(id), group_key text not null, platform text not null,
  tracking text, package_key text, buyer text, ship_name text,
  status text not null default 'todo' check (status in ('todo','in_progress','packed','problem')),
  problem_note text, problem_by text, problem_at timestamptz, resolved_note text,
  started_at timestamptz, packed_at timestamptz, packed_by text, created_at timestamptz not null default now(),
  unique (show_id, group_key));
alter table show_orders add column if not exists package_id bigint references packages(id);
create table if not exists pack_scans (
  id bigserial primary key, package_id bigint not null references packages(id), sku char(6) not null, client_id uuid unique,
  scanned_by text not null, scanned_at timestamptz not null default now(), undone boolean not null default false);
create table if not exists pack_photos (
  id bigserial primary key, package_id bigint not null references packages(id), path text not null, bytes int,
  taken_by text not null, taken_at timestamptz not null default now(), deleted_at timestamptz, deleted_by text, deleted_reason text);
create table if not exists pack_clock (
  id bigserial primary key, profile_id bigint not null references profiles(id), clock_in timestamptz not null default now(), clock_out timestamptz,
  edited_by text, note text);
create index if not exists packages_status on packages (status);
create index if not exists pack_scans_pkg on pack_scans (package_id) where not undone;
alter table packages enable row level security; alter table pack_scans enable row level security;
alter table pack_photos enable row level security; alter table pack_clock enable row level security;
revoke all on packages, pack_scans, pack_photos, pack_clock from anon, authenticated;

-- photos are kept 60 days (Kenny, Nov 15)
insert into settings_history (key, value, effective_from, set_by, reason)
select 'photos', tfd_get_setting('photos') || '{"retention_days":60}', now(), 'System', 'Packing photos kept 60 days (storage plan)'
where (tfd_get_setting('photos')->>'retention_days')::int = 90;

create or replace function tfd_can_pack() returns boolean language sql stable security definer set search_path = public as
  $$ select exists (select 1 from profiles where auth_id = auth.uid() and active and role in ('packer','admin')) $$;

-- packing photos (private): packers add, packers and admins view, admins delete (expiry)
insert into storage.buckets (id, name, public) values ('pack-photos', 'pack-photos', false) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tfd pack photos read') then
    create policy "tfd pack photos read" on storage.objects for select to authenticated using (bucket_id = 'pack-photos' and public.tfd_can_pack());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tfd pack photos add') then
    create policy "tfd pack photos add" on storage.objects for insert to authenticated with check (bucket_id = 'pack-photos' and public.tfd_can_pack());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tfd pack photos delete') then
    create policy "tfd pack photos delete" on storage.objects for delete to authenticated using (bucket_id = 'pack-photos' and public.tfd_is_admin());
  end if;
end $$;

-- units sold (finalized) but not packed yet: still physically in the bin
create or replace function tfd_to_pack(p_sku text) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from show_orders o join pulls pl on pl.id = o.pull_id join packages pk on pk.id = o.package_id
  where pl.sku = p_sku and o.state = 'matched' and pk.status <> 'packed' $$;

-- ---------------------------------------------------------------- packages from a finalized show
create or replace function tfd_make_packages(p_show bigint) returns int language plpgsql security definer set search_path = public as $$
declare s shows; n int;
begin
  select * into s from shows where id = p_show;
  insert into packages (show_id, group_key, platform, tracking, package_key, buyer, ship_name)
    select p_show, g.k, s.platform, max(o.tracking), max(o.package_key), max(o.buyer), max(o.ship_name)
    from show_orders o cross join lateral (select coalesce(nullif(o.tracking, ''), nullif(o.package_key, ''), 'order:' || coalesce(o.order_id, o.id::text)) k) g
    where o.show_id = p_show and o.state = 'matched' group by g.k
    on conflict (show_id, group_key) do nothing;
  update show_orders o set package_id = pk.id from packages pk
    where o.show_id = p_show and o.state = 'matched' and pk.show_id = p_show
      and pk.group_key = coalesce(nullif(o.tracking, ''), nullif(o.package_key, ''), 'order:' || coalesce(o.order_id, o.id::text));
  select count(*) into n from packages where show_id = p_show;
  return n;
end $$;

-- ---------------------------------------------------------------- packer: clock, data, scans, photos, finish, problem
create or replace function tfd_pack_me() returns profiles language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('any');
  if me.role not in ('packer','admin') then raise exception 'Packers and admins only'; end if;
  return me;
end $$;

create or replace function tfd_pack_clock(p_in boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); c pack_clock;
begin
  select * into c from pack_clock where profile_id = me.id and clock_out is null order by id desc limit 1;
  if p_in then
    if c.id is not null then return jsonb_build_object('ok', true, 'clock_in', c.clock_in); end if;
    insert into pack_clock (profile_id) values (me.id) returning * into c;
    perform tfd_log(me.name, 'Fulfillment', 'clock_in', me.name || ' clocked in to pack');
    return jsonb_build_object('ok', true, 'clock_in', c.clock_in);
  end if;
  if c.id is null then raise exception 'You''re not clocked in'; end if;
  update pack_clock set clock_out = now() where id = c.id;
  perform tfd_log(me.name, 'Fulfillment', 'clock_out', me.name || ' clocked out (' || to_char(extract(epoch from now() - c.clock_in) / 3600.0, 'FM990.00') || ' h)');
  return jsonb_build_object('ok', true);
end $$;

-- everything the packing screen needs (no prices or costs); packages not yet packed, oldest first
create or replace function tfd_pack_data() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_pack_me();
begin
  return jsonb_build_object('me', me.name,
    'clock_in', (select clock_in from pack_clock where profile_id = me.id and clock_out is null order by id desc limit 1),
    'rules', jsonb_build_object('photo_required', coalesce((tfd_get_setting('rules')->>'photo_required')::boolean, true),
                                'all_items_scanned', coalesce((tfd_get_setting('rules')->>'all_items_scanned')::boolean, true)),
    'packages', coalesce((select jsonb_agg(tfd_pack_pkg(pk.id) order by pk.created_at, pk.id) from packages pk where pk.status <> 'packed'), '[]'));
end $$;

create or replace function tfd_pack_pkg(p_id bigint) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', pk.id, 'status', pk.status, 'tracking', pk.tracking, 'package_key', pk.package_key, 'buyer', pk.buyer, 'ship_name', pk.ship_name,
    'platform', pk.platform, 'show', tfd_show_label(s), 'problem_note', pk.problem_note, 'resolved_note', pk.resolved_note, 'created_at', pk.created_at,
    'orders', (select coalesce(jsonb_agg(o.order_id order by o.order_id), '[]') from show_orders o where o.package_id = pk.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('sku', x.sku, 'qty', x.qty, 'scanned', coalesce(sc.n, 0), 'name', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)),
        'brand', pr.brand, 'model', pr.model, 'color', coalesce(pr.color_name, pr.color_code), 'lens_size', pr.lens_size, 'image_url', pr.image_url, 'upc', pr.upc,
        'bin', b.code, 'on_stage', pr.on_stage) order by b.code nulls last, x.sku), '[]')
      from (select pl.sku, count(*)::int qty from show_orders o join pulls pl on pl.id = o.pull_id where o.package_id = pk.id group by pl.sku) x
      join products pr on pr.sku = x.sku left join bins b on b.id = pr.bin_id
      left join (select sku, count(*)::int n from pack_scans where package_id = pk.id and not undone group by sku) sc on sc.sku = x.sku),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', ph.id, 'path', ph.path, 'at', ph.taken_at, 'by', ph.taken_by) order by ph.id), '[]')
      from pack_photos ph where ph.package_id = pk.id and ph.deleted_at is null))
  from packages pk join shows s on s.id = pk.show_id where pk.id = p_id $$;

create or replace function tfd_pack_check(p_pkg bigint, p_need_open boolean) returns packages language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages;
begin
  select * into pk from packages where id = p_pkg for update;
  if pk.id is null then raise exception 'No such package'; end if;
  if pk.status = 'packed' then raise exception 'That package is already packed'; end if;
  if p_need_open and pk.status = 'problem' then raise exception 'This package is marked Problem. Kenny has to resolve it first'; end if;
  if not exists (select 1 from pack_clock where profile_id = me.id and clock_out is null) then raise exception 'Clock in first'; end if;
  return pk;
end $$;

create or replace function tfd_pack_scan(p_pkg bigint, p_code text, p_client_id uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages; c text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); sk text; need int; got int; x pack_scans;
begin
  if p_client_id is not null then
    select * into x from pack_scans where client_id = p_client_id;
    if x.id is not null then return jsonb_build_object('ok', true, 'repeat', true, 'package', tfd_pack_pkg(x.package_id)); end if;
  end if;
  pk := tfd_pack_check(p_pkg, true);
  select sku into sk from products where sku = c or upper(upc) = c limit 1;
  if sk is null then return jsonb_build_object('ok', false, 'error', 'Unknown item: ' || p_code); end if;
  select count(*) into need from show_orders o join pulls pl on pl.id = o.pull_id where o.package_id = pk.id and pl.sku = sk;
  if need = 0 then return jsonb_build_object('ok', false, 'error', 'WRONG ITEM: SKU ' || sk || ' is not in this package', 'sku', sk); end if;
  select count(*) into got from pack_scans where package_id = pk.id and sku = sk and not undone;
  if got >= need then return jsonb_build_object('ok', false, 'error', 'TOO MANY: this package only needs ' || need || ' of SKU ' || sk, 'sku', sk); end if;
  insert into pack_scans (package_id, sku, client_id, scanned_by) values (pk.id, sk, p_client_id, me.name);
  if pk.status = 'todo' then update packages set status = 'in_progress', started_at = now() where id = pk.id; end if;
  return jsonb_build_object('ok', true, 'sku', sk, 'package', tfd_pack_pkg(pk.id));
end $$;

create or replace function tfd_pack_undo(p_pkg bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages; x pack_scans;
begin
  pk := tfd_pack_check(p_pkg, false);
  select * into x from pack_scans where package_id = pk.id and not undone order by id desc limit 1;
  if x.id is null then raise exception 'Nothing to undo'; end if;
  update pack_scans set undone = true where id = x.id;
  return jsonb_build_object('ok', true, 'sku', x.sku, 'package', tfd_pack_pkg(pk.id));
end $$;

create or replace function tfd_pack_photo_add(p_pkg bigint, p_path text, p_bytes int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages;
begin
  pk := tfd_pack_check(p_pkg, false);
  if coalesce(p_path, '') = '' then raise exception 'No photo'; end if;
  insert into pack_photos (package_id, path, bytes, taken_by) values (pk.id, p_path, p_bytes, me.name);
  if pk.status = 'todo' then update packages set status = 'in_progress', started_at = now() where id = pk.id; end if;
  return jsonb_build_object('ok', true, 'package', tfd_pack_pkg(pk.id));
end $$;

-- a packer can remove a photo of a package that isn't packed yet (retake); the file stays until expiry
create or replace function tfd_pack_photo_remove(p_photo bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); ph pack_photos; pk packages;
begin
  select * into ph from pack_photos where id = p_photo and deleted_at is null;
  if ph.id is null then raise exception 'No such photo'; end if;
  pk := tfd_pack_check(ph.package_id, false);
  update pack_photos set deleted_at = now(), deleted_by = me.name, deleted_reason = 'retake' where id = ph.id;
  return jsonb_build_object('ok', true, 'package', tfd_pack_pkg(pk.id));
end $$;

create or replace function tfd_pack_finish(p_pkg bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages; r jsonb := tfd_get_setting('rules'); missing text;
begin
  pk := tfd_pack_check(p_pkg, true);
  if coalesce((r->>'all_items_scanned')::boolean, true) then
    select string_agg(x.sku || ' (' || x.need - coalesce(x.got, 0) || ' left)', ', ') into missing from (
      select pl.sku, count(*) need, (select count(*) from pack_scans s where s.package_id = pk.id and s.sku = pl.sku and not s.undone) got
      from show_orders o join pulls pl on pl.id = o.pull_id where o.package_id = pk.id group by pl.sku) x where coalesce(x.got, 0) < x.need;
    if missing is not null then raise exception 'Not every item is scanned: %', missing; end if;
  end if;
  if coalesce((r->>'photo_required')::boolean, true) and not exists (select 1 from pack_photos where package_id = pk.id and deleted_at is null) then
    raise exception 'Take the photo first (label and every item together)'; end if;
  update packages set status = 'packed', packed_at = now(), packed_by = me.name, started_at = coalesce(started_at, now()) where id = pk.id;
  perform tfd_log(me.name, 'Fulfillment', 'package_packed', 'Packed ' || coalesce(pk.tracking, pk.package_key, 'package #' || pk.id) || ' for ' || coalesce(pk.buyer, pk.ship_name, '?'),
    jsonb_build_object('package', pk.id, 'show', pk.show_id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pack_problem(p_pkg bigint, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_pack_me(); pk packages;
begin
  pk := tfd_pack_check(p_pkg, false);
  if trim(coalesce(p_note, '')) = '' then raise exception 'Say what''s wrong (missing, damaged, wrong item…)'; end if;
  update packages set status = 'problem', problem_note = trim(p_note), problem_by = me.name, problem_at = now() where id = pk.id;
  perform tfd_log(me.name, 'Fulfillment', 'package_problem', 'Problem on ' || coalesce(pk.tracking, pk.package_key, 'package #' || pk.id) || ': ' || trim(p_note), jsonb_build_object('package', pk.id));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- admin: queue, pick list, lookup, resolve, unpack, stage sample, photo expiry
create or replace function tfd_pack_queue() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin');
begin
  return jsonb_build_object(
    'packages', coalesce((select jsonb_agg(jsonb_build_object('id', pk.id, 'status', pk.status, 'tracking', pk.tracking, 'buyer', pk.buyer, 'ship_name', pk.ship_name,
        'platform', pk.platform, 'show_id', pk.show_id, 'show', tfd_show_label(s), 'created_at', pk.created_at, 'started_at', pk.started_at, 'problem_note', pk.problem_note,
        'problem_by', pk.problem_by, 'units', (select count(*) from show_orders o where o.package_id = pk.id),
        'scanned', (select count(*) from pack_scans x where x.package_id = pk.id and not x.undone),
        'photos', (select count(*) from pack_photos ph where ph.package_id = pk.id and ph.deleted_at is null))
      order by pk.status = 'problem' desc, pk.created_at, pk.id) from packages pk join shows s on s.id = pk.show_id where pk.status <> 'packed'), '[]'),
    'by_show', coalesce((select jsonb_agg(jsonb_build_object('show_id', s.id, 'show', tfd_show_label(s), 'left', x.n, 'oldest', x.oldest) order by x.oldest)
      from (select show_id, count(*) n, min(created_at) oldest from packages where status <> 'packed' group by show_id) x join shows s on s.id = x.show_id), '[]'),
    'packed_today', (select count(*) from packages where status = 'packed' and packed_at >= date_trunc('day', now() at time zone 'America/New_York') at time zone 'America/New_York'),
    'clocked_in', coalesce((select jsonb_agg(jsonb_build_object('name', pr.name, 'since', c.clock_in) order by c.clock_in) from pack_clock c join profiles pr on pr.id = c.profile_id where c.clock_out is null), '[]'),
    'storage', jsonb_build_object('bytes', coalesce((select sum(bytes) from pack_photos where deleted_at is null), 0), 'photos', (select count(*) from pack_photos where deleted_at is null),
      'retention_days', coalesce((tfd_get_setting('photos')->>'retention_days')::int, 60)));
end $$;

create or replace function tfd_pick_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_pack_me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'need', x.need, 'bin', b.code, 'name', coalesce(pr.name, concat_ws(' ', pr.brand, pr.model)),
      'brand', pr.brand, 'model', pr.model, 'color', coalesce(pr.color_name, pr.color_code), 'on_stage', pr.on_stage,
      'in_stock', tfd_on_hand(x.sku) + tfd_to_pack(x.sku),
      'stage_note', pr.on_stage and x.need >= tfd_on_hand(x.sku) + tfd_to_pack(x.sku)) order by b.code nulls last, x.sku)
    from (select pl.sku, count(*)::int - coalesce(max(sc.n), 0) need from show_orders o join pulls pl on pl.id = o.pull_id join packages pk on pk.id = o.package_id
            left join lateral (select count(*)::int n from pack_scans s join packages p2 on p2.id = s.package_id where s.sku = pl.sku and not s.undone and p2.status <> 'packed') sc on true
          where pk.status <> 'packed' group by pl.sku) x
    join products pr on pr.sku = x.sku left join bins b on b.id = pr.bin_id where x.need > 0), '[]');
end $$;

create or replace function tfd_pack_lookup(p_q text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); q text := upper(regexp_replace(coalesce(p_q, ''), '\s', '', 'g'));
begin
  if length(q) < 2 then raise exception 'Type at least 2 characters'; end if;
  return coalesce((select jsonb_agg(tfd_pack_pkg(pk.id) || jsonb_build_object('packed_at', pk.packed_at, 'packed_by', pk.packed_by,
      'all_photos', (select coalesce(jsonb_agg(jsonb_build_object('id', ph.id, 'path', ph.path, 'at', ph.taken_at, 'by', ph.taken_by, 'deleted_at', ph.deleted_at, 'deleted_reason', ph.deleted_reason) order by ph.id), '[]')
        from pack_photos ph where ph.package_id = pk.id)) order by pk.created_at desc)
    from packages pk where upper(coalesce(pk.tracking, '')) like '%' || q || '%' or (length(coalesce(pk.tracking, '')) >= 8 and q like '%' || upper(pk.tracking))
      or upper(coalesce(pk.package_key, '')) = q or upper(coalesce(pk.buyer, '')) like '%' || q || '%' or upper(replace(coalesce(pk.ship_name, ''), ' ', '')) like '%' || q || '%'
      or exists (select 1 from show_orders o where o.package_id = pk.id and upper(coalesce(o.order_id, '')) = q)), '[]');
end $$;

create or replace function tfd_pack_resolve(p_pkg bigint, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); pk packages;
begin
  select * into pk from packages where id = p_pkg for update;
  if pk.status <> 'problem' then raise exception 'That package isn''t marked Problem'; end if;
  if trim(coalesce(p_note, '')) = '' then raise exception 'Say how it was fixed'; end if;
  update packages set status = case when exists (select 1 from pack_scans where package_id = pk.id and not undone) then 'in_progress' else 'todo' end,
    resolved_note = trim(p_note) where id = pk.id;
  perform tfd_log(me.name, 'Fulfillment', 'package_resolve', 'Problem resolved on ' || coalesce(pk.tracking, 'package #' || pk.id) || ': ' || trim(p_note), jsonb_build_object('package', pk.id));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_pack_unpack(p_pkg bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); pk packages;
begin
  select * into pk from packages where id = p_pkg for update;
  if pk.status <> 'packed' then raise exception 'That package isn''t packed'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  update packages set status = 'in_progress', packed_at = null, packed_by = null where id = pk.id;
  perform tfd_log(me.name, 'Fulfillment', 'package_unpack', 'Unpacked ' || coalesce(pk.tracking, 'package #' || pk.id) || ' (back to the queue; scans and photos kept)', jsonb_build_object('package', pk.id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_set_on_stage(p_sku text, p_on boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); p products;
begin
  select * into p from products where sku = p_sku for update;
  if p.sku is null then raise exception 'No such SKU'; end if;
  update products set on_stage = p_on where sku = p_sku;
  perform tfd_log(me.name, 'Inventory', 'on_stage', 'SKU ' || p_sku || case when p_on then ' sample is on the stage table' else ' sample back in its bin' end, jsonb_build_object('sku', p_sku));
  return jsonb_build_object('ok', true);
end $$;

-- photos past retention (admin's browser deletes the files, then marks them)
create or replace function tfd_photos_expired() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); d int := coalesce((tfd_get_setting('photos')->>'retention_days')::int, 60);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'path', path)) from (select id, path from pack_photos
    where deleted_at is null and taken_at < now() - make_interval(days => d) order by id limit 200) x), '[]');
end $$;

create or replace function tfd_photos_mark_deleted(p_ids bigint[], p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles := tfd_require('admin'); n int;
begin
  update pack_photos set deleted_at = now(), deleted_by = me.name, deleted_reason = coalesce(nullif(trim(p_reason), ''), 'expired') where id = any(p_ids) and deleted_at is null;
  get diagnostics n = row_count;
  if n > 0 then perform tfd_log(me.name, 'Fulfillment', 'photos_deleted', n || ' packing photo(s) deleted (' || coalesce(nullif(trim(p_reason), ''), 'past the retention period') || ')'); end if;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;

-- ---------------------------------------------------------------- finalize makes packages; unfinalize only before packing starts
create or replace function tfd_show_finalize(p_show bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; r jsonb; f jsonb; cbp int; o record; tk record; bl jsonb; units int := 0; cost bigint := 0; x record;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'matched' then raise exception 'Import the CSV first'; end if;
  r := tfd_show_review(p_show);
  bl := r->'blockers';
  if jsonb_array_length(bl) > 0 then raise exception 'Can''t finalize yet: %', (select string_agg(v, '; ') from jsonb_array_elements_text(bl) v); end if;
  f := tfd_show_fees(s); cbp := tfd_show_comm_bp(s);
  -- lock the floor each pull showed when it was scanned (later floor changes never touch this show)
  update show_orders so set floor_cents = pl.floor_cents from pulls pl where pl.id = so.pull_id and so.show_id = p_show and so.state = 'matched';
  for o in select so.*, pl.sku from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' order by pl.part, pl.pull_no, so.id for update of so loop
    select * into tk from tfd_take_fifo(o.sku, 1);
    update show_orders so set cost_cents = tk.value_cents, fifo = tk.taken, fee_cents = tfd_order_fee(so, f, s.platform) where so.id = o.id;
    update show_orders set commission_cents = round(cbp * (sale_cents - fee_cents) / 10000.0)::int where id = o.id;
    units := units + 1; cost := cost + tk.value_cents;
  end loop;
  for x in select pl.sku, count(*)::int n, sum(so.cost_cents) v from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' group by pl.sku loop
    insert into stock_moves (sku, kind, qty, value_cents, actor, detail) values (x.sku, 'show_sale', -x.n, -x.v, me.name, jsonb_build_object('show', p_show, 'label', tfd_show_label(s)));
  end loop;
  update pulls set status = 'sold' where id in (select pull_id from show_orders where show_id = p_show and state = 'matched');
  perform tfd_make_packages(p_show);   -- the show's packages go to the packing queue
  r := tfd_show_review(p_show);   -- re-read with the locked numbers
  update shows set status = 'finalized', fees = f, finalized_at = now(), finalized_by = me.name,
    totals = (r->'totals') || jsonb_build_object('pay', r->'pay', 'ad_spend_cents', s.ad_spend_cents) where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_finalize', 'Show finalized: ' || tfd_show_label(s) || ' (' || units || ' unit(s) out of inventory at $' || to_char(cost / 100.0, 'FM999999990.00') ||
    ' cost, sales $' || to_char((r->'totals'->>'sales_cents')::numeric / 100, 'FM999999990.00') || ', fee ' || coalesce(((f->>'pct_sale_bp')::numeric / 100)::text || '%', '?') || ')', jsonb_build_object('show', p_show));
  return jsonb_build_object('ok', true, 'units', units, 'cost_cents', cost);
end $$;

create or replace function tfd_show_unfinalize(p_show bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; s shows; o record; t jsonb; x record; units int := 0;
begin
  me := tfd_require('admin');
  select * into s from shows where id = p_show for update;
  if s.status <> 'finalized' then raise exception 'That show isn''t finalized'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if exists (select 1 from packages pk where pk.show_id = p_show and (pk.status <> 'todo' or exists (select 1 from pack_scans ps where ps.package_id = pk.id)
             or exists (select 1 from pack_photos ph where ph.package_id = pk.id))) then
    raise exception 'Packing has started on this show''s packages, so it can''t be unfinalized. Unpack them first (Fulfillment)'; end if;
  update show_orders set package_id = null where show_id = p_show and package_id is not null;
  delete from packages where show_id = p_show;
  for x in select pl.sku, count(*)::int n, sum(so.cost_cents) v from show_orders so join pulls pl on pl.id = so.pull_id
           where so.show_id = p_show and so.state = 'matched' and so.fifo is not null group by pl.sku loop
    insert into stock_moves (sku, kind, qty, value_cents, reason, actor, detail) values (x.sku, 'show_unfinalize', x.n, x.v, trim(p_reason), me.name, jsonb_build_object('show', p_show, 'label', tfd_show_label(s)));
  end loop;
  for o in select * from show_orders where show_id = p_show and state = 'matched' and fifo is not null for update loop
    for t in select * from jsonb_array_elements(o.fifo) loop
      update cost_layers set qty_remaining = qty_remaining + (t->>'qty')::int where id = (t->>'layer')::bigint;
    end loop;
    units := units + 1;
  end loop;
  update show_orders set cost_cents = null, fifo = null, fee_cents = null, commission_cents = null, floor_cents = null where show_id = p_show;
  update pulls set status = 'held' where show_id = p_show and status = 'sold';
  update shows set status = 'matched', finalized_at = null, finalized_by = null, totals = null where id = p_show;
  perform tfd_log(me.name, 'Shows', 'show_unfinalize', 'Show unfinalized: ' || tfd_show_label(s) || ' (' || units || ' unit(s) back in inventory; fees stay at this show''s rate)', jsonb_build_object('show', p_show), p_reason);
  return jsonb_build_object('ok', true, 'units', units);
end $$;

-- ---------------------------------------------------------------- stock and bins count sold-not-packed units (still in the bin)
create or replace function tfd_stock() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare low_default int := (tfd_get_setting('inventory')->>'low_stock_default')::int;
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(row order by row->>'sku') from (
    select to_jsonb(p) || jsonb_build_object(
      'bin', b.code, 'on_hand', s.on_hand, 'held', h.held, 'sold_not_packed', tfd_to_pack(p.sku), 'in_bin', s.on_hand + tfd_to_pack(p.sku), 'available', s.on_hand - h.held,
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

create or replace function tfd_bins() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'note', b.note,
      'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', x.name, 'brand', x.brand, 'model', x.model, 'color_code', x.color_code, 'lens_size', x.lens_size,
          'color_name', x.color_name, 'upc', x.upc, 'on_hand', x.oh, 'to_pack', x.tp, 'in_bin', x.oh + x.tp, 'on_stage', x.on_stage) order by x.sku)
        from (select p.*, tfd_on_hand(p.sku) oh, tfd_to_pack(p.sku) tp from products p where p.bin_id = b.id) x where x.oh + x.tp > 0), '[]'))
    order by b.code = 'NOT_ASSIGNED' desc, b.code) from bins b), '[]');
end $$;

create or replace function tfd_bin_detail(p_code text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bins; c text := upper(trim(p_code));
begin
  perform tfd_require('admin');
  select * into b from bins where code = c;
  if b.id is null then raise exception 'No such bin'; end if;
  return jsonb_build_object('code', b.code, 'note', b.note, 'created_at', b.created_at,
    'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', x.name, 'brand', x.brand, 'model', x.model, 'color_code', x.color_code, 'lens_size', x.lens_size,
        'color_name', x.color_name, 'upc', x.upc, 'on_hand', x.oh, 'to_pack', x.tp, 'in_bin', x.oh + x.tp, 'on_stage', x.on_stage) order by x.sku)
      from (select p.*, tfd_on_hand(p.sku) oh, tfd_to_pack(p.sku) tp from products p where p.bin_id = b.id) x where x.oh + x.tp > 0), '[]'),
    'sold_out', coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', coalesce(x.name, concat_ws(' ', x.brand, x.model))) order by x.sku)
      from (select p.*, tfd_on_hand(p.sku) oh, tfd_to_pack(p.sku) tp from products p where p.bin_id = b.id) x where x.oh + x.tp = 0), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', m.at, 'kind', m.kind, 'sku', m.sku, 'name', coalesce(p.name, concat_ws(' ', p.brand, p.model)),
        'qty', m.qty, 'actor', m.actor, 'from', m.detail->>'from', 'to', m.detail->>'to', 'reason', m.reason, 'detail', m.detail) order by m.at desc, m.id desc)
      from (select * from stock_moves m where (m.kind = 'bin_move' and (m.detail->>'from' = c or m.detail->>'to' = c))
               or (m.kind = 'receipt' and m.detail->>'bin' = c) or (m.kind = 'verify' and m.detail->>'bin' = c)
               or (m.kind in ('adjust_out','adjust_in') and m.sku in (select sku from products where bin_id = b.id))
             order by m.at desc, m.id desc limit 300) m left join products p on p.sku = m.sku), '[]'));
end $$;

create or replace function tfd_bin_verify(p_bin text, p_counts jsonb, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; b bins; p products; counted int; oh int; diffs jsonb := '[]'; d jsonb; r jsonb;
begin
  me := tfd_require('admin');
  select * into b from bins where code = upper(trim(p_bin));
  if b.id is null then raise exception 'No such bin'; end if;
  for p in select * from products where bin_id = b.id and tfd_on_hand(sku) + tfd_to_pack(sku) > 0 order by sku loop
    if not p_counts ? p.sku then raise exception 'Enter a count for every SKU in the bin (missing %)', p.sku; end if;
    counted := (p_counts->>p.sku)::int; oh := tfd_on_hand(p.sku) + tfd_to_pack(p.sku) - case when p.on_stage then 1 else 0 end;   -- sold-not-packed units are still in the bin; the stage sample isn't
    if counted < 0 then raise exception 'Counts can''t be negative'; end if;
    if counted <> oh then diffs := diffs || jsonb_build_object('sku', p.sku, 'name', p.name, 'on_hand', oh, 'counted', counted, 'diff', counted - oh); end if;
  end loop;
  if not p_confirm or jsonb_array_length(diffs) = 0 then
    if p_confirm then
      perform tfd_log(me.name, 'Inventory', 'bin_verify', 'Bin ' || b.code || ' verified: all counts match');
      insert into stock_moves (sku, kind, qty, actor, detail) select p2.sku, 'verify', 0, me.name, jsonb_build_object('bin', b.code, 'result', 'match')
        from products p2 where p2.bin_id = b.id and tfd_on_hand(p2.sku) + tfd_to_pack(p2.sku) > 0;
    end if;
    return jsonb_build_object('ok', true, 'differences', diffs, 'applied', p_confirm);
  end if;
  for d in select * from jsonb_array_elements(diffs) loop
    r := tfd_adjust((d->>'sku')::char(6), case when (d->>'diff')::int > 0 then 'in' else 'out' end, abs((d->>'diff')::int), 'count correction', 'Bin ' || b.code || ' verify', true);
    insert into stock_moves (sku, kind, qty, actor, detail) values ((d->>'sku')::char(6), 'verify', 0, me.name, jsonb_build_object('bin', b.code, 'on_hand', d->'on_hand', 'counted', d->'counted'));
  end loop;
  perform tfd_log(me.name, 'Inventory', 'bin_verify', 'Bin ' || b.code || ' verified: ' || jsonb_array_length(diffs) || ' SKU(s) corrected', jsonb_build_object('differences', diffs));
  return jsonb_build_object('ok', true, 'differences', diffs, 'applied', true);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function tfd_can_pack(), tfd_to_pack(text), tfd_make_packages(bigint), tfd_pack_me(), tfd_pack_clock(boolean), tfd_pack_data(), tfd_pack_pkg(bigint),
  tfd_pack_check(bigint, boolean), tfd_pack_scan(bigint, text, uuid), tfd_pack_undo(bigint), tfd_pack_photo_add(bigint, text, int), tfd_pack_photo_remove(bigint),
  tfd_pack_finish(bigint), tfd_pack_problem(bigint, text), tfd_pack_queue(), tfd_pick_list(), tfd_pack_lookup(text), tfd_pack_resolve(bigint, text),
  tfd_pack_unpack(bigint, text), tfd_set_on_stage(text, boolean), tfd_photos_expired(), tfd_photos_mark_deleted(bigint[], text) from public, anon;
revoke execute on function tfd_to_pack(text), tfd_make_packages(bigint), tfd_pack_me(), tfd_pack_pkg(bigint), tfd_pack_check(bigint, boolean) from authenticated;
grant execute on function tfd_can_pack(), tfd_pack_clock(boolean), tfd_pack_data(), tfd_pack_scan(bigint, text, uuid), tfd_pack_undo(bigint), tfd_pack_photo_add(bigint, text, int),
  tfd_pack_photo_remove(bigint), tfd_pack_finish(bigint), tfd_pack_problem(bigint, text), tfd_pack_queue(), tfd_pick_list(), tfd_pack_lookup(text), tfd_pack_resolve(bigint, text),
  tfd_pack_unpack(bigint, text), tfd_set_on_stage(text, boolean), tfd_photos_expired(), tfd_photos_mark_deleted(bigint[], text) to authenticated;
