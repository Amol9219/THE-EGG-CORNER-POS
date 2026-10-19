create index if not exists production_batches_production_run_id_idx
  on public.production_batches(production_run_id)
  where production_run_id is not null;
create index if not exists production_consumption_production_run_id_idx
  on public.production_consumption(production_run_id)
  where production_run_id is not null;
create index if not exists production_runs_created_by_idx
  on public.production_runs(created_by)
  where created_by is not null;
