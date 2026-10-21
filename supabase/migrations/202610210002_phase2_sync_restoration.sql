-- Phase 2: complete standalone paper-receipt synchronization and restoration.
-- Receipt images are private storage objects. The database stores only the
-- storage path, never a public URL or image bytes.

-- Phase 2 must run after the baseline sync RPC and Phase 1 security wrapper.
-- Fail early with an actionable message instead of allowing PostgreSQL to
-- compile a wrapper that can only fail later for every non-receipt operation.
do $$
begin
  if to_regprocedure('public.apply_sync_operation(uuid,uuid,jsonb)') is null
     and to_regprocedure('public.apply_sync_operation_phase1(uuid,uuid,jsonb)') is null then
    raise exception using
      message = 'Phase 2 prerequisite missing: deploy the baseline OneBill sync migrations and 202610210001_phase1_security_hardening.sql first';
  end if;
end $$;

-- Be self-contained for projects where the earlier paper-receipt migration
-- was not deployed. Existing tables/data are preserved.
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

create index if not exists paper_receipts_business_id_idx
  on public.paper_receipts(business_id);
create index if not exists paper_receipts_customer_id_idx
  on public.paper_receipts(customer_id);

alter table public.paper_receipts enable row level security;
drop policy if exists "Owners manage their paper receipts" on public.paper_receipts;
create policy "Owners manage their paper receipts"
on public.paper_receipts for all
using (
  exists (
    select 1 from public.businesses b
    where b.id = paper_receipts.business_id and b.owner_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.businesses b
    where b.id = paper_receipts.business_id and b.owner_id = auth.uid()
  )
);

insert into storage.buckets (id, name, public)
values ('paper-receipts', 'paper-receipts', false)
on conflict (id) do update set public = false;

