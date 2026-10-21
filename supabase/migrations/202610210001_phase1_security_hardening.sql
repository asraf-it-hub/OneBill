-- Phase 1 security hardening.
-- The previous apply_sync_operation implementation is retained as a private
-- implementation detail. This wrapper performs all tenant and financial
-- validation before delegating to it, so authenticated callers cannot claim
-- another owner's business or overwrite another owner's records.

alter function public.apply_sync_operation(uuid, uuid, jsonb)
  rename to apply_sync_operation_legacy;

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
  v_operation_id uuid;
  v_entity_id uuid;
  v_business_id uuid;
  v_invoice_id uuid;
  v_customer_id uuid;
  v_payment_id uuid;
  v_operation_type text;
  v_payload jsonb;
  v_invoice jsonb;
  v_existing_owner uuid;
  v_existing_business uuid;
  v_existing_updated_at timestamptz;
  v_updated_at timestamptz;
  v_subtotal bigint;
  v_discount bigint;
  v_interest bigint;
  v_paid bigint;
  v_total bigint;
  v_amount bigint;
  v_paid_from_payments bigint;
  v_item jsonb;
  v_items_total bigint := 0;
begin
  if auth.role() = 'anon' then
    raise exception 'Authentication is required';
  end if;
  if p_owner_id is null or p_device_id is null or p_operation is null then
    raise exception 'Invalid sync operation envelope';
  end if;
  if auth.role() = 'authenticated' and p_owner_id <> auth.uid() then
    raise exception 'p_owner_id does not match authenticated user';
  end if;

  v_operation_id := (p_operation->>'operationId')::uuid;
  v_entity_id := (p_operation->>'entityId')::uuid;
  v_business_id := nullif(p_operation->>'businessId', '')::uuid;
  v_operation_type := coalesce(p_operation->>'operationType', '');
  v_payload := p_operation->'payload';
  if v_operation_id is null or v_entity_id is null or v_payload is null then
    raise exception 'Invalid sync operation envelope';
  end if;

  -- A retry is idempotent only for the account that created the operation.
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

  -- The Flutter repository emits BusinessUpdated while older cloud code only
  -- handled BusinessProfileUpdated. Keep the existing payload semantics while
  -- ensuring it can only update an already-owned business.
  if v_operation_type = 'BusinessUpdated' then
    v_operation_type := 'BusinessProfileUpdated';
    p_operation := jsonb_set(p_operation, '{operationType}', to_jsonb(v_operation_type));
  end if;

  if v_operation_type = 'BusinessCreated' then
    if exists (select 1 from public.businesses b where b.id = v_entity_id and b.owner_id <> p_owner_id) then
      raise exception 'Business belongs to another account';
    end if;
    v_business_id := v_entity_id;
  elsif v_operation_type in ('BusinessProfileUpdated', 'BusinessDeleted') then
    if not exists (select 1 from public.businesses b where b.id = v_entity_id and b.owner_id = p_owner_id) then
      raise exception 'Business does not belong to the authenticated account';
    end if;
    v_business_id := v_entity_id;
  else
    if v_business_id is null or not exists (
      select 1 from public.businesses b
      where b.id = v_business_id and b.owner_id = p_owner_id
    ) then
      raise exception 'Business does not belong to the authenticated account';
    end if;
  end if;

  -- Existing rows may never move between businesses or owners. This check is
  -- deliberately made before the legacy upsert, which otherwise overwrote
  -- owner_id/business_id on a conflicting primary key.
  if v_operation_type like 'Customer%' then
    if exists (select 1 from public.customers c where c.id = v_entity_id)
       and not exists (select 1 from public.customers c where c.id = v_entity_id and c.owner_id = p_owner_id and c.business_id = v_business_id) then
      raise exception 'Customer belongs to another business or account';
    end if;
  elsif v_operation_type like 'Invoice%' then
    if exists (select 1 from public.invoices i where i.id = v_entity_id)
       and not exists (select 1 from public.invoices i where i.id = v_entity_id and i.owner_id = p_owner_id and i.business_id = v_business_id) then
      raise exception 'Invoice belongs to another business or account';
    end if;
  elsif v_operation_type like 'Payment%' then
    v_payment_id := v_entity_id;
    if exists (select 1 from public.payments p where p.id = v_payment_id)
       and not exists (select 1 from public.payments p where p.id = v_payment_id and p.owner_id = p_owner_id and p.business_id = v_business_id) then
      raise exception 'Payment belongs to another business or account';
    end if;
  elsif v_operation_type like 'Income%' then
    if exists (select 1 from public.income_entries ie where ie.id = v_entity_id)
       and not exists (select 1 from public.income_entries ie where ie.id = v_entity_id and ie.owner_id = p_owner_id and ie.business_id = v_business_id) then
      raise exception 'Income entry belongs to another business or account';
    end if;
  elsif v_operation_type like 'Expense%' then
    if exists (select 1 from public.expenses e where e.id = v_entity_id)
       and not exists (select 1 from public.expenses e where e.id = v_entity_id and e.owner_id = p_owner_id and e.business_id = v_business_id) then
      raise exception 'Expense belongs to another business or account';
    end if;
  end if;

  if v_operation_type in ('CustomerCreated', 'CustomerUpdated') then
    v_updated_at := nullif(v_payload->>'updatedAt', '')::timestamptz;
    select c.updated_at into v_existing_updated_at from public.customers c where c.id = v_entity_id;
    if v_existing_updated_at is not null and v_updated_at is not null and v_updated_at < v_existing_updated_at then
      raise exception 'Stale customer update';
    end if;
  elsif v_operation_type in ('InvoiceCreated', 'InvoiceUpdated') then
    v_invoice := coalesce(v_payload->'invoice', '{}'::jsonb);
    v_customer_id := nullif(v_invoice->>'customerId', '')::uuid;
    if v_customer_id is not null and not exists (
      select 1 from public.customers c where c.id = v_customer_id and c.owner_id = p_owner_id and c.business_id = v_business_id
    ) then
      raise exception 'Invoice customer does not belong to this business';
    end if;
    v_subtotal := coalesce((v_invoice->>'subtotalPaise')::bigint, 0);
    v_discount := coalesce((v_invoice->>'discountPaise')::bigint, 0);
    v_interest := coalesce((v_invoice->>'interestPaise')::bigint, 0);
    v_paid := coalesce((v_invoice->>'paidPaise')::bigint, 0);
    v_total := v_subtotal - v_discount + v_interest;
    if v_subtotal < 0 or v_discount < 0 or v_interest < 0 or v_paid < 0 or v_discount > v_subtotal + v_interest or v_paid > v_total then
      raise exception 'Invalid invoice totals';
    end if;
    if jsonb_typeof(v_payload->'items') = 'array' then
      for v_item in select value from jsonb_array_elements(v_payload->'items') loop
        if coalesce((v_item->>'quantityMilliunits')::bigint, 0) <= 0
           or coalesce((v_item->>'unitPricePaise')::bigint, 0) < 0
           or coalesce((v_item->>'lineTotalPaise')::bigint, 0) < 0 then
          raise exception 'Invalid invoice item';
        end if;
        v_items_total := v_items_total + coalesce((v_item->>'lineTotalPaise')::bigint, 0);
      end loop;
      if v_items_total <> v_subtotal then
        raise exception 'Invoice subtotal does not match invoice items';
      end if;
    end if;
    v_updated_at := nullif(v_invoice->>'updatedAt', '')::timestamptz;
    select i.updated_at into v_existing_updated_at from public.invoices i where i.id = v_entity_id;
    if v_existing_updated_at is not null and v_updated_at is not null and v_updated_at < v_existing_updated_at then
      raise exception 'Stale invoice update';
    end if;
  elsif v_operation_type = 'PaymentRecorded' then
    v_invoice_id := nullif(v_payload->>'invoiceId', '')::uuid;
    v_amount := (v_payload->>'amountPaise')::bigint;
    if v_invoice_id is null or v_amount is null or v_amount <= 0 then
      raise exception 'Invalid payment amount or invoice';
    end if;
    select i.subtotal_paise - i.discount_paise + i.interest_paise
      into v_total
    from public.invoices i
    where i.id = v_invoice_id and i.owner_id = p_owner_id and i.business_id = v_business_id and i.deleted_at is null
    for update;
    if not found then
      raise exception 'Invoice does not belong to this business';
    end if;
    select coalesce(sum(p.amount_paise), 0) into v_paid_from_payments
    from public.payments p
    where p.invoice_id = v_invoice_id and p.owner_id = p_owner_id
      and p.business_id = v_business_id and p.deleted_at is null;
    if v_amount > v_total - v_paid_from_payments then
      raise exception 'Payment exceeds the permitted invoice balance';
    end if;
  elsif v_operation_type = 'PaymentReversed' then
    if not exists (select 1 from public.payments p where p.id = v_entity_id and p.owner_id = p_owner_id and p.business_id = v_business_id) then
      raise exception 'Payment does not belong to this business';
    end if;
  elsif v_operation_type in ('IncomeCreated', 'IncomeUpdated', 'ExpenseCreated', 'ExpenseUpdated') then
    v_amount := (v_payload->>'amountPaise')::bigint;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Amount must be greater than zero';
    end if;
  end if;

  -- Inventory/supplier operations are no longer part of the supported client
  -- surface. Reject them instead of acknowledging an operation the app cannot
  -- safely validate in this phase.
  if v_operation_type like 'Product%' or v_operation_type like 'Stock%'
     or v_operation_type like 'Supplier%' or v_operation_type like 'Purchase%' then
    raise exception 'Unsupported operation type';
  end if;
  if v_operation_type in ('PaperReceiptCreated', 'PaperReceiptDeleted') then
    raise exception 'Paper receipt sync requires a dedicated server handler';
  end if;
  if v_operation_type not in (
    'BusinessCreated', 'BusinessProfileUpdated', 'BusinessDeleted',
    'CustomerCreated', 'CustomerUpdated', 'CustomerArchived',
    'InvoiceCreated', 'InvoiceUpdated', 'InvoiceVoided',
    'PaymentRecorded', 'PaymentReversed',
    'IncomeCreated', 'IncomeUpdated', 'IncomeDeleted',
    'ExpenseCreated', 'ExpenseUpdated', 'ExpenseDeleted'
  ) then
    raise exception 'Unsupported operation type';
  end if;

  return public.apply_sync_operation_legacy(p_owner_id, p_device_id, p_operation);
