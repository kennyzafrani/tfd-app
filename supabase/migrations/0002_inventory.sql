-- TFD app — Phase 2: Inventory (catalog, bins, receiving, FIFO cost layers, adjustments, lists, Whatnot export).
-- Same pattern as Phase 1: tables locked, everything through checked + logged tfd_* functions.

-- ---------------------------------------------------------------- tables
create table if not exists bins (
  id bigserial primary key, code text not null unique, note text, created_at timestamptz not null default now());

create table if not exists products (
  sku          char(6) primary key check (sku ~ '^[0-9]{6}$'),
  brand        text not null, model text not null, color_code text not null, lens_size text not null,
  ident        text not null unique,            -- normalized brand|model|color|lens: one product, forever
  name         text, color_name text, retail_cents int check (retail_cents >= 0), weight_oz numeric(8,2) check (weight_oz >= 0),
  image_url    text, category text, subcategory text, upc text, specs text,
  bin_id       bigint references bins(id),
  low_stock    int check (low_stock >= 0),      -- null = use the Settings default
  created_at   timestamptz not null default now());

create table if not exists receipts (
  id bigserial primary key, supplier text not null, invoice_no text, received_date date not null,
  status text not null default 'draft' check (status in ('draft','confirmed','undone')),
  source_file text, created_by text not null, created_at timestamptz not null default now(),
  confirmed_by text, confirmed_at timestamptz);

create table if not exists receipt_lines (
  id bigserial primary key, receipt_id bigint not null references receipts(id) on delete cascade, line_no int not null,
  brand text, model text, color_code text, lens_size text,
  name text, color_name text, retail_cents int, weight_oz numeric(8,2), image_url text, category text, subcategory text, upc text, specs text,
  bin_code text, lists bigint[] not null default '{}',
  invoiced_qty int not null default 0 check (invoiced_qty >= 0), received_qty int not null default 0 check (received_qty >= 0),
  unit_cost_cents int check (unit_cost_cents >= 0),
  map_sku char(6),                                -- Kenny's answer to a near-match: use this existing SKU
  confirmed_new boolean not null default false,   -- Kenny's answer to a near-match: it really is a new product
  updates text[] not null default '{}',           -- catalog fields Kenny chose to overwrite with this line's value
  result_sku char(6));                            -- filled at Confirm count

create table if not exists cost_layers (           -- FIFO: each receipt line (or count-up) is a layer
  id bigserial primary key, sku char(6) not null references products(sku), receipt_line_id bigint references receipt_lines(id),
  unit_cost_cents int not null check (unit_cost_cents >= 0), qty_in int not null check (qty_in >= 0),
  qty_remaining int not null check (qty_remaining >= 0 and qty_remaining <= qty_in), created_at timestamptz not null default now());
create index if not exists cost_layers_sku on cost_layers (sku, created_at, id);

create table if not exists stock_moves (           -- every change to stock, for the SKU history page
  id bigserial primary key, at timestamptz not null default now(), sku char(6) not null references products(sku),
  kind text not null, qty int not null, value_cents bigint, reason text, note text,
  receipt_id bigint references receipts(id), detail jsonb, actor text not null);
create index if not exists stock_moves_sku on stock_moves (sku, at desc);

create table if not exists inv_lists (
  id bigserial primary key, name text not null unique, kind text not null check (kind in ('manual','rule')),
  rule jsonb not null default '{}', pct int check (pct between 1 and 100), skus char(6)[] not null default '{}',
  created_by text not null, created_at timestamptz not null default now());

alter table bins enable row level security; alter table products enable row level security;
alter table receipts enable row level security; alter table receipt_lines enable row level security;
alter table cost_layers enable row level security; alter table stock_moves enable row level security;
alter table inv_lists enable row level security;
revoke all on bins, products, receipts, receipt_lines, cost_layers, stock_moves, inv_lists from anon, authenticated;

-- Whatnot export needs a few more defaults Kenny fills in (left blank: never guessed).
update setting_defaults set value = '{"category":"Bags & Accessories","subcategory":"Sunglasses","type":"","price_source":"retail","shipping_profile":"","offerable":"","hazmat":"","condition":""}'
  where key = 'whatnot_export' and not (value ? 'type');
insert into settings_history (key, value, effective_from, set_by, reason)
select 'whatnot_export', (select value from setting_defaults where key = 'whatnot_export') || tfd_get_setting('whatnot_export'), now(), 'System', 'Added Whatnot export fields (Phase 2)'
where not (tfd_get_setting('whatnot_export') ? 'type');

-- ---------------------------------------------------------------- helpers
-- Fix from Phase 1: the floor calculation failed when typical shipping wasn't set yet.
create or replace function tfd_floor(p_cost_cents int, p_platform jsonb, p_commission_bp int, p_floor_profit_bp int)
returns jsonb language plpgsql immutable as $$
declare a numeric; b numeric; f numeric; s numeric; c numeric; r numeric; exact numeric; flags text[] := '{}';
begin
  if jsonb_typeof(p_platform->'pct_sale_bp') = 'null' or jsonb_typeof(p_platform->'pct_ship_bp') = 'null' or jsonb_typeof(p_platform->'fixed_cents') = 'null' then
    return jsonb_build_object('exact_cents', null, 'rounded_cents', null, 'flags', jsonb_build_array('fees_not_set'));
  end if;
  a := (p_platform->>'pct_sale_bp')::numeric / 10000; b := (p_platform->>'pct_ship_bp')::numeric / 10000; f := (p_platform->>'fixed_cents')::numeric;
  if jsonb_typeof(p_platform->'typical_ship_cents') = 'null' then s := 0; flags := flags || 'shipping_not_set'::text; else s := (p_platform->>'typical_ship_cents')::numeric; end if;
  c := p_commission_bp::numeric / 10000; r := p_floor_profit_bp::numeric / 10000;
  exact := ceil((p_cost_cents * (1 + r) / (1 - c) + b * s + f) / (1 - a) - 0.000001);
  return jsonb_build_object('exact_cents', exact, 'rounded_cents', ceil(exact / 100) * 100, 'flags', to_jsonb(flags));
