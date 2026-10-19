-- Allow the owner to record several finished products first and aggregate
-- the run's raw-material consumption once, without creating a recipe/BOM.
create table if not exists public.production_runs (
  id uuid primary key default gen_random_uuid(),
  run_code text not null unique,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.production_runs enable row level security;
revoke all on public.production_runs from anon, authenticated;
grant select on public.production_runs to authenticated;
drop policy if exists tec_owner_read_production_runs on public.production_runs;
create policy tec_owner_read_production_runs on public.production_runs
  for select to authenticated using (private.is_owner());

alter table public.production_batches
  add column if not exists production_run_id uuid references public.production_runs(id);
alter table public.production_consumption
  add column if not exists production_run_id uuid references public.production_runs(id);
alter table public.production_consumption alter column production_batch_id drop not null;
alter table public.production_consumption
  drop constraint if exists production_consumption_single_parent_check;
alter table public.production_consumption
  add constraint production_consumption_single_parent_check
  check ((production_batch_id is null) <> (production_run_id is null));

create or replace function public.tec_owner_complete_production_run(
  p_outputs jsonb,
  p_consumption jsonb,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_run_id uuid;
  v_run_code text;
  v_output record;
  v_raw_line record;
  v_product public.products%rowtype;
  v_raw public.raw_materials%rowtype;
  v_batch public.inventory_batches%rowtype;
  v_production_id uuid;
  v_output_batch_id uuid;
  v_batch_code text;
  v_required numeric;
  v_available numeric;
  v_remaining numeric;
  v_take numeric;
  v_output_count integer;
  v_consumption_count integer;
  v_total_output numeric := 0;
  v_total_consumption numeric := 0;
  v_line_count integer := 0;
  v_produced_on timestamptz;
  v_expires_on date;
  v_unit_cost numeric;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_outputs is null or pg_catalog.jsonb_typeof(p_outputs)<>'array' then raise exception 'Finished products are required'; end if;
  if pg_catalog.jsonb_array_length(p_outputs)<1 or pg_catalog.jsonb_array_length(p_outputs)>40 then raise exception 'Enter 1 to 40 finished product lines'; end if;
  if p_consumption is null or pg_catalog.jsonb_typeof(p_consumption)<>'array' then raise exception 'Aggregate raw material usage is required'; end if;
  if pg_catalog.jsonb_array_length(p_consumption)<1 or pg_catalog.jsonb_array_length(p_consumption)>50 then raise exception 'Enter 1 to 50 raw material lines'; end if;
  if exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_outputs)
      as x(product_id uuid, produced_qty numeric, produced_on timestamptz, expires_on date, unit_cost numeric)
    where x.product_id is null or x.produced_qty is null or x.produced_qty<=0 or x.produced_on is null
       or (x.expires_on is not null and x.expires_on<x.produced_on::date)
       or (x.unit_cost is not null and x.unit_cost<0)
  ) then raise exception 'Each finished product needs valid quantity/date and non-negative optional cost'; end if;
  if exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_consumption)
      as x(raw_material_id uuid, quantity numeric)
    where x.raw_material_id is null or x.quantity is null or x.quantity<=0
  ) then raise exception 'Each raw material needs a quantity greater than zero'; end if;
  select count(*) into v_output_count from pg_catalog.jsonb_to_recordset(p_outputs)
    as x(product_id uuid, produced_qty numeric, produced_on timestamptz, expires_on date, unit_cost numeric);
  if v_output_count<>(select count(distinct x.product_id) from pg_catalog.jsonb_to_recordset(p_outputs)
       as x(product_id uuid, produced_qty numeric, produced_on timestamptz, expires_on date, unit_cost numeric))
  then raise exception 'Add each product once and combine its quantity'; end if;
  select count(*) into v_consumption_count from pg_catalog.jsonb_to_recordset(p_consumption)
    as x(raw_material_id uuid, quantity numeric);
  if v_consumption_count<>(select count(distinct x.raw_material_id) from pg_catalog.jsonb_to_recordset(p_consumption)
       as x(raw_material_id uuid, quantity numeric))
  then raise exception 'Add each raw material once and combine its quantity'; end if;

  v_run_code:='RUN-'||pg_catalog.to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD-HH24MISS')||'-'||
    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text,'-',''),1,6));
  insert into public.production_runs(run_code,notes,created_by)
    values(v_run_code,nullif(pg_catalog.btrim(p_notes),''),auth.uid()) returning id into v_run_id;

  for v_output in
    select x.product_id,x.produced_qty,x.produced_on,x.expires_on,x.unit_cost,
           nullif(pg_catalog.btrim(x.batch_code),'') as batch_code,
           nullif(pg_catalog.btrim(x.notes),'') as notes
    from pg_catalog.jsonb_to_recordset(p_outputs)
      as x(product_id uuid, produced_qty numeric, produced_on timestamptz, expires_on date,
           unit_cost numeric, batch_code text, notes text)
    order by x.product_id
  loop
    select p.* into v_product from public.products p where p.id=v_output.product_id for update;
    if not found or not v_product.is_active then raise exception 'A finished product is inactive or missing'; end if;
    v_produced_on:=v_output.produced_on;
    v_expires_on:=v_output.expires_on;
    v_unit_cost:=v_output.unit_cost;
    v_batch_code:=coalesce(v_output.batch_code,
      'RUN-'||pg_catalog.to_char(v_produced_on,'YYYYMMDD')||'-'||
      pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text,'-',''),1,8)));
    if exists(select 1 from public.production_batches b where b.batch_code=v_batch_code)
       or exists(select 1 from public.inventory_batches b where b.batch_code=v_batch_code)
    then raise exception 'Batch code % already exists',v_batch_code; end if;
    insert into public.production_batches(batch_code,product_id,planned_qty,produced_qty,unit,produced_on,expires_on,notes,status,created_by,production_run_id)
      values(v_batch_code,v_product.id,v_output.produced_qty,v_output.produced_qty,v_product.unit,v_produced_on,v_expires_on,v_output.notes,'completed',auth.uid(),v_run_id)
      returning id into v_production_id;
    update public.products set current_stock=current_stock+v_output.produced_qty,updated_at=now(),
      status=case when status='Deleted' then status when current_stock+v_output.produced_qty<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
      where id=v_product.id;
    insert into public.inventory_batches(item_kind,raw_material_id,product_id,batch_code,received_qty,available_qty,unit,manufactured_on,expires_on,unit_cost,quality_status,source_type,source_id,created_by,received_on)
      values('product',null,v_product.id,v_batch_code,v_output.produced_qty,v_output.produced_qty,v_product.unit,v_produced_on::date,v_expires_on,v_unit_cost,'accepted','production',v_production_id,auth.uid(),v_produced_on::date)
      returning id into v_output_batch_id;
    insert into public.stock_movements(item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,reference_type,reference_id,reason,created_by,approved_by,unit_cost_snapshot)
      values('product',null,v_product.id,v_output_batch_id,'production_output',v_output.produced_qty,v_product.unit,'production_batch',v_production_id,'Finished goods from production run '||v_run_code,auth.uid(),auth.uid(),v_unit_cost);
    insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data,approved_by)
      values(auth.uid(),'production_run_output_added','production_batch',v_production_id,'Finished output in grouped production run',
        pg_catalog.jsonb_build_object('run_id',v_run_id,'run_code',v_run_code,'batch_code',v_batch_code,'product_id',v_product.id,'produced_qty',v_output.produced_qty,'unit',v_product.unit,'unit_cost',v_unit_cost),auth.uid());
    v_total_output:=v_total_output+v_output.produced_qty;
  end loop;

  for v_raw_line in
    select x.raw_material_id,round(x.quantity,6) as quantity
    from pg_catalog.jsonb_to_recordset(p_consumption) as x(raw_material_id uuid, quantity numeric)
    order by x.raw_material_id
  loop
    select r.* into v_raw from public.raw_materials r where r.id=v_raw_line.raw_material_id for update;
    if not found or not v_raw.is_active then raise exception 'A raw material is inactive or missing'; end if;
    v_required:=v_raw_line.quantity;
    if v_required<=0 then raise exception 'Raw material quantity is too small'; end if;
    if coalesce(v_raw.current_stock,0)<v_required then raise exception 'Insufficient current stock for raw material %; required %, available %',v_raw.name,v_required,v_raw.current_stock; end if;
    select coalesce(sum(b.available_qty),0) into v_available from public.inventory_batches b
      where b.item_kind='raw_material' and b.raw_material_id=v_raw.id and b.quality_status='accepted'
        and b.available_qty>0 and (b.expires_on is null or b.expires_on>=current_date);
    if v_available<v_required then raise exception 'Insufficient accepted batch stock for raw material %; required %, batch available %',v_raw.name,v_required,v_available; end if;
    v_remaining:=v_required;
    for v_batch in select b.* from public.inventory_batches b
      where b.item_kind='raw_material' and b.raw_material_id=v_raw.id and b.quality_status='accepted'
        and b.available_qty>0 and (b.expires_on is null or b.expires_on>=current_date)
      order by b.expires_on nulls last,b.created_at,b.id for update
    loop
      exit when v_remaining<=0;
      v_take:=least(v_remaining,v_batch.available_qty);
      if v_take>0 then
        update public.inventory_batches set available_qty=available_qty-v_take where id=v_batch.id;
        insert into public.production_consumption(production_batch_id,production_run_id,raw_material_id,batch_id,quantity,unit)
          values(null,v_run_id,v_raw.id,v_batch.id,v_take,v_raw.unit);
        insert into public.stock_movements(item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,reference_type,reference_id,reason,created_by,approved_by,unit_cost_snapshot)
          values('raw_material',v_raw.id,null,v_batch.id,'production_use',-v_take,v_raw.unit,'production_run',v_run_id,'Aggregate raw material use for production run '||v_run_code,auth.uid(),auth.uid(),v_batch.unit_cost);
        v_remaining:=v_remaining-v_take;
      end if;
    end loop;
    if v_remaining>0 then raise exception 'Raw material batch stock changed; transaction rolled back'; end if;
    update public.raw_materials set current_stock=current_stock-v_required,updated_at=now() where id=v_raw.id;
    v_total_consumption:=v_total_consumption+v_required;
    v_line_count:=v_line_count+1;
  end loop;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data,approved_by)
    values(auth.uid(),'production_run_completed','production_run',v_run_id,'Grouped production with aggregate raw-material consumption',
      pg_catalog.jsonb_build_object('run_code',v_run_code,'output_lines',v_output_count,'total_output_quantity',v_total_output,'raw_material_lines',v_line_count,'total_raw_material_quantity',v_total_consumption),auth.uid());
  return pg_catalog.jsonb_build_object('id',v_run_id,'run_code',v_run_code,'output_lines',v_output_count,
    'total_output_quantity',v_total_output,'raw_material_lines',v_line_count,'total_raw_material_quantity',v_total_consumption);
end;
$function$;

revoke execute on function public.tec_owner_complete_production_run(jsonb,jsonb,text) from public;
revoke execute on function public.tec_owner_complete_production_run(jsonb,jsonb,text) from anon;
grant execute on function public.tec_owner_complete_production_run(jsonb,jsonb,text) to authenticated;
