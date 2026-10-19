-- Owner-managed Opening Finished Stock with monthly carry-forward snapshots.
create unique index if not exists stock_movements_opening_finished_stock_idempotency_key
  on public.stock_movements(reference_type, reference_id)
  where reference_type = 'opening_finished_stock' and reference_id is not null;

alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check (movement_type = any (array['opening','receipt','production_use','production_output','outlet_dispatch','return_in','adjustment','transfer_out','transfer_in','write_off','reversal','opening_finished_stock']::text[]));
alter table public.stock_movements drop constraint if exists stock_movements_quantity_delta_check;
alter table public.stock_movements add constraint stock_movements_quantity_delta_check
  check (quantity_delta <> 0 or movement_type = 'opening_finished_stock');

create table if not exists public.monthly_product_openings (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  period_start date not null,
  opening_qty numeric not null check (opening_qty >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  unique (product_id, period_start),
  check (extract(day from period_start) = 1)
);
alter table public.monthly_product_openings enable row level security;
revoke all on public.monthly_product_openings from anon, authenticated;
grant select on public.monthly_product_openings to authenticated;
drop policy if exists tec_owner_read_monthly_product_openings on public.monthly_product_openings;
create policy tec_owner_read_monthly_product_openings on public.monthly_product_openings
  for select to authenticated using (private.is_owner());

create or replace function public.tec_owner_get_monthly_product_opening(p_period_start date)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_period_start date;
  v_current_month date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_period_start is null or extract(day from p_period_start) <> 1 then raise exception 'Select the first day of a month'; end if;
  if p_period_start > v_current_month then raise exception 'Future monthly opening stock is not available yet'; end if;
  v_period_start := p_period_start;

  insert into public.monthly_product_openings(product_id, period_start, opening_qty, updated_by)
  select p.id, v_period_start,
         greatest(0, p.current_stock - coalesce(sum(sm.quantity_delta) filter (
           where sm.created_at >= v_period_start::timestamptz
             and (v_period_start < v_current_month or sm.movement_type <> 'opening_finished_stock')
         ), 0)),
         auth.uid()
    from public.products p
    left join public.stock_movements sm on sm.product_id = p.id
   where p.is_active = true and p.product_type = 'finished'
   group by p.id, p.current_stock
  on conflict (product_id, period_start) do nothing;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', p.id,
    'product_name', p.name,
    'unit', p.unit,
    'opening_qty', mpo.opening_qty,
    'current_stock', p.current_stock,
    'period_start', mpo.period_start
  ) order by p.name), '[]'::jsonb)
    into v_result
    from public.monthly_product_openings mpo
    join public.products p on p.id = mpo.product_id
   where mpo.period_start = v_period_start and p.is_active = true;

  return jsonb_build_object('period_start', v_period_start, 'products', v_result);
end;
$function$;
revoke execute on function public.tec_owner_get_monthly_product_opening(date) from public, anon;
grant execute on function public.tec_owner_get_monthly_product_opening(date) to authenticated;