end $$;

create or replace function tfd_norm(t text) returns text language sql immutable as
  $$ select lower(regexp_replace(trim(coalesce(t, '')), '\s+', ' ', 'g')) $$;
create or replace function tfd_ident(b text, m text, c text, l text) returns text language sql immutable as
  $$ select tfd_norm(b) || '|' || tfd_norm(m) || '|' || tfd_norm(c) || '|' || tfd_norm(l) $$;

create or replace function tfd_on_hand(p_sku text) returns int language sql stable security definer set search_path = public as
  $$ select coalesce(sum(qty_remaining), 0)::int from cost_layers where sku = p_sku $$;

create or replace function tfd_bin_id(p_code text, p_actor text) returns bigint language plpgsql security definer set search_path = public as $$
declare c text := upper(trim(coalesce(p_code, ''))); id_ bigint;
begin
  if c = '' then return null; end if;
  if c !~ '^[A-Z0-9][A-Z0-9 ._-]{0,19}$' then raise exception 'Bin "%" isn''t a valid bin code (letters, numbers, dashes; e.g. A4)', p_code; end if;
  select id into id_ from bins where code = c;
  if id_ is null then
    insert into bins (code) values (c) returning id into id_;
    perform tfd_log(p_actor, 'Inventory', 'bin_create', 'Bin ' || c || ' created');
  end if;
  return id_;
end $$;

create or replace function tfd_next_sku() returns char(6) language sql volatile security definer set search_path = public as
  $$ select lpad((greatest(coalesce(max(sku::int), 100000), 100000) + 1)::text, 6, '0')::char(6) from products $$;

-- FIFO removal: takes units from the oldest layers. Returns total value removed (cents).
create or replace function tfd_take_fifo(p_sku text, p_qty int, out value_cents bigint, out taken jsonb) language plpgsql security definer set search_path = public as $$
declare l cost_layers; need int := p_qty; t int;
begin
  value_cents := 0; taken := '[]';
  for l in select * from cost_layers where sku = p_sku and qty_remaining > 0 order by created_at, id for update loop
    exit when need = 0;
    t := least(need, l.qty_remaining);
    update cost_layers set qty_remaining = qty_remaining - t where id = l.id;
    value_cents := value_cents + t::bigint * l.unit_cost_cents; need := need - t;
    taken := taken || jsonb_build_object('layer', l.id, 'qty', t);
  end loop;
  if need > 0 then raise exception 'Only % unit(s) of SKU % on hand', p_qty - need, p_sku; end if;
end $$;

create or replace function tfd_product_json(p products) returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(p) || jsonb_build_object('bin', (select code from bins where id = p.bin_id), 'on_hand', tfd_on_hand(p.sku)) $$;

-- ---------------------------------------------------------------- receiving
-- Lines come from the TFD receiving template (or a blank receipt). Keys: brand, model, color_code, lens_size,
-- invoiced_qty, received_qty, unit_cost_cents, name, color_name, retail_cents, weight_oz, image_url, category, subcategory, upc, specs, bin_code
create or replace function tfd_line_values(l jsonb) returns receipt_lines language plpgsql immutable as $$
declare r receipt_lines;
begin
  r.brand := nullif(trim(l->>'brand'), ''); r.model := nullif(trim(l->>'model'), ''); r.color_code := nullif(trim(l->>'color_code'), ''); r.lens_size := nullif(trim(l->>'lens_size'), '');
  r.name := nullif(trim(l->>'name'), ''); r.color_name := nullif(trim(l->>'color_name'), ''); r.image_url := nullif(trim(l->>'image_url'), '');
  r.category := nullif(trim(l->>'category'), ''); r.subcategory := nullif(trim(l->>'subcategory'), ''); r.upc := nullif(trim(l->>'upc'), ''); r.specs := nullif(trim(l->>'specs'), '');
  r.bin_code := nullif(upper(trim(l->>'bin_code')), '');
  r.retail_cents := nullif(l->>'retail_cents', '')::int; r.weight_oz := nullif(l->>'weight_oz', '')::numeric; r.unit_cost_cents := nullif(l->>'unit_cost_cents', '')::int;
  r.invoiced_qty := coalesce(nullif(l->>'invoiced_qty', '')::int, 0);
  r.received_qty := coalesce(nullif(l->>'received_qty', '')::int, r.invoiced_qty);
  r.lists := coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(l->'lists', '[]')) x), '{}');
  return r;
end $$;

