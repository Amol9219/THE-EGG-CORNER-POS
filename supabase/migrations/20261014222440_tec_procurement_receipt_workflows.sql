-- TEC Masala Business procurement and receipt workflow functions.
-- SECURITY INVOKER keeps caller privileges and row-level security active.

CREATE OR REPLACE FUNCTION public.tec_create_purchase_order(p_supplier_id uuid, p_ordered_on date, p_expected_on date, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_po_id uuid;
  v_po_number text;
  v_subtotal numeric(14,2);
  v_line jsonb;
  v_raw uuid;
  v_product uuid;
  v_qty numeric;
  v_rate numeric;
  v_unit text;
  v_active boolean;
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'Sign-in required';
  end if;
  if not private.is_owner() then
    raise exception 'Owner permission required';
  end if;
  if p_supplier_id is null or not exists (
    select 1 from public.suppliers s where s.id = p_supplier_id and s.is_active = true
  ) then
    raise exception 'Select an active supplier';
  end if;
  if p_ordered_on is null then
    raise exception 'Order date is required';
  end if;
  if p_expected_on is not null and p_expected_on < p_ordered_on then
    raise exception 'Expected date cannot be earlier than order date';
  end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Order lines must be an array';
  end if;
  v_count := pg_catalog.jsonb_array_length(p_lines);
  if v_count < 1 or v_count > 50 then
    raise exception 'A purchase order must contain 1 to 50 lines';
  end if;

  for v_line in select e.value from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  loop
    v_raw := nullif(pg_catalog.btrim(v_line->>'raw_material_id'), '')::uuid;
    v_product := nullif(pg_catalog.btrim(v_line->>'product_id'), '')::uuid;
    if (v_raw is null) = (v_product is null) then
      raise exception 'Each order line must reference exactly one raw material or product';
    end if;
    v_qty := coalesce(nullif(v_line->>'ordered_qty', '')::numeric, 0);
    v_rate := nullif(v_line->>'unit_rate', '')::numeric;
    v_unit := nullif(pg_catalog.btrim(v_line->>'unit'), '');
    if v_qty <= 0 or v_rate is null or v_rate < 0 or v_unit is null then
      raise exception 'Each line needs a positive quantity, unit and non-negative rate';
    end if;
    if v_raw is not null then
      select r.is_active into v_active from public.raw_materials r where r.id = v_raw;
    else
      select p.is_active into v_active from public.products p where p.id = v_product;
    end if;
    if coalesce(v_active, false) is not true then
      raise exception 'An order line references an unknown or inactive item';
    end if;
  end loop;

  select coalesce(sum((e.value->>'ordered_qty')::numeric * (e.value->>'unit_rate')::numeric), 0)
    into v_subtotal
    from pg_catalog.jsonb_array_elements(p_lines) as e(value);

  v_po_number := 'PO-' || pg_catalog.to_char(p_ordered_on, 'YYYYMMDD') || '-' ||
                 pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text, '-', ''), 1, 8));

  insert into public.purchase_orders
    (po_number, supplier_id, status, ordered_on, expected_on, subtotal, notes, created_by)
  values
    (v_po_number, p_supplier_id, 'draft', p_ordered_on, p_expected_on,
     v_subtotal, nullif(pg_catalog.btrim(p_notes), ''), auth.uid())
  returning id into v_po_id;

  insert into public.purchase_order_lines
    (purchase_order_id, raw_material_id, product_id, ordered_qty, unit, unit_rate, received_qty)
  select
    v_po_id,
    nullif(pg_catalog.btrim(e.value->>'raw_material_id'), '')::uuid,
    nullif(pg_catalog.btrim(e.value->>'product_id'), '')::uuid,
    (e.value->>'ordered_qty')::numeric,
    pg_catalog.btrim(e.value->>'unit'),
    (e.value->>'unit_rate')::numeric,
    0
  from pg_catalog.jsonb_array_elements(p_lines) as e(value);

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, after_data)
  values (auth.uid(), 'purchase_order_created', 'purchase_order', v_po_id,
          'Draft purchase order created', pg_catalog.jsonb_build_object(
            'po_number', v_po_number, 'status', 'draft', 'subtotal', v_subtotal, 'line_count', v_count
          ));

  return pg_catalog.jsonb_build_object(
    'id', v_po_id, 'po_number', v_po_number, 'status', 'draft',
    'subtotal', v_subtotal, 'line_count', v_count
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_record_goods_receipt(p_purchase_order_id uuid, p_supplier_invoice_number text, p_received_at timestamp with time zone, p_invoice_total numeric, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_po public.purchase_orders%rowtype;
  v_receipt_id uuid;
  v_receipt_number text;
  v_line jsonb;
  v_pol public.purchase_order_lines%rowtype;
  v_line_id uuid;
  v_qty numeric;
  v_pending numeric;
  v_count integer;
  v_distinct integer;
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'Sign-in required';
  end if;
  if not private.is_owner() then
    raise exception 'Owner permission required';
  end if;
  if p_purchase_order_id is null then
    raise exception 'Select a purchase order';
  end if;
  if p_invoice_total is not null and p_invoice_total < 0 then
    raise exception 'Invoice total cannot be negative';
  end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Receipt lines must be an array';
  end if;
  v_count := pg_catalog.jsonb_array_length(p_lines);
  if v_count < 1 or v_count > 50 then
    raise exception 'A receipt must contain 1 to 50 lines';
  end if;
  select count(*), count(distinct nullif(e.value->>'purchase_order_line_id','')::uuid)
    into v_count, v_distinct
    from pg_catalog.jsonb_array_elements(p_lines) as e(value);
  if v_count <> v_distinct then
    raise exception 'A purchase order line may appear only once per receipt';
  end if;

  select po.* into v_po
    from public.purchase_orders po
   where po.id = p_purchase_order_id
   for update;
  if not found then
    raise exception 'Purchase order was not found';
  end if;
  if v_po.status not in ('approved', 'part_received') then
    raise exception 'Only approved or partially received purchase orders can be received';
  end if;

  for v_line in select e.value from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  loop
    v_line_id := nullif(pg_catalog.btrim(v_line->>'purchase_order_line_id'), '')::uuid;
    v_qty := coalesce(nullif(v_line->>'received_qty', '')::numeric, 0);
    if v_line_id is null or v_qty <= 0 then
      raise exception 'Each receipt line needs a purchase order line and a positive quantity';
    end if;
    select pol.* into v_pol
      from public.purchase_order_lines pol
     where pol.id = v_line_id and pol.purchase_order_id = p_purchase_order_id
     for update;
    if not found then
      raise exception 'A receipt line does not belong to the selected purchase order';
    end if;
    select coalesce(sum(grl.received_qty), 0) into v_pending
      from public.goods_receipt_lines grl
      join public.goods_receipts gr on gr.id = grl.goods_receipt_id
     where grl.purchase_order_line_id = v_line_id
       and gr.status = 'inspection_pending';
    if v_pol.received_qty + v_pending + v_qty > v_pol.ordered_qty then
      raise exception 'Received quantity exceeds the outstanding purchase order quantity';
    end if;
  end loop;

  v_receipt_number := 'GRN-' || pg_catalog.to_char(coalesce(p_received_at::date, current_date), 'YYYYMMDD') || '-' ||
                      pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.goods_receipts
    (receipt_number, purchase_order_id, supplier_id, supplier_invoice_number, received_at,
     status, invoice_total, notes, created_by)
  values
    (v_receipt_number, v_po.id, v_po.supplier_id,
     nullif(pg_catalog.btrim(p_supplier_invoice_number), ''), coalesce(p_received_at, now()),
     'inspection_pending', p_invoice_total, nullif(pg_catalog.btrim(p_notes), ''), auth.uid())
  returning id into v_receipt_id;

  insert into public.goods_receipt_lines
    (goods_receipt_id, purchase_order_line_id, raw_material_id, product_id, received_qty,
     accepted_qty, rejected_qty, unit, unit_rate, quality_notes)
  select
    v_receipt_id, pol.id, pol.raw_material_id, pol.product_id,
    (e.value->>'received_qty')::numeric, 0, 0, pol.unit, pol.unit_rate,
    nullif(pg_catalog.btrim(e.value->>'quality_notes'), '')
  from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  join public.purchase_order_lines pol
    on pol.id = (e.value->>'purchase_order_line_id')::uuid
   and pol.purchase_order_id = p_purchase_order_id;
  get diagnostics v_inserted = row_count;
  if v_inserted <> v_count then
    raise exception 'Not all receipt lines were saved';
  end if;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, after_data)
  values (auth.uid(), 'goods_receipt_recorded', 'goods_receipt', v_receipt_id,
          'Receipt recorded; inspection pending', pg_catalog.jsonb_build_object(
            'receipt_number', v_receipt_number, 'purchase_order_id', v_po.id,
            'status', 'inspection_pending', 'line_count', v_count
          ));

  return pg_catalog.jsonb_build_object(
    'id', v_receipt_id, 'receipt_number', v_receipt_number,
    'status', 'inspection_pending', 'line_count', v_count
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_review_goods_receipt(p_goods_receipt_id uuid, p_decision text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_receipt public.goods_receipts%rowtype;
  v_line public.goods_receipt_lines%rowtype;
  v_batch_id uuid;
  v_item_kind text;
  v_reason text;
  v_new_status text;
begin
  if auth.uid() is null then
    raise exception 'Sign-in required';
  end if;
  if not private.is_owner() then
    raise exception 'Owner permission required';
  end if;
  if p_decision not in ('accepted', 'rejected') then
    raise exception 'Decision must be accepted or rejected';
  end if;
  if p_decision = 'rejected' and nullif(pg_catalog.btrim(p_note), '') is null then
    raise exception 'A reason is required when rejecting a receipt';
  end if;

  select gr.* into v_receipt
    from public.goods_receipts gr
   where gr.id = p_goods_receipt_id
   for update;
  if not found then
    raise exception 'Goods receipt was not found';
  end if;
  if v_receipt.status <> 'inspection_pending' then
    raise exception 'This goods receipt has already been inspected';
  end if;
  if v_receipt.purchase_order_id is null then
    raise exception 'This receipt is not linked to a purchase order';
  end if;
  perform 1 from public.purchase_orders po where po.id = v_receipt.purchase_order_id for update;
  if not found then
    raise exception 'Related purchase order was not found';
  end if;

  v_reason := coalesce(nullif(pg_catalog.btrim(p_note), ''),
                       'Goods receipt ' || v_receipt.receipt_number);
  for v_line in
    select grl.* from public.goods_receipt_lines grl
     where grl.goods_receipt_id = v_receipt.id
     order by grl.id for update
  loop
    if p_decision = 'accepted' then
      update public.goods_receipt_lines
         set accepted_qty = received_qty, rejected_qty = 0,
             quality_notes = case when nullif(pg_catalog.btrim(p_note), '') is null
                                  then quality_notes
                                  else concat_ws(E'\n', nullif(quality_notes, ''), 'Inspection: ' || pg_catalog.btrim(p_note)) end
       where id = v_line.id;

      v_item_kind := case when v_line.raw_material_id is not null then 'raw_material' else 'product' end;
      insert into public.inventory_batches
        (item_kind, raw_material_id, product_id, batch_code, received_qty, available_qty, unit,
         unit_cost, quality_status, source_type, source_id, created_by)
      values
        (v_item_kind, v_line.raw_material_id, v_line.product_id,
         v_receipt.receipt_number || '-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(v_line.id::text, '-', ''), 1, 8)),
         v_line.received_qty, v_line.received_qty, v_line.unit, v_line.unit_rate,
         'accepted', 'goods_receipt', v_receipt.id, auth.uid())
      returning id into v_batch_id;

      if v_line.raw_material_id is not null then
        update public.raw_materials
           set current_stock = current_stock + v_line.received_qty, updated_at = now()
         where id = v_line.raw_material_id;
      else
        update public.products
           set current_stock = current_stock + v_line.received_qty, updated_at = now()
         where id = v_line.product_id;
      end if;

      insert into public.stock_movements
        (item_kind, raw_material_id, product_id, batch_id, movement_type, quantity_delta, unit,
         reference_type, reference_id, reason, created_by, approved_by)
      values
        (v_item_kind, v_line.raw_material_id, v_line.product_id, v_batch_id, 'receipt',
         v_line.received_qty, v_line.unit, 'goods_receipt', v_receipt.id,
         v_reason, auth.uid(), auth.uid());

      update public.purchase_order_lines
         set received_qty = received_qty + v_line.received_qty
       where id = v_line.purchase_order_line_id;
    else
      update public.goods_receipt_lines
         set accepted_qty = 0, rejected_qty = received_qty,
             quality_notes = concat_ws(E'\n', nullif(quality_notes, ''), 'Rejected: ' || pg_catalog.btrim(p_note))
       where id = v_line.id;
    end if;
  end loop;

  update public.goods_receipts
     set status = p_decision, mismatch_resolution = nullif(pg_catalog.btrim(p_note), ''),
         inspected_by = auth.uid(), inspected_at = now()
   where id = v_receipt.id;

  if p_decision = 'accepted' then
    update public.purchase_orders po
       set status = case
         when not exists (
           select 1 from public.purchase_order_lines pol
            where pol.purchase_order_id = po.id and pol.received_qty < pol.ordered_qty
         ) then 'received'
         when exists (
           select 1 from public.purchase_order_lines pol
            where pol.purchase_order_id = po.id and pol.received_qty > 0
         ) then 'part_received'
         else po.status
       end
     where po.id = v_receipt.purchase_order_id;
  end if;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, before_data, after_data, approved_by)
  values (auth.uid(), 'goods_receipt_' || p_decision, 'goods_receipt', v_receipt.id,
          v_reason, pg_catalog.jsonb_build_object('status', 'inspection_pending'),
          pg_catalog.jsonb_build_object('status', p_decision, 'receipt_number', v_receipt.receipt_number),
          auth.uid());

  return pg_catalog.jsonb_build_object(
    'id', v_receipt.id, 'receipt_number', v_receipt.receipt_number,
    'status', p_decision, 'stock_updated', (p_decision = 'accepted')
  );
end;
$function$;


revoke execute on function public.tec_create_purchase_order(uuid, date, date, text, jsonb) from public;
revoke execute on function public.tec_create_purchase_order(uuid, date, date, text, jsonb) from anon;
grant execute on function public.tec_create_purchase_order(uuid, date, date, text, jsonb) to authenticated;

revoke execute on function public.tec_record_goods_receipt(uuid, text, timestamptz, numeric, text, jsonb) from public;
revoke execute on function public.tec_record_goods_receipt(uuid, text, timestamptz, numeric, text, jsonb) from anon;
grant execute on function public.tec_record_goods_receipt(uuid, text, timestamptz, numeric, text, jsonb) to authenticated;

revoke execute on function public.tec_review_goods_receipt(uuid, text, text) from public;
revoke execute on function public.tec_review_goods_receipt(uuid, text, text) from anon;
grant execute on function public.tec_review_goods_receipt(uuid, text, text) to authenticated;
