-- TFD app — Phase 2b: Inventory lots (Kenny's review, Nov 10 2026).
-- Lots (named supplier · invoice · date), every field optional except cost, UPC matching with Match / Match all,
-- searchable dropdown values, lot photos, NOT_ASSIGNED bin, full SKU editing, alert dismissals, bin history,
-- and inventory version history with restore.

-- ---------------------------------------------------------------- schema changes
alter table activity_log add column if not exists tx bigint default txid_current();
create index if not exists activity_log_tx on activity_log (tx);

alter table products alter column brand drop not null, alter column model drop not null, alter column color_code drop not null,
  alter column lens_size drop not null, alter column ident drop not null;
update products set upc = nullif(trim(upc), '') where upc is distinct from nullif(trim(upc), '');
create unique index if not exists products_upc on products (upc) where upc is not null;

alter table receipts add column if not exists name text, add column if not exists name_custom boolean not null default false;
alter table receipts alter column supplier drop not null;

alter table receipt_lines alter column invoiced_qty drop not null, alter column invoiced_qty drop default,
  alter column received_qty drop not null, alter column received_qty drop default;
alter table receipt_lines add column if not exists update_catalog boolean not null default false;

create table if not exists lot_photos (
  id bigserial primary key, receipt_id bigint not null references receipts(id), path text not null unique, caption text,
  uploaded_by text not null, at timestamptz not null default now());
create table if not exists alert_dismissals (
  id bigserial primary key, sku char(6) not null references products(sku), kind text not null check (kind in ('low','out')),
  on_hand int not null, at timestamptz not null default now(), by_name text not null, unique (sku, kind));
create table if not exists inv_changes (
  id bigserial primary key, tx bigint not null default txid_current(), at timestamptz not null default now(), actor text,
  tbl text not null, op char(1) not null, pk text not null, old jsonb, new jsonb);
create index if not exists inv_changes_tx on inv_changes (tx);
alter table lot_photos enable row level security; alter table alert_dismissals enable row level security; alter table inv_changes enable row level security;
revoke all on lot_photos, alert_dismissals, inv_changes from anon, authenticated;

insert into bins (code, note) values ('NOT_ASSIGNED', 'SKUs waiting to be put away') on conflict (code) do nothing;
update products set bin_id = (select id from bins where code = 'NOT_ASSIGNED') where bin_id is null;

-- Required fields: every lot field can be toggled except cost (always required).
update setting_defaults set value = jsonb_set(value, '{required_fields}',
  '["supplier","received_date","brand","model","color_code","lens_size","name","retail","received_qty"]')
  where key = 'inventory';
insert into settings_history (key, value, effective_from, set_by, reason)
select 'inventory', cur || jsonb_build_object('required_fields', (
    select to_jsonb(array_agg(distinct k)) from (
      select unnest(array['supplier','received_date','brand','model','color_code','lens_size']) k
      union all
      select case x when 'product_name' then 'name' when 'retail_price' then 'retail' when 'weight' then 'weight' when 'image' then 'image_url'
                    when 'bin' then 'bin' when 'quantity' then 'received_qty' when 'category' then 'category' when 'subcategory' then 'subcategory'
                    when 'brand' then 'brand' end
      from jsonb_array_elements_text(cur->'required_fields') x) s where k is not null)),
  now(), 'System', 'Required fields reorganized for lots (every field can be toggled except cost)'
from (select tfd_get_setting('inventory') cur) c
where not (c.cur->'required_fields' ? 'received_qty');

-- ---------------------------------------------------------------- helpers
create or replace function tfd_is_admin() returns boolean language sql stable security definer set search_path = public as
  $$ select exists (select 1 from profiles where auth_id = auth.uid() and role = 'admin' and active) $$;

create or replace function tfd_req() returns text[] language sql stable security definer set search_path = public as
  $$ select coalesce((select array_agg(x) from jsonb_array_elements_text(tfd_get_setting('inventory')->'required_fields') x), '{}') $$;

create or replace function tfd_lot_auto_name(p_supplier text, p_invoice text, p_date date) returns text language sql immutable as
  $$ select concat_ws(' · ', nullif(trim(p_supplier), ''), nullif(trim(p_invoice), ''), p_date::text) $$;

update receipts set name = tfd_lot_auto_name(supplier, invoice_no, received_date) where name is null;

create or replace function tfd_full_ident(b text, m text, c text, l text) returns text language sql immutable as
  $$ select case when nullif(trim(b), '') is null or nullif(trim(m), '') is null or nullif(trim(c), '') is null or nullif(trim(l), '') is null
                 then null else tfd_ident(b, m, c, l) end $$;

create or replace function tfd_cand(p products, p_reason text) returns jsonb language sql stable security definer set search_path = public as
  $$ select jsonb_build_object('sku', p.sku, 'reason', p_reason, 'brand', p.brand, 'model', p.model, 'color_code', p.color_code, 'lens_size', p.lens_size,
       'name', p.name, 'upc', p.upc, 'bin', (select code from bins where id = p.bin_id), 'on_hand', tfd_on_hand(p.sku)) $$;

create or replace function tfd_line_values(l jsonb) returns receipt_lines language plpgsql immutable as $$
declare r receipt_lines;
begin
  r.brand := nullif(trim(l->>'brand'), ''); r.model := nullif(trim(l->>'model'), ''); r.color_code := nullif(trim(l->>'color_code'), ''); r.lens_size := nullif(trim(l->>'lens_size'), '');
  r.name := nullif(trim(l->>'name'), ''); r.color_name := nullif(trim(l->>'color_name'), ''); r.image_url := nullif(trim(l->>'image_url'), '');
  r.category := nullif(trim(l->>'category'), ''); r.subcategory := nullif(trim(l->>'subcategory'), ''); r.upc := nullif(trim(l->>'upc'), ''); r.specs := nullif(trim(l->>'specs'), '');
  r.bin_code := nullif(upper(trim(l->>'bin_code')), '');
  r.retail_cents := nullif(l->>'retail_cents', '')::int; r.weight_oz := nullif(l->>'weight_oz', '')::numeric; r.unit_cost_cents := nullif(l->>'unit_cost_cents', '')::int;
  r.invoiced_qty := nullif(l->>'invoiced_qty', '')::int; r.received_qty := nullif(l->>'received_qty', '')::int;
  r.lists := coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(l->'lists', '[]')) x), '{}');
  return r;