create or replace function tfd_receipt_create(p_supplier text, p_invoice_no text, p_date date, p_lines jsonb default '[]', p_source_file text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare me profiles; rid bigint; l jsonb; v receipt_lines; n int := 0;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_supplier, '')) = '' then raise exception 'Supplier is required'; end if;
  insert into receipts (supplier, invoice_no, received_date, source_file, created_by)
    values (trim(p_supplier), nullif(trim(p_invoice_no), ''), coalesce(p_date, current_date), p_source_file, me.name) returning id into rid;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    n := n + 1; v := tfd_line_values(l);
    insert into receipt_lines (receipt_id, line_no, brand, model, color_code, lens_size, name, color_name, retail_cents, weight_oz, image_url, category, subcategory, upc, specs, bin_code, lists, invoiced_qty, received_qty, unit_cost_cents)
      values (rid, n, v.brand, v.model, v.color_code, v.lens_size, v.name, v.color_name, v.retail_cents, v.weight_oz, v.image_url, v.category, v.subcategory, v.upc, v.specs, v.bin_code, v.lists, v.invoiced_qty, v.received_qty, v.unit_cost_cents);
  end loop;
  perform tfd_log(me.name, 'Inventory', 'receipt_draft', 'Receipt draft #' || rid || ' started: ' || trim(p_supplier) || coalesce(' invoice ' || nullif(trim(p_invoice_no), ''), '') || ' (' || n || ' lines)',
    jsonb_build_object('receipt', rid), null, null, null, p_source_file);
  return rid;
end $$;

create or replace function tfd_receipt_header(p_id bigint, p_supplier text, p_invoice_no text, p_date date) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  if trim(coalesce(p_supplier, '')) = '' then raise exception 'Supplier is required'; end if;
  update receipts set supplier = trim(p_supplier), invoice_no = nullif(trim(p_invoice_no), ''), received_date = p_date where id = p_id and status = 'draft';
  if not found then raise exception 'Only draft receipts can be changed'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Save one line (p_line_id null = add a line). p_fields uses the same keys as the template, plus map_sku, confirmed_new, updates.
create or replace function tfd_receipt_line_save(p_receipt_id bigint, p_line_id bigint, p_fields jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v receipt_lines; id_ bigint := p_line_id;
begin
  perform tfd_require('admin');
  if not exists (select 1 from receipts where id = p_receipt_id and status = 'draft') then raise exception 'Only draft receipts can be changed'; end if;
  v := tfd_line_values(p_fields);
  if id_ is null then
    insert into receipt_lines (receipt_id, line_no) values (p_receipt_id, coalesce((select max(line_no) from receipt_lines where receipt_id = p_receipt_id), 0) + 1) returning id into id_;
  end if;
  update receipt_lines set brand = v.brand, model = v.model, color_code = v.color_code, lens_size = v.lens_size, name = v.name, color_name = v.color_name,
    retail_cents = v.retail_cents, weight_oz = v.weight_oz, image_url = v.image_url, category = v.category, subcategory = v.subcategory, upc = v.upc, specs = v.specs,
    bin_code = v.bin_code, lists = v.lists, invoiced_qty = v.invoiced_qty, received_qty = v.received_qty, unit_cost_cents = v.unit_cost_cents,
    map_sku = nullif(p_fields->>'map_sku', '')::char(6), confirmed_new = coalesce((p_fields->>'confirmed_new')::boolean, false),
    updates = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_fields->'updates', '[]')) x), '{}')
  where id = id_ and receipt_id = p_receipt_id;
  if not found then raise exception 'No such line'; end if;
  return id_;
end $$;

