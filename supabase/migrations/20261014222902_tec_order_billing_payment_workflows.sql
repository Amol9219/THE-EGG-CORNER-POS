-- TEC Masala Business order, billing and payment workflow functions.
-- SECURITY INVOKER keeps caller permissions and row-level security active.

CREATE OR REPLACE FUNCTION public.tec_create_outlet_order(p_outlet_id uuid, p_requested_delivery_date date, p_delivery_charge numeric, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_order_id uuid;
  v_order_number text;
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
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
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
  insert into public.outlet_orders
    (order_number, outlet_id, status, requested_delivery_date, delivery_charge, goods_total, notes, submitted_by)
  values
    (v_order_number, p_outlet_id, 'draft', p_requested_delivery_date, v_delivery, v_total,
     nullif(pg_catalog.btrim(p_notes), ''), auth.uid())
  returning id into v_order_id;

  insert into public.outlet_order_lines(outlet_order_id, product_id, quantity, unit, unit_price)
  select v_order_id, p.id, (e.value->>'quantity')::numeric, p.unit, op.selling_price
    from pg_catalog.jsonb_array_elements(p_lines) as e(value)
    join public.products p on p.id = (e.value->>'product_id')::uuid
    join public.outlet_prices op on op.outlet_id = p_outlet_id and op.product_id = p.id and op.is_active = true;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, after_data)
  values (auth.uid(), 'outlet_order_created', 'outlet_order', v_order_id,
          'Draft outlet order created', pg_catalog.jsonb_build_object(
            'order_number', v_order_number, 'status', 'draft', 'goods_total', v_total,
            'delivery_charge', v_delivery, 'line_count', v_count
          ));
  return pg_catalog.jsonb_build_object('id', v_order_id, 'order_number', v_order_number,
    'status', 'draft', 'goods_total', v_total, 'delivery_charge', v_delivery);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_issue_bill(p_outlet_order_id uuid, p_business_name text, p_business_address text, p_business_mobile text, p_gstin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_order public.outlet_orders%rowtype;
  v_bill_id uuid;
  v_bill_number text;
  v_goods_total numeric(14,2);
  v_grand_total numeric(14,2);
  v_line_count integer;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  select o.* into v_order from public.outlet_orders o where o.id=p_outlet_order_id for update;
  if not found then raise exception 'Outlet order was not found'; end if;
  if v_order.status <> 'delivered' then raise exception 'Only delivered orders can be billed'; end if;
  if exists (select 1 from public.bills b where b.outlet_order_id=v_order.id) then
    raise exception 'A bill already exists for this order';
  end if;
  select count(*),coalesce(sum(l.line_total),0) into v_line_count,v_goods_total
    from public.outlet_order_lines l where l.outlet_order_id=v_order.id;
  if v_line_count<1 then raise exception 'An order needs at least one line to create a bill'; end if;
  v_grand_total := v_goods_total+v_order.delivery_charge;
  v_bill_number := 'BILL-'||pg_catalog.to_char(current_date,'YYYYMMDD')||'-'||
    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.bills
    (bill_number,outlet_order_id,outlet_id,business_name,business_address,business_mobile,gstin,
     goods_total,delivery_charge,grand_total,paid_total,status,created_by)
  values
    (v_bill_number,v_order.id,v_order.outlet_id,
     coalesce(nullif(pg_catalog.btrim(p_business_name),''),'TEC Masala Business'),
     nullif(pg_catalog.btrim(p_business_address),''),nullif(pg_catalog.btrim(p_business_mobile),''),
     nullif(pg_catalog.btrim(p_gstin),''),v_goods_total,v_order.delivery_charge,v_grand_total,0,'pending',auth.uid())
  returning id into v_bill_id;

  insert into public.bill_lines(bill_id,product_id,product_name_snapshot,quantity,unit,unit_price)
  select v_bill_id,l.product_id,coalesce(p.name,'Product'),l.quantity,l.unit,l.unit_price
    from public.outlet_order_lines l left join public.products p on p.id=l.product_id
   where l.outlet_order_id=v_order.id;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data)
  values (auth.uid(),'bill_issued','bill',v_bill_id,'Bill issued from delivered order',
          pg_catalog.jsonb_build_object('bill_number',v_bill_number,'outlet_order_id',v_order.id,
            'goods_total',v_goods_total,'delivery_charge',v_order.delivery_charge,'grand_total',v_grand_total));
  return pg_catalog.jsonb_build_object('id',v_bill_id,'bill_number',v_bill_number,'grand_total',v_grand_total,'status','pending');
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_record_payment(p_payment_type text, p_bill_id uuid, p_supplier_id uuid, p_amount numeric, p_method text, p_reference_number text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_payment_id uuid;
  v_bill public.bills%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
  if nullif(pg_catalog.btrim(p_method),'') is null then raise exception 'Payment method is required'; end if;
  if p_payment_type not in ('outlet_receipt','supplier_payment','supplier_advance','supplier_refund') then
    raise exception 'Unsupported payment type';
  end if;
  if p_payment_type='outlet_receipt' then
    if p_bill_id is null or p_supplier_id is not null then raise exception 'Outlet receipt must link to a bill only'; end if;
    select b.* into v_bill from public.bills b where b.id=p_bill_id for update;
    if not found or v_bill.status='cancelled' then raise exception 'Bill was not found or is cancelled'; end if;
  else
    if p_supplier_id is null or p_bill_id is not null then raise exception 'Supplier payments must link to a supplier only'; end if;
    if not exists (select 1 from public.suppliers s where s.id=p_supplier_id) then raise exception 'Supplier was not found'; end if;
  end if;

  insert into public.payments
    (bill_id,supplier_id,payment_type,amount,method,reference_number,status,paid_at,recorded_by,notes)
  values
    (p_bill_id,p_supplier_id,p_payment_type,p_amount,pg_catalog.btrim(p_method),
     nullif(pg_catalog.btrim(p_reference_number),''),'pending',now(),auth.uid(),nullif(pg_catalog.btrim(p_notes),''))
  returning id into v_payment_id;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data)
  values (auth.uid(),'payment_recorded','payment',v_payment_id,'Payment recorded; approval pending',
          pg_catalog.jsonb_build_object('payment_type',p_payment_type,'amount',p_amount,'status','pending'));
  return pg_catalog.jsonb_build_object('id',v_payment_id,'status','pending','amount',p_amount);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_review_payment(p_payment_id uuid, p_decision text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_payment public.payments%rowtype;
  v_bill public.bills%rowtype;
  v_new_paid numeric;
  v_new_status text;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected'; end if;
  if p_decision='rejected' and nullif(pg_catalog.btrim(p_note),'') is null then
    raise exception 'A rejection reason is required';
  end if;
  select p.* into v_payment from public.payments p where p.id=p_payment_id for update;
  if not found then raise exception 'Payment was not found'; end if;
  if v_payment.status<>'pending' then raise exception 'This payment has already been reviewed'; end if;
  v_reason := coalesce(nullif(pg_catalog.btrim(p_note),''),'Payment review');

  if p_decision='approved' and v_payment.payment_type='outlet_receipt' then
    select b.* into v_bill from public.bills b where b.id=v_payment.bill_id for update;
    if not found or v_bill.status='cancelled' then raise exception 'The linked bill was not found or is cancelled'; end if;
    v_new_paid := v_bill.paid_total+v_payment.amount;
    if v_new_paid>v_bill.grand_total then raise exception 'Payment exceeds the outstanding bill balance'; end if;
    v_new_status := case when v_new_paid>=v_bill.grand_total then 'paid'
                         when v_new_paid>0 then 'partial' else 'pending' end;
    update public.bills set paid_total=v_new_paid,status=v_new_status where id=v_bill.id;
  end if;

  update public.payments
     set status=p_decision, approved_by=auth.uid(), approved_at=now(),
         notes=case when nullif(pg_catalog.btrim(p_note),'') is null then notes
                    else concat_ws(E'\n',nullif(notes,''),'Review: '||pg_catalog.btrim(p_note)) end
   where id=v_payment.id;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values (auth.uid(),'payment_'||p_decision,'payment',v_payment.id,v_reason,
          pg_catalog.jsonb_build_object('status','pending'),
          pg_catalog.jsonb_build_object('status',p_decision,'amount',v_payment.amount,
            'payment_type',v_payment.payment_type),auth.uid());
  return pg_catalog.jsonb_build_object('id',v_payment.id,'status',p_decision,'bill_id',v_payment.bill_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_transition_outlet_order(p_outlet_order_id uuid, p_action text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_order public.outlet_orders%rowtype;
  v_line public.outlet_order_lines%rowtype;
  v_batch public.inventory_batches%rowtype;
  v_new_status text;
  v_reason text;
  v_remaining numeric;
  v_take numeric;
  v_current_stock numeric;
  v_min_stock numeric;
  v_new_stock numeric;
  v_product_status text;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if p_action not in ('submit', 'confirm', 'dispatch', 'deliver', 'cancel') then
    raise exception 'Unsupported outlet order action';
  end if;
  select o.* into v_order from public.outlet_orders o where o.id=p_outlet_order_id for update;
  if not found then raise exception 'Outlet order was not found'; end if;
  v_reason := nullif(pg_catalog.btrim(p_reason), '');

  if p_action='submit' then
    if v_order.status <> 'draft' then raise exception 'Only draft orders can be submitted'; end if;
    if not exists (select 1 from public.outlet_order_lines l where l.outlet_order_id=v_order.id) then
      raise exception 'An order needs at least one line';
    end if;
    v_new_status := 'submitted';
    update public.outlet_orders set status=v_new_status, submitted_by=auth.uid() where id=v_order.id;
  elsif p_action='confirm' then
    if v_order.status not in ('submitted','needs_approval') then
      raise exception 'Only submitted orders can be confirmed';
    end if;
    v_new_status := 'confirmed';
    update public.outlet_orders set status=v_new_status, approved_by=auth.uid(), approved_at=now(),
      confirmed_delivery_date=coalesce(confirmed_delivery_date,requested_delivery_date) where id=v_order.id;
  elsif p_action='dispatch' then
    if v_order.status <> 'confirmed' then raise exception 'Only confirmed orders can be dispatched'; end if;
    for v_line in
      select l.* from public.outlet_order_lines l where l.outlet_order_id=v_order.id order by l.id for update
    loop
      select p.current_stock, p.min_stock, p.status into v_current_stock, v_min_stock, v_product_status
        from public.products p where p.id=v_line.product_id for update;
      if not found then raise exception 'A product on this order no longer exists'; end if;
      if coalesce(v_current_stock,0) < v_line.quantity then
        raise exception 'Insufficient product stock for dispatch; product id %', v_line.product_id;
      end if;
      v_remaining := v_line.quantity;
      for v_batch in
        select ib.* from public.inventory_batches ib
         where ib.item_kind='product' and ib.product_id=v_line.product_id
           and ib.quality_status='accepted' and ib.available_qty>0
           and (ib.expires_on is null or ib.expires_on >= current_date)
         order by ib.created_at, ib.id
         for update
      loop
        exit when v_remaining <= 0;
        v_take := least(v_remaining, v_batch.available_qty);
        if v_take > 0 then
          update public.inventory_batches set available_qty=available_qty-v_take where id=v_batch.id;
          insert into public.stock_movements
            (item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,
             reference_type,reference_id,reason,created_by,approved_by)
          values
            ('product',null,v_line.product_id,v_batch.id,'outlet_dispatch',-v_take,v_line.unit,
             'outlet_order',v_order.id,
             coalesce(v_reason,'Dispatch for order '||v_order.order_number),auth.uid(),auth.uid());
          v_remaining := v_remaining-v_take;
        end if;
      end loop;
      if v_remaining > 0 then
        raise exception 'Insufficient accepted, non-expired batch stock for product id %', v_line.product_id;
      end if;
      v_new_stock := v_current_stock-v_line.quantity;
      update public.products
         set current_stock=v_new_stock, updated_at=now(),
             status=case when status='Deleted' then status
                         when v_new_stock<=0 then 'Out of Stock'
                         when v_new_stock<=coalesce(v_min_stock,0) then 'Low Stock'
                         else 'Available' end
       where id=v_line.product_id;
    end loop;
    v_new_status := 'dispatched';
    update public.outlet_orders set status=v_new_status where id=v_order.id;
  elsif p_action='deliver' then
    if v_order.status <> 'dispatched' then raise exception 'Only dispatched orders can be marked delivered'; end if;
    v_new_status := 'delivered';
    update public.outlet_orders set status=v_new_status, delivered_at=now() where id=v_order.id;
  else
    if v_order.status not in ('draft','submitted','needs_approval','confirmed') then
      raise exception 'Dispatched or delivered orders cannot be cancelled; use return workflow';
    end if;
    if v_reason is null then raise exception 'A cancellation reason is required'; end if;
    v_new_status := 'cancelled';
    update public.outlet_orders set status=v_new_status, notes=concat_ws(E'\n',nullif(notes,''),'Cancellation: '||v_reason) where id=v_order.id;
  end if;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values (auth.uid(),'outlet_order_'||p_action,'outlet_order',v_order.id,
          coalesce(v_reason,'Status changed by Owner'),
          pg_catalog.jsonb_build_object('status',v_order.status,'order_number',v_order.order_number),
          pg_catalog.jsonb_build_object('status',v_new_status,'order_number',v_order.order_number),
          case when p_action in ('confirm','dispatch') then auth.uid() else null end);
  return pg_catalog.jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'status',v_new_status);
end;
$function$;


revoke execute on function public.tec_create_outlet_order(uuid, date, numeric, text, jsonb) from public;
revoke execute on function public.tec_create_outlet_order(uuid, date, numeric, text, jsonb) from anon;
grant execute on function public.tec_create_outlet_order(uuid, date, numeric, text, jsonb) to authenticated;

revoke execute on function public.tec_transition_outlet_order(uuid, text, text) from public;
revoke execute on function public.tec_transition_outlet_order(uuid, text, text) from anon;
grant execute on function public.tec_transition_outlet_order(uuid, text, text) to authenticated;

revoke execute on function public.tec_issue_bill(uuid, text, text, text, text) from public;
revoke execute on function public.tec_issue_bill(uuid, text, text, text, text) from anon;
grant execute on function public.tec_issue_bill(uuid, text, text, text, text) to authenticated;

revoke execute on function public.tec_record_payment(text, uuid, uuid, numeric, text, text, text) from public;
revoke execute on function public.tec_record_payment(text, uuid, uuid, numeric, text, text, text) from anon;
grant execute on function public.tec_record_payment(text, uuid, uuid, numeric, text, text, text) to authenticated;

revoke execute on function public.tec_review_payment(uuid, text, text) from public;
revoke execute on function public.tec_review_payment(uuid, text, text) from anon;
grant execute on function public.tec_review_payment(uuid, text, text) to authenticated;
