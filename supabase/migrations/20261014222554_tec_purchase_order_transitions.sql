-- Audited, transactional purchase-order status changes.
-- SECURITY INVOKER keeps caller permissions and RLS active.

CREATE OR REPLACE FUNCTION public.tec_transition_purchase_order(p_purchase_order_id uuid, p_action text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_po public.purchase_orders%rowtype;
  v_new_status text;
  v_reason text;
begin
  if auth.uid() is null then
    raise exception 'Sign-in required';
  end if;
  if not private.is_owner() then
    raise exception 'Owner permission required';
  end if;
  if p_action not in ('submit', 'approve', 'cancel') then
    raise exception 'Unsupported purchase order action';
  end if;

  select po.* into v_po
    from public.purchase_orders po
   where po.id = p_purchase_order_id
   for update;
  if not found then
    raise exception 'Purchase order was not found';
  end if;

  v_reason := nullif(pg_catalog.btrim(p_reason), '');
  if p_action = 'submit' then
    if v_po.status <> 'draft' then
      raise exception 'Only draft purchase orders can be submitted';
    end if;
    v_new_status := 'pending_approval';
    update public.purchase_orders set status = v_new_status where id = v_po.id;
  elsif p_action = 'approve' then
    if v_po.status <> 'pending_approval' then
      raise exception 'Only purchase orders pending approval can be approved';
    end if;
    v_new_status := 'approved';
    update public.purchase_orders
       set status = v_new_status, approved_by = auth.uid(), approved_at = now()
     where id = v_po.id;
  else
    if v_po.status not in ('draft', 'pending_approval') then
      raise exception 'Only draft or pending-approval purchase orders can be cancelled';
    end if;
    if v_reason is null then
      raise exception 'A cancellation reason is required';
    end if;
    v_new_status := 'cancelled';
    update public.purchase_orders
       set status = v_new_status, cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = v_reason
     where id = v_po.id;
  end if;

  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, reason, before_data, after_data, approved_by)
  values (
    auth.uid(), 'purchase_order_' || p_action, 'purchase_order', v_po.id,
    coalesce(v_reason, 'Status changed by Owner'),
    pg_catalog.jsonb_build_object('status', v_po.status, 'po_number', v_po.po_number),
    pg_catalog.jsonb_build_object('status', v_new_status, 'po_number', v_po.po_number),
    case when p_action = 'approve' then auth.uid() else null end
  );

  return pg_catalog.jsonb_build_object('id', v_po.id, 'po_number', v_po.po_number, 'status', v_new_status);
end;
$function$;

revoke execute on function public.tec_transition_purchase_order(uuid, text, text) from public;
revoke execute on function public.tec_transition_purchase_order(uuid, text, text) from anon;
grant execute on function public.tec_transition_purchase_order(uuid, text, text) to authenticated;