create or replace function tfd_receipt_line_delete(p_receipt_id bigint, p_line_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  if not exists (select 1 from receipts where id = p_receipt_id and status = 'draft') then raise exception 'Only draft receipts can be changed'; end if;
  delete from receipt_lines where id = p_line_id and receipt_id = p_receipt_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_receipt_discard(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_id;
  if r.status is distinct from 'draft' then raise exception 'Only drafts can be discarded'; end if;
  delete from receipts where id = p_id;
  perform tfd_log(me.name, 'Inventory', 'receipt_discard', 'Receipt draft #' || p_id || ' discarded (' || r.supplier || ')');
  return jsonb_build_object('ok', true);
end $$;

-- Check one line against the catalog. Returns status (ok/new/near/error), the matched product, conflicts, problems.
create or replace function tfd_line_check(l receipt_lines) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p products; probs text[] := '{}'; conflicts jsonb := '[]'; near jsonb; status text; req jsonb; brands jsonb; f text; lv text; pv text;
  inv jsonb := tfd_get_setting('inventory'); fields text[] := array['name','color_name','retail_cents','weight_oz','image_url','category','subcategory','upc','specs'];
begin
  req := inv->'required_fields';
  brands := tfd_get_setting('lists')->'brands';
  if l.brand is null or l.model is null or l.color_code is null or l.lens_size is null then
    probs := probs || 'Brand, model #, color code and lens size are all required'::text;
  elsif not exists (select 1 from jsonb_array_elements_text(brands) b where tfd_norm(b) = tfd_norm(l.brand)) then
    probs := probs || ('Brand "' || l.brand || '" isn''t in Settings → Lists → Brands');
  end if;
  if l.unit_cost_cents is null then probs := probs || 'Unit cost is required'::text; end if;
  if l.map_sku is not null then select * into p from products where sku = l.map_sku;
  elsif l.brand is not null then select * into p from products where ident = tfd_ident(l.brand, l.model, l.color_code, l.lens_size); end if;

  if p.sku is not null then
    status := 'existing';
    for f in select unnest(fields) loop
      lv := to_jsonb(l) ->> f; pv := to_jsonb(p) ->> f;
      if lv is not null and pv is not null and lv <> pv and (f not in ('retail_cents','weight_oz') or lv::numeric <> pv::numeric) then
        conflicts := conflicts || jsonb_build_object('field', f, 'catalog', pv, 'line', lv, 'update', f = any(l.updates)); end if;
    end loop;
    if l.bin_code is not null and p.bin_id is not null and l.bin_code <> (select code from bins where id = p.bin_id) then
      probs := probs || ('SKU ' || p.sku || ' lives in bin ' || (select code from bins where id = p.bin_id) || '. Leave Bin blank, or use Bins → Move SKU');
    end if;
  else
    select coalesce(jsonb_agg(jsonb_build_object('sku', x.sku, 'brand', x.brand, 'model', x.model, 'color_code', x.color_code, 'lens_size', x.lens_size, 'name', x.name)), '[]') into near
      from (select * from products where tfd_norm(brand) = tfd_norm(l.brand) and tfd_norm(model) = tfd_norm(l.model) limit 10) x;
    if jsonb_array_length(near) > 0 and not l.confirmed_new then status := 'near'; else status := 'new'; end if;
    if l.received_qty > 0 then
      if req ? 'product_name' and l.name is null then probs := probs || 'Product name is required for a new SKU'::text; end if;
      if req ? 'retail_price' and l.retail_cents is null then probs := probs || 'Retail price is required for a new SKU'::text; end if;
      if req ? 'weight' and l.weight_oz is null then probs := probs || 'Weight is required for a new SKU'::text; end if;
      if req ? 'image' and l.image_url is null then probs := probs || 'Image is required for a new SKU'::text; end if;
      if req ? 'category' and l.category is null then probs := probs || 'Category is required for a new SKU'::text; end if;
      if req ? 'subcategory' and l.subcategory is null then probs := probs || 'Subcategory is required for a new SKU'::text; end if;
      if req ? 'bin' and l.bin_code is null then probs := probs || 'Bin is required for a new SKU'::text; end if;
    end if;
  end if;
  if exists (select 1 from receipt_lines o where o.receipt_id = l.receipt_id and o.id <> l.id and o.brand is not null
             and tfd_ident(o.brand, o.model, o.color_code, o.lens_size) = tfd_ident(l.brand, l.model, l.color_code, l.lens_size)) then
    probs := probs || 'Same product appears on another line of this receipt. Combine them into one line'::text;
  end if;
  return jsonb_build_object('status', status, 'product', case when p.sku is null then null else tfd_product_json(p) end,
    'near', coalesce(near, '[]'), 'conflicts', conflicts, 'problems', to_jsonb(probs));
end $$;

create or replace function tfd_receipts() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'supplier', r.supplier, 'invoice_no', r.invoice_no, 'received_date', r.received_date, 'status', r.status,
      'created_by', r.created_by, 'confirmed_at', r.confirmed_at, 'lines', (select count(*) from receipt_lines where receipt_id = r.id),
      'units', (select coalesce(sum(received_qty), 0) from receipt_lines where receipt_id = r.id),
      'cost_cents', (select coalesce(sum(received_qty::bigint * coalesce(unit_cost_cents, 0)), 0) from receipt_lines where receipt_id = r.id),
      'discrepancies', (select count(*) from receipt_lines where receipt_id = r.id and received_qty <> invoiced_qty))
    order by (r.status = 'draft') desc, r.id desc) from receipts r), '[]');
end $$;

