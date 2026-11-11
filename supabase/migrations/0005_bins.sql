-- TFD app — bins Q-01..T-40 (160), only existing bins can be used, out-of-stock SKUs leave the bin view (Kenny, Nov 10 2026).
insert into bins (code)
select l || '-' || lpad(n::text, 2, '0') from unnest(array['Q','R','S','T']) l, generate_series(1, 40) n
on conflict (code) do nothing;

-- bins are no longer created on the fly: a SKU can only go into a bin that exists
create or replace function tfd_bin_id(p_code text, p_actor text) returns bigint language plpgsql security definer set search_path = public as $$
declare c text := upper(trim(coalesce(p_code, ''))); id_ bigint;
begin
  if c = '' then return null; end if;
  select id into id_ from bins where code = c;
  if id_ is null then raise exception 'Bin "%" doesn''t exist. Pick a bin from the list (Inventory → Bins → New bin to add one)', c; end if;
  return id_;
end $$;

create or replace function tfd_bin_create(p_code text, p_note text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; c text := upper(trim(coalesce(p_code, '')));
begin
  me := tfd_require('admin');
  if c !~ '^[A-Z0-9][A-Z0-9 ._-]{0,19}$' then raise exception 'Bin "%" isn''t a valid bin code (letters, numbers, dashes; e.g. Q-01)', c; end if;
  if exists (select 1 from bins where code = c) then raise exception 'Bin % already exists', c; end if;
  insert into bins (code, note) values (c, nullif(trim(p_note), ''));
  perform tfd_log(me.name, 'Inventory', 'bin_create', 'Bin ' || c || ' created');
  return jsonb_build_object('ok', true);
end $$;

-- a lot row can only name a bin that exists
create or replace function tfd_lot_issues(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r receipts; req text[] := tfd_req(); out jsonb := '[]'; l receipt_lines; chk jsonb; pr jsonb;
begin
  select * into r from receipts where id = p_id;
  if 'supplier' = any(req) and r.supplier is null then out := out || to_jsonb('Supplier is required'::text); end if;
  if 'invoice_no' = any(req) and r.invoice_no is null then out := out || to_jsonb('Invoice # is required'::text); end if;
  if 'received_date' = any(req) and r.received_date is null then out := out || to_jsonb('Date is required'::text); end if;
  if not exists (select 1 from receipt_lines where receipt_id = p_id) then out := out || to_jsonb('Add at least one SKU row'::text); end if;
  for l in select * from receipt_lines where receipt_id = p_id order by line_no loop
    chk := tfd_line_check(l);
    for pr in select * from jsonb_array_elements(chk->'problems') loop
      out := out || to_jsonb('Row ' || l.line_no || ': ' || (pr->>'m'));
    end loop;
    if chk->>'status' <> 'existing' and l.bin_code is not null and not exists (select 1 from bins where code = l.bin_code) then
      out := out || to_jsonb('Row ' || l.line_no || ': Bin "' || l.bin_code || '" doesn''t exist. Pick a bin from the list');
    end if;
    if 'lot_photo' = any(req) and not exists (select 1 from lot_photos where line_id = l.id) then
      out := out || to_jsonb('Row ' || l.line_no || ': Lot image is required');
    end if;
  end loop;
  return out;
end $$;

-- bins show only what's physically there (on hand > 0); sold-out SKUs live on in the bin's history
create or replace function tfd_bins() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'note', b.note,
      'skus', coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', x.name, 'brand', x.brand, 'model', x.model, 'color_code', x.color_code, 'lens_size', x.lens_size,
          'color_name', x.color_name, 'upc', x.upc, 'on_hand', x.oh) order by x.sku)
        from (select p.*, tfd_on_hand(p.sku) oh from products p where p.bin_id = b.id) x where x.oh > 0), '[]'))
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
        'color_name', x.color_name, 'upc', x.upc, 'on_hand', x.oh) order by x.sku)
      from (select p.*, tfd_on_hand(p.sku) oh from products p where p.bin_id = b.id) x where x.oh > 0), '[]'),
    'sold_out', coalesce((select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', coalesce(x.name, concat_ws(' ', x.brand, x.model))) order by x.sku)
      from (select p.*, tfd_on_hand(p.sku) oh from products p where p.bin_id = b.id) x where x.oh = 0), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', m.at, 'kind', m.kind, 'sku', m.sku, 'name', coalesce(p.name, concat_ws(' ', p.brand, p.model)),
        'qty', m.qty, 'actor', m.actor, 'from', m.detail->>'from', 'to', m.detail->>'to', 'reason', m.reason, 'detail', m.detail) order by m.at desc, m.id desc)
      from (select * from stock_moves m where (m.kind = 'bin_move' and (m.detail->>'from' = c or m.detail->>'to' = c))
               or (m.kind = 'receipt' and m.detail->>'bin' = c) or (m.kind = 'verify' and m.detail->>'bin' = c)
               or (m.kind in ('adjust_out','adjust_in') and m.sku in (select sku from products where bin_id = b.id))
             order by m.at desc, m.id desc limit 300) m left join products p on p.sku = m.sku), '[]'));
end $$;

-- counting a bin only asks about SKUs that should physically be there
create or replace function tfd_bin_verify(p_bin text, p_counts jsonb, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; b bins; p products; counted int; oh int; diffs jsonb := '[]'; d jsonb; r jsonb;
begin
  me := tfd_require('admin');
  select * into b from bins where code = upper(trim(p_bin));
  if b.id is null then raise exception 'No such bin'; end if;
  for p in select * from products where bin_id = b.id and tfd_on_hand(sku) > 0 order by sku loop
    if not p_counts ? p.sku then raise exception 'Enter a count for every SKU in the bin (missing %)', p.sku; end if;
    counted := (p_counts->>p.sku)::int; oh := tfd_on_hand(p.sku);
    if counted < 0 then raise exception 'Counts can''t be negative'; end if;
    if counted <> oh then diffs := diffs || jsonb_build_object('sku', p.sku, 'name', p.name, 'on_hand', oh, 'counted', counted, 'diff', counted - oh); end if;
  end loop;
  if not p_confirm or jsonb_array_length(diffs) = 0 then
    if p_confirm then
      perform tfd_log(me.name, 'Inventory', 'bin_verify', 'Bin ' || b.code || ' verified: all counts match');
      insert into stock_moves (sku, kind, qty, actor, detail) select p2.sku, 'verify', 0, me.name, jsonb_build_object('bin', b.code, 'result', 'match')
        from products p2 where p2.bin_id = b.id and tfd_on_hand(p2.sku) > 0;
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
