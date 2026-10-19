-- Keep opening-stock receipt and soft-delete history in the stock movement ledger.
alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check (movement_type = any (array['opening','receipt','production_use','production_output','outlet_dispatch','return_in','adjustment','transfer_out','transfer_in','write_off','reversal','opening_finished_stock']::text[]));

alter table public.stock_movements drop constraint if exists stock_movements_quantity_delta_check;
alter table public.stock_movements add constraint stock_movements_quantity_delta_check
  check (quantity_delta <> 0 or movement_type = 'opening_finished_stock');