create or replace function tfd_receipt(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r receipts;
begin
  perform tfd_require('admin');
  select * into r from receipts where id = p_id;
  if r.id is null then raise exception 'No such receipt'; end if;
  return to_jsonb(r) || jsonb_build_object('lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('check', case when r.status = 'draft' then tfd_line_check(l) else null end) order by l.line_no) from receipt_lines l where l.receipt_id = p_id), '[]'));
end $$;

create or replace function tfd_receipt_confirm(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; r receipts; l receipt_lines; chk jsonb; p products; sku_ char(6); bad text[] := '{}'; created int := 0; units int := 0; cost bigint := 0;
  disc jsonb := '[]'; f text; bin_ bigint; lid bigint;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_id for update;
  if r.status is distinct from 'draft' then raise exception 'This receipt was already confirmed'; end if;
  if not exists (select 1 from receipt_lines where receipt_id = p_id) then raise exception 'The receipt has no lines'; end if;
  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    chk := tfd_line_check(l);
    if chk->>'status' = 'near' then bad := bad || ('Line ' || l.line_no || ': looks like an existing product. Pick it, or confirm it''s new'); end if;
    if jsonb_array_length(chk->'problems') > 0 then bad := bad || ('Line ' || l.line_no || ': ' || (select string_agg(x, '; ') from jsonb_array_elements_text(chk->'problems') x)); end if;
  end loop;
  if cardinality(bad) > 0 then raise exception '%', array_to_string(bad, E'\n'); end if;

  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    if l.map_sku is not null then select * into p from products where sku = l.map_sku;
    else select * into p from products where ident = tfd_ident(l.brand, l.model, l.color_code, l.lens_size); end if;
    if p.sku is null then
      if l.received_qty = 0 then
        if l.invoiced_qty > 0 then disc := disc || jsonb_build_object('line', l.line_no, 'sku', null, 'invoiced', l.invoiced_qty, 'received', 0); end if;
        continue;                                          -- nothing arrived: no catalog entry yet
      end if;
      sku_ := tfd_next_sku();
      bin_ := tfd_bin_id(l.bin_code, me.name);
      insert into products (sku, brand, model, color_code, lens_size, ident, name, color_name, retail_cents, weight_oz, image_url, category, subcategory, upc, specs, bin_id)
        values (sku_, trim(l.brand), trim(l.model), trim(l.color_code), trim(l.lens_size), tfd_ident(l.brand, l.model, l.color_code, l.lens_size),
          l.name, l.color_name, l.retail_cents, l.weight_oz, l.image_url, l.category, l.subcategory, l.upc, l.specs, bin_);
      created := created + 1;
    else
      sku_ := p.sku;
      foreach f in array l.updates loop                       -- catalog fields Kenny chose to overwrite
        if f in ('name','color_name','retail_cents','weight_oz','image_url','category','subcategory','upc','specs') and to_jsonb(l) ->> f is not null then
          execute format('update products set %I = $1.%I where sku = $2', f, f) using l, sku_;
        end if;
      end loop;
      if p.bin_id is null and l.bin_code is not null then update products set bin_id = tfd_bin_id(l.bin_code, me.name) where sku = sku_; end if;
    end if;
    update receipt_lines set result_sku = sku_ where id = l.id;
    if l.received_qty > 0 then
      insert into cost_layers (sku, receipt_line_id, unit_cost_cents, qty_in, qty_remaining) values (sku_, l.id, l.unit_cost_cents, l.received_qty, l.received_qty);
      insert into stock_moves (sku, kind, qty, value_cents, receipt_id, actor, detail)
        values (sku_, 'receipt', l.received_qty, l.received_qty::bigint * l.unit_cost_cents, p_id, me.name, jsonb_build_object('line', l.line_no, 'unit_cost_cents', l.unit_cost_cents));
      units := units + l.received_qty; cost := cost + l.received_qty::bigint * l.unit_cost_cents;
    end if;
    if l.received_qty <> l.invoiced_qty then disc := disc || jsonb_build_object('line', l.line_no, 'sku', sku_, 'invoiced', l.invoiced_qty, 'received', l.received_qty); end if;
    if cardinality(l.lists) > 0 then
      update inv_lists set skus = (select array_agg(distinct s) from unnest(skus || sku_) s) where id = any(l.lists) and kind = 'manual';
    end if;
  end loop;
  update receipts set status = 'confirmed', confirmed_by = me.name, confirmed_at = now() where id = p_id;
  perform tfd_log(me.name, 'Inventory', 'receipt_confirm',
    'Receipt #' || p_id || ' confirmed: ' || r.supplier || coalesce(' invoice ' || r.invoice_no, '') || ', ' || units || ' units, ' || tfd_fmt('x_cents', to_jsonb(cost)) ||
      case when created > 0 then ', ' || created || ' new SKU(s)' else '' end || case when jsonb_array_length(disc) > 0 then ', ' || jsonb_array_length(disc) || ' count difference(s)' else '' end,
    jsonb_build_object('receipt', p_id, 'discrepancies', disc), null, jsonb_build_object('type', 'receipt', 'id', p_id), null, r.source_file);
  return jsonb_build_object('ok', true, 'units', units, 'cost_cents', cost, 'new_skus', created, 'discrepancies', disc,
    'skus', (select jsonb_agg(distinct result_sku) from receipt_lines where receipt_id = p_id and result_sku is not null));
end $$;

-- ---------------------------------------------------------------- catalog edits
create or replace function tfd_product_update(p_sku text, p_fields jsonb, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; p products; f text; parts text[] := '{}'; prev jsonb := '{}';
  editable text[] := array['name','color_name','retail_cents','weight_oz','image_url','category','subcategory','upc','specs','low_stock'];
begin
  me := tfd_require('admin');
  select * into p from products where sku = p_sku for update;
  if p.sku is null then raise exception 'No such SKU'; end if;
  for f in select jsonb_object_keys(p_fields) loop
    if not f = any(editable) then raise exception '% can''t be edited here (brand, model, color code and lens size define the product)', f; end if;
    if (case when f in ('retail_cents','weight_oz','low_stock') then (to_jsonb(p) ->> f)::numeric is distinct from nullif(p_fields ->> f, '')::numeric
            else (to_jsonb(p) ->> f) is distinct from nullif(p_fields ->> f, '') end) then
      prev := prev || jsonb_build_object(f, to_jsonb(p) -> f);
      parts := parts || (replace(f, '_', ' ') || ': ' || coalesce(to_jsonb(p) ->> f, 'blank') || ' → ' || coalesce(nullif(p_fields ->> f, ''), 'blank'));
      execute format('update products set %I = (jsonb_populate_record(null::products, $1)).%I where sku = $2', f, f) using jsonb_build_object(f, nullif(p_fields ->> f, '')), p_sku;
    end if;
  end loop;
  if cardinality(parts) = 0 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  perform tfd_log(me.name, 'Inventory', 'product_edit', 'SKU ' || p_sku || ': ' || array_to_string(parts, '; '), null, p_reason, null);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- stock
create or replace function tfd_floor_for(p_cost_cents int, p_platform text) returns jsonb language sql stable security definer set search_path = public as $$
  select tfd_floor(p_cost_cents, tfd_get_setting('platform.' || p_platform), (select commission_bp from tfd_rate_for(null, 'streamer')), (tfd_get_setting('pricing')->>'floor_profit_bp')::int) $$;

create or replace function tfd_stock() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare low_default int := (tfd_get_setting('inventory')->>'low_stock_default')::int;
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(row order by row->>'sku') from (
    select to_jsonb(p) || jsonb_build_object(
      'bin', b.code, 'on_hand', s.on_hand, 'held', 0, 'sold_not_packed', 0, 'available', s.on_hand,
      'value_cents', s.value_cents, 'max_cost_cents', s.max_cost, 'low_stock_effective', coalesce(p.low_stock, low_default),
      'floor_tiktok', case when s.max_cost is null then null else (tfd_floor_for(s.max_cost, 'tiktok')->>'rounded_cents')::int end,
      'floor_whatnot', case when s.max_cost is null then null else (tfd_floor_for(s.max_cost, 'whatnot')->>'rounded_cents')::int end,
      'last_received', (select max(r.received_date) from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku),
      'suppliers', (select coalesce(jsonb_agg(distinct r.supplier), '[]') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku),
      'receipts', (select coalesce(jsonb_agg(distinct r.id), '[]') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku and c.qty_remaining > 0),
      'sold_30', 0) as row
    from products p left join bins b on b.id = p.bin_id
    cross join lateral (select coalesce(sum(qty_remaining), 0)::int on_hand, coalesce(sum(qty_remaining::bigint * unit_cost_cents), 0) value_cents,
                               max(unit_cost_cents) filter (where qty_remaining > 0) max_cost from cost_layers c where c.sku = p.sku) s) x), '[]');
end $$;

create or replace function tfd_sku_history(p_sku text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p products;
begin
  perform tfd_require('admin');
  select * into p from products where sku = p_sku;
  if p.sku is null then raise exception 'No such SKU'; end if;
  return jsonb_build_object('product', tfd_product_json(p),
    'layers', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'unit_cost_cents', c.unit_cost_cents, 'qty_in', c.qty_in, 'qty_remaining', c.qty_remaining, 'created_at', c.created_at,
        'receipt', (select receipt_id from receipt_lines where id = c.receipt_line_id)) order by c.created_at, c.id) from cost_layers c where c.sku = p_sku), '[]'),
    'moves', coalesce((select jsonb_agg(to_jsonb(m) order by m.at desc, m.id desc) from stock_moves m where m.sku = p_sku), '[]'));
