-- Harden privileged RPC access. This migration does not modify business rows.
-- Financial RPCs are authenticated-only and fail closed for missing/unknown roles.
CREATE OR REPLACE FUNCTION public.tec_main_kitchen_financial_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_today date := (now() at time zone 'Asia/Kolkata')::date;
 v_month date := date_trunc('month',(now() at time zone 'Asia/Kolkata'))::date;
 v_sales_today numeric(14,2);
 v_sales_month numeric(14,2);
 v_cogs_today numeric(14,2);
 v_cogs_month numeric(14,2);
 v_exp_today numeric(14,2);
 v_exp_month numeric(14,2);
 v_receipts_today numeric(14,2);
 v_receipts_month numeric(14,2);
 v_outstanding numeric(14,2);
 v_net_today numeric(14,2);
 v_net_month numeric(14,2);
 v_unknown_today integer;
 v_unknown_month integer;
 v_unknown_sales_today numeric(14,2);
 v_unknown_sales_month numeric(14,2);
begin
 if auth.uid() is null then raise exception 'Sign-in required'; end if;
 if coalesce(private.current_app_role(), '') <> 'owner' then raise exception 'Owner permission required'; end if;
 select coalesce(sum(goods_total),0) into v_sales_today from public.bills where status<>'cancelled' and (issued_at at time zone 'Asia/Kolkata')::date=v_today;
 select coalesce(sum(goods_total),0) into v_sales_month from public.bills where status<>'cancelled' and (issued_at at time zone 'Asia/Kolkata')::date>=v_month;
 select coalesce(sum(abs(sm.quantity_delta)*coalesce(sm.unit_cost_snapshot,0)),0) into v_cogs_today
  from public.stock_movements sm join public.bills b on b.outlet_order_id=sm.outlet_order_id
  where sm.movement_type='outlet_dispatch' and b.status<>'cancelled' and (b.issued_at at time zone 'Asia/Kolkata')::date=v_today;
 select coalesce(sum(abs(sm.quantity_delta)*coalesce(sm.unit_cost_snapshot,0)),0) into v_cogs_month
  from public.stock_movements sm join public.bills b on b.outlet_order_id=sm.outlet_order_id
  where sm.movement_type='outlet_dispatch' and b.status<>'cancelled' and (b.issued_at at time zone 'Asia/Kolkata')::date>=v_month;
 select coalesce(sum(amount),0) into v_exp_today from public.main_kitchen_expenses where expense_date=v_today;
 select coalesce(sum(amount),0) into v_exp_month from public.main_kitchen_expenses where expense_date>=v_month;
 select coalesce(sum(amount),0) into v_receipts_today from public.payments where payment_type='outlet_receipt' and status='approved' and (coalesce(paid_at,created_at) at time zone 'Asia/Kolkata')::date=v_today;
 select coalesce(sum(amount),0) into v_receipts_month from public.payments where payment_type='outlet_receipt' and status='approved' and (coalesce(paid_at,created_at) at time zone 'Asia/Kolkata')::date>=v_month;
 select coalesce(sum(greatest(0,grand_total-paid_total)),0) into v_outstanding from public.bills where status<>'cancelled';
 select count(*),coalesce(sum(b.goods_total),0) into v_unknown_today,v_unknown_sales_today from public.bills b
  where b.status<>'cancelled' and (b.issued_at at time zone 'Asia/Kolkata')::date=v_today
   and (exists(select 1 from public.stock_movements sm where sm.movement_type='outlet_dispatch' and (sm.outlet_order_id=b.outlet_order_id or sm.reference_id=b.outlet_order_id) and sm.unit_cost_snapshot is null)
    or not exists(select 1 from public.stock_movements sm where sm.movement_type='outlet_dispatch' and sm.outlet_order_id=b.outlet_order_id and sm.unit_cost_snapshot is not null));
 select count(*),coalesce(sum(b.goods_total),0) into v_unknown_month,v_unknown_sales_month from public.bills b
  where b.status<>'cancelled' and (b.issued_at at time zone 'Asia/Kolkata')::date>=v_month
   and (exists(select 1 from public.stock_movements sm where sm.movement_type='outlet_dispatch' and (sm.outlet_order_id=b.outlet_order_id or sm.reference_id=b.outlet_order_id) and sm.unit_cost_snapshot is null)
    or not exists(select 1 from public.stock_movements sm where sm.movement_type='outlet_dispatch' and sm.outlet_order_id=b.outlet_order_id and sm.unit_cost_snapshot is not null));
 v_net_today:=case when v_unknown_today=0 then v_sales_today-v_cogs_today-v_exp_today else null end;
 v_net_month:=case when v_unknown_month=0 then v_sales_month-v_cogs_month-v_exp_month else null end;
 return jsonb_build_object(
  'as_of_date',v_today,'month_start',v_month,
  'today_sales',v_sales_today,'today_cost_of_goods',v_cogs_today,'today_expenses',v_exp_today,'today_net_profit',v_net_today,'today_owner_share',case when v_net_today is null then null else v_net_today/2 end,'today_co_owner_share',case when v_net_today is null then null else v_net_today/2 end,'today_received',v_receipts_today,'today_cost_coverage_complete',v_unknown_today=0,'today_unknown_cost_bills',v_unknown_today,'today_unknown_cost_sales',v_unknown_sales_today,
  'month_sales',v_sales_month,'month_cost_of_goods',v_cogs_month,'month_expenses',v_exp_month,'month_net_profit',v_net_month,'month_owner_share',case when v_net_month is null then null else v_net_month/2 end,'month_co_owner_share',case when v_net_month is null then null else v_net_month/2 end,'month_received',v_receipts_month,'outstanding',v_outstanding,'month_cost_coverage_complete',v_unknown_month=0,'month_unknown_cost_bills',v_unknown_month,'month_unknown_cost_sales',v_unknown_sales_month
 );
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_outlet_food_financial_summary(p_outlet_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_sales numeric(14,2);
 v_expenses numeric(14,2);
 v_days integer;
begin
 if auth.uid() is null then raise exception 'Sign-in required'; end if;
 if not coalesce(private.is_owner(), false) and not (coalesce(private.current_app_role(), '')='outlet' and p_outlet_id is not null and p_outlet_id=private.current_outlet_id()) then raise exception 'You can only view your own Outlet food financials'; end if;
 if p_outlet_id is null then raise exception 'Select an Outlet'; end if;
 select coalesce(sum(amount),0) into v_sales from public.outlet_food_sales where outlet_id=p_outlet_id and (p_from is null or sale_date>=p_from) and (p_to is null or sale_date<=p_to);
 select coalesce(sum(amount),0) into v_expenses from public.outlet_business_expenses where outlet_id=p_outlet_id and (p_from is null or expense_date>=p_from) and (p_to is null or expense_date<=p_to);
 select count(distinct sale_date) into v_days from public.outlet_food_sales where outlet_id=p_outlet_id and (p_from is null or sale_date>=p_from) and (p_to is null or sale_date<=p_to);
 return jsonb_build_object('outlet_id',p_outlet_id,'from_date',p_from,'to_date',p_to,'food_sales',v_sales,'outlet_expenses',v_expenses,'food_profit',v_sales-v_expenses,'sales_days',v_days);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_owner_manufacturing_profit_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_today date := (now() at time zone 'Asia/Kolkata')::date;
 v_month date := date_trunc('month',(now() at time zone 'Asia/Kolkata'))::date;
 v_revenue_today numeric(14,2);
 v_revenue_month numeric(14,2);
 v_cost_today numeric(14,2);
 v_cost_month numeric(14,2);
 v_known_revenue_today numeric(14,2);
 v_known_revenue_month numeric(14,2);
 v_unknown_today integer;
 v_unknown_month integer;
begin
 if auth.uid() is null then raise exception 'Sign-in required'; end if;
 if not coalesce(private.is_owner(), false) and coalesce(private.current_app_role(), '') <> 'production_owner' then raise exception 'Owner permission required'; end if;
 select coalesce(sum(t.total_amount),0) into v_revenue_today from public.main_kitchen_transfers t where t.status='transferred' and t.transfer_date=v_today;
 select coalesce(sum(t.total_amount),0) into v_revenue_month from public.main_kitchen_transfers t where t.status='transferred' and t.transfer_date>=v_month;
 select coalesce(sum(t.total_amount),0) into v_known_revenue_today from public.main_kitchen_transfers t join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and c.source_cost_known and t.transfer_date=v_today;
 select coalesce(sum(t.total_amount),0) into v_known_revenue_month from public.main_kitchen_transfers t join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and c.source_cost_known and t.transfer_date>=v_month;
 select coalesce(sum(c.source_cost_total),0) into v_cost_today from public.main_kitchen_transfers t join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and c.source_cost_known and t.transfer_date=v_today;
 select coalesce(sum(c.source_cost_total),0) into v_cost_month from public.main_kitchen_transfers t join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and c.source_cost_known and t.transfer_date>=v_month;
 select count(*) into v_unknown_today from public.main_kitchen_transfers t left join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and t.transfer_date=v_today and coalesce(c.source_cost_known,false)=false;
 select count(*) into v_unknown_month from public.main_kitchen_transfers t left join public.owner_transfer_costs c on c.transfer_id=t.id where t.status='transferred' and t.transfer_date>=v_month and coalesce(c.source_cost_known,false)=false;
 return jsonb_build_object('today_transfer_revenue',v_revenue_today,'today_known_production_cost',v_cost_today,'today_known_cost_transfer_revenue',v_known_revenue_today,'today_known_manufacturing_profit',v_known_revenue_today-v_cost_today,'today_unknown_cost_transfers',v_unknown_today,'month_transfer_revenue',v_revenue_month,'month_known_production_cost',v_cost_month,'month_known_cost_transfer_revenue',v_known_revenue_month,'month_known_manufacturing_profit',v_known_revenue_month-v_cost_month,'month_unknown_cost_transfers',v_unknown_month);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tec_record_product_stock_out(p_product_id uuid, p_quantity numeric, p_movement_type text DEFAULT 'sale_out'::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_product public.products%rowtype;
  v_movement_id uuid;
  v_type text;
begin
  if auth.uid() is null then raise exception 'Sign-in required'; end if;
  if not coalesce(private.is_owner(), false) then raise exception 'Owner permission required'; end if;
  if p_product_id is null then raise exception 'Product required'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Quantity must be greater than zero'; end if;
  v_type := coalesce(nullif(pg_catalog.btrim(p_movement_type),''),'sale_out');
  if v_type not in ('sale_out','wastage_out','internal_use') then raise exception 'Invalid stock-out type'; end if;
  select * into v_product from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Active product not found'; end if;
  if coalesce(v_product.current_stock,0) < p_quantity then
    raise exception 'Insufficient stock for %; available %, requested %',v_product.name,v_product.current_stock,p_quantity;
  end if;
  update public.products
    set current_stock=current_stock-p_quantity,
        updated_at=now(),
        status=case when current_stock-p_quantity<=0 then 'Out of Stock'
                    when current_stock-p_quantity<=coalesce(min_stock,0) then 'Low Stock'
                    else 'Available' end
    where id=v_product.id;
  insert into public.stock_movements(item_kind,product_id,movement_type,quantity_delta,unit,reference_type,reason,created_by,approved_by)
    values('product',v_product.id,v_type,-p_quantity,v_product.unit,'manual_stock_out',
      nullif(pg_catalog.btrim(p_reason),''),auth.uid(),auth.uid())
    returning id into v_movement_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data,approved_by)
    values(auth.uid(),'product_stock_out_recorded','stock_movement',v_movement_id,
      coalesce(nullif(pg_catalog.btrim(p_reason),''),v_type),
      pg_catalog.jsonb_build_object('product_id',v_product.id,'product_name',v_product.name,'quantity',p_quantity,'unit',v_product.unit,'movement_type',v_type),auth.uid());
  return pg_catalog.jsonb_build_object('movement_id',v_movement_id,'product_id',v_product.id,
    'product_name',v_product.name,'quantity',p_quantity,'unit',v_product.unit,'movement_type',v_type,
    'current_stock',v_product.current_stock-p_quantity);
end;
$function$;
REVOKE ALL ON FUNCTION public.tec_main_kitchen_financial_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_main_kitchen_financial_summary() TO authenticated;

REVOKE ALL ON FUNCTION public.tec_outlet_food_financial_summary(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_outlet_food_financial_summary(uuid, date, date) TO authenticated;

REVOKE ALL ON FUNCTION public.tec_owner_manufacturing_profit_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_owner_manufacturing_profit_summary() TO authenticated;

REVOKE ALL ON FUNCTION public.tec_record_product_stock_out(uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_record_product_stock_out(uuid, numeric, text, text) TO authenticated;

-- The current app calls the five-argument payment RPC, which validates and stores
-- customer details when payment_method = credit. Disable the legacy overload.
REVOKE ALL ON FUNCTION public.tec_restaurant_record_payment(uuid, numeric, text) FROM PUBLIC, anon, authenticated;

DO $verify$
BEGIN
  IF has_function_privilege('anon', 'public.tec_main_kitchen_financial_summary()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.tec_outlet_food_financial_summary(uuid,date,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.tec_owner_manufacturing_profit_summary()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.tec_record_product_stock_out(uuid,numeric,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous access remains on a protected RPC';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.tec_main_kitchen_financial_summary()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.tec_outlet_food_financial_summary(uuid,date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.tec_owner_manufacturing_profit_summary()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.tec_record_product_stock_out(uuid,numeric,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated RPC access was not preserved';
  END IF;
  IF has_function_privilege('authenticated', 'public.tec_restaurant_record_payment(uuid,numeric,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Legacy three-argument payment RPC is still callable';
  END IF;
END;
$verify$;