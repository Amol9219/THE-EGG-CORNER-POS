-- Partnership-to-Owner masala purchase request workflow.
-- Requests do not move stock until the Owner approves them.
alter table public.main_kitchen_purchase_invoices
  add column if not exists status text not null default 'approved',
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text;

create table if not exists public.main_kitchen_purchase_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_invoice_id uuid not null references public.main_kitchen_purchase_invoices(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  product_name_snapshot text not null,
  quantity numeric not null check (quantity > 0),
  unit text not null,
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

alter table public.main_kitchen_purchase_invoices
  drop constraint if exists main_kitchen_purchase_invoices_status_check;
alter table public.main_kitchen_purchase_invoices
  add constraint main_kitchen_purchase_invoices_status_check
  check (status in ('pending_approval','approved','rejected'));

alter table public.main_kitchen_purchase_invoice_lines enable row level security;
drop policy if exists "Owner and partnership can read purchase invoice lines" on public.main_kitchen_purchase_invoice_lines;
create policy "Owner and partnership can read purchase invoice lines"
on public.main_kitchen_purchase_invoice_lines for select to authenticated
using (
  private.is_owner()
  or exists (
    select 1 from public.main_kitchen_purchase_invoices i
    where i.id = purchase_invoice_id
      and i.created_by = auth.uid()
      and private.current_app_role() = 'co_owner'
  )
);

create or replace function public.tec_submit_main_kitchen_purchase_request(
  p_lines jsonb,
  p_invoice_date date default current_date,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_invoice_id uuid;
  v_invoice_number text;
  v_line jsonb;
  v_product public.products%rowtype;
  v_price numeric(14,2);
  v_qty numeric;
  v_total numeric(14,2) := 0;
  v_count integer := 0;
  v_stock numeric;
  v_raw public.raw_materials%rowtype;
  v_name_norm text;
begin
  if auth.uid() is null or private.current_app_role() <> 'co_owner' then
    raise exception 'Partnership permission required';
  end if;
  if p_invoice_date is null or p_invoice_date > current_date then
    raise exception 'Purchase date is invalid';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 50 then
    raise exception 'Select between 1 and 50 masala items';
  end if;
  if (select count(*) from jsonb_array_elements(p_lines)) <>
     (select count(distinct nullif(value->>'product_id','')::uuid) from jsonb_array_elements(p_lines)) then
    raise exception 'A masala can appear only once on an invoice';
  end if;

  v_invoice_number := 'MKI-' || to_char(p_invoice_date,'YYYYMMDD') || '-' ||
    upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.main_kitchen_purchase_invoices
    (invoice_number, invoice_date, notes, total_amount, created_by, status)
  values (v_invoice_number, p_invoice_date, nullif(btrim(p_notes),''), 0, auth.uid(), 'pending_approval')
  returning id into v_invoice_id;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if nullif(v_line->>'product_id','') is null then raise exception 'Select a valid masala'; end if;
    v_qty := coalesce(nullif(v_line->>'quantity','')::numeric,0);
    if v_qty <= 0 then raise exception 'Every selected masala needs a positive quantity'; end if;

    select * into v_product from public.products
      where id = (v_line->>'product_id')::uuid and is_active = true and product_type = 'finished';
    if not found then raise exception 'Selected masala is unavailable'; end if;

    select transfer_price into v_price from public.production_transfer_prices
      where product_id = v_product.id
        and effective_at < (p_invoice_date::timestamp + interval '1 day')
      order by effective_at desc, created_at desc limit 1;
    if v_price is null then raise exception 'Owner has not set a sale price for %', v_product.name; end if;

    v_stock := coalesce(v_product.current_stock,0);
    v_name_norm := lower(regexp_replace(v_product.name,'[^a-z]','','g'));
    if v_name_norm in ('mirchi','mirachi','namak','katta') then
      select * into v_raw from public.raw_materials r
      where r.is_active = true
        and lower(regexp_replace(r.name,'[^a-z]','','g')) =
          case when v_name_norm in ('mirchi','mirachi') then
            (select lower(regexp_replace(r2.name,'[^a-z]','','g')) from public.raw_materials r2
              where r2.is_active=true and lower(regexp_replace(r2.name,'[^a-z]','','g')) in ('mirchi','mirachi')
              order by case when lower(regexp_replace(r2.name,'[^a-z]','','g'))=v_name_norm then 0 else 1 end limit 1)
          else v_name_norm end
      limit 1;
      if found and coalesce(v_raw.current_stock,0) >= 0 then v_stock := v_raw.current_stock; end if;
    end if;
    if v_qty > v_stock then raise exception 'Requested quantity for % exceeds current Owner stock', v_product.name; end if;

    insert into public.main_kitchen_purchase_invoice_lines
      (purchase_invoice_id,product_id,product_name_snapshot,quantity,unit,unit_price,line_total)
    values (v_invoice_id,v_product.id,v_product.name,v_qty,v_product.unit,round(v_price,2),round(v_qty*v_price,2));
    v_total := v_total + round(v_qty*v_price,2);
    v_count := v_count + 1;
  end loop;

  update public.main_kitchen_purchase_invoices set total_amount=round(v_total,2) where id=v_invoice_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,after_data)
  values(auth.uid(),'main_kitchen_purchase_request_submitted','main_kitchen_purchase_invoice',v_invoice_id,
    'Partnership purchase request awaiting Owner approval',
    jsonb_build_object('invoice_number',v_invoice_number,'status','pending_approval','line_count',v_count,'total_amount',round(v_total,2)));
  return jsonb_build_object('id',v_invoice_id,'invoice_number',v_invoice_number,'status','pending_approval','line_count',v_count,'total_amount',round(v_total,2));
end;
$function$;

create or replace function public.tec_review_main_kitchen_purchase_request(
  p_invoice_id uuid,
  p_decision text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_invoice public.main_kitchen_purchase_invoices%rowtype;
  v_line public.main_kitchen_purchase_invoice_lines%rowtype;
  v_transfer jsonb;
  v_transfer_id uuid;
  v_count integer := 0;
begin
  if auth.uid() is null or not private.is_owner() then
    raise exception 'Owner permission required';
  end if;
  if p_decision not in ('approve','reject') then raise exception 'Decision must be approve or reject'; end if;
  if p_decision='reject' and nullif(btrim(p_note),'') is null then raise exception 'Please provide a rejection reason'; end if;

  select * into v_invoice from public.main_kitchen_purchase_invoices
    where id=p_invoice_id for update;
  if not found then raise exception 'Purchase request not found'; end if;
  if v_invoice.status <> 'pending_approval' then raise exception 'This request has already been reviewed'; end if;
  if not exists(select 1 from public.main_kitchen_purchase_invoice_lines where purchase_invoice_id=v_invoice.id) then
    raise exception 'Purchase request has no line items';
  end if;

  if p_decision='approve' then
    for v_line in
      select * from public.main_kitchen_purchase_invoice_lines
      where purchase_invoice_id=v_invoice.id order by created_at,id
    loop
      v_transfer := public.tec_record_main_kitchen_transfer(
        v_line.product_id, v_line.quantity, v_line.unit_price, v_invoice.invoice_date,
        concat('Approved Partnership purchase ',v_invoice.invoice_number,
          case when nullif(btrim(v_invoice.notes),'') is not null then ' · '||btrim(v_invoice.notes) else '' end)
      );
      v_transfer_id := (v_transfer->>'id')::uuid;
      update public.main_kitchen_transfers set purchase_invoice_id=v_invoice.id where id=v_transfer_id;
      v_count := v_count + 1;
    end loop;
    update public.main_kitchen_purchase_invoices
      set status='approved', reviewed_by=auth.uid(), reviewed_at=now(), review_note=nullif(btrim(p_note),'')
      where id=v_invoice.id;
  else
    update public.main_kitchen_purchase_invoices
      set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), review_note=nullif(btrim(p_note),'')
      where id=v_invoice.id;
  end if;

  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,reason,before_data,after_data,approved_by)
  values(auth.uid(),'main_kitchen_purchase_request_'||p_decision,'main_kitchen_purchase_invoice',v_invoice.id,
    coalesce(nullif(btrim(p_note),''),'Owner reviewed Partnership purchase request'),
    jsonb_build_object('status','pending_approval'),
    jsonb_build_object('status',case when p_decision='approve' then 'approved' else 'rejected' end,'line_count',v_count),
    case when p_decision='approve' then auth.uid() else null end);
  return jsonb_build_object('id',v_invoice.id,'invoice_number',v_invoice.invoice_number,
    'status',case when p_decision='approve' then 'approved' else 'rejected' end,'transfers_created',v_count);
end;
$function$;

revoke execute on function public.tec_submit_main_kitchen_purchase_request(jsonb,date,text) from public, anon;
grant execute on function public.tec_submit_main_kitchen_purchase_request(jsonb,date,text) to authenticated;
revoke execute on function public.tec_review_main_kitchen_purchase_request(uuid,text,text) from public, anon;
grant execute on function public.tec_review_main_kitchen_purchase_request(uuid,text,text) to authenticated;