end $$;

-- ---------------------------------------------------------------- matching + checks
-- status: existing (matched or same brand/model/color/size), new, suggest (needs Match or New), pick (UPC and details point to different SKUs)
create or replace function tfd_line_check(l receipt_lines) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare req text[] := tfd_req(); p products; up products; ip products; probs jsonb := '[]'; cands jsonb := '[]'; conflicts jsonb := '[]';
  status text; idt text := tfd_full_ident(l.brand, l.model, l.color_code, l.lens_size); f text; lv text; pv text; dup text;
  catfields text[] := array['brand','model','color_code','lens_size','upc','name','color_name','retail_cents','weight_oz','image_url','category','subcategory','specs'];
  reqmap jsonb := '{"brand":"brand","model":"model","color_code":"color_code","lens_size":"lens_size","upc":"upc","name":"name","color_name":"color_name",
    "retail":"retail_cents","weight":"weight_oz","image_url":"image_url","category":"category","subcategory":"subcategory","specs":"specs","bin":"bin_code"}';
  labels jsonb := '{"brand":"Brand","model":"Model #","color_code":"Color code","lens_size":"Lens size","upc":"UPC","name":"Product name","color_name":"Color name",
    "retail":"Retail price","weight":"Weight","image_url":"Image URL","category":"Category","subcategory":"Subcategory","specs":"Specs","bin":"Bin"}';
begin
  if l.map_sku is not null then
    select * into p from products where sku = l.map_sku;
    if p.sku is null then probs := probs || jsonb_build_object('f', null, 'm', 'Matched SKU ' || l.map_sku || ' no longer exists'); end if;
    status := 'existing';
  else
    if l.upc is not null then select * into up from products where upc = l.upc; end if;
    if idt is not null then select * into ip from products where ident = idt; end if;
    if l.confirmed_new then
      status := 'new';
      if up.sku is not null then probs := probs || jsonb_build_object('f', 'upc', 'm', 'UPC is already on SKU ' || up.sku || '. One UPC can''t be on two SKUs. Match it, or fix the UPC'); end if;
      if ip.sku is not null then probs := probs || jsonb_build_object('f', 'brand', 'm', 'Brand, model, color and size already belong to SKU ' || ip.sku || '. Match it, or change a detail'); end if;
    elsif ip.sku is not null and (up.sku is null or up.sku = ip.sku) then
      p := ip; status := 'existing';
    elsif ip.sku is not null then
      status := 'pick'; cands := jsonb_build_array(tfd_cand(up, 'Same UPC'), tfd_cand(ip, 'Same brand, model, color, size'));
      probs := probs || jsonb_build_object('f', 'upc', 'm', 'UPC matches SKU ' || up.sku || ' but the details match SKU ' || ip.sku || '. Pick the right one');
    elsif up.sku is not null then
      status := 'suggest'; cands := jsonb_build_array(tfd_cand(up, 'Same UPC'));
      probs := probs || jsonb_build_object('f', 'upc', 'm', 'Same UPC as SKU ' || up.sku || '. Click Match (or New if it really is a different product)');
    else
      select coalesce(jsonb_agg(tfd_cand(x, 'Same brand + model') order by x.sku), '[]') into cands
        from (select * from products where l.brand is not null and l.model is not null and tfd_norm(brand) = tfd_norm(l.brand) and tfd_norm(model) = tfd_norm(l.model) limit 8) x;
      if jsonb_array_length(cands) > 0 then
        status := 'suggest';
        probs := probs || jsonb_build_object('f', null, 'm', 'Looks like an existing product (same brand + model). Click Match or New');
      else status := 'new'; end if;
    end if;
  end if;

  if status = 'new' then
    for f in select x from jsonb_object_keys(reqmap) x loop
      if f = any(req) and to_jsonb(l) ->> (reqmap->>f) is null then
        probs := probs || jsonb_build_object('f', reqmap->>f, 'm', (labels->>f) || ' is required');
      end if;
    end loop;
  end if;
  if 'invoiced_qty' = any(req) and l.invoiced_qty is null then probs := probs || jsonb_build_object('f', 'invoiced_qty', 'm', 'Invoiced qty is required'); end if;
  if 'received_qty' = any(req) and l.received_qty is null then probs := probs || jsonb_build_object('f', 'received_qty', 'm', 'Received qty is required'); end if;
  if l.unit_cost_cents is null then probs := probs || jsonb_build_object('f', 'unit_cost_cents', 'm', 'Unit cost is required'); end if;
  if l.bin_code is not null and status = 'new' and l.bin_code !~ '^[A-Z0-9][A-Z0-9 ._-]{0,19}$' then
    probs := probs || jsonb_build_object('f', 'bin_code', 'm', 'Bin "' || l.bin_code || '" isn''t a valid bin code (letters, numbers, dashes)'); end if;

  if idt is not null then
    select string_agg(o.line_no::text, ', ') into dup from receipt_lines o where o.receipt_id = l.receipt_id and o.id <> l.id
      and tfd_full_ident(o.brand, o.model, o.color_code, o.lens_size) = idt;
    if dup is not null then probs := probs || jsonb_build_object('f', 'brand', 'm', 'Same product as row ' || dup || '. Combine them into one row'); end if;
  end if;
  if l.upc is not null then
    select string_agg(o.line_no::text, ', ') into dup from receipt_lines o where o.receipt_id = l.receipt_id and o.id <> l.id and o.upc = l.upc;
    if dup is not null then probs := probs || jsonb_build_object('f', 'upc', 'm', 'Same UPC as row ' || dup || '. Combine them into one row'); end if;
  end if;
  if l.map_sku is not null then
    select string_agg(o.line_no::text, ', ') into dup from receipt_lines o where o.receipt_id = l.receipt_id and o.id <> l.id and o.map_sku = l.map_sku;
    if dup is not null then probs := probs || jsonb_build_object('f', null, 'm', 'Row ' || dup || ' is matched to the same SKU. Combine them into one row'); end if;
  end if;

  if status = 'existing' and p.sku is not null then
    foreach f in array catfields loop
      lv := to_jsonb(l) ->> f; pv := to_jsonb(p) ->> f;
      if lv is not null and pv is not null and (case when f in ('retail_cents','weight_oz') then lv::numeric <> pv::numeric else tfd_norm(lv) <> tfd_norm(pv) end) then
        conflicts := conflicts || jsonb_build_object('field', f, 'catalog', pv, 'line', lv);
      end if;
    end loop;
  end if;

  return jsonb_build_object('status', status, 'product', case when p.sku is null then null else tfd_product_json(p) end,
    'candidates', cands, 'conflicts', conflicts, 'problems', probs);