end $$;

-- ---------------------------------------------------------------- adjustments
create or replace function tfd_adjust(p_sku text, p_direction text, p_qty int, p_reason text, p_note text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; p products; rules jsonb := tfd_get_setting('rules'); tk record; v bigint; cost int; lid bigint; mid bigint; ok_reasons text[];
begin
  me := tfd_require('admin');
  select * into p from products where sku = p_sku;
  if p.sku is null then raise exception 'No such SKU: %', p_sku; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be at least 1'; end if;
  if (rules->>'adjust_reason_required')::boolean and trim(coalesce(p_reason, '')) = '' then raise exception 'A reason is required'; end if;
  if p_direction = 'out' then
    ok_reasons := array['damaged','lost','theft','personal/sample','return to supplier','count correction'];
    if trim(coalesce(p_reason, '')) <> '' and not p_reason = any(ok_reasons) then raise exception 'Pick a reason from the list'; end if;
    -- held units can't be removed (holds arrive with Shows; until then available = on hand)
    if p_qty > tfd_on_hand(p_sku) then raise exception 'Only % unit(s) of SKU % available to remove', tfd_on_hand(p_sku), p_sku; end if;
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

-- ---------------------------------------------------------------- bins
create or replace function tfd_bins() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'note', b.note,
      'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'brand', p.brand, 'model', p.model, 'color_code', p.color_code, 'lens_size', p.lens_size, 'on_hand', tfd_on_hand(p.sku)) order by p.sku) from products p where p.bin_id = b.id), '[]'))
    order by b.code) from bins b), '[]');
end $$;