create or replace function public.tec_owner_record_opening_finished_stock(
  p_product_id uuid, p_quantity numeric, p_received_on date,
  p_total_cost numeric, p_reason text, p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_product public.products%rowtype;
  v_existing record;
  v_batch_id uuid;
  v_movement_id uuid;
  v_batch_code text;
  v_reason text;
  v_unit_cost numeric;
  v_current_stock numeric;
  v_month_start date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_product_id is null then raise exception 'Select a finished product'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Quantity must be greater than zero'; end if;
  if p_received_on is null then raise exception 'Stock date is required'; end if;
  if p_received_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'Stock date cannot be in the future'; end if;
  if p_total_cost is not null and p_total_cost < 0 then raise exception 'Total cost cannot be negative'; end if;
  if p_idempotency_key is null then raise exception 'Submission key is required'; end if;
  v_reason := coalesce(nullif(pg_catalog.btrim(p_reason), ''), 'Opening finished goods stock');
  if p_total_cost is not null then v_unit_cost := round(p_total_cost / p_quantity, 6); end if;

  select p.* into v_product from public.products p
   where p.id = p_product_id and p.is_active and p.product_type = 'finished' for update;
  if not found then raise exception 'Active finished product not found'; end if;

  select sm.id, sm.product_id, sm.quantity_delta, sm.unit_cost_snapshot, ib.received_on,
         p.name, p.unit, p.current_stock
    into v_existing from public.stock_movements sm
    join public.inventory_batches ib on ib.id = sm.batch_id
    join public.products p on p.id = sm.product_id
   where sm.reference_type = 'opening_finished_stock' and sm.reference_id = p_idempotency_key;
  if found then
    if v_existing.product_id <> p_product_id or v_existing.quantity_delta <> p_quantity
       or v_existing.received_on <> p_received_on or v_existing.unit_cost_snapshot is distinct from v_unit_cost then
      raise exception 'This submission key was already used for a different Opening Stock entry';
    end if;
    return jsonb_build_object('duplicate', true, 'batch_id', (select batch_id from public.stock_movements where id=v_existing.id),
      'movement_id', v_existing.id, 'product_id', v_existing.product_id, 'product_name', v_existing.name,
      'quantity_added', v_existing.quantity_delta, 'unit', v_existing.unit, 'current_stock', v_existing.current_stock,
      'received_on', v_existing.received_on);
  end if;

  v_batch_code := 'OPEN-' || to_char(p_received_on, 'YYYYMMDD') || '-' || upper(replace(p_idempotency_key::text, '-', ''));
  insert into public.inventory_batches(item_kind, product_id, batch_code, received_qty, available_qty, unit,
    received_on, unit_cost, quality_status, source_type, created_by)
  values ('product', v_product.id, v_batch_code, p_quantity, p_quantity, v_product.unit,
    p_received_on, v_unit_cost, 'accepted', 'opening_finished_stock', auth.uid())
  returning id into v_batch_id;

  insert into public.stock_movements(item_kind, product_id, batch_id, movement_type, quantity_delta, unit,
    reference_type, reference_id, reason, created_by, approved_by, unit_cost_snapshot)
  values ('product', v_product.id, v_batch_id, 'opening_finished_stock', p_quantity, v_product.unit,
    'opening_finished_stock', p_idempotency_key, v_reason, auth.uid(), auth.uid(), v_unit_cost)
  on conflict (reference_type, reference_id)
    where reference_type = 'opening_finished_stock' and reference_id is not null
  do nothing returning id into v_movement_id;

  if v_movement_id is null then
    delete from public.inventory_batches where id = v_batch_id;
    select sm.id, sm.product_id, sm.quantity_delta, sm.unit_cost_snapshot, ib.received_on,
           p.name, p.unit, p.current_stock
      into v_existing from public.stock_movements sm
      join public.inventory_batches ib on ib.id = sm.batch_id
      join public.products p on p.id = sm.product_id
     where sm.reference_type = 'opening_finished_stock' and sm.reference_id = p_idempotency_key;
    if not found then raise exception 'Opening Stock could not be recorded; retry the submission'; end if;
    if v_existing.product_id <> p_product_id or v_existing.quantity_delta <> p_quantity
       or v_existing.received_on <> p_received_on or v_existing.unit_cost_snapshot is distinct from v_unit_cost then
      raise exception 'This submission key was already used for a different Opening Stock entry';
    end if;
    return jsonb_build_object('duplicate', true, 'batch_id', (select batch_id from public.stock_movements where id=v_existing.id),
      'movement_id', v_existing.id, 'product_id', v_existing.product_id, 'product_name', v_existing.name,
      'quantity_added', v_existing.quantity_delta, 'unit', v_existing.unit, 'current_stock', v_existing.current_stock,
      'received_on', v_existing.received_on);
  end if;

  update public.products set current_stock=current_stock+p_quantity, updated_at=now(),
    status=case when status='Deleted' then status when current_stock+p_quantity<=0 then 'Out of Stock'
      when current_stock+p_quantity<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
   where id=v_product.id returning current_stock into v_current_stock;

  update public.monthly_product_openings
     set opening_qty=opening_qty+p_quantity, updated_at=now(), updated_by=auth.uid()
   where product_id=v_product.id and period_start=v_month_start;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, after_data, approved_by)
  values (auth.uid(), 'opening_finished_stock_recorded', 'inventory_batch', v_batch_id, v_reason,
    jsonb_build_object('product_id',v_product.id,'quantity',p_quantity,'unit',v_product.unit,'received_on',p_received_on,
      'total_cost',p_total_cost,'unit_cost',v_unit_cost,'batch_id',v_batch_id,'movement_id',v_movement_id,
      'idempotency_key',p_idempotency_key), auth.uid());

  return jsonb_build_object('duplicate',false,'batch_id',v_batch_id,'movement_id',v_movement_id,
    'product_id',v_product.id,'product_name',v_product.name,'quantity_added',p_quantity,'unit',v_product.unit,
    'unit_cost',v_unit_cost,'current_stock',v_current_stock,'received_on',p_received_on,'reason',v_reason);