end $$;

create or replace function tfd_lot_issues(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r receipts; req text[] := tfd_req(); out jsonb := '[]'; l receipt_lines; chk jsonb; pr jsonb;
begin
  select * into r from receipts where id = p_id;
  if 'supplier' = any(req) and r.supplier is null then out := out || to_jsonb('Supplier is required'::text); end if;
  if 'invoice_no' = any(req) and r.invoice_no is null then out := out || to_jsonb('Invoice # is required'::text); end if;
  if 'received_date' = any(req) and r.received_date is null then out := out || to_jsonb('Date is required'::text); end if;
  if 'lot_photo' = any(req) and not exists (select 1 from lot_photos where receipt_id = p_id) then out := out || to_jsonb('At least one lot photo is required'::text); end if;
  if not exists (select 1 from receipt_lines where receipt_id = p_id) then out := out || to_jsonb('Add at least one SKU row'::text); end if;
  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    chk := tfd_line_check(l);
    for pr in select * from jsonb_array_elements(chk->'problems') loop
      out := out || to_jsonb('Row ' || l.line_no || ': ' || (pr->>'m'));
    end loop;
  end loop;
  return out;
end $$;

-- ---------------------------------------------------------------- lots
create or replace function tfd_receipt_create(p_supplier text, p_invoice_no text, p_date date, p_lines jsonb default '[]', p_source_file text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles; rid bigint; l jsonb; v receipt_lines; n int := 0; d date := coalesce(p_date, current_date);
begin
  me := tfd_require('admin');
  insert into receipts (supplier, invoice_no, received_date, source_file, created_by, name)
    values (nullif(trim(p_supplier), ''), nullif(trim(p_invoice_no), ''), d, p_source_file, me.name, tfd_lot_auto_name(p_supplier, p_invoice_no, d)) returning id into rid;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    n := n + 1; v := tfd_line_values(l);
    insert into receipt_lines (receipt_id, line_no, brand, model, color_code, lens_size, name, color_name, retail_cents, weight_oz, image_url, category, subcategory, upc, specs, bin_code, lists, invoiced_qty, received_qty, unit_cost_cents)
      values (rid, n, v.brand, v.model, v.color_code, v.lens_size, v.name, v.color_name, v.retail_cents, v.weight_oz, v.image_url, v.category, v.subcategory, v.upc, v.specs, v.bin_code, v.lists, v.invoiced_qty, v.received_qty, v.unit_cost_cents);
  end loop;
  perform tfd_log(me.name, 'Inventory', 'receipt_draft', 'Lot draft started: ' || tfd_lot_auto_name(p_supplier, p_invoice_no, d) || ' (' || n || ' SKU rows)',
    jsonb_build_object('receipt', rid), null, null, null, p_source_file);
  return rid;
end $$;

drop function if exists tfd_receipt_header(bigint, text, text, date);
create or replace function tfd_receipt_header(p_id bigint, p_supplier text, p_invoice_no text, p_date date, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts; auto text; nm text; custom boolean;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_id for update;
  if r.id is null then raise exception 'No such lot'; end if;
  if r.status = 'draft' then
    auto := tfd_lot_auto_name(p_supplier, p_invoice_no, coalesce(p_date, r.received_date));
    if p_name is null then nm := case when r.name_custom then r.name else auto end; custom := r.name_custom;
    elsif trim(p_name) = '' or trim(p_name) = auto then nm := auto; custom := false;
    else nm := trim(p_name); custom := true; end if;
    update receipts set supplier = nullif(trim(p_supplier), ''), invoice_no = nullif(trim(p_invoice_no), ''), received_date = coalesce(p_date, received_date),
      name = nm, name_custom = custom where id = p_id;
  else
    if p_name is null or trim(p_name) = '' then raise exception 'Only the lot name can change after the count is confirmed'; end if;
    if trim(p_name) <> r.name then
      update receipts set name = trim(p_name), name_custom = true where id = p_id;
      perform tfd_log(me.name, 'Inventory', 'lot_rename', 'Lot renamed: "' || r.name || '" → "' || trim(p_name) || '"', jsonb_build_object('receipt', p_id));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'name', (select name from receipts where id = p_id));
end $$;

create or replace function tfd_receipt_line_save(p_receipt_id bigint, p_line_id bigint, p_fields jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v receipt_lines; id_ bigint := p_line_id;
begin
  perform tfd_require('admin');
  if not exists (select 1 from receipts where id = p_receipt_id and status = 'draft') then raise exception 'Only draft lots can be changed'; end if;
  v := tfd_line_values(p_fields);
  if id_ is null then
    insert into receipt_lines (receipt_id, line_no) values (p_receipt_id, coalesce((select max(line_no) from receipt_lines where receipt_id = p_receipt_id), 0) + 1) returning id into id_;
  end if;
  update receipt_lines set brand = v.brand, model = v.model, color_code = v.color_code, lens_size = v.lens_size, name = v.name, color_name = v.color_name,
    retail_cents = v.retail_cents, weight_oz = v.weight_oz, image_url = v.image_url, category = v.category, subcategory = v.subcategory, upc = v.upc, specs = v.specs,
    bin_code = v.bin_code, lists = v.lists, invoiced_qty = v.invoiced_qty, received_qty = v.received_qty, unit_cost_cents = v.unit_cost_cents,
    map_sku = nullif(p_fields->>'map_sku', '')::char(6), confirmed_new = coalesce((p_fields->>'confirmed_new')::boolean, false),
    update_catalog = coalesce((p_fields->>'update_catalog')::boolean, false)
  where id = id_ and receipt_id = p_receipt_id;
  if not found then raise exception 'No such row'; end if;
  return id_;
end $$;

create or replace function tfd_receipt_discard(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_id;
  if r.status is distinct from 'draft' then raise exception 'Only drafts can be discarded'; end if;
  delete from lot_photos where receipt_id = p_id;
  delete from receipt_lines where receipt_id = p_id;   -- children first, so version restore can replay in reverse
  delete from receipts where id = p_id;
  perform tfd_log(me.name, 'Inventory', 'receipt_discard', 'Lot draft discarded: ' || r.name);
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_lot_match_all(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare l receipt_lines; chk jsonb; n int := 0;
begin
  perform tfd_require('admin');
  if not exists (select 1 from receipts where id = p_id and status = 'draft') then raise exception 'Only draft lots can be changed'; end if;
  for l in select * from receipt_lines where receipt_id = p_id and map_sku is null and not confirmed_new order by line_no loop
    chk := tfd_line_check(l);
    if chk->>'status' = 'suggest' and chk->'candidates'->0->>'reason' = 'Same UPC' then
      update receipt_lines set map_sku = (chk->'candidates'->0->>'sku')::char(6) where id = l.id; n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'matched', n);
end $$;

create or replace function tfd_receipts() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'supplier', r.supplier, 'invoice_no', r.invoice_no, 'received_date', r.received_date,
      'status', r.status, 'created_by', r.created_by, 'confirmed_at', r.confirmed_at, 'source_file', r.source_file,
      'skus', (select count(*) from receipt_lines where receipt_id = r.id),
      'units', (select coalesce(sum(coalesce(received_qty, invoiced_qty, 0)), 0) from receipt_lines where receipt_id = r.id),
      'cost_cents', (select coalesce(sum(coalesce(received_qty, invoiced_qty, 0)::bigint * coalesce(unit_cost_cents, 0)), 0) from receipt_lines where receipt_id = r.id),
      'discrepancies', (select count(*) from receipt_lines where receipt_id = r.id and received_qty is not null and invoiced_qty is not null and received_qty <> invoiced_qty),
      'photos', (select count(*) from lot_photos where receipt_id = r.id),
      'search', concat_ws(' ', r.name, r.supplier, r.invoice_no, r.received_date::text, r.source_file, r.created_by,
        (select string_agg(concat_ws(' ', brand, model, color_code, lens_size, upc, name, color_name, category, subcategory, specs, bin_code, result_sku, map_sku), ' ')
           from receipt_lines where receipt_id = r.id)))
    order by (r.status = 'draft') desc, r.received_date desc, r.id desc) from receipts r), '[]');
