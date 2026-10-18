-- Restrict direct client writes to transaction-bearing restaurant tables.
-- All order creation, status transitions, billing and payment updates go through validated RPCs.
CREATE OR REPLACE FUNCTION public.tec_restaurant_transition_order(p_order_id uuid, p_next_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text;
  v_outlet uuid;
  v_order public.restaurant_orders%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign-in required';
  END IF;

  v_role := private.current_app_role();
  v_outlet := private.current_outlet_id();
  IF coalesce(v_role, '') <> 'outlet' OR v_outlet IS NULL THEN
    RAISE EXCEPTION 'Outlet role required';
  END IF;

  IF p_next_status IS NULL OR p_next_status NOT IN ('preparing', 'ready', 'served') THEN
    RAISE EXCEPTION 'Invalid next order status';
  END IF;

  SELECT o.* INTO v_order
  FROM public.restaurant_orders AS o
  WHERE o.id = p_order_id AND o.outlet_id = v_outlet
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order was not found for this Outlet';
  END IF;

  IF NOT (
    (v_order.status = 'pending' AND p_next_status = 'preparing')
    OR (v_order.status = 'preparing' AND p_next_status = 'ready')
    OR (v_order.status = 'ready' AND p_next_status = 'served')
  ) THEN
    RAISE EXCEPTION 'Invalid order status transition: % to %', v_order.status, p_next_status;
  END IF;

  UPDATE public.restaurant_orders
  SET status = p_next_status,
      ready_at = CASE WHEN p_next_status = 'ready' THEN now() ELSE ready_at END,
      served_at = CASE WHEN p_next_status = 'served' THEN now() ELSE served_at END,
      updated_at = now()
  WHERE id = v_order.id AND outlet_id = v_outlet
  RETURNING * INTO v_order;

  RETURN pg_catalog.jsonb_build_object(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'status', v_order.status,
    'ready_at', v_order.ready_at,
    'served_at', v_order.served_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.tec_restaurant_transition_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tec_restaurant_transition_order(uuid, text) TO authenticated;

REVOKE ALL PRIVILEGES ON TABLE
  public.restaurant_orders,
  public.restaurant_order_items,
  public.restaurant_bills,
  public.restaurant_bill_payments
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE
  public.restaurant_orders,
  public.restaurant_order_items,
  public.restaurant_bills,
  public.restaurant_bill_payments
TO authenticated;

DO $verify$
BEGIN
  IF has_function_privilege('anon', 'public.tec_restaurant_transition_order(uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.tec_restaurant_transition_order(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Order transition RPC grants are incorrect';
  END IF;

  IF NOT has_table_privilege('authenticated', 'public.restaurant_orders', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.restaurant_order_items', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.restaurant_bills', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.restaurant_bill_payments', 'SELECT') THEN
    RAISE EXCEPTION 'Authenticated read access was not preserved';
  END IF;

  IF has_table_privilege('authenticated', 'public.restaurant_orders', 'INSERT')
     OR has_table_privilege('authenticated', 'public.restaurant_orders', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.restaurant_orders', 'DELETE')
     OR has_table_privilege('authenticated', 'public.restaurant_order_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.restaurant_order_items', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.restaurant_order_items', 'DELETE')
     OR has_table_privilege('authenticated', 'public.restaurant_bills', 'INSERT')
     OR has_table_privilege('authenticated', 'public.restaurant_bills', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.restaurant_bills', 'DELETE')
     OR has_table_privilege('authenticated', 'public.restaurant_bill_payments', 'INSERT')
     OR has_table_privilege('authenticated', 'public.restaurant_bill_payments', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.restaurant_bill_payments', 'DELETE') THEN
    RAISE EXCEPTION 'Direct transaction-table writes remain available';
  END IF;
END;
$verify$;