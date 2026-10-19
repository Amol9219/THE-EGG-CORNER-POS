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
  v_cost_row record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
  IF coalesce(private.current_app_role(), '') <> 'co_owner' THEN RAISE EXCEPTION 'Partnership permission required'; END IF;

  SELECT coalesce(sum(b.goods_total),0) INTO v_sales_today
  FROM public.bills b
  WHERE b.status <> 'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date = v_today;
  SELECT coalesce(sum(b.goods_total),0) INTO v_sales_month
  FROM public.bills b
  WHERE b.status <> 'cancelled' AND (b.issued_at at time zone 'Asia/Kolkata')::date >= v_month;

  -- Use the partnership's transfer purchase price for its cost of goods.
  -- This deliberately never reads raw-material costs or manufacturing profit.
  FOR v_cost_row IN WITH receipts AS (
    SELECT t.product_id, t.quantity, t.unit_price,
      coalesce(sum(t.quantity) OVER (PARTITION BY t.product_id ORDER BY t.transfer_date,t.created_at,t.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS qty_before
    FROM public.main_kitchen_transfers t
    WHERE t.status = 'transferred'
  ), receipt_ranges AS (
    SELECT product_id, unit_price, qty_before, qty_before + quantity AS qty_after FROM receipts
  ), dispatches AS (
    SELECT sm.id, sm.product_id, abs(sm.quantity_delta) AS quantity, sm.created_at,
      b.id AS bill_id, b.issued_at, b.goods_total
    FROM public.stock_movements sm
    JOIN public.bills b ON b.outlet_order_id = sm.outlet_order_id AND b.status <> 'cancelled'
    WHERE sm.movement_type = 'outlet_dispatch' AND sm.product_id IS NOT NULL AND sm.quantity_delta < 0
  ), sales AS (
    SELECT d.*,
      coalesce(sum(d.quantity) OVER (PARTITION BY d.product_id ORDER BY d.issued_at,d.created_at,d.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS qty_before
    FROM dispatches d
  ), sale_ranges AS (
    SELECT *, qty_before + quantity AS qty_after FROM sales
  ), allocations AS (
    SELECT s.id AS dispatch_id, s.bill_id, s.issued_at, s.goods_total, s.quantity,
      coalesce(sum(greatest(0, least(r.qty_after,s.qty_after)-greatest(r.qty_before,s.qty_before))),0) AS covered_qty,
      coalesce(sum(greatest(0, least(r.qty_after,s.qty_after)-greatest(r.qty_before,s.qty_before))*r.unit_price),0) AS cogs
    FROM sale_ranges s
    LEFT JOIN receipt_ranges r ON r.product_id = s.product_id
      AND r.qty_after > s.qty_before AND r.qty_before < s.qty_after
    GROUP BY s.id,s.bill_id,s.issued_at,s.goods_total,s.quantity
  ), bill_costs AS (
    SELECT bill_id, max(issued_at) AS issued_at, max(goods_total) AS goods_total,
      sum(quantity) AS sold_qty, sum(covered_qty) AS covered_qty, sum(cogs) AS cogs
    FROM allocations GROUP BY bill_id
  ), coverage AS (
    SELECT b.id AS bill_id, b.issued_at, b.goods_total,
      coalesce(c.sold_qty,0) AS sold_qty, coalesce(c.covered_qty,0) AS covered_qty, coalesce(c.cogs,0) AS cogs
    FROM public.bills b LEFT JOIN bill_costs c ON c.bill_id=b.id
    WHERE b.status <> 'cancelled'
  )
  SELECT
    coalesce(sum(c.cogs) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date=v_today),0) AS cogs_today,
    coalesce(sum(c.cogs) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date>=v_month),0) AS cogs_month,
    count(*) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date=v_today AND (c.sold_qty=0 OR c.covered_qty+0.000001<c.sold_qty)) AS unknown_today,
    count(*) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date>=v_month AND (c.sold_qty=0 OR c.covered_qty+0.000001<c.sold_qty)) AS unknown_month,
    coalesce(sum(c.goods_total) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date=v_today AND (c.sold_qty=0 OR c.covered_qty+0.000001<c.sold_qty)),0) AS unknown_sales_today,
    coalesce(sum(c.goods_total) FILTER (WHERE (c.issued_at at time zone 'Asia/Kolkata')::date>=v_month AND (c.sold_qty=0 OR c.covered_qty+0.000001<c.sold_qty)),0) AS unknown_sales_month
  FROM coverage c
  LOOP
    v_cogs_today := v_cost_row.cogs_today;
    v_cogs_month := v_cost_row.cogs_month;
    v_unknown_today := v_cost_row.unknown_today;
    v_unknown_month := v_cost_row.unknown_month;
    v_unknown_sales_today := v_cost_row.unknown_sales_today;
    v_unknown_sales_month := v_cost_row.unknown_sales_month;
  END LOOP;

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

REVOKE ALL ON FUNCTION public.tec_partnership_financial_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_partnership_financial_summary() TO authenticated;
