-- Idempotent apply_sync_operation RPC update for Supabase Cloud

create or replace function public.apply_sync_operation(
  p_owner_id uuid,
  p_device_id uuid,
  p_operation jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
<<fn>>
declare
  op_id uuid := (p_operation->>'operationId')::uuid;
  business_id uuid := nullif(p_operation->>'businessId', '')::uuid;
  entity_id uuid := (p_operation->>'entityId')::uuid;
  op_type text := p_operation->>'operationType';
  payload jsonb := p_operation->'payload';
  payment_amount bigint;
  existing_owner uuid;
begin
  if p_owner_id is null or p_device_id is null or op_id is null or entity_id is null or payload is null then
    return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', 'Invalid sync operation envelope');
  end if;

  select so.owner_id into existing_owner
  from public.sync_operations so where so.operation_id = op_id for update;
  if found then
    if existing_owner <> p_owner_id then
      return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', 'Operation belongs to another account');
    end if;
    return jsonb_build_object('acknowledged', true, 'operationId', op_id, 'idempotent', true);
  end if;

  if op_type = 'BusinessCreated' then
    insert into public.businesses (id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language, created_at, updated_at, deleted_at)
    values (entity_id, p_owner_id, coalesce(payload->>'name', 'My Business'), coalesce(payload->>'ownerName', 'Owner'), payload->>'businessType', payload->>'phone', payload->>'email', payload->>'address', payload->>'upiId', coalesce(payload->>'preferredLanguage','en'), coalesce((payload->>'createdAt')::timestamptz, now()), coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz)
    on conflict (id) do update set
      name = excluded.name,
      owner_name = excluded.owner_name,
      business_type = excluded.business_type,
      phone = excluded.phone,
      email = excluded.email,
      address = excluded.address,
      upi_id = excluded.upi_id,
      preferred_language = excluded.preferred_language,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'BusinessUpdated' then
    update public.businesses set
      name = coalesce(payload->>'name', name),
      owner_name = coalesce(payload->>'ownerName', owner_name),
      business_type = payload->>'businessType',
      phone = payload->>'phone',
      email = payload->>'email',
      address = payload->>'address',
      upi_id = payload->>'upiId',
      preferred_language = coalesce(payload->>'preferredLanguage', preferred_language),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now()),
      deleted_at = (payload->>'deletedAt')::timestamptz,
      version = version + 1
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'CustomerCreated' then
    insert into public.customers (id, owner_id, business_id, name, phone, email, notes, created_at, updated_at, deleted_at)
    values (entity_id, p_owner_id, business_id, coalesce(payload->>'name', 'Customer'), coalesce(payload->>'phone', ''), payload->>'email', payload->>'notes', coalesce((payload->>'createdAt')::timestamptz, now()), coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz)
    on conflict (id) do update set
      name = excluded.name,
      phone = excluded.phone,
      email = excluded.email,
      notes = excluded.notes,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'CustomerUpdated' then
    update public.customers set
      name = coalesce(payload->>'name', name),
      phone = coalesce(payload->>'phone', phone),
      email = payload->>'email',
      notes = payload->>'notes',
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now()),
      version = version + 1
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'CustomerArchived' then
    update public.customers set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = now(),
      version = version + 1
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'InvoiceCreated' then
    insert into public.invoices (id, owner_id, business_id, customer_id, invoice_number, issued_at, due_at, subtotal_paise, discount_paise, interest_paise, paid_paise, notes, created_at, updated_at, deleted_at)
    values (
      (payload->'invoice'->>'id')::uuid,
      p_owner_id,
      business_id,
      (payload->'invoice'->>'customerId')::uuid,
      payload->'invoice'->>'invoiceNumber',
      coalesce((payload->'invoice'->>'issuedAt')::timestamptz, now()),
      (payload->'invoice'->>'dueAt')::timestamptz,
      coalesce((payload->'invoice'->>'subtotalPaise')::bigint, 0),
      coalesce((payload->'invoice'->>'discountPaise')::bigint, 0),
      coalesce((payload->'invoice'->>'interestPaise')::bigint, 0),
      coalesce((payload->'invoice'->>'paidPaise')::bigint, 0),
      payload->'invoice'->>'notes',
      coalesce((payload->'invoice'->>'createdAt')::timestamptz, now()),
      coalesce((payload->'invoice'->>'updatedAt')::timestamptz, now()),
      (payload->'invoice'->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      subtotal_paise = excluded.subtotal_paise,
      discount_paise = excluded.discount_paise,
      interest_paise = excluded.interest_paise,
      notes = excluded.notes,
      updated_at = excluded.updated_at;

    delete from public.invoice_items where invoice_id = (payload->'invoice'->>'id')::uuid;
    insert into public.invoice_items (id, owner_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
    select
      (item->>'id')::uuid,
      p_owner_id,
      (payload->'invoice'->>'id')::uuid,
      item->>'description',
      (item->>'quantityMilliunits')::integer,
      (item->>'unitPricePaise')::bigint,
      (item->>'lineTotalPaise')::bigint,
      (item->>'sortOrder')::integer
    from jsonb_array_elements(payload->'items') item
    on conflict (id) do nothing;

  elsif op_type = 'InvoiceUpdated' then
    update public.invoices set
      due_at = (payload->'invoice'->>'dueAt')::timestamptz,
      discount_paise = coalesce((payload->'invoice'->>'discountPaise')::bigint, 0),
      interest_paise = coalesce((payload->'invoice'->>'interestPaise')::bigint, 0),
      notes = payload->'invoice'->>'notes',
      updated_at = now(),
      version = version + 1
    where id = entity_id and owner_id = p_owner_id;

    delete from public.invoice_items where invoice_id = entity_id;
    insert into public.invoice_items (id, owner_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
    select
      (item->>'id')::uuid,
      p_owner_id,
      entity_id,
      item->>'description',
      (item->>'quantityMilliunits')::integer,
      (item->>'unitPricePaise')::bigint,
      (item->>'lineTotalPaise')::bigint,
      (item->>'sortOrder')::integer
    from jsonb_array_elements(payload->'items') item
    on conflict (id) do nothing;

  elsif op_type = 'InvoiceVoided' then
    update public.invoices set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = now(),
      version = version + 1
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'PaymentRecorded' then
    payment_amount := (payload->>'amountPaise')::bigint;
    insert into public.payments (id, owner_id, business_id, invoice_id, amount_paise, method, note, received_at, created_at, deleted_at)
    values (
      entity_id,
      p_owner_id,
      business_id,
      (payload->>'invoiceId')::uuid,
      payment_amount,
      coalesce(payload->>'method', 'cash'),
      payload->>'note',
      coalesce((payload->>'receivedAt')::timestamptz, now()),
      coalesce((payload->>'createdAt')::timestamptz, now()),
      (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do nothing;

    update public.invoices set
      paid_paise = paid_paise + payment_amount,
      updated_at = now(),
      version = version + 1
    where id = (payload->>'invoiceId')::uuid;

  elsif op_type = 'PaymentReversed' then
    payment_amount := (payload->>'amountPaise')::bigint;
    update public.payments set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

    update public.invoices set
      paid_paise = greatest(0, paid_paise - payment_amount),
      updated_at = now(),
      version = version + 1
    where id = (payload->>'invoiceId')::uuid and owner_id = p_owner_id;

  elsif op_type in ('IncomeCreated', 'IncomeUpdated', 'IncomeDeleted') then
    if op_type = 'IncomeCreated' then
      insert into public.income_entries (id, owner_id, business_id, amount_paise, description, income_date, created_at, updated_at, deleted_at)
      values (
        entity_id,
        p_owner_id,
        business_id,
        (payload->>'amountPaise')::bigint,
        payload->>'description',
        coalesce((payload->>'incomeDate')::timestamptz, now()),
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        amount_paise = excluded.amount_paise,
        description = excluded.description,
        income_date = excluded.income_date,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;

    elsif op_type = 'IncomeUpdated' then
      update public.income_entries set
        amount_paise = (payload->>'amountPaise')::bigint,
        description = payload->>'description',
        income_date = (payload->>'incomeDate')::timestamptz,
        updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
      where id = entity_id and owner_id = p_owner_id;

    else
      update public.income_entries set
        deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
        updated_at = now()
      where id = entity_id and owner_id = p_owner_id;
    end if;

  elsif op_type in ('ExpenseCreated', 'ExpenseUpdated', 'ExpenseDeleted') then
    if op_type = 'ExpenseCreated' then
      insert into public.expenses (id, owner_id, business_id, amount_paise, category, description, expense_date, created_at, updated_at, deleted_at)
      values (
        entity_id,
        p_owner_id,
        business_id,
        (payload->>'amountPaise')::bigint,
        coalesce(payload->>'category', 'Other'),
        payload->>'description',
        coalesce((payload->>'expenseDate')::timestamptz, now()),
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        amount_paise = excluded.amount_paise,
        category = excluded.category,
        description = excluded.description,
        expense_date = excluded.expense_date,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;

    elsif op_type = 'ExpenseUpdated' then
      update public.expenses set
        amount_paise = (payload->>'amountPaise')::bigint,
        category = coalesce(payload->>'category', 'Other'),
        description = payload->>'description',
        expense_date = (payload->>'expenseDate')::timestamptz,
        updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
      where id = entity_id and owner_id = p_owner_id;

    else
      update public.expenses set
        deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
        updated_at = now()
      where id = entity_id and owner_id = p_owner_id;
    end if;

  elsif op_type in ('InventoryProductCreated', 'InventoryProductUpdated', 'InventoryProductDeleted', 'InventoryAdjusted') then
    if op_type = 'InventoryProductCreated' then
      insert into public.inventory_products (id, owner_id, business_id, name, sku, unit, stock_milliunits, low_stock_threshold_milliunits, unit_cost_paise, created_at, updated_at, deleted_at)
      values (
        entity_id,
        p_owner_id,
        business_id,
        payload->>'name',
        payload->>'sku',
        coalesce(payload->>'unit','pcs'),
        coalesce((payload->>'stockMilliunits')::integer, 0),
        coalesce((payload->>'lowStockThresholdMilliunits')::integer, 0),
        coalesce((payload->>'unitCostPaise')::bigint, 0),
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        name = excluded.name,
        sku = excluded.sku,
        unit = excluded.unit,
        stock_milliunits = excluded.stock_milliunits,
        low_stock_threshold_milliunits = excluded.low_stock_threshold_milliunits,
        unit_cost_paise = excluded.unit_cost_paise,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;

    elsif op_type = 'InventoryProductDeleted' then
      update public.inventory_products set
        deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
        updated_at = now()
      where id = entity_id and owner_id = p_owner_id;

    else
      update public.inventory_products set
        name = coalesce(payload->>'name', name),
        sku = payload->>'sku',
        unit = coalesce(payload->>'unit','pcs'),
        stock_milliunits = coalesce((payload->>'stockMilliunits')::integer, stock_milliunits),
        low_stock_threshold_milliunits = coalesce((payload->>'lowStockThresholdMilliunits')::integer, low_stock_threshold_milliunits),
        unit_cost_paise = coalesce((payload->>'unitCostPaise')::bigint, unit_cost_paise),
        updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
      where id = entity_id and owner_id = p_owner_id;
    end if;

  elsif op_type in ('SupplierCreated', 'SupplierUpdated', 'SupplierDeleted') then
    if op_type = 'SupplierCreated' then
      insert into public.suppliers (id, owner_id, business_id, name, phone, email, address, notes, created_at, updated_at, deleted_at)
      values (
        entity_id,
        p_owner_id,
        business_id,
        payload->>'name',
        payload->>'phone',
        payload->>'email',
        payload->>'address',
        payload->>'notes',
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        name = excluded.name,
        phone = excluded.phone,
        email = excluded.email,
        address = excluded.address,
        notes = excluded.notes,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;

    elsif op_type = 'SupplierDeleted' then
      update public.suppliers set
        deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
        updated_at = now()
      where id = entity_id and owner_id = p_owner_id;

    else
      update public.suppliers set
        name = coalesce(payload->>'name', name),
        phone = coalesce(payload->>'phone', phone),
        email = payload->>'email',
        address = payload->>'address',
        notes = payload->>'notes',
        updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
      where id = entity_id and owner_id = p_owner_id;
    end if;

  elsif op_type = 'SupplierPaymentRecorded' then
    insert into public.supplier_payments (id, owner_id, business_id, supplier_id, amount_paise, paid_at, note, created_at, deleted_at)
    values (
      entity_id,
      p_owner_id,
      business_id,
      (payload->>'supplierId')::uuid,
      (payload->>'amountPaise')::bigint,
      coalesce((payload->>'paidAt')::timestamptz, now()),
      payload->>'note',
      coalesce((payload->>'createdAt')::timestamptz, now()),
      (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      amount_paise = excluded.amount_paise,
      note = excluded.note;
  end if;

  insert into public.sync_operations (operation_id, owner_id, business_id, entity_type, entity_id, operation_type, payload, device_id, occurred_at)
  values (op_id, p_owner_id, business_id, p_operation->>'entityType', entity_id, op_type, payload, p_device_id, (p_operation->>'occurredAt')::timestamptz)
  on conflict (operation_id) do nothing;

  return jsonb_build_object('acknowledged', true, 'operationId', op_id, 'idempotent', false);
exception when others then
  return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', SQLERRM);
end;
$$;

revoke all on function public.apply_sync_operation(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to service_role;
