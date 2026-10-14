-- TEC Masala Business: recipe/BOM and transactional production completion.
-- SECURITY INVOKER preserves caller privileges and RLS.

create table if not exists public.production_recipes (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  recipe_name text not null,
  output_qty numeric not null default 1 check (output_qty > 0),
  output_unit text not null,
  is_active boolean not null default true,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists production_recipes_one_active_per_product
  on public.production_recipes(product_id) where is_active;
create table if not exists public.production_recipe_lines (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.production_recipes(id) on delete cascade,
  raw_material_id uuid not null references public.raw_materials(id),
  quantity numeric not null check (quantity > 0),
  unit text not null,
  created_at timestamptz not null default now(),
  unique(recipe_id, raw_material_id)
);
alter table public.production_recipes enable row level security;
alter table public.production_recipe_lines enable row level security;
grant select, insert, update, delete on public.production_recipes, public.production_recipe_lines to authenticated;
drop policy if exists tec_owner_only on public.production_recipes;
create policy tec_owner_only on public.production_recipes for all to authenticated using (private.is_owner()) with check (private.is_owner());
drop policy if exists tec_owner_only on public.production_recipe_lines;
create policy tec_owner_only on public.production_recipe_lines for all to authenticated using (private.is_owner()) with check (private.is_owner());

CREATE OR REPLACE FUNCTION public.tec_complete_production(p_recipe_id uuid, p_batch_code text, p_planned_qty numeric, p_produced_qty numeric, p_produced_on timestamp with time zone, p_expires_on date, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_recipe public.production_recipes%rowtype;
  v_product public.products%rowtype;
  v_recipe_line public.production_recipe_lines%rowtype;
  v_raw public.raw_materials%rowtype;
  v_batch public.inventory_batches%rowtype;
  v_production_id uuid;
  v_output_batch_id uuid;
  v_batch_code text;
  v_required numeric;
  v_available numeric;
  v_remaining numeric;
  v_take numeric;
  v_new_stock numeric;
  v_status text;
  v_unit_cost numeric;
  v_line_count integer:=0;
  v_cost_total numeric:=0;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if p_recipe_id is null then raise exception 'Select a recipe'; end if;
  if p_planned_qty is null or p_planned_qty<=0 or p_produced_qty is null or p_produced_qty<=0 then
    raise exception 'Planned and produced quantities must be greater than zero';
  end if;
  if p_produced_on is null then raise exception 'Production date is required'; end if;
  if p_expires_on is not null and p_expires_on<p_produced_on::date then
    raise exception 'Expiry cannot be earlier than production date';
  end if;

  select r.* into v_recipe from public.production_recipes r where r.id=p_recipe_id and r.is_active=true for update;
  if not found then raise exception 'Active recipe was not found'; end if;
  select p.* into v_product from public.products p where p.id=v_recipe.product_id for update;
  if not found or not v_product.is_active then raise exception 'Recipe product is inactive'; end if;
  if v_product.unit<>v_recipe.output_unit then raise exception 'Recipe output unit no longer matches the product unit'; end if;
  if not exists(select 1 from public.production_recipe_lines l where l.recipe_id=v_recipe.id) then
    raise exception 'Recipe has no ingredients';
  end if;

  v_batch_code:=coalesce(nullif(pg_catalog.btrim(p_batch_code),''),'PROD-'||pg_catalog.to_char(p_produced_on,'YYYYMMDD')||'-'||pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text,'-',''),1,8)));
  if exists(select 1 from public.inventory_batches b where b.batch_code=v_batch_code) then
    raise exception 'Batch code already exists; choose another code';
  end if;
  if exists(select 1 from public.production_batches b where b.batch_code=v_batch_code) then
    raise exception 'Production batch code already exists; choose another code';
  end if;

  insert into public.production_batches(batch_code,product_id,planned_qty,produced_qty,unit,produced_on,expires_on,notes,status,created_by)
  values(v_batch_code,v_product.id,p_planned_qty,p_produced_qty,v_product.unit,p_produced_on,p_expires_on,
    nullif(pg_catalog.btrim(p_notes),''),'completed',auth.uid())
  returning id into v_production_id;

  for v_recipe_line in
    select l.* from public.production_recipe_lines l
     where l.recipe_id=v_recipe.id order by l.raw_material_id for update
  loop
    select r.* into v_raw from public.raw_materials r where r.id=v_recipe_line.raw_material_id for update;
    if not found or not v_raw.is_active then raise exception 'A recipe raw material is inactive or missing'; end if;
    if v_raw.unit<>v_recipe_line.unit then raise exception 'Recipe unit differs from the raw material unit'; end if;
    v_required:=round((v_recipe_line.quantity/v_recipe.output_qty)*p_produced_qty,6);
    if v_required<=0 then raise exception 'Calculated ingredient quantity is too small'; end if;
    if coalesce(v_raw.current_stock,0)<v_required then
      raise exception 'Insufficient current stock for raw material %; required %, available %',v_raw.name,v_required,v_raw.current_stock;
    end if;
    select coalesce(sum(b.available_qty),0) into v_available
      from public.inventory_batches b
     where b.item_kind='raw_material' and b.raw_material_id=v_raw.id
       and b.quality_status='accepted' and b.available_qty>0
       and (b.expires_on is null or b.expires_on>=p_produced_on::date);
    if v_available<v_required then
      raise exception 'Insufficient accepted, non-expired batch stock for raw material %; required %, batch available %',v_raw.name,v_required,v_available;
    end if;

    v_remaining:=v_required;
    v_unit_cost:=null;
    for v_batch in
      select b.* from public.inventory_batches b
       where b.item_kind='raw_material' and b.raw_material_id=v_raw.id
         and b.quality_status='accepted' and b.available_qty>0
         and (b.expires_on is null or b.expires_on>=p_produced_on::date)
       order by b.expires_on nulls last,b.created_at,b.id for update
    loop
      exit when v_remaining<=0;
      v_take:=least(v_remaining,v_batch.available_qty);
      if v_take>0 then
        update public.inventory_batches set available_qty=available_qty-v_take where id=v_batch.id;
        insert into public.production_consumption(production_batch_id,raw_material_id,batch_id,quantity,unit)
        values(v_production_id,v_raw.id,v_batch.id,v_take,v_recipe_line.unit);
        insert into public.stock_movements(item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,reference_type,reference_id,reason,created_by,approved_by)
        values('raw_material',v_raw.id,null,v_batch.id,'production_use',-v_take,v_recipe_line.unit,'production_batch',v_production_id,
          'Consumed for production batch '||v_batch_code,auth.uid(),auth.uid());
        if v_batch.unit_cost is not null then v_cost_total:=v_cost_total+v_take*v_batch.unit_cost; end if;
        v_remaining:=v_remaining-v_take;
      end if;
    end loop;
    if v_remaining>0 then raise exception 'Batch stock changed during production; transaction rolled back'; end if;
    update public.raw_materials set current_stock=current_stock-v_required,updated_at=now() where id=v_raw.id;
    v_line_count:=v_line_count+1;
  end loop;

  update public.products set current_stock=current_stock+p_produced_qty,updated_at=now(),
    status=case when status='Deleted' then status
                when current_stock+p_produced_qty<=0 then 'Out of Stock'
                when current_stock+p_produced_qty<=coalesce(min_stock,0) then 'Low Stock'
                else 'Available' end
   where id=v_product.id;

  insert into public.inventory_batches(item_kind,raw_material_id,product_id,batch_code,received_qty,available_qty,unit,
    manufactured_on,expires_on,unit_cost,quality_status,source_type,source_id,created_by)
  values('product',null,v_product.id,v_batch_code,p_produced_qty,p_produced_qty,v_product.unit,
    p_produced_on::date,p_expires_on,
    case when p_produced_qty>0 and v_cost_total>0 then round(v_cost_total/p_produced_qty,4) else null end,
    'accepted','production',v_production_id,auth.uid())
  returning id into v_output_batch_id;

  insert into public.stock_movements(item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,reference_type,reference_id,reason,created_by,approved_by)
  values('product',null,v_product.id,v_output_batch_id,'production_output',p_produced_qty,v_product.unit,
    'production_batch',v_production_id,'Finished goods from production batch '||v_batch_code,auth.uid(),auth.uid());

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data,approved_by)
  values(auth.uid(),'production_completed','production_batch',v_production_id,'Production completed; stock movements recorded',
    pg_catalog.jsonb_build_object('batch_code',v_batch_code,'product_id',v_product.id,'produced_qty',p_produced_qty,'unit',v_product.unit,'recipe_id',v_recipe.id,'ingredient_lines',v_line_count),auth.uid());

  return pg_catalog.jsonb_build_object('id',v_production_id,'batch_code',v_batch_code,'output_batch_id',v_output_batch_id,
    'status','completed','produced_qty',p_produced_qty,'unit',v_product.unit,'ingredient_lines',v_line_count);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_save_production_recipe(p_product_id uuid, p_recipe_name text, p_output_qty numeric, p_output_unit text, p_notes text, p_lines jsonb, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_recipe_id uuid;
  v_product public.products%rowtype;
  v_line jsonb;
  v_raw_id uuid;
  v_qty numeric;
  v_unit text;
  v_active boolean;
  v_count integer;
  v_distinct integer;
  v_before jsonb;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if nullif(pg_catalog.btrim(p_recipe_name),'') is null then raise exception 'Recipe name is required'; end if;
  if p_output_qty is null or p_output_qty <= 0 then raise exception 'Output quantity must be greater than zero'; end if;
  if nullif(pg_catalog.btrim(p_output_unit),'') is null then raise exception 'Output unit is required'; end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array' then raise exception 'Recipe ingredients must be an array'; end if;
  v_count := pg_catalog.jsonb_array_length(p_lines);
  if v_count<1 or v_count>50 then raise exception 'A recipe needs 1 to 50 ingredient lines'; end if;
  select count(*),count(distinct nullif(e.value->>'raw_material_id','')::uuid)
    into v_count,v_distinct from pg_catalog.jsonb_array_elements(p_lines) as e(value);
  if v_count<>v_distinct then raise exception 'Each raw material may appear only once in a recipe'; end if;

  select p.* into v_product from public.products p where p.id=p_product_id for update;
  if not found or not v_product.is_active then raise exception 'Select an active finished product'; end if;
  if v_product.unit<>pg_catalog.btrim(p_output_unit) then
    raise exception 'Recipe output unit must match the finished product unit';
  end if;

  for v_line in select e.value from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  loop
    v_raw_id:=nullif(pg_catalog.btrim(v_line->>'raw_material_id'),'')::uuid;
    v_qty:=coalesce(nullif(v_line->>'quantity','')::numeric,0);
    v_unit:=nullif(pg_catalog.btrim(v_line->>'unit'),'');
    if v_raw_id is null or v_qty<=0 or v_unit is null then
      raise exception 'Each ingredient needs raw material, positive quantity and unit';
    end if;
    select r.is_active,r.unit into v_active,v_unit from public.raw_materials r where r.id=v_raw_id;
    if coalesce(v_active,false) is not true then raise exception 'Recipe references an unknown or inactive raw material'; end if;
    if v_unit<>pg_catalog.btrim(v_line->>'unit') then raise exception 'Ingredient unit must match the raw material unit'; end if;
  end loop;

  if p_recipe_id is null then
    insert into public.production_recipes(product_id,recipe_name,output_qty,output_unit,is_active,notes,created_by)
    values(p_product_id,pg_catalog.btrim(p_recipe_name),p_output_qty,pg_catalog.btrim(p_output_unit),true,
      nullif(pg_catalog.btrim(p_notes),''),auth.uid())
    returning id into v_recipe_id;
  else
    select to_jsonb(r) into v_before from public.production_recipes r where r.id=p_recipe_id for update;
    if v_before is null then raise exception 'Recipe was not found'; end if;
    update public.production_recipes
       set product_id=p_product_id,recipe_name=pg_catalog.btrim(p_recipe_name),output_qty=p_output_qty,
           output_unit=pg_catalog.btrim(p_output_unit),notes=nullif(pg_catalog.btrim(p_notes),''),
           updated_at=now()
     where id=p_recipe_id returning id into v_recipe_id;
    delete from public.production_recipe_lines where recipe_id=v_recipe_id;
  end if;

  insert into public.production_recipe_lines(recipe_id,raw_material_id,quantity,unit)
  select v_recipe_id,(e.value->>'raw_material_id')::uuid,(e.value->>'quantity')::numeric,pg_catalog.btrim(e.value->>'unit')
    from pg_catalog.jsonb_array_elements(p_lines) as e(value);

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data)
  values(auth.uid(),case when p_recipe_id is null then 'production_recipe_created' else 'production_recipe_updated' end,
    'production_recipe',v_recipe_id,'Recipe saved',v_before,
    pg_catalog.jsonb_build_object('recipe_name',pg_catalog.btrim(p_recipe_name),'product_id',p_product_id,'output_qty',p_output_qty,'output_unit',p_output_unit,'line_count',v_count));
  return pg_catalog.jsonb_build_object('id',v_recipe_id,'recipe_name',pg_catalog.btrim(p_recipe_name),'line_count',v_count);
end;
$function$;


revoke execute on function public.tec_save_production_recipe(uuid,text,numeric,text,text,jsonb,uuid) from public;
revoke execute on function public.tec_save_production_recipe(uuid,text,numeric,text,text,jsonb,uuid) from anon;
grant execute on function public.tec_save_production_recipe(uuid,text,numeric,text,text,jsonb,uuid) to authenticated;
revoke execute on function public.tec_complete_production(uuid,text,numeric,numeric,timestamptz,date,text) from public;
revoke execute on function public.tec_complete_production(uuid,text,numeric,numeric,timestamptz,date,text) from anon;
grant execute on function public.tec_complete_production(uuid,text,numeric,numeric,timestamptz,date,text) to authenticated;
