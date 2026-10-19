CREATE OR REPLACE FUNCTION public.tec_partnership_financial_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_month date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  v_sales_today numeric(14,2) := 0;
  v_sales_month numeric(14,2) := 0;
  v_cogs_today numeric(14,2) := 0;
  v_cogs_month numeric(14,2) := 0;
  v_exp_today numeric(14,2) := 0;
  v_exp_month numeric(14,2) := 0;
  v_received_today numeric(14,2) := 0;
  v_received_month numeric(14,2) := 0;
  v_outstanding numeric(14,2) := 0;
  v_unknown_today integer := 0;
  v_unknown_month integer := 0;
  v_unknown_sales_today numeric(14,2) := 0;
  v_unknown_sales_month numeric(14,2) := 0;
  v_net_today numeric(14,2);
  v_net_month numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
  IF coalesce(private.current_app_role(), '') <> 'co_owner' THEN RAISE EXCEPTION 'Partnership permission required'; END IF;

  SELECT coalesce(sum(b.goods_total),0) INTO v_sales_today FROM public.bills b
  WHERE b.status <> 'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date = v_today;
  SELECT coalesce(sum(b.goods_total),0) INTO v_sales_month FROM public.bills b
  WHERE b.status <> 'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date >= v_month;

  -- Dispatch snapshots are the partnership's agreed transfer purchase prices.
  -- The owner-only manufacturing cost ledger is intentionally not consulted.
  SELECT coalesce(sum(abs(sm.quantity_delta)*sm.unit_cost_snapshot),0) INTO v_cogs_today
  FROM public.stock_movements sm JOIN public.bills b ON b.outlet_order_id=sm.outlet_order_id
  WHERE sm.movement_type='outlet_dispatch' AND b.status<>'cancelled'
    AND (b.issued_at at time zone 'Asia/Kolkata')::date=v_today AND sm.unit_cost_snapshot IS NOT NULL;
  SELECT coalesce(sum(abs(sm.quantity_delta)*sm.unit_cost_snapshot),0) INTO v_cogs_month
  FROM public.stock_movements sm JOIN public.bills b ON b.outlet_order_id=sm.outlet_order_id
  WHERE sm.movement_type='outlet_dispatch' AND b.status<>'cancelled'
    AND (b.issued_at at time zone 'Asia/Kolkata')::date>=v_month AND sm.unit_cost_snapshot IS NOT NULL;
  SELECT count(*),coalesce(sum(b.goods_total),0) INTO v_unknown_today,v_unknown_sales_today
  FROM public.bills b WHERE b.status<>'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date=v_today
    AND (NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.movement_type='outlet_dispatch' AND sm.outlet_order_id=b.outlet_order_id)
      OR EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.movement_type='outlet_dispatch' AND sm.outlet_order_id=b.outlet_order_id AND sm.unit_cost_snapshot IS NULL));
  SELECT count(*),coalesce(sum(b.goods_total),0) INTO v_unknown_month,v_unknown_sales_month
  FROM public.bills b WHERE b.status<>'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date>=v_month
    AND (NOT EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.movement_type='outlet_dispatch' AND sm.outlet_order_id=b.outlet_order_id)
      OR EXISTS (SELECT 1 FROM public.stock_movements sm WHERE sm.movement_type='outlet_dispatch' AND sm.outlet_order_id=b.outlet_order_id AND sm.unit_cost_snapshot IS NULL));

  SELECT coalesce(sum(e.amount),0) INTO v_exp_today FROM public.main_kitchen_expenses e WHERE e.expense_date=v_today;
  SELECT coalesce(sum(e.amount),0) INTO v_exp_month FROM public.main_kitchen_expenses e WHERE e.expense_date>=v_month;
  SELECT coalesce(sum(p.amount),0) INTO v_received_today FROM public.payments p
  WHERE p.payment_type='outlet_receipt' AND p.status='approved' AND (coalesce(p.paid_at,p.created_at) at time zone 'Asia/Kolkata')::date=v_today;
  SELECT coalesce(sum(p.amount),0) INTO v_received_month FROM public.payments p
  WHERE p.payment_type='outlet_receipt' AND p.status='approved' AND (coalesce(p.paid_at,p.created_at) at time zone 'Asia/Kolkata')::date>=v_month;
  SELECT coalesce(sum(greatest(0,b.grand_total-b.paid_total)),0) INTO v_outstanding FROM public.bills b WHERE b.status<>'cancelled';

  v_net_today := CASE WHEN v_unknown_today=0 THEN v_sales_today-v_cogs_today-v_exp_today ELSE NULL END;
  v_net_month := CASE WHEN v_unknown_month=0 THEN v_sales_month-v_cogs_month-v_exp_month ELSE NULL END;
  RETURN jsonb_build_object(
    'as_of_date',v_today,'month_start',v_month,
    'today_sales',v_sales_today,'today_cost_of_goods',v_cogs_today,'today_expenses',v_exp_today,
    'today_net_profit',v_net_today,'today_owner_share',CASE WHEN v_net_today IS NULL THEN NULL ELSE v_net_today/2 END,
    'today_co_owner_share',CASE WHEN v_net_today IS NULL THEN NULL ELSE v_net_today/2 END,
    'today_received',v_received_today,'today_cost_coverage_complete',v_unknown_today=0,
    'today_unknown_cost_bills',v_unknown_today,'today_unknown_cost_sales',v_unknown_sales_today,
    'month_sales',v_sales_month,'month_cost_of_goods',v_cogs_month,'month_expenses',v_exp_month,
    'month_net_profit',v_net_month,'month_owner_share',CASE WHEN v_net_month IS NULL THEN NULL ELSE v_net_month/2 END,
    'month_co_owner_share',CASE WHEN v_net_month IS NULL THEN NULL ELSE v_net_month/2 END,
    'month_received',v_received_month,'outstanding',v_outstanding,'month_cost_coverage_complete',v_unknown_month=0,
    'month_unknown_cost_bills',v_unknown_month,'month_unknown_cost_sales',v_unknown_sales_month
  );
END;
$function$;
