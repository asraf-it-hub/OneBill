-- Migration: Add secure server-side account deletion functions
-- Supports authenticated user deletion (derived strictly from auth.uid())

-- Drop all existing variants to eliminate ambiguity completely
drop function if exists public.delete_user_account();
drop function if exists public.delete_user_account(text);

-- Single unambiguous deletion function
create or replace function public.delete_user_account()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid;
  v_deleted_businesses int := 0;
  v_deleted_invoices int := 0;
  v_deleted_customers int := 0;
  v_deleted_payments int := 0;
  v_deleted_expenses int := 0;
  v_deleted_income int := 0;
  v_deleted_receipts int := 0;
  v_deleted_sync_ops int := 0;
begin
  -- 1. Derive user identity securely from auth.uid()
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required. No authenticated user found.'
      using errcode = '40100';
  end if;

  -- 2. Clean up child tables safely (to_regclass skips any tables that do not exist)
  if to_regclass('public.supplier_payments') is not null then
    execute 'delete from public.supplier_payments where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
  end if;

  if to_regclass('public.suppliers') is not null then
    execute 'delete from public.suppliers where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
  end if;

  if to_regclass('public.inventory_movements') is not null then
    execute 'delete from public.inventory_movements where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
  end if;

  if to_regclass('public.inventory_products') is not null then
    execute 'delete from public.inventory_products where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
  end if;

  if to_regclass('public.payments') is not null then
    execute 'delete from public.payments where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_payments = row_count;
  end if;

  if to_regclass('public.invoice_items') is not null then
    execute 'delete from public.invoice_items where invoice_id in (select i.id from public.invoices i join public.businesses b on b.id = i.business_id where b.owner_id = $1) or owner_id = $1' using v_user_id;
  end if;

  if to_regclass('public.invoices') is not null then
    execute 'delete from public.invoices where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_invoices = row_count;
  end if;

  if to_regclass('public.paper_receipts') is not null then
    execute 'delete from public.paper_receipts where business_id in (select id from public.businesses where owner_id = $1)' using v_user_id;
    get diagnostics v_deleted_receipts = row_count;
  end if;

  if to_regclass('public.expenses') is not null then
    execute 'delete from public.expenses where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_expenses = row_count;
  end if;

  if to_regclass('public.income_entries') is not null then
    execute 'delete from public.income_entries where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_income = row_count;
  end if;

  if to_regclass('public.customers') is not null then
    execute 'delete from public.customers where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_customers = row_count;
  end if;

  if to_regclass('public.sync_operations') is not null then
    execute 'delete from public.sync_operations where business_id in (select id from public.businesses where owner_id = $1) or owner_id = $1' using v_user_id;
    get diagnostics v_deleted_sync_ops = row_count;
  end if;

  if to_regclass('public.businesses') is not null then
    execute 'delete from public.businesses where owner_id = $1' using v_user_id;
    get diagnostics v_deleted_businesses = row_count;
  end if;

  -- 3. Delete from auth.users
  delete from auth.users where id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'businesses_deleted', v_deleted_businesses,
    'invoices_deleted', v_deleted_invoices,
    'customers_deleted', v_deleted_customers,
    'payments_deleted', v_deleted_payments,
    'expenses_deleted', v_deleted_expenses,
    'income_deleted', v_deleted_income,
    'paper_receipts_deleted', v_deleted_receipts,
    'sync_operations_deleted', v_deleted_sync_ops
  );
end;
$$;

-- Grant execution
grant execute on function public.delete_user_account() to authenticated, anon, service_role;

-- Force PostgREST to reload schema cache immediately
notify pgrst, 'reload schema';