end $$;

create or replace function tfd_receipt(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r receipts;
begin
  perform tfd_require('admin');
  select * into r from receipts where id = p_id;
  if r.id is null then raise exception 'No such lot'; end if;
  return to_jsonb(r) || jsonb_build_object(
    'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('check', case when r.status = 'draft' then tfd_line_check(l) else null end) order by l.line_no) from receipt_lines l where l.receipt_id = p_id), '[]'),
    'photos', coalesce((select jsonb_agg(to_jsonb(ph) order by ph.id) from lot_photos ph where ph.receipt_id = p_id), '[]'),
    'issues', case when r.status = 'draft' then tfd_lot_issues(p_id) else '[]' end,
    'required', to_jsonb(tfd_req()));
end $$;

create or replace function tfd_receipt_confirm(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts; l receipt_lines; chk jsonb; sku_ char(6); issues jsonb; created int := 0; units int := 0; cost bigint := 0; qty int;
  disc jsonb := '[]'; bin_ bigint;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_id for update;
  if r.status is distinct from 'draft' then raise exception 'This lot was already confirmed'; end if;
  issues := tfd_lot_issues(p_id);
  if jsonb_array_length(issues) > 0 then raise exception '%', (select string_agg(x, E'\n') from jsonb_array_elements_text(issues) x); end if;
  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    chk := tfd_line_check(l);
    qty := coalesce(l.received_qty, l.invoiced_qty, 0);
    if chk->>'status' = 'existing' then
      sku_ := chk->'product'->>'sku';
      if l.update_catalog then
        update products set name = coalesce(l.name, name), color_name = coalesce(l.color_name, color_name), retail_cents = coalesce(l.retail_cents, retail_cents),
          weight_oz = coalesce(l.weight_oz, weight_oz), image_url = coalesce(l.image_url, image_url), category = coalesce(l.category, category),
          subcategory = coalesce(l.subcategory, subcategory), specs = coalesce(l.specs, specs) where sku = sku_;
      end if;
    elsif chk->>'status' = 'new' then
      if qty = 0 then
        if coalesce(l.invoiced_qty, 0) > 0 then disc := disc || jsonb_build_object('line', l.line_no, 'sku', null, 'invoiced', l.invoiced_qty, 'received', 0); end if;
        continue;
      end if;
      sku_ := tfd_next_sku();
      bin_ := tfd_bin_id(coalesce(l.bin_code, 'NOT_ASSIGNED'), me.name);
      insert into products (sku, brand, model, color_code, lens_size, ident, name, color_name, retail_cents, weight_oz, image_url, category, subcategory, upc, specs, bin_id)
        values (sku_, l.brand, l.model, l.color_code, l.lens_size, tfd_full_ident(l.brand, l.model, l.color_code, l.lens_size),
          l.name, l.color_name, l.retail_cents, l.weight_oz, l.image_url, l.category, l.subcategory, l.upc, l.specs, bin_);
      created := created + 1;
    else
      raise exception 'Row % still needs Match or New', l.line_no;
    end if;
    update receipt_lines set result_sku = sku_ where id = l.id;
    if qty > 0 then
      insert into cost_layers (sku, receipt_line_id, unit_cost_cents, qty_in, qty_remaining) values (sku_, l.id, l.unit_cost_cents, qty, qty);
      insert into stock_moves (sku, kind, qty, value_cents, receipt_id, actor, detail)
        values (sku_, 'receipt', qty, qty::bigint * l.unit_cost_cents, p_id, me.name, jsonb_build_object('line', l.line_no, 'unit_cost_cents', l.unit_cost_cents,
          'bin', (select b.code from products p join bins b on b.id = p.bin_id where p.sku = sku_), 'new', chk->>'status' = 'new'));
      units := units + qty; cost := cost + qty::bigint * l.unit_cost_cents;
    end if;
    if l.received_qty is not null and l.invoiced_qty is not null and l.received_qty <> l.invoiced_qty then
      disc := disc || jsonb_build_object('line', l.line_no, 'sku', sku_, 'invoiced', l.invoiced_qty, 'received', l.received_qty); end if;
    if cardinality(l.lists) > 0 then
      update inv_lists set skus = (select array_agg(distinct s) from unnest(skus || sku_) s) where id = any(l.lists) and kind = 'manual';
    end if;
  end loop;
  update receipts set status = 'confirmed', confirmed_by = me.name, confirmed_at = now() where id = p_id;
  perform tfd_log(me.name, 'Inventory', 'receipt_confirm',
    'Lot confirmed: ' || r.name || ', ' || units || ' units, ' || tfd_fmt('x_cents', to_jsonb(cost)) ||
      case when created > 0 then ', ' || created || ' new SKU(s)' else '' end || case when jsonb_array_length(disc) > 0 then ', ' || jsonb_array_length(disc) || ' count difference(s)' else '' end,
    jsonb_build_object('receipt', p_id, 'discrepancies', disc), null, jsonb_build_object('type', 'receipt', 'id', p_id), null, r.source_file);
  return jsonb_build_object('ok', true, 'units', units, 'cost_cents', cost, 'new_skus', created, 'discrepancies', disc,
    'skus', (select jsonb_agg(distinct result_sku) from receipt_lines where receipt_id = p_id and result_sku is not null));
end $$;

create or replace function tfd_field_values() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '{}'; f text; vals jsonb;
begin
  perform tfd_require('admin');
  foreach f in array array['brand','model','color_code','lens_size','name','color_name','category','subcategory','specs'] loop
    execute format('select coalesce(jsonb_agg(v order by lower(v)), ''[]'') from (select distinct on (lower(v)) v from (
        select %1$I v from products union all select %1$I from receipt_lines) a where v is not null and trim(v) <> '''' order by lower(v), v) b', f) into vals;
    out := out || jsonb_build_object(f, vals);
  end loop;
  return out || jsonb_build_object(
      'supplier', (select coalesce(jsonb_agg(v order by lower(v)), '[]') from (select distinct on (lower(supplier)) supplier v from receipts where supplier is not null order by lower(supplier), supplier) s),
      'bin', (select coalesce(jsonb_agg(code order by code = 'NOT_ASSIGNED' desc, code), '[]') from bins));
end $$;

create or replace function tfd_lot_photo_add(p_receipt_id bigint, p_path text, p_caption text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me profiles; id_ bigint; r receipts;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_receipt_id;
  if r.id is null then raise exception 'No such lot'; end if;
  if p_path not like 'lot-' || p_receipt_id || '/%' then raise exception 'Photo path doesn''t belong to this lot'; end if;
  insert into lot_photos (receipt_id, path, caption, uploaded_by) values (p_receipt_id, p_path, nullif(trim(p_caption), ''), me.name) returning id into id_;
  perform tfd_log(me.name, 'Inventory', 'lot_photo', 'Photo added to lot ' || r.name, jsonb_build_object('receipt', p_receipt_id, 'photo', id_));
  return id_;
end $$;

create or replace function tfd_lot_photo_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; ph lot_photos;
begin
  me := tfd_require('admin');
  delete from lot_photos where id = p_id returning * into ph;
  if ph.id is null then raise exception 'No such photo'; end if;
  perform tfd_log(me.name, 'Inventory', 'lot_photo_delete', 'Photo removed from lot ' || (select name from receipts where id = ph.receipt_id) || ' (file kept, restorable)',
    jsonb_build_object('receipt', ph.receipt_id, 'photo', p_id));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- SKU editing (every field)
create or replace function tfd_product_update(p_sku text, p_fields jsonb, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; p products; np products; f text; parts text[] := '{}'; clean jsonb := '{}'; other text; idt text;
  editable text[] := array['brand','model','color_code','lens_size','upc','name','color_name','retail_cents','weight_oz','image_url','category','subcategory','specs','low_stock'];
begin
  me := tfd_require('admin');
  select * into p from products where sku = p_sku for update;
  if p.sku is null then raise exception 'No such SKU'; end if;
  for f in select jsonb_object_keys(p_fields) loop
    if not f = any(editable) then raise exception '% can''t be edited here', f; end if;
    clean := clean || jsonb_build_object(f, nullif(trim(p_fields ->> f), ''));
  end loop;
  np := jsonb_populate_record(p, clean);
  foreach f in array editable loop
    if (case when f in ('retail_cents','weight_oz','low_stock') then (to_jsonb(p) ->> f)::numeric is distinct from (to_jsonb(np) ->> f)::numeric
             else (to_jsonb(p) ->> f) is distinct from (to_jsonb(np) ->> f) end) then
      parts := parts || (replace(f, '_', ' ') || ': ' || coalesce(to_jsonb(p) ->> f, 'blank') || ' → ' || coalesce(to_jsonb(np) ->> f, 'blank'));
    end if;
  end loop;
  if cardinality(parts) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  idt := tfd_full_ident(np.brand, np.model, np.color_code, np.lens_size);
  if idt is not null then
    select sku into other from products where ident = idt and sku <> p_sku;
    if other is not null then raise exception 'Those details (brand, model, color, size) already belong to SKU %', other; end if;
  end if;
  if np.upc is not null then
    select sku into other from products where upc = np.upc and sku <> p_sku;
    if other is not null then raise exception 'UPC % is already on SKU %', np.upc, other; end if;
  end if;
  update products set brand = np.brand, model = np.model, color_code = np.color_code, lens_size = np.lens_size, ident = idt, upc = np.upc,
    name = np.name, color_name = np.color_name, retail_cents = np.retail_cents, weight_oz = np.weight_oz, image_url = np.image_url,
    category = np.category, subcategory = np.subcategory, specs = np.specs, low_stock = np.low_stock where sku = p_sku;
  perform tfd_log(me.name, 'Inventory', 'product_edit', 'SKU ' || p_sku || ': ' || array_to_string(parts, '; '), jsonb_build_object('sku', p_sku), p_reason, null);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- stock alerts
create or replace function tfd_alert_dismissed(p_sku text, p_kind text, p_on_hand int) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from alert_dismissals d where d.sku = p_sku and d.kind = p_kind and d.on_hand = p_on_hand
    and not exists (select 1 from stock_moves m where m.sku = p_sku and m.qty > 0 and m.at > d.at)) $$;

create or replace function tfd_alert_dismiss(p_sku text, p_kind text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; oh int;
begin
  me := tfd_require('admin');
  if p_kind not in ('low','out') then raise exception 'Unknown alert'; end if;
  if not exists (select 1 from products where sku = p_sku) then raise exception 'No such SKU'; end if;
  oh := tfd_on_hand(p_sku);
  insert into alert_dismissals (sku, kind, on_hand, by_name) values (p_sku, p_kind, oh, me.name)
    on conflict (sku, kind) do update set on_hand = excluded.on_hand, at = now(), by_name = excluded.by_name;
  perform tfd_log(me.name, 'Inventory', 'alert_dismiss', 'Dismissed ' || case p_kind when 'low' then 'low-stock' else 'out-of-stock' end || ' alert for SKU ' || p_sku || ' at ' || oh || ' on hand');
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_stock() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare low_default int := (tfd_get_setting('inventory')->>'low_stock_default')::int;
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(row order by row->>'sku') from (
    select to_jsonb(p) || jsonb_build_object(
      'bin', b.code, 'on_hand', s.on_hand, 'held', 0, 'sold_not_packed', 0, 'available', s.on_hand,
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
                               max(unit_cost_cents) filter (where qty_remaining > 0) max_cost from cost_layers c where c.sku = p.sku) s) x), '[]');
end $$;

-- ---------------------------------------------------------------- bins
create or replace function tfd_bins() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'note', b.note,
      'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'brand', p.brand, 'model', p.model, 'color_code', p.color_code, 'lens_size', p.lens_size,
          'color_name', p.color_name, 'upc', p.upc, 'on_hand', tfd_on_hand(p.sku)) order by p.sku) from products p where p.bin_id = b.id), '[]'))
    order by b.code = 'NOT_ASSIGNED' desc, b.code) from bins b), '[]');
end $$;

create or replace function tfd_bin_detail(p_code text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bins; c text := upper(trim(p_code));
begin
  perform tfd_require('admin');
  select * into b from bins where code = c;
  if b.id is null then raise exception 'No such bin'; end if;
  return jsonb_build_object('code', b.code, 'note', b.note, 'created_at', b.created_at,
    'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'brand', p.brand, 'model', p.model, 'color_code', p.color_code, 'lens_size', p.lens_size,
        'color_name', p.color_name, 'upc', p.upc, 'on_hand', tfd_on_hand(p.sku)) order by p.sku) from products p where p.bin_id = b.id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', m.at, 'kind', m.kind, 'sku', m.sku, 'name', coalesce(p.name, concat_ws(' ', p.brand, p.model)),
        'qty', m.qty, 'actor', m.actor, 'from', m.detail->>'from', 'to', m.detail->>'to', 'reason', m.reason, 'detail', m.detail) order by m.at desc, m.id desc)
      from (select * from stock_moves m where (m.kind = 'bin_move' and (m.detail->>'from' = c or m.detail->>'to' = c))
               or (m.kind = 'receipt' and m.detail->>'bin' = c) or (m.kind = 'verify' and m.detail->>'bin' = c)
             order by m.at desc, m.id desc limit 300) m left join products p on p.sku = m.sku), '[]'));
end $$;

-- ---------------------------------------------------------------- version history
create or replace function tfd_track() returns trigger language plpgsql security definer set search_path = public as $$
declare k text := TG_ARGV[0]; who text := coalesce((select name from profiles where auth_id = auth.uid()), 'System');
begin
  if TG_OP = 'INSERT' then insert into inv_changes (actor, tbl, op, pk, new) values (who, TG_TABLE_NAME, 'I', to_jsonb(new) ->> k, to_jsonb(new));
  elsif TG_OP = 'UPDATE' then
    if to_jsonb(old) is distinct from to_jsonb(new) then insert into inv_changes (actor, tbl, op, pk, old, new) values (who, TG_TABLE_NAME, 'U', to_jsonb(old) ->> k, to_jsonb(old), to_jsonb(new)); end if;
  else insert into inv_changes (actor, tbl, op, pk, old) values (who, TG_TABLE_NAME, 'D', to_jsonb(old) ->> k, to_jsonb(old)); end if;
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['bins','products','receipts','receipt_lines','cost_layers','stock_moves','inv_lists','lot_photos','alert_dismissals'] loop
    execute format('drop trigger if exists tfd_track on %I', t);
    execute format('create trigger tfd_track after insert or update or delete on %I for each row execute function tfd_track(%L)', t, case when t = 'products' then 'sku' else 'id' end);
  end loop;
end $$;

create or replace function tfd_versions(p_limit int default 300) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(v order by (v->>'last')::bigint desc) from (
    select jsonb_build_object('tx', c.tx, 'last', max(c.id), 'at', min(c.at), 'changes', count(*),
      'actor', coalesce((select a.actor from activity_log a where a.tx = c.tx order by a.id limit 1), min(c.actor)),
      'summary', coalesce((select string_agg(a.summary, ' · ' order by a.id) from activity_log a where a.tx = c.tx),
        case when bool_and(c.tbl in ('receipts','receipt_lines')) then 'Lot draft edited' else 'Inventory changed' end),
      'restore', exists (select 1 from activity_log a where a.tx = c.tx and a.action = 'version_restore')) v
    from inv_changes c group by c.tx order by max(c.id) desc limit p_limit) x), '[]');
end $$;

create or replace function tfd_revert_change(c inv_changes) returns void language plpgsql security definer set search_path = public as $$
declare pkcol text := case when c.tbl = 'products' then 'sku' else 'id' end; cols text; rcols text;
begin
  if c.op = 'I' then
    execute format('delete from %I where %I::text = $1', c.tbl, pkcol) using c.pk;
  elsif c.op = 'D' then
    execute format('insert into %I select * from jsonb_populate_record(null::%I, $1)', c.tbl, c.tbl) using c.old;
  else
    select string_agg(quote_ident(attname), ', ' order by attnum), string_agg('r.' || quote_ident(attname), ', ' order by attnum) into cols, rcols
      from pg_attribute where attrelid = c.tbl::regclass and attnum > 0 and not attisdropped;
    execute format('update %I t set (%s) = (select %s from jsonb_populate_record(null::%I, $1) r) where t.%I::text = $2', c.tbl, cols, rcols, c.tbl, pkcol) using c.old, c.pk;
  end if;
end $$;

create or replace function tfd_version_restore(p_tx bigint, p_reason text, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; target bigint; top bigint; c inv_changes; n int := 0; txs bigint[]; lid bigint; label text;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_confirm is distinct from 'RESTORE' then raise exception 'Type RESTORE to confirm'; end if;
  select max(id) into target from inv_changes where tx = p_tx;
  if target is null then raise exception 'No such version'; end if;
  select max(id) into top from inv_changes;
  if top = target then raise exception 'That is already the current version. Nothing to restore'; end if;
  select array_agg(distinct tx) into txs from inv_changes where id > target and id <= top;
  for c in select * from inv_changes where id > target and id <= top order by id desc loop
    perform tfd_revert_change(c); n := n + 1;
  end loop;
  label := coalesce((select string_agg(summary, ' · ' order by id) from activity_log where tx = p_tx), 'version of ' || (select to_char(min(at), 'Mon DD HH24:MI') from inv_changes where tx = p_tx));
  lid := tfd_log(me.name, 'Inventory', 'version_restore', 'Restored inventory to right after: ' || left(label, 200) || ' (' || cardinality(txs) || ' later action(s) reversed, ' || n || ' changes)',
    jsonb_build_object('to_tx', p_tx, 'reversed_txs', to_jsonb(txs)), p_reason);
  update activity_log set undone_by = lid where tx = any(txs) and undo is not null and undone_by is null;
  return jsonb_build_object('ok', true, 'actions', cardinality(txs), 'changes', n);
end $$;

-- ---------------------------------------------------------------- lot photo storage (private bucket, admins only)
insert into storage.buckets (id, name, public) values ('lot-photos', 'lot-photos', false) on conflict (id) do nothing;
drop policy if exists "tfd lot photos read" on storage.objects;
drop policy if exists "tfd lot photos add" on storage.objects;
create policy "tfd lot photos read" on storage.objects for select to authenticated using (bucket_id = 'lot-photos' and public.tfd_is_admin());
create policy "tfd lot photos add" on storage.objects for insert to authenticated with check (bucket_id = 'lot-photos' and public.tfd_is_admin());

-- ---------------------------------------------------------------- grants
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function tfd_state(), tfd_settings(), tfd_setting_history(text), tfd_set_setting(text, jsonb, timestamptz, text),
  tfd_set_rate(text, text, int, int, timestamptz, text), tfd_set_role(text, jsonb, text), tfd_users(),
  tfd_update_user(bigint, text, text, boolean, text), tfd_floor_preview(int, text), tfd_activity(jsonb), tfd_undo(bigint, text, boolean),
  tfd_receipt_create(text, text, date, jsonb, text), tfd_receipt_header(bigint, text, text, date, text), tfd_receipt_line_save(bigint, bigint, jsonb),
  tfd_receipt_line_delete(bigint, bigint), tfd_receipt_discard(bigint), tfd_receipts(), tfd_receipt(bigint), tfd_receipt_confirm(bigint),
  tfd_lot_match_all(bigint), tfd_field_values(), tfd_lot_photo_add(bigint, text, text), tfd_lot_photo_delete(bigint),
  tfd_product_update(text, jsonb, text), tfd_stock(), tfd_sku_history(text), tfd_adjust(text, text, int, text, text, boolean), tfd_alert_dismiss(text, text),
  tfd_bins(), tfd_bin_detail(text), tfd_bin_create(text, text), tfd_move_sku(text, text), tfd_bin_verify(text, jsonb, boolean),
  tfd_lists(), tfd_list_save(bigint, text, text, jsonb, int, text[]), tfd_list_delete(bigint), tfd_whatnot_export(bigint), tfd_export_logged(text, int),
  tfd_versions(int), tfd_version_restore(bigint, text, text), tfd_is_admin()
  to authenticated;
grant execute on function tfd_create_profile(uuid, uuid, text, text, text), tfd_log_from_server(uuid, text, text) to service_role;
