-- Keep raw stock, recipe formulae and production consumption owner-only.
drop policy if exists tec_production_owner_raw on public.raw_materials;
drop policy if exists tec_production_owner_recipes on public.production_recipes;
drop policy if exists tec_production_owner_recipe_lines on public.production_recipe_lines;
drop policy if exists tec_production_owner_consumption on public.production_consumption;
drop policy if exists tec_production_owner_stock_movements_read on public.stock_movements;
drop policy if exists tec_production_owner_stock_movements_insert on public.stock_movements;

-- Replace the legacy role allowance with an explicit owner-only check in each
-- production RPC, so API callers cannot bypass the screen restrictions.
do $migration$
declare
  v_function record;
  v_definition text;
  v_updated text;
begin
  for v_function in
    select p.oid, p.proname
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname=any(array[
         'tec_complete_production',
         'tec_owner_complete_manual_production',
         'tec_save_production_recipe',
         'tec_set_production_transfer_price'
       ])
  loop
    v_definition:=pg_catalog.pg_get_functiondef(v_function.oid);
    v_updated:=pg_catalog.replace(
      v_definition,
      'if not (private.is_owner() or private.current_app_role() = ''production_owner'') then',
      'if not coalesce(private.is_owner(), false) then'
    );
    if v_updated=v_definition then
      raise exception 'Expected production-owner permission check was not found in %',v_function.proname;
    end if;
    execute v_updated;
  end loop;
end
$migration$;
