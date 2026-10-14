-- Explicitly reject users whose profile role cannot be resolved by current_app_role().

CREATE OR REPLACE FUNCTION public.tec_create_outlet_order(p_outlet_id uuid, p_requested_delivery_date date, p_delivery_charge numeric, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order_id uuid;
  v_order_number text;
  v_role text;
  v_new_status text;
  v_total numeric(14,2) := 0;
  v_delivery numeric(14,2) := coalesce(p_delivery_charge, 0);
  v_line jsonb;
  v_product_id uuid;
  v_qty numeric;
  v_price numeric;
  v_price_count integer;
  v_unit text;
  v_active boolean;
  v_count integer;
  v_distinct integer;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  v_role := private.current_app_role();
  if v_role is null or v_role not in ('owner','outlet') then raise exception 'Owner or outlet role required'; end if;
  if v_role='outlet' and p_outlet_id is distinct from private.current_outlet_id() then
    raise exception 'An outlet user can only create an order for their assigned outlet';
  end if;
  if p_outlet_id is null or not exists (
    select 1 from public.outlets o where o.id = p_outlet_id and o.is_active = true
  ) then raise exception 'Select an active outlet'; end if;
  if v_delivery < 0 then raise exception 'Delivery charge cannot be negative'; end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Order lines must be an array';
  end if;
  v_count := pg_catalog.jsonb_array_length(p_lines);
  if v_count < 1 or v_count > 50 then raise exception 'An order must contain 1 to 50 lines'; end if;
  select count(*), count(distinct nullif(e.value->>'product_id','')::uuid)
    into v_count, v_distinct from pg_catalog.jsonb_array_elements(p_lines) as e(value);
  if v_count <> v_distinct then raise exception 'Each product may appear only once per order'; end if;

  for v_line in select e.value from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  loop
    v_product_id := nullif(pg_catalog.btrim(v_line->>'product_id'), '')::uuid;
    v_qty := coalesce(nullif(v_line->>'quantity', '')::numeric, 0);
    if v_product_id is null or v_qty <= 0 then raise exception 'Each order line needs a product and positive quantity'; end if;
    select p.is_active, p.unit into v_active, v_unit
      from public.products p where p.id = v_product_id;
    if coalesce(v_active, false) is not true then raise exception 'An order line references an inactive product'; end if;
    select count(*), max(op.selling_price) into v_price_count, v_price
      from public.outlet_prices op
     where op.outlet_id = p_outlet_id and op.product_id = v_product_id and op.is_active = true;
    if v_price_count <> 1 then
      raise exception 'Each selected product must have exactly one active outlet price';
    end if;
    v_total := v_total + v_qty * v_price;
  end loop;

  v_order_number := 'ORD-' || pg_catalog.to_char(current_date, 'YYYYMMDD') || '-' ||
                    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text, '-', ''), 1, 8));
  v_new_status := case when v_role='outlet' then 'submitted' else 'draft' end;
  insert into public.outlet_orders
    (order_number, outlet_id, status, requested_delivery_date, delivery_charge, goods_total, notes, submitted_by)
  values
    (v_order_number, p_outlet_id, v_new_status, p_requested_delivery_date, v_delivery, v_total,
     nullif(pg_catalog.btrim(p_notes), ''), auth.uid())
  returning id into v_order_id;

  insert into public.outlet_order_lines(outlet_order_id, product_id, quantity, unit, unit_price)
  select v_order_id, p.id, (e.value->>'quantity')::numeric, p.unit, op.selling_price
    from pg_catalog.jsonb_array_elements(p_lines) as e(value)
    join public.products p on p.id = (e.value->>'product_id')::uuid
    join public.outlet_prices op on op.outlet_id = p_outlet_id and op.product_id = p.id and op.is_active = true;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, after_data)
  values (auth.uid(), 'outlet_order_created', 'outlet_order', v_order_id,
          'Outlet order created by validated workflow', pg_catalog.jsonb_build_object(
            'order_number', v_order_number, 'status', v_new_status, 'goods_total', v_total,
            'delivery_charge', v_delivery, 'line_count', v_count
          ));
  return pg_catalog.jsonb_build_object('id', v_order_id, 'order_number', v_order_number,
    'status', v_new_status, 'goods_total', v_total, 'delivery_charge', v_delivery);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_create_return_request(p_bill_id uuid, p_reason text, p_comment text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_bill public.bills%rowtype;
  v_role text;
  v_request_id uuid;
  v_return_number text;
  v_line jsonb;
  v_product_id uuid;
  v_qty numeric;
  v_condition text;
  v_unit text;
  v_billed numeric;
  v_previously_requested numeric;
  v_count integer;
  v_distinct integer;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  v_role:=private.current_app_role();
  if v_role is null or v_role not in ('owner','outlet') then raise exception 'Owner or outlet role required'; end if;
  if nullif(pg_catalog.btrim(p_reason),'') is null then raise exception 'Return reason is required'; end if;
  if p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array' then raise exception 'Return lines must be an array'; end if;
  v_count:=pg_catalog.jsonb_array_length(p_lines);
  if v_count<1 or v_count>50 then raise exception 'A return request must contain 1 to 50 lines'; end if;
  select count(*),count(distinct nullif(e.value->>'product_id','')::uuid)
    into v_count,v_distinct from pg_catalog.jsonb_array_elements(p_lines) as e(value);
  if v_count<>v_distinct then raise exception 'Each product may appear only once per return request'; end if;

  select b.* into v_bill from public.bills b where b.id=p_bill_id for update;
  if not found or v_bill.status='cancelled' then raise exception 'Bill was not found or is cancelled'; end if;
  if v_role='outlet' and v_bill.outlet_id is distinct from private.current_outlet_id() then
    raise exception 'You can only request returns for your own outlet bills';
  end if;

  for v_line in select e.value from pg_catalog.jsonb_array_elements(p_lines) as e(value)
  loop
    v_product_id:=nullif(pg_catalog.btrim(v_line->>'product_id'),'')::uuid;
    v_qty:=coalesce(nullif(v_line->>'quantity','')::numeric,0);
    v_condition:=coalesce(nullif(pg_catalog.btrim(v_line->>'condition'),''),'unknown');
    if v_product_id is null or v_qty<=0 then raise exception 'Each return line needs a product and positive quantity'; end if;
    if v_condition is null or v_condition not in ('good','damaged','unknown') then raise exception 'Invalid return condition'; end if;
    select coalesce(sum(bl.quantity),0) into v_billed from public.bill_lines bl
      where bl.bill_id=v_bill.id and bl.product_id=v_product_id;
    if v_billed<=0 then raise exception 'Product is not present on the selected bill'; end if;
    select coalesce(sum(rl.quantity),0) into v_previously_requested
      from public.return_request_lines rl join public.return_requests rr on rr.id=rl.return_request_id
     where rr.bill_id=v_bill.id and rr.status<>'rejected' and rl.product_id=v_product_id;
    if v_qty+v_previously_requested>v_billed then
      raise exception 'Return quantity for product % exceeds billed quantity; billed %, already requested %, new %',v_product_id,v_billed,v_previously_requested,v_qty;
    end if;
    select p.unit into v_unit from public.products p where p.id=v_product_id;
    if not found then raise exception 'Returned product was not found'; end if;
    if v_unit is null then raise exception 'Product unit is required'; end if;
  end loop;

  v_return_number:='RET-'||pg_catalog.to_char(current_date,'YYYYMMDD')||'-'||
    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.return_requests(return_number,outlet_id,bill_id,status,reason,comment,requested_by)
  values(v_return_number,v_bill.outlet_id,v_bill.id,'requested',pg_catalog.btrim(p_reason),
    nullif(pg_catalog.btrim(p_comment),''),auth.uid())
  returning id into v_request_id;

  insert into public.return_request_lines(return_request_id,product_id,quantity,condition,restock_approved)
  select v_request_id,(e.value->>'product_id')::uuid,(e.value->>'quantity')::numeric,
    coalesce(nullif(pg_catalog.btrim(e.value->>'condition'),''),'unknown'),false
  from pg_catalog.jsonb_array_elements(p_lines) as e(value);

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data)
  values(auth.uid(),'return_requested','return_request',v_request_id,pg_catalog.btrim(p_reason),
    pg_catalog.jsonb_build_object('return_number',v_return_number,'bill_id',v_bill.id,'line_count',v_count,'status','requested'));
  return pg_catalog.jsonb_build_object('id',v_request_id,'return_number',v_return_number,'status','requested');
end;
$function$;


revoke execute on function public.tec_create_outlet_order(uuid,date,numeric,text,jsonb) from public;
revoke execute on function public.tec_create_outlet_order(uuid,date,numeric,text,jsonb) from anon;
grant execute on function public.tec_create_outlet_order(uuid,date,numeric,text,jsonb) to authenticated;
revoke execute on function public.tec_create_return_request(uuid,text,text,jsonb) from public;
revoke execute on function public.tec_create_return_request(uuid,text,text,jsonb) from anon;
grant execute on function public.tec_create_return_request(uuid,text,text,jsonb) to authenticated;
