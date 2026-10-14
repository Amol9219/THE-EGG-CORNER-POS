create table if not exists public.business_settings (
  id smallint primary key default 1 check (id=1),
  business_name text not null default 'TEC Masala Business',
  address text,
  mobile text,
  gstin text,
  logo_path text,
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.business_settings enable row level security;
grant select,insert,update on public.business_settings to authenticated;
drop policy if exists tec_owner_only on public.business_settings;
create policy tec_owner_only on public.business_settings
  for all to authenticated using (private.is_owner()) with check (private.is_owner());
insert into public.business_settings(id,business_name)
values(1,'TEC Masala Business')
on conflict(id) do nothing;