drop policy if exists "OneBill receipt objects read" on storage.objects;
create policy "OneBill receipt objects read"
on storage.objects for select to authenticated
using (
  bucket_id = 'paper-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "OneBill receipt objects upload" on storage.objects;
create policy "OneBill receipt objects upload"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'paper-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "OneBill receipt objects update" on storage.objects;
create policy "OneBill receipt objects update"
on storage.objects for update to authenticated
using (
  bucket_id = 'paper-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'paper-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "OneBill receipt objects delete" on storage.objects;
create policy "OneBill receipt objects delete"
on storage.objects for delete to authenticated
using (
  bucket_id = 'paper-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- The Phase 1 function remains the implementation for every existing
-- operation. This wrapper adds the two previously missing receipt handlers.
do $$
begin
  if to_regprocedure('public.apply_sync_operation(uuid,uuid,jsonb)') is not null
     and to_regprocedure('public.apply_sync_operation_phase1(uuid,uuid,jsonb)') is null then
    execute format(
      'alter function %s rename to apply_sync_operation_phase1',
      to_regprocedure('public.apply_sync_operation(uuid,uuid,jsonb)')
    );
  end if;
end $$;

create or replace function public.apply_sync_operation(
  p_owner_id uuid,
  p_device_id uuid,
  p_operation jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_operation_id uuid := (p_operation->>'operationId')::uuid;
  v_entity_id uuid := (p_operation->>'entityId')::uuid;
  v_business_id uuid := nullif(p_operation->>'businessId', '')::uuid;
  v_operation_type text := p_operation->>'operationType';
  v_payload jsonb := p_operation->'payload';
  v_customer_id uuid := nullif(v_payload->>'customerId', '')::uuid;
  v_storage_path text := coalesce(v_payload->>'storagePath', v_payload->>'imageUrl');
  v_existing_owner uuid;
begin
  if auth.role() = 'anon' then
    raise exception 'Authentication is required';
  end if;
  if p_owner_id is null or p_device_id is null or v_operation_id is null
     or v_entity_id is null or v_payload is null then
    raise exception 'Invalid sync operation envelope';
  end if;
  if auth.role() = 'authenticated' and p_owner_id <> auth.uid() then
    raise exception 'p_owner_id does not match authenticated user';
  end if;

  if v_operation_type not in ('PaperReceiptCreated', 'PaperReceiptDeleted') then
    return public.apply_sync_operation_phase1(p_owner_id, p_device_id, p_operation);
  end if;

  select so.owner_id into v_existing_owner
  from public.sync_operations so
  where so.operation_id = v_operation_id
  for update;
  if found then
    if v_existing_owner <> p_owner_id then
      raise exception 'Operation belongs to another account';
    end if;
    return jsonb_build_object('acknowledged', true, 'operationId', v_operation_id, 'idempotent', true);
  end if;

  if v_business_id is null or not exists (
    select 1 from public.businesses b
    where b.id = v_business_id and b.owner_id = p_owner_id
  ) then
    raise exception 'Receipt business does not belong to the authenticated account';
  end if;
  if v_customer_id is null or not exists (
    select 1 from public.customers c
    where c.id = v_customer_id and c.business_id = v_business_id and c.owner_id = p_owner_id
  ) then
    raise exception 'Receipt customer does not belong to this business';
  end if;
  if v_storage_path is not null and v_storage_path !~ ('^' || p_owner_id::text || '/' || v_business_id::text || '/' || v_entity_id::text || '/') then
    raise exception 'Receipt storage path is not account-scoped';
  end if;
  if exists (select 1 from public.paper_receipts r where r.id = v_entity_id)
     and not exists (
       select 1 from public.paper_receipts r
       where r.id = v_entity_id and r.business_id = v_business_id
     ) then
    raise exception 'Receipt belongs to another business';
  end if;

  if v_operation_type = 'PaperReceiptCreated' then
    if v_storage_path is null or v_storage_path = '' then
      raise exception 'Receipt image was not uploaded';
    end if;
    insert into public.paper_receipts (
      id, business_id, customer_id, receipt_date, image_url, notes,
      created_at, updated_at, deleted_at
    ) values (
      v_entity_id, v_business_id, v_customer_id,
      coalesce((v_payload->>'receiptDate')::timestamptz, now()),
      v_storage_path, v_payload->>'notes',
      coalesce((v_payload->>'createdAt')::timestamptz, now()),
      coalesce((v_payload->>'updatedAt')::timestamptz, now()),
      null
    )
    on conflict (id) do update set
      business_id = excluded.business_id,
      customer_id = excluded.customer_id,
      receipt_date = excluded.receipt_date,
      image_url = excluded.image_url,
      notes = excluded.notes,
      updated_at = excluded.updated_at,
      deleted_at = null;
  else
    update public.paper_receipts
    set deleted_at = coalesce((v_payload->>'deletedAt')::timestamptz, now()),
        updated_at = now()
    where id = v_entity_id and business_id = v_business_id;
    if v_storage_path is not null and v_storage_path <> '' then
      delete from storage.objects
      where bucket_id = 'paper-receipts' and name = v_storage_path;
    end if;
  end if;

  insert into public.sync_operations (
    operation_id, owner_id, business_id, entity_type, entity_id,
    operation_type, payload, device_id, occurred_at
  ) values (
    v_operation_id, p_owner_id, v_business_id, 'PaperReceipt', v_entity_id,
    v_operation_type, v_payload, p_device_id,
    coalesce((p_operation->>'occurredAt')::timestamptz, now())
  );
  return jsonb_build_object('acknowledged', true, 'operationId', v_operation_id);
exception when others then
  return jsonb_build_object('acknowledged', false, 'operationId', v_operation_id, 'reason', SQLERRM);
end;
$$;

do $$
begin
  if to_regprocedure('public.apply_sync_operation_phase1(uuid,uuid,jsonb)') is not null then
    revoke execute on function public.apply_sync_operation_phase1(uuid, uuid, jsonb) from public, anon, authenticated;
  end if;
end $$;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to service_role;

-- Include all currently supported cloud records in a restoration snapshot.
create or replace function public.get_sync_snapshot()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'businesses', coalesce((select jsonb_agg(to_jsonb(b)) from public.businesses b where b.owner_id = auth.uid()), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(to_jsonb(c)) from public.customers c where c.owner_id = auth.uid()), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(to_jsonb(i)) from public.invoices i where i.owner_id = auth.uid()), '[]'::jsonb),
    'invoice_items', coalesce((select jsonb_agg(to_jsonb(ii)) from public.invoice_items ii where ii.owner_id = auth.uid()), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(p)) from public.payments p where p.owner_id = auth.uid()), '[]'::jsonb),
    'income_entries', coalesce((select jsonb_agg(to_jsonb(ie)) from public.income_entries ie where ie.owner_id = auth.uid()), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(ex)) from public.expenses ex where ex.owner_id = auth.uid()), '[]'::jsonb),
    'paper_receipts', coalesce((select jsonb_agg(to_jsonb(pr)) from public.paper_receipts pr join public.businesses b on b.id = pr.business_id where b.owner_id = auth.uid()), '[]'::jsonb)
  );
$$;

revoke all on function public.get_sync_snapshot() from public, anon;
grant execute on function public.get_sync_snapshot() to authenticated;
