-- TFD app — lot images per SKU row (Kenny, Nov 10 2026). Replaces the lot-wide photo section.
-- A lot image is an internal photo of the item / box for that row. Separate from the listing image URL.
alter table lot_photos add column if not exists line_id bigint references receipt_lines(id);


create or replace function tfd_line_photo_add(p_receipt_id bigint, p_line_id bigint, p_path text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me profiles; id_ bigint; r receipts; ln int;
begin
  me := tfd_require('admin');
  select * into r from receipts where id = p_receipt_id;
  if r.id is null then raise exception 'No such lot'; end if;
  select line_no into ln from receipt_lines where id = p_line_id and receipt_id = p_receipt_id;
  if ln is null then raise exception 'No such row in this lot'; end if;
  if p_path not like 'lot-' || p_receipt_id || '/%' then raise exception 'Photo path doesn''t belong to this lot'; end if;
  insert into lot_photos (receipt_id, line_id, path, uploaded_by) values (p_receipt_id, p_line_id, p_path, me.name) returning id into id_;
  perform tfd_log(me.name, 'Inventory', 'lot_photo', 'Lot image added to row ' || ln || ' of lot ' || r.name, jsonb_build_object('receipt', p_receipt_id, 'line', p_line_id, 'photo', id_));
  return id_;
end $$;

create or replace function tfd_receipt_line_delete(p_receipt_id bigint, p_line_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform tfd_require('admin');
  if not exists (select 1 from receipts where id = p_receipt_id and status = 'draft') then raise exception 'Only draft lots can be changed'; end if;
  delete from lot_photos where line_id = p_line_id and receipt_id = p_receipt_id;
  delete from receipt_lines where id = p_line_id and receipt_id = p_receipt_id;
  return jsonb_build_object('ok', true);
end $$;

-- "lot_photo" required now means: every row needs at least one lot image
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
    if 'lot_photo' = any(req) and not exists (select 1 from lot_photos where line_id = l.id) then
      out := out || to_jsonb('Row ' || l.line_no || ': Lot image is required');
    end if;
  end loop;
  return out;
end $$;

revoke execute on function tfd_line_photo_add(bigint, bigint, text) from public, anon;
grant execute on function tfd_line_photo_add(bigint, bigint, text) to authenticated;