exception when others then
  return jsonb_build_object(
    'acknowledged', false,
    'operationId', v_operation_id,
    'reason', SQLERRM
  );
end;
$$;

revoke execute on function public.apply_sync_operation_legacy(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to service_role;

-- These checks protect new writes immediately while NOT VALID keeps an older
-- production dataset deployable. Existing rows can be validated separately
-- after data cleanup.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_financial_values_ck') then
    alter table public.invoices add constraint invoices_financial_values_ck
      check (subtotal_paise >= 0 and discount_paise >= 0 and interest_paise >= 0 and paid_paise >= 0 and discount_paise <= subtotal_paise + interest_paise and paid_paise <= subtotal_paise - discount_paise + interest_paise) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_positive_amount_ck') then
    alter table public.payments add constraint payments_positive_amount_ck check (amount_paise > 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'income_positive_amount_ck') then
    alter table public.income_entries add constraint income_positive_amount_ck check (amount_paise > 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'expenses_positive_amount_ck') then
    alter table public.expenses add constraint expenses_positive_amount_ck check (amount_paise > 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoice_items_nonnegative_ck') then
    alter table public.invoice_items add constraint invoice_items_nonnegative_ck
      check (quantity_milliunits > 0 and unit_price_paise >= 0 and line_total_paise >= 0) not valid;
  end if;
end $$;
