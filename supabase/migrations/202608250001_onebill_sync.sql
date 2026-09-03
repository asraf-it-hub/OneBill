-- OneBill cloud recovery and sync layer.
-- SQLite/Drift remains the source of immediate application state. This schema
-- stores authenticated account data and idempotent, auditable sync operations.

create table if not exists public.businesses (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  owner_name text not null,
  business_type text,
  phone text,
  email text,
  address text,
  upi_id text,
  preferred_language text not null default 'en' check (preferred_language in ('en', 'te')),
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);

create index if not exists businesses_owner_id_idx on public.businesses(owner_id);

-- Immutable operation receipt: operation_id is the idempotency key. The cloud
-- never creates a second financial event if a device safely retries a request.
create table if not exists public.sync_operations (
  operation_id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid references public.businesses(id),
  entity_type text not null,
  entity_id uuid not null,
  operation_type text not null,
  payload jsonb not null,
  device_id uuid not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now()
);

create index if not exists sync_operations_business_received_idx on public.sync_operations(business_id, received_at);

alter table public.businesses enable row level security;
alter table public.sync_operations enable row level security;

drop policy if exists "Owners manage their businesses" on public.businesses;
create policy "Owners manage their businesses"
on public.businesses for all
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

drop policy if exists "Owners read their own operation history" on public.sync_operations;
create policy "Owners read their own operation history"
on public.sync_operations for select
using (owner_id = auth.uid());

-- Clients submit operations through a server-side endpoint or RPC that verifies
-- business ownership, validates payloads, and inserts by operation_id. Direct
-- client inserts into sync_operations are intentionally not granted here.
