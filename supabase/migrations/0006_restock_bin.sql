-- TFD app — a sold-out SKU coming back in a lot goes into the bin picked on that lot row; it's required (Kenny, Nov 10 2026).
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
      -- sold-out SKU coming back: it goes into the bin chosen on the lot row (never assumed)
      if tfd_on_hand(sku_) = 0 and l.bin_code is not null then
        bin_ := tfd_bin_id(l.bin_code, me.name);
        if bin_ is distinct from (select bin_id from products where sku = sku_) then
          insert into stock_moves (sku, kind, qty, actor, detail) values (sku_, 'bin_move', 0, me.name,
            jsonb_build_object('from', (select b.code from products p join bins b on b.id = p.bin_id where p.sku = sku_), 'to', l.bin_code, 'lot', p_id));
          update products set bin_id = bin_ where sku = sku_;
        end if;
      end if;
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

