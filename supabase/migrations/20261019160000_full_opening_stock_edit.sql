drop function if exists public.tec_owner_update_opening_finished_stock(uuid,numeric,date,numeric);

create or replace function public.tec_owner_update_opening_finished_stock(
  p_batch_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_received_on date,
  p_total_cost numeric,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_batch public.inventory_batches%rowtype;
  v_old_product public.products%rowtype;
  v_new_product public.products%rowtype;
  v_movement public.stock_movements%rowtype;
  v_consumed numeric;
  v_delta numeric;
  v_unit_cost numeric;
  v_old_stock numeric;
  v_new_stock numeric;
  v_reason text;
  v_month_start date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_batch_id is null or p_product_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'Select a finished product and enter a quantity greater than zero';
  end if;
  if p_received_on is null or p_received_on > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'Enter today or an earlier stock date';
  end if;
  if p_total_cost is not null and p_total_cost < 0 then raise exception 'Total cost cannot be negative'; end if;

  select b.* into v_batch
    from public.inventory_batches b
   where b.id=p_batch_id and b.item_kind='product' and b.source_type='opening_finished_stock'
   for update;
  if not found then raise exception 'Opening Stock entry not found'; end if;
  if v_batch.quality_status <> 'accepted' then raise exception 'Deleted Opening Stock cannot be edited'; end if;

  select sm.* into v_movement
    from public.stock_movements sm
   where sm.batch_id=v_batch.id and sm.reference_type='opening_finished_stock'
   for update;
  if not found then raise exception 'Opening Stock movement not found'; end if;

  v_consumed := v_batch.received_qty-v_batch.available_qty;
  if v_consumed < 0 then raise exception 'Opening Stock batch balance is invalid'; end if;
  if p_quantity < v_consumed then
    raise exception 'Quantity cannot be less than the amount already used from this batch (%)',v_consumed;
  end if;
  if p_product_id <> v_batch.product_id and v_consumed > 0 then
    raise exception 'Product cannot be changed after any quantity from this Opening Stock batch has been used';
  end if;

  perform p.id
    from public.products p
   where p.id in (v_batch.product_id,p_product_id)
   order by p.id
   for update;
  select p.* into v_old_product from public.products p where p.id=v_batch.product_id;
  if not found then raise exception 'Original finished product not found'; end if;
  select p.* into v_new_product
    from public.products p
   where p.id=p_product_id and p.is_active=true and p.product_type='finished';
  if not found then raise exception 'Select an active finished product'; end if;

  if p_total_cost is not null then v_unit_cost:=round(p_total_cost/p_quantity,6); end if;
  v_reason:=coalesce(nullif(pg_catalog.btrim(p_reason),''),v_movement.reason,'Opening finished goods stock');

  if p_product_id=v_batch.product_id then
    v_delta:=p_quantity-v_batch.received_qty;
    update public.products
       set current_stock=current_stock+v_delta,updated_at=now(),
           status=case when status='Deleted' then status when current_stock+v_delta<=0 then 'Out of Stock'
             when current_stock+v_delta<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
     where id=v_new_product.id returning current_stock into v_new_stock;
    v_old_stock:=v_new_stock;
    update public.monthly_product_openings
       set opening_qty=greatest(0,opening_qty+v_delta),updated_at=now(),updated_by=auth.uid()
     where product_id=v_new_product.id and period_start=v_month_start;
  else
    update public.products
       set current_stock=current_stock-v_batch.received_qty,updated_at=now(),
           status=case when status='Deleted' then status when current_stock-v_batch.received_qty<=0 then 'Out of Stock'
             when current_stock-v_batch.received_qty<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
     where id=v_old_product.id returning current_stock into v_old_stock;
    update public.products
       set current_stock=current_stock+p_quantity,updated_at=now(),
           status=case when status='Deleted' then status when current_stock+p_quantity<=0 then 'Out of Stock'
             when current_stock+p_quantity<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
     where id=v_new_product.id returning current_stock into v_new_stock;
    update public.monthly_product_openings
       set opening_qty=greatest(0,opening_qty-v_batch.received_qty),updated_at=now(),updated_by=auth.uid()
     where product_id=v_old_product.id and period_start=v_month_start;
    update public.monthly_product_openings
       set opening_qty=opening_qty+p_quantity,updated_at=now(),updated_by=auth.uid()
     where product_id=v_new_product.id and period_start=v_month_start;
  end if;

  update public.inventory_batches
     set product_id=v_new_product.id,unit=v_new_product.unit,received_qty=p_quantity,
         available_qty=p_quantity-v_consumed,received_on=p_received_on,unit_cost=v_unit_cost
   where id=v_batch.id;
  update public.stock_movements
     set product_id=v_new_product.id,unit=v_new_product.unit,quantity_delta=p_quantity,
         unit_cost_snapshot=v_unit_cost,reason=v_reason
   where id=v_movement.id;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values(auth.uid(),'opening_finished_stock_updated','inventory_batch',v_batch.id,v_reason,
    jsonb_build_object('product_id',v_old_product.id,'product_name',v_old_product.name,
      'quantity',v_batch.received_qty,'available_qty',v_batch.available_qty,'received_on',v_batch.received_on,
      'unit_cost',v_batch.unit_cost,'movement_reason',v_movement.reason),
    jsonb_build_object('product_id',v_new_product.id,'product_name',v_new_product.name,
      'quantity',p_quantity,'available_qty',p_quantity-v_consumed,'already_used_qty',v_consumed,
      'received_on',p_received_on,'total_cost',p_total_cost,'unit_cost',v_unit_cost,
      'old_product_current_stock',v_old_stock,'new_product_current_stock',v_new_stock),auth.uid());

  return jsonb_build_object('batch_id',v_batch.id,'product_id',v_new_product.id,'product_name',v_new_product.name,
    'quantity',p_quantity,'available_qty',p_quantity-v_consumed,'already_used_qty',v_consumed,
    'unit',v_new_product.unit,'unit_cost',v_unit_cost,'current_stock',v_new_stock,'received_on',p_received_on,
    'old_product_current_stock',v_old_stock);
end;
$function$;

revoke execute on function public.tec_owner_update_opening_finished_stock(uuid,uuid,numeric,date,numeric,text) from public,anon;
grant execute on function public.tec_owner_update_opening_finished_stock(uuid,uuid,numeric,date,numeric,text) to authenticated;