create or replace function tfd_bin_create(p_code text, p_note text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('admin');
  if exists (select 1 from bins where code = upper(trim(p_code))) then raise exception 'Bin % already exists', upper(trim(p_code)); end if;
  perform tfd_bin_id(p_code, me.name);
  update bins set note = nullif(trim(p_note), '') where code = upper(trim(p_code));
  return jsonb_build_object('ok', true);
end $$;

create or replace function tfd_move_sku(p_sku text, p_bin text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; p products; old_code text; new_id bigint; mid bigint;
begin
  me := tfd_require('admin');
  select * into p from products where sku = p_sku for update;
  if p.sku is null then raise exception 'No such SKU'; end if;
  old_code := (select code from bins where id = p.bin_id);
  new_id := tfd_bin_id(p_bin, me.name);
  if new_id is null then raise exception 'Pick a bin'; end if;
  if new_id = p.bin_id then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  update products set bin_id = new_id where sku = p_sku;
  insert into stock_moves (sku, kind, qty, actor, detail) values (p_sku, 'bin_move', 0, me.name, jsonb_build_object('from', old_code, 'to', upper(trim(p_bin)))) returning id into mid;
  perform tfd_log(me.name, 'Inventory', 'bin_move', 'SKU ' || p_sku || ' moved from ' || coalesce(old_code, 'no bin') || ' to ' || upper(trim(p_bin)) || ' (all ' || tfd_on_hand(p_sku) || ' units)',
    jsonb_build_object('sku', p_sku), null, jsonb_build_object('type', 'bin_move', 'sku', p_sku, 'from_bin', p.bin_id, 'to_bin', new_id));
  return jsonb_build_object('ok', true);
end $$;

-- Verify a bin: p_counts = {"123456": 7, ...} for every SKU in the bin. Without p_confirm it only returns the differences.
create or replace function tfd_bin_verify(p_bin text, p_counts jsonb, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; b bins; p products; counted int; oh int; diffs jsonb := '[]'; d jsonb; r jsonb;
begin
  me := tfd_require('admin');
  select * into b from bins where code = upper(trim(p_bin));
  if b.id is null then raise exception 'No such bin'; end if;
  for p in select * from products where bin_id = b.id order by sku loop
    if not p_counts ? p.sku then raise exception 'Enter a count for every SKU in the bin (missing %)', p.sku; end if;
    counted := (p_counts->>p.sku)::int; oh := tfd_on_hand(p.sku);
    if counted < 0 then raise exception 'Counts can''t be negative'; end if;
    if counted <> oh then diffs := diffs || jsonb_build_object('sku', p.sku, 'name', p.name, 'on_hand', oh, 'counted', counted, 'diff', counted - oh); end if;
  end loop;
  if not p_confirm or jsonb_array_length(diffs) = 0 then
    if p_confirm then
      perform tfd_log(me.name, 'Inventory', 'bin_verify', 'Bin ' || b.code || ' verified: all counts match');
      insert into stock_moves (sku, kind, qty, actor, detail) select p2.sku, 'verify', 0, me.name, jsonb_build_object('bin', b.code, 'result', 'match') from products p2 where p2.bin_id = b.id;
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

-- ---------------------------------------------------------------- lists
create or replace function tfd_list_skus(l inv_lists) returns table (sku char(6), qty int) language plpgsql stable security definer set search_path = public as $$
declare ru jsonb := l.rule;
begin
  return query
  with st as (select p.*, tfd_on_hand(p.sku) oh,
                (select coalesce(array_agg(distinct r.supplier), '{}') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id join receipts r on r.id = rl.receipt_id where c.sku = p.sku) sups,
                (select coalesce(array_agg(distinct rl.receipt_id), '{}') from cost_layers c join receipt_lines rl on rl.id = c.receipt_line_id where c.sku = p.sku and c.qty_remaining > 0) rcpts
              from products p)
  select st.sku, (case when l.pct is null then st.oh else floor(st.oh * l.pct / 100.0) end)::int
  from st
  where (l.kind = 'manual' and st.sku = any(l.skus))
     or (l.kind = 'rule'
         and (jsonb_array_length(coalesce(ru->'brands', '[]')) = 0 or exists (select 1 from jsonb_array_elements_text(ru->'brands') x where tfd_norm(x) = tfd_norm(st.brand)))
         and (jsonb_array_length(coalesce(ru->'categories', '[]')) = 0 or exists (select 1 from jsonb_array_elements_text(ru->'categories') x where tfd_norm(x) = tfd_norm(st.category)))
         and (jsonb_array_length(coalesce(ru->'subcategories', '[]')) = 0 or exists (select 1 from jsonb_array_elements_text(ru->'subcategories') x where tfd_norm(x) = tfd_norm(st.subcategory)))
         and (jsonb_array_length(coalesce(ru->'suppliers', '[]')) = 0 or exists (select 1 from jsonb_array_elements_text(ru->'suppliers') x where tfd_norm(x) = any(select tfd_norm(s) from unnest(st.sups) s)))
         and (jsonb_array_length(coalesce(ru->'receipts', '[]')) = 0 or exists (select 1 from jsonb_array_elements_text(ru->'receipts') x where x::bigint = any(st.rcpts)))
         and (ru->>'retail_min' is null or st.retail_cents >= (ru->>'retail_min')::int)
         and (ru->>'retail_max' is null or st.retail_cents <= (ru->>'retail_max')::int)
         and (ru->>'qty_min' is null or st.oh >= (ru->>'qty_min')::int)
         and (ru->>'qty_max' is null or st.oh <= (ru->>'qty_max')::int))
  order by st.sku;
end $$;

create or replace function tfd_lists() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('count', (select count(*) from tfd_list_skus(l)), 'units', (select coalesce(sum(qty), 0) from tfd_list_skus(l))) order by l.name) from inv_lists l), '[]');
end $$;

create or replace function tfd_list_save(p_id bigint, p_name text, p_kind text, p_rule jsonb, p_pct int, p_skus text[]) returns bigint
language plpgsql security definer set search_path = public as $$
declare me profiles; id_ bigint := p_id; bad text;
begin
  me := tfd_require('admin');
  if trim(coalesce(p_name, '')) = '' then raise exception 'Give the list a name'; end if;
  if p_kind not in ('manual','rule') then raise exception 'Pick manual or rule'; end if;
  if p_pct is not null and (p_pct < 1 or p_pct > 100) then raise exception '%% of inventory must be 1–100'; end if;
  select s into bad from unnest(coalesce(p_skus, '{}')) s where not exists (select 1 from products where sku = s) limit 1;
  if bad is not null then raise exception 'Unknown SKU %', bad; end if;
  if id_ is null then
    insert into inv_lists (name, kind, rule, pct, skus, created_by) values (trim(p_name), p_kind, coalesce(p_rule, '{}'), p_pct, coalesce(p_skus, '{}')::char(6)[], me.name) returning id into id_;
    perform tfd_log(me.name, 'Inventory', 'list_create', 'List "' || trim(p_name) || '" created');
  else
    update inv_lists set name = trim(p_name), kind = p_kind, rule = coalesce(p_rule, '{}'), pct = p_pct, skus = coalesce(p_skus, '{}')::char(6)[] where id = id_;
    if not found then raise exception 'No such list'; end if;
    perform tfd_log(me.name, 'Inventory', 'list_edit', 'List "' || trim(p_name) || '" edited');
  end if;
  return id_;
exception when unique_violation then raise exception 'A list named "%" already exists', trim(p_name);
end $$;

create or replace function tfd_list_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; n text;
begin
  me := tfd_require('admin');
  delete from inv_lists where id = p_id returning name into n;
  if n is null then raise exception 'No such list'; end if;
  perform tfd_log(me.name, 'Inventory', 'list_delete', 'List "' || n || '" deleted (stock not touched)');
  return jsonb_build_object('ok', true);
end $$;

