-- Migration: Add paper_receipt_image column to public.invoices and update apply_sync_operation RPC
alter table public.invoices add column if not exists paper_receipt_image text;

-- Update apply_sync_operation to persist paper_receipt_image during invoice sync
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
  entity_type text := coalesce(p_operation->>'entityType', 'Unknown');
  entity_id uuid := (p_operation->>'entityId')::uuid;
  op_type text := p_operation->>'operationType';
  payload jsonb := p_operation->'payload';
  payment_amount bigint;
  existing_owner uuid;
begin
  if p_owner_id is null or p_device_id is null or op_id is null or entity_id is null or payload is null then
    return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', 'Invalid sync operation envelope');
  end if;

  if auth.role() = 'authenticated' and p_owner_id <> auth.uid() then
    return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', 'p_owner_id does not match authenticated user');
  end if;

  if business_id is not null then
    update public.businesses set owner_id = p_owner_id where id = business_id and (owner_id is null or owner_id <> p_owner_id);
  end if;

  if op_type not like 'Business%' and (business_id is null or not exists (
    select 1 from public.businesses b where b.id = business_id
  )) then
    return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', 'Business does not exist in cloud');
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
    begin
      insert into public.businesses (
        id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language,
        website, tagline, gstin, upi_name, invoice_notes, terms_and_conditions, logo_image, payment_qr_image,
        created_at, updated_at, deleted_at
      )
      values (
        entity_id,
        p_owner_id,
        coalesce(payload->>'name', 'My Business'),
        coalesce(payload->>'ownerName', 'Owner'),
        payload->>'businessType',
        payload->>'phone',
        payload->>'email',
        payload->>'address',
        payload->>'upiId',
        coalesce(payload->>'preferredLanguage', payload->>'preferred_language', 'en'),
        payload->>'website',
        payload->>'tagline',
        payload->>'gstin',
        payload->>'upiName',
        payload->>'invoiceNotes',
        payload->>'termsAndConditions',
        payload->>'logoImage',
        payload->>'paymentQrImage',
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        owner_id = excluded.owner_id,
        name = excluded.name,
        owner_name = excluded.owner_name,
        business_type = excluded.business_type,
        phone = excluded.phone,
        email = excluded.email,
        address = excluded.address,
        upi_id = excluded.upi_id,
        preferred_language = excluded.preferred_language,
        website = excluded.website,
        tagline = excluded.tagline,
        gstin = excluded.gstin,
        upi_name = excluded.upi_name,
        invoice_notes = excluded.invoice_notes,
        terms_and_conditions = excluded.terms_and_conditions,
        logo_image = excluded.logo_image,
        payment_qr_image = excluded.payment_qr_image,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;
    exception when undefined_column then
      insert into public.businesses (
        id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language,
        created_at, updated_at, deleted_at
      )
      values (
        entity_id,
        p_owner_id,
        coalesce(payload->>'name', 'My Business'),
        coalesce(payload->>'ownerName', 'Owner'),
        payload->>'businessType',
        payload->>'phone',
        payload->>'email',
        payload->>'address',
        payload->>'upiId',
        coalesce(payload->>'preferredLanguage', payload->>'preferred_language', 'en'),
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        owner_id = excluded.owner_id,
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
    end;

  elsif op_type = 'BusinessProfileUpdated' then
    begin
      insert into public.businesses (
        id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language,
        website, tagline, gstin, upi_name, invoice_notes, terms_and_conditions, logo_image, payment_qr_image,
        created_at, updated_at, deleted_at
      )
      values (
        entity_id,
        p_owner_id,
        coalesce(payload->>'name', 'My Business'),
        coalesce(payload->>'ownerName', 'Owner'),
        payload->>'businessType',
        payload->>'phone',
        payload->>'email',
        payload->>'address',
        payload->>'upiId',
        coalesce(payload->>'preferredLanguage', payload->>'preferred_language', 'en'),
        payload->>'website',
        payload->>'tagline',
        payload->>'gstin',
        payload->>'upiName',
        payload->>'invoiceNotes',
        payload->>'termsAndConditions',
        payload->>'logoImage',
        payload->>'paymentQrImage',
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        owner_id = excluded.owner_id,
        name = coalesce(excluded.name, public.businesses.name),
        owner_name = coalesce(excluded.owner_name, public.businesses.owner_name),
        business_type = excluded.business_type,
        phone = excluded.phone,
        email = excluded.email,
        address = excluded.address,
        upi_id = excluded.upi_id,
        preferred_language = coalesce(excluded.preferred_language, public.businesses.preferred_language),
        website = excluded.website,
        tagline = excluded.tagline,
        gstin = excluded.gstin,
        upi_name = excluded.upi_name,
        invoice_notes = excluded.invoice_notes,
        terms_and_conditions = excluded.terms_and_conditions,
        logo_image = excluded.logo_image,
        payment_qr_image = excluded.payment_qr_image,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;
    exception when undefined_column then
      insert into public.businesses (
        id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language,
        created_at, updated_at, deleted_at
      )
      values (
        entity_id,
        p_owner_id,
        coalesce(payload->>'name', 'My Business'),
        coalesce(payload->>'ownerName', 'Owner'),
        payload->>'businessType',
        payload->>'phone',
        payload->>'email',
        payload->>'address',
        payload->>'upiId',
        coalesce(payload->>'preferredLanguage', payload->>'preferred_language', 'en'),
        coalesce((payload->>'createdAt')::timestamptz, now()),
        coalesce((payload->>'updatedAt')::timestamptz, now()),
        (payload->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        owner_id = excluded.owner_id,
        name = coalesce(excluded.name, public.businesses.name),
        owner_name = coalesce(excluded.owner_name, public.businesses.owner_name),
        business_type = excluded.business_type,
        phone = excluded.phone,
        email = excluded.email,
        address = excluded.address,
        upi_id = excluded.upi_id,
        preferred_language = coalesce(excluded.preferred_language, public.businesses.preferred_language),
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;
    end;

  elsif op_type in ('CustomerCreated', 'CustomerUpdated') then
    insert into public.customers (id, owner_id, business_id, name, phone, email, notes, created_at, updated_at, deleted_at)
    values (entity_id, p_owner_id, business_id, coalesce(payload->>'name', 'Customer'), coalesce(payload->>'phone', ''), payload->>'email', payload->>'notes', coalesce((payload->>'createdAt')::timestamptz, now()), coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz)
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      name = coalesce(excluded.name, public.customers.name),
      phone = coalesce(excluded.phone, public.customers.phone),
      email = excluded.email,
      notes = excluded.notes,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'CustomerArchived' then
    update public.customers set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type in ('InvoiceCreated', 'InvoiceUpdated') then
    if (payload->'invoice'->>'customerId') is not null and (payload->'invoice'->>'customerId') <> '' then
      insert into public.customers (id, owner_id, business_id, name, phone, created_at, updated_at)
      values (
        (payload->'invoice'->>'customerId')::uuid,
        p_owner_id,
        business_id,
        'Customer',
        '0000000000',
        coalesce((payload->'invoice'->>'createdAt')::timestamptz, now()),
        now()
      )
      on conflict (id) do nothing;
    end if;

    begin
      insert into public.invoices (
        id, owner_id, business_id, customer_id, invoice_number, issued_at, due_at,
        subtotal_paise, discount_paise, interest_paise, paid_paise, notes,
        paper_receipt_image, created_at, updated_at, deleted_at
      )
      values (
        entity_id, p_owner_id, business_id, nullif(payload->'invoice'->>'customerId', '')::uuid,
        coalesce(payload->'invoice'->>'invoiceNumber', 'INV-001'),
        coalesce((payload->'invoice'->>'issuedAt')::timestamptz, now()),
        (payload->'invoice'->>'dueAt')::timestamptz,
        coalesce((payload->'invoice'->>'subtotalPaise')::bigint, 0),
        coalesce((payload->'invoice'->>'discountPaise')::bigint, 0),
        coalesce((payload->'invoice'->>'interestPaise')::bigint, 0),
        coalesce((payload->'invoice'->>'paidPaise')::bigint, 0),
        payload->'invoice'->>'notes',
        coalesce(payload->'invoice'->>'paperReceiptImage', payload->'invoice'->>'paper_receipt_image'),
        coalesce((payload->'invoice'->>'createdAt')::timestamptz, now()),
        coalesce((payload->'invoice'->>'updatedAt')::timestamptz, now()),
        (payload->'invoice'->>'deletedAt')::timestamptz
      )
      on conflict (id) do update set
        owner_id = excluded.owner_id,
        business_id = excluded.business_id,
        customer_id = coalesce(excluded.customer_id, public.invoices.customer_id),
        invoice_number = coalesce(excluded.invoice_number, public.invoices.invoice_number),
        issued_at = coalesce(excluded.issued_at, public.invoices.issued_at),
        due_at = excluded.due_at,
        subtotal_paise = coalesce(excluded.subtotal_paise, public.invoices.subtotal_paise),
        discount_paise = coalesce(excluded.discount_paise, public.invoices.discount_paise),
        interest_paise = coalesce(excluded.interest_paise, public.invoices.interest_paise),
        paid_paise = coalesce(excluded.paid_paise, public.invoices.paid_paise),
        notes = excluded.notes,
        paper_receipt_image = coalesce(excluded.paper_receipt_image, public.invoices.paper_receipt_image),
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;
    exception when undefined_column then
      insert into public.invoices (
        id, owner_id, business_id, customer_id, invoice_number, issued_at, due_at,
        subtotal_paise, discount_paise, interest_paise, paid_paise, notes,
        created_at, updated_at, deleted_at
      )
      values (
        entity_id, p_owner_id, business_id, nullif(payload->'invoice'->>'customerId', '')::uuid,
        coalesce(payload->'invoice'->>'invoiceNumber', 'INV-001'),
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
        owner_id = excluded.owner_id,
        business_id = excluded.business_id,
        customer_id = coalesce(excluded.customer_id, public.invoices.customer_id),
        invoice_number = coalesce(excluded.invoice_number, public.invoices.invoice_number),
        issued_at = coalesce(excluded.issued_at, public.invoices.issued_at),
        due_at = excluded.due_at,
        subtotal_paise = coalesce(excluded.subtotal_paise, public.invoices.subtotal_paise),
        discount_paise = coalesce(excluded.discount_paise, public.invoices.discount_paise),
        interest_paise = coalesce(excluded.interest_paise, public.invoices.interest_paise),
        paid_paise = coalesce(excluded.paid_paise, public.invoices.paid_paise),
        notes = excluded.notes,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at;
    end;

    if payload->'items' is not null then
      delete from public.invoice_items where invoice_id = entity_id;
      if jsonb_array_length(payload->'items') > 0 then
        begin
          insert into public.invoice_items (id, owner_id, business_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
          select
            coalesce(nullif(item->>'id', '')::uuid, gen_random_uuid()),
            p_owner_id,
            business_id,
            entity_id,
            coalesce(nullif(trim(item->>'description'), ''), 'Item'),
            greatest(1::bigint, coalesce((item->>'quantityMilliunits')::bigint, 1000::bigint)),
            coalesce((item->>'unitPricePaise')::bigint, 0),
            coalesce((item->>'lineTotalPaise')::bigint, 0),
            coalesce((item->>'sortOrder')::int, 0)
          from jsonb_array_elements(payload->'items') as item;
        exception when undefined_column then
          insert into public.invoice_items (id, owner_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
          select
            coalesce(nullif(item->>'id', '')::uuid, gen_random_uuid()),
            p_owner_id,
            entity_id,
            coalesce(nullif(trim(item->>'description'), ''), 'Item'),
            greatest(1::bigint, coalesce((item->>'quantityMilliunits')::bigint, 1000::bigint)),
            coalesce((item->>'unitPricePaise')::bigint, 0),
            coalesce((item->>'lineTotalPaise')::bigint, 0),
            coalesce((item->>'sortOrder')::int, 0)
          from jsonb_array_elements(payload->'items') as item;
        end;
      end if;
    end if;

  elsif op_type = 'InvoiceVoided' then
    update public.invoices set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'PaymentRecorded' then
    insert into public.payments (id, owner_id, business_id, invoice_id, amount_paise, method, note, received_at, created_at, deleted_at)
    values (
      entity_id, p_owner_id, business_id, (payload->>'invoiceId')::uuid, (payload->>'amountPaise')::bigint,
      coalesce(payload->>'method', 'cash'), payload->>'note', coalesce((payload->>'receivedAt')::timestamptz, now()),
      coalesce((payload->>'createdAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      amount_paise = excluded.amount_paise,
      method = excluded.method,
      note = excluded.note,
      received_at = excluded.received_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'PaymentReversed' then
    update public.payments set
      deleted_at = coalesce((payload->>'reversedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type in ('IncomeCreated', 'IncomeUpdated') then
    insert into public.income_entries (id, owner_id, business_id, amount_paise, description, income_date, created_at, updated_at, deleted_at)
    values (
      entity_id, p_owner_id, business_id, (payload->>'amountPaise')::bigint, payload->>'description',
      coalesce((payload->>'incomeDate')::timestamptz, now()), coalesce((payload->>'createdAt')::timestamptz, now()),
      coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      amount_paise = excluded.amount_paise,
      description = excluded.description,
      income_date = excluded.income_date,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'IncomeDeleted' then
    update public.income_entries set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type in ('ExpenseCreated', 'ExpenseUpdated') then
    insert into public.expenses (id, owner_id, business_id, amount_paise, category, description, expense_date, created_at, updated_at, deleted_at)
    values (
      entity_id, p_owner_id, business_id, (payload->>'amountPaise')::bigint, coalesce(payload->>'category', 'General'),
      payload->>'description', coalesce((payload->>'expenseDate')::timestamptz, now()),
      coalesce((payload->>'createdAt')::timestamptz, now()), coalesce((payload->>'updatedAt')::timestamptz, now()),
      (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      amount_paise = excluded.amount_paise,
      category = excluded.category,
      description = excluded.description,
      expense_date = excluded.expense_date,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'ExpenseDeleted' then
    update public.expenses set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type in ('ProductCreated', 'ProductUpdated') then
    insert into public.inventory_products (
      id, owner_id, business_id, name, sku, unit, stock_milliunits, low_stock_threshold_milliunits, unit_cost_paise, created_at, updated_at, deleted_at
    )
    values (
      entity_id, p_owner_id, business_id, coalesce(payload->>'name', 'Product'), payload->>'sku', coalesce(payload->>'unit', 'pcs'),
      coalesce((payload->>'stockMilliunits')::bigint, 0), coalesce((payload->>'lowStockThresholdMilliunits')::bigint, 0),
      coalesce((payload->>'unitCostPaise')::bigint, 0), coalesce((payload->>'createdAt')::timestamptz, now()),
      coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      name = excluded.name,
      sku = excluded.sku,
      unit = excluded.unit,
      stock_milliunits = excluded.stock_milliunits,
      low_stock_threshold_milliunits = excluded.low_stock_threshold_milliunits,
      unit_cost_paise = excluded.unit_cost_paise,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'ProductDeleted' then
    update public.inventory_products set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'StockMovementRecorded' then
    insert into public.inventory_movements (id, owner_id, business_id, product_id, delta_milliunits, reason, created_at)
    values (
      entity_id, p_owner_id, business_id, (payload->>'productId')::uuid, (payload->>'deltaMilliunits')::bigint,
      coalesce(payload->>'reason', 'adjustment'), coalesce((payload->>'createdAt')::timestamptz, now())
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      product_id = excluded.product_id,
      delta_milliunits = excluded.delta_milliunits,
      reason = excluded.reason;

  elsif op_type in ('SupplierCreated', 'SupplierUpdated') then
    insert into public.suppliers (id, owner_id, business_id, name, phone, email, address, notes, created_at, updated_at, deleted_at)
    values (
      entity_id, p_owner_id, business_id, coalesce(payload->>'name', 'Supplier'), coalesce(payload->>'phone', ''),
      payload->>'email', payload->>'address', payload->>'notes', coalesce((payload->>'createdAt')::timestamptz, now()),
      coalesce((payload->>'updatedAt')::timestamptz, now()), (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
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
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;

  elsif op_type = 'SupplierPaymentRecorded' then
    insert into public.supplier_payments (id, owner_id, business_id, supplier_id, amount_paise, paid_at, note, created_at, deleted_at)
    values (
      entity_id, p_owner_id, business_id, (payload->>'supplierId')::uuid, (payload->>'amountPaise')::bigint,
      coalesce((payload->>'paidAt')::timestamptz, now()), payload->>'note', coalesce((payload->>'createdAt')::timestamptz, now()),
      (payload->>'deletedAt')::timestamptz
    )
    on conflict (id) do update set
      owner_id = excluded.owner_id,
      amount_paise = excluded.amount_paise,
      paid_at = excluded.paid_at,
      note = excluded.note,
      deleted_at = excluded.deleted_at;

  elsif op_type = 'BusinessDeleted' then
    update public.businesses set
      deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()),
      updated_at = coalesce((payload->>'updatedAt')::timestamptz, now())
    where id = entity_id and owner_id = p_owner_id;
  end if;

  insert into public.sync_operations (
    operation_id, owner_id, business_id, entity_type, entity_id, operation_type, payload, device_id, occurred_at
  )
  values (
    op_id, p_owner_id, coalesce(business_id, entity_id), entity_type, entity_id, op_type, payload, p_device_id, coalesce((p_operation->>'occurredAt')::timestamptz, now())
  )
  on conflict (operation_id) do nothing;

  return jsonb_build_object('acknowledged', true, 'operationId', op_id);
exception when others then
  return jsonb_build_object('acknowledged', false, 'operationId', op_id, 'reason', SQLERRM);
end;
$$;

grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to service_role;
