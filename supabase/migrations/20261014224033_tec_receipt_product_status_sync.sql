-- Keep product status (Available / Low Stock / Out of Stock) aligned when goods receipts increase stock.

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
           set current_stock = current_stock + v_line.received_qty,
               status = case
                 when status = 'Deleted' then status
                 when current_stock + v_line.received_qty <= 0 then 'Out of Stock'
                 when current_stock + v_line.received_qty <= coalesce(min_stock, 0) then 'Low Stock'
                 else 'Available'
               end,
               updated_at = now()
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
revoke execute on function public.tec_review_goods_receipt(uuid,text,text) from public;
revoke execute on function public.tec_review_goods_receipt(uuid,text,text) from anon;
grant execute on function public.tec_review_goods_receipt(uuid,text,text) to authenticated;
