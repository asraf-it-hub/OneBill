-- OneBill Paper Receipts Schema and Sync Migration

create table if not exists public.paper_receipts (
  id uuid primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  receipt_date timestamptz not null,
  image_url text,
  notes text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);

create index if not exists paper_receipts_business_id_idx on public.paper_receipts(business_id);
create index if not exists paper_receipts_customer_id_idx on public.paper_receipts(customer_id);

alter table public.paper_receipts enable row level security;

drop policy if exists "Owners manage their paper receipts" on public.paper_receipts;
create policy "Owners manage their paper receipts"
on public.paper_receipts for all
using (
  exists (
    select 1 from public.businesses b
    where b.id = paper_receipts.business_id
    and b.owner_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.businesses b
    where b.id = paper_receipts.business_id
    and b.owner_id = auth.uid()
  )
);