end;
$function$;
revoke execute on function public.tec_owner_record_opening_finished_stock(uuid,numeric,date,numeric,text,uuid) from public, anon;
grant execute on function public.tec_owner_record_opening_finished_stock(uuid,numeric,date,numeric,text,uuid) to authenticated;

create or replace function public.tec_owner_update_opening_finished_stock(
  p_batch_id uuid, p_quantity numeric, p_received_on date, p_total_cost numeric
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_batch public.inventory_batches%rowtype;
  v_product public.products%rowtype;
  v_movement public.stock_movements%rowtype;
  v_consumed numeric;
  v_delta numeric;
  v_unit_cost numeric;
  v_new_stock numeric;
  v_month_start date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_batch_id is null or p_quantity is null or p_quantity <= 0 then raise exception 'Valid batch and quantity are required'; end if;
  if p_received_on is null or p_received_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'Enter a valid stock date'; end if;
  if p_total_cost is not null and p_total_cost < 0 then raise exception 'Total cost cannot be negative'; end if;
  select b.* into v_batch from public.inventory_batches b
   where b.id=p_batch_id and b.item_kind='product' and b.source_type='opening_finished_stock' for update;
  if not found then raise exception 'Opening Stock entry not found'; end if;
  if v_batch.quality_status <> 'accepted' then raise exception 'Deleted Opening Stock cannot be edited'; end if;
  select sm.* into v_movement from public.stock_movements sm
   where sm.batch_id=v_batch.id and sm.reference_type='opening_finished_stock' for update;
  if not found then raise exception 'Opening Stock movement not found'; end if;
  v_consumed := v_batch.received_qty-v_batch.available_qty;
  if v_consumed < 0 then raise exception 'Opening Stock batch balance is invalid'; end if;
  if p_quantity < v_consumed then raise exception 'Quantity cannot be less than the amount already used from this batch (%)',v_consumed; end if;
  select p.* into v_product from public.products p where p.id=v_batch.product_id for update;
  if not found then raise exception 'Finished product not found'; end if;
  v_delta := p_quantity-v_batch.received_qty;
  if p_total_cost is not null then v_unit_cost:=round(p_total_cost/p_quantity,6); end if;

  update public.inventory_batches set received_qty=p_quantity, available_qty=p_quantity-v_consumed,
    received_on=p_received_on, unit_cost=v_unit_cost where id=v_batch.id;
  update public.stock_movements set quantity_delta=p_quantity, unit_cost_snapshot=v_unit_cost,
    reason=reason || ' (Opening Stock edited)' where id=v_movement.id;
  update public.products set current_stock=current_stock+v_delta, updated_at=now(),
    status=case when status='Deleted' then status when current_stock+v_delta<=0 then 'Out of Stock'
      when current_stock+v_delta<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
   where id=v_product.id returning current_stock into v_new_stock;
  update public.monthly_product_openings set opening_qty=greatest(0,opening_qty+v_delta),updated_at=now(),updated_by=auth.uid()
   where product_id=v_product.id and period_start=v_month_start;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values(auth.uid(),'opening_finished_stock_updated','inventory_batch',v_batch.id,'Opening finished stock corrected',
    jsonb_build_object('quantity',v_batch.received_qty,'available_qty',v_batch.available_qty,'received_on',v_batch.received_on,'unit_cost',v_batch.unit_cost),
    jsonb_build_object('quantity',p_quantity,'available_qty',p_quantity-v_consumed,'already_used_qty',v_consumed,
      'received_on',p_received_on,'total_cost',p_total_cost,'unit_cost',v_unit_cost,'current_stock',v_new_stock),auth.uid());
  return jsonb_build_object('batch_id',v_batch.id,'product_id',v_product.id,'product_name',v_product.name,
    'quantity',p_quantity,'available_qty',p_quantity-v_consumed,'already_used_qty',v_consumed,
    'unit',v_product.unit,'unit_cost',v_unit_cost,'current_stock',v_new_stock,'received_on',p_received_on);
end;
$function$;
revoke execute on function public.tec_owner_update_opening_finished_stock(uuid,numeric,date,numeric) from public, anon;
grant execute on function public.tec_owner_update_opening_finished_stock(uuid,numeric,date,numeric) to authenticated;

create or replace function public.tec_owner_delete_opening_finished_stock(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_batch public.inventory_batches%rowtype;
  v_product public.products%rowtype;
  v_movement public.stock_movements%rowtype;
  v_consumed numeric;
  v_new_stock numeric;
  v_month_start date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(),false) then raise exception 'Owner permission required'; end if;
  select b.* into v_batch from public.inventory_batches b
   where b.id=p_batch_id and b.item_kind='product' and b.source_type='opening_finished_stock' for update;
  if not found then raise exception 'Opening Stock entry not found'; end if;
  if v_batch.quality_status <> 'accepted' then raise exception 'Opening Stock entry is already deleted'; end if;
  select sm.* into v_movement from public.stock_movements sm
   where sm.batch_id=v_batch.id and sm.reference_type='opening_finished_stock' for update;
  if not found then raise exception 'Opening Stock movement not found'; end if;
  v_consumed:=v_batch.received_qty-v_batch.available_qty;
  if v_consumed<0 then raise exception 'Opening Stock batch balance is invalid'; end if;
  select p.* into v_product from public.products p where p.id=v_batch.product_id for update;
  if not found then raise exception 'Finished product not found'; end if;

  update public.inventory_batches set available_qty=0,quality_status='rejected' where id=v_batch.id;
  update public.stock_movements set quantity_delta=v_consumed,reason=reason || ' (Opening Stock deleted)'
   where id=v_movement.id;
  update public.products set current_stock=current_stock-v_batch.available_qty,updated_at=now(),
    status=case when status='Deleted' then status when current_stock-v_batch.available_qty<=0 then 'Out of Stock'
      when current_stock-v_batch.available_qty<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
   where id=v_product.id returning current_stock into v_new_stock;
  update public.monthly_product_openings set opening_qty=greatest(0,opening_qty-v_batch.received_qty),
    updated_at=now(),updated_by=auth.uid() where product_id=v_product.id and period_start=v_month_start;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values(auth.uid(),'opening_finished_stock_deleted','inventory_batch',v_batch.id,'Opening finished stock removed',
    jsonb_build_object('quantity',v_batch.received_qty,'available_qty',v_batch.available_qty,
      'received_on',v_batch.received_on,'unit_cost',v_batch.unit_cost),
    jsonb_build_object('quantity_retained_for_used_stock',v_consumed,'current_stock',v_new_stock),auth.uid());
  return jsonb_build_object('batch_id',v_batch.id,'product_id',v_product.id,'product_name',v_product.name,
    'removed_quantity',v_batch.available_qty,'quantity_already_used',v_consumed,'current_stock',v_new_stock);
end;
$function$;
revoke execute on function public.tec_owner_delete_opening_finished_stock(uuid) from public, anon;
grant execute on function public.tec_owner_delete_opening_finished_stock(uuid) to authenticated;