-- Rows for the Whatnot bulk upload: a list (or everything, when p_list_id is null), with the qty to list.
create or replace function tfd_whatnot_export(p_list_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l inv_lists; w jsonb := tfd_get_setting('whatnot_export'); rows_ jsonb;
begin
  perform tfd_require('admin');
  if p_list_id is not null then select * into l from inv_lists where id = p_list_id; if l.id is null then raise exception 'No such list'; end if;
  else l.kind := 'rule'; l.rule := '{}'; l.pct := null; end if;
  select coalesce(jsonb_agg(tfd_product_json(p) || jsonb_build_object('qty', s.qty,
      'floor_whatnot', (tfd_floor_for((select max(unit_cost_cents) from cost_layers c where c.sku = p.sku and c.qty_remaining > 0), 'whatnot')->>'rounded_cents')::int,
      'cost_cents', (select max(unit_cost_cents) from cost_layers c where c.sku = p.sku and c.qty_remaining > 0)) order by p.sku), '[]')
    into rows_ from tfd_list_skus(l) s join products p on p.sku = s.sku where s.qty > 0;
  return jsonb_build_object('settings', w, 'rows', rows_, 'list', case when p_list_id is null then 'Full inventory' else l.name end);
end $$;

create or replace function tfd_export_logged(p_what text, p_rows int) returns void language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := tfd_require('admin');
  perform tfd_log(me.name, 'Inventory', 'export', 'Exported ' || p_what || ' (' || p_rows || ' rows)');
end $$;

-- ---------------------------------------------------------------- undo (extends Phase 1)
create or replace function tfd_undo_inventory(u jsonb, p_entry bigint, p_actor text, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare r receipts; c cost_layers; m stock_moves; t jsonb;
begin
  if u->>'type' = 'receipt' then
    select * into r from receipts where id = (u->>'id')::bigint for update;
    if r.status <> 'confirmed' then raise exception 'Receipt isn''t confirmed'; end if;
    if exists (select 1 from cost_layers cl join receipt_lines rl on rl.id = cl.receipt_line_id where rl.receipt_id = r.id and cl.qty_remaining < cl.qty_in) then
      raise exception 'Some units from this receipt have already left stock (sold or removed), so it can''t be undone. Use Adjustments instead.'; end if;
    for c in select cl.* from cost_layers cl join receipt_lines rl on rl.id = cl.receipt_line_id where rl.receipt_id = r.id loop
      update cost_layers set qty_remaining = 0 where id = c.id;
      insert into stock_moves (sku, kind, qty, value_cents, receipt_id, reason, actor) values (c.sku, 'receipt_undo', -c.qty_in, -(c.qty_in::bigint * c.unit_cost_cents), r.id, p_reason, p_actor);
    end loop;
    update receipts set status = 'undone' where id = r.id;
    return 'Undid receipt #' || r.id || ' (stock removed; SKUs stay in the catalog)';
  elsif u->>'type' = 'adjust' then
    select * into m from stock_moves where id = (u->>'move')::bigint;
    if m.kind = 'adjust_out' then
      for t in select * from jsonb_array_elements(m.detail->'taken') loop
        update cost_layers set qty_remaining = qty_remaining + (t->>'qty')::int where id = (t->>'layer')::bigint;
      end loop;
    else
      select * into c from cost_layers where id = (m.detail->>'layer')::bigint for update;
      if c.qty_remaining < c.qty_in then raise exception 'Some of those units have already left stock, so this can''t be undone'; end if;
      update cost_layers set qty_remaining = 0 where id = c.id;
    end if;
    insert into stock_moves (sku, kind, qty, value_cents, reason, actor, detail) values (m.sku, 'adjust_undo', -m.qty, -m.value_cents, p_reason, p_actor, jsonb_build_object('undid_move', m.id));
    return 'Undid adjustment of SKU ' || m.sku;
  elsif u->>'type' = 'bin_move' then
    update products set bin_id = (u->>'from_bin')::bigint where sku = u->>'sku';
    insert into stock_moves (sku, kind, qty, actor, detail) values ((u->>'sku')::char(6), 'bin_move', 0, p_actor, jsonb_build_object('undo', true, 'to', (select code from bins where id = (u->>'from_bin')::bigint)));
    return 'Undid bin move of SKU ' || (u->>'sku');
  end if;
  raise exception 'This action cannot be undone';
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
  else
    summ := tfd_undo_inventory(u, e.id, me.name, p_reason);
  end if;
  new_id := tfd_log(me.name, e.tab, 'undo', summ, null, p_reason, null, e.id);
  update activity_log set undone_by = new_id where id = e.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- permissions
grant usage on schema public to anon, authenticated, service_role;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function tfd_state(), tfd_settings(), tfd_setting_history(text), tfd_set_setting(text, jsonb, timestamptz, text),
  tfd_set_rate(text, text, int, int, timestamptz, text), tfd_set_role(text, jsonb, text), tfd_users(),
  tfd_update_user(bigint, text, text, boolean, text), tfd_floor_preview(int, text), tfd_activity(jsonb), tfd_undo(bigint, text, boolean),
  tfd_receipt_create(text, text, date, jsonb, text), tfd_receipt_header(bigint, text, text, date), tfd_receipt_line_save(bigint, bigint, jsonb),
  tfd_receipt_line_delete(bigint, bigint), tfd_receipt_discard(bigint), tfd_receipts(), tfd_receipt(bigint), tfd_receipt_confirm(bigint),
  tfd_product_update(text, jsonb, text), tfd_stock(), tfd_sku_history(text), tfd_adjust(text, text, int, text, text, boolean),
  tfd_bins(), tfd_bin_create(text, text), tfd_move_sku(text, text), tfd_bin_verify(text, jsonb, boolean),
  tfd_lists(), tfd_list_save(bigint, text, text, jsonb, int, text[]), tfd_list_delete(bigint), tfd_whatnot_export(bigint), tfd_export_logged(text, int)
  to authenticated;
grant execute on function tfd_create_profile(uuid, uuid, text, text, text), tfd_log_from_server(uuid, text, text) to service_role;
