-- Tighten return input validation without changing the workflow contract.

CREATE OR REPLACE FUNCTION public.tec_create_return_request(p_bill_id uuid, p_reason text, p_comment text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
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
  if v_role not in ('owner','outlet') then raise exception 'Owner or outlet role required'; end if;
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

CREATE OR REPLACE FUNCTION public.tec_process_return_request(p_return_request_id uuid, p_action text, p_note text, p_line_reviews jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_return public.return_requests%rowtype;
  v_line public.return_request_lines%rowtype;
  v_review jsonb;
  v_line_id uuid;
  v_condition text;
  v_restock boolean;
  v_new_batch_id uuid;
  v_new_batch_code text;
  v_unit text;
  v_product public.products%rowtype;
  v_new_stock numeric;
  v_line_count integer;
  v_distinct integer;
  v_restocked integer:=0;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not private.is_owner() then raise exception 'Owner permission required'; end if;
  if p_action not in ('approve','reject','receive','close') then raise exception 'Unsupported return action'; end if;
  select r.* into v_return from public.return_requests r where r.id=p_return_request_id for update;
  if not found then raise exception 'Return request was not found'; end if;
  v_reason:=nullif(pg_catalog.btrim(p_note),'');

  if p_action in ('approve','reject') then
    if v_return.status<>'requested' then raise exception 'Only requested returns can be reviewed'; end if;
    if p_action='reject' then
      if v_reason is null then raise exception 'A rejection reason is required'; end if;
      update public.return_requests set status='rejected',decided_by=auth.uid(),decided_at=now(),decision_note=v_reason where id=v_return.id;
    else
      if p_line_reviews is null or pg_catalog.jsonb_typeof(p_line_reviews)<>'array' then raise exception 'Inspect every return line before approval'; end if;
      select count(*),count(distinct nullif(e.value->>'line_id','')::uuid)
        into v_line_count,v_distinct from pg_catalog.jsonb_array_elements(p_line_reviews) as e(value);
      if v_line_count<1 or v_line_count>50 or v_line_count<>v_distinct then
        raise exception 'Every return line needs exactly one unique inspection result';
      end if;
      if v_line_count<>(select count(*) from public.return_request_lines l where l.return_request_id=v_return.id) then
        raise exception 'Inspection results must include all return lines';
      end if;
      for v_review in select e.value from pg_catalog.jsonb_array_elements(p_line_reviews) as e(value)
      loop
        v_line_id:=nullif(pg_catalog.btrim(v_review->>'line_id'),'')::uuid;
        v_condition:=nullif(pg_catalog.btrim(v_review->>'condition'),'');
        v_restock:=coalesce((v_review->>'restock_approved')::boolean,false);
        if v_condition is null or v_condition not in ('good','damaged','unknown') then raise exception 'Invalid inspected condition'; end if;
        if v_restock and v_condition<>'good' then raise exception 'Only good-condition items can be approved for restocking'; end if;
        update public.return_request_lines
           set condition=v_condition,restock_approved=v_restock
         where id=v_line_id and return_request_id=v_return.id;
        if not found then raise exception 'Inspection line does not belong to this return request'; end if;
      end loop;
      update public.return_requests set status='approved',decided_by=auth.uid(),decided_at=now(),
        decision_note=coalesce(v_reason,'Inspected by Owner') where id=v_return.id;
    end if;
  elsif p_action='receive' then
    if v_return.status<>'approved' then raise exception 'Only approved returns can be received'; end if;
    for v_line in select l.* from public.return_request_lines l where l.return_request_id=v_return.id order by l.product_id,l.id for update
    loop
      if v_line.condition='good' and v_line.restock_approved then
        select p.* into v_product from public.products p where p.id=v_line.product_id for update;
        if not found then raise exception 'A returned product no longer exists'; end if;
        v_unit:=v_product.unit;
        v_new_batch_code:='RET-'||pg_catalog.substr(pg_catalog.replace(v_return.id::text,'-',''),1,8)||'-'||pg_catalog.substr(pg_catalog.replace(v_line.id::text,'-',''),1,8);
        insert into public.inventory_batches(item_kind,raw_material_id,product_id,batch_code,received_qty,available_qty,unit,
          quality_status,source_type,source_id,created_by)
        values('product',null,v_product.id,v_new_batch_code,v_line.quantity,v_line.quantity,v_unit,
          'accepted','return_request',v_return.id,auth.uid())
        returning id into v_new_batch_id;
        v_new_stock:=v_product.current_stock+v_line.quantity;
        update public.products set current_stock=v_new_stock,updated_at=now(),
          status=case when status='Deleted' then status when v_new_stock<=0 then 'Out of Stock'
                      when v_new_stock<=coalesce(min_stock,0) then 'Low Stock' else 'Available' end
        where id=v_product.id;
        insert into public.stock_movements(item_kind,raw_material_id,product_id,batch_id,movement_type,quantity_delta,unit,
          reference_type,reference_id,reason,created_by,approved_by)
        values('product',null,v_product.id,v_new_batch_id,'return_in',v_line.quantity,v_unit,'return_request',v_return.id,
          coalesce(v_reason,'Approved return '||v_return.return_number),auth.uid(),auth.uid());
        v_restocked:=v_restocked+1;
      end if;
    end loop;
    update public.return_requests set status='received',decision_note=case when v_reason is null then decision_note else concat_ws(E'\n',nullif(decision_note,''),'Received: '||v_reason) end where id=v_return.id;
  else
    if v_return.status<>'received' then raise exception 'Only received returns can be closed'; end if;
    update public.return_requests set status='closed',decision_note=case when v_reason is null then decision_note else concat_ws(E'\n',nullif(decision_note,''),'Closed: '||v_reason) end where id=v_return.id;
  end if;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values(auth.uid(),'return_'||p_action,'return_request',v_return.id,
    coalesce(v_reason,'Return workflow action'),
    pg_catalog.jsonb_build_object('status',v_return.status),
    pg_catalog.jsonb_build_object('status',case when p_action='approve' then 'approved' when p_action='reject' then 'rejected' when p_action='receive' then 'received' else 'closed' end,'restocked_lines',v_restocked),
    auth.uid());
  return pg_catalog.jsonb_build_object('id',v_return.id,'return_number',v_return.return_number,
    'status',case when p_action='approve' then 'approved' when p_action='reject' then 'rejected' when p_action='receive' then 'received' else 'closed' end,
    'restocked_lines',v_restocked);
end;
$function$;


revoke execute on function public.tec_create_return_request(uuid,text,text,jsonb) from public;
revoke execute on function public.tec_create_return_request(uuid,text,text,jsonb) from anon;
grant execute on function public.tec_create_return_request(uuid,text,text,jsonb) to authenticated;
revoke execute on function public.tec_process_return_request(uuid,text,text,jsonb) from public;
revoke execute on function public.tec_process_return_request(uuid,text,text,jsonb) from anon;
grant execute on function public.tec_process_return_request(uuid,text,text,jsonb) to authenticated;
