-- Additive cloud entity schema and transactional sync RPC.
-- Existing businesses and sync_operations tables are preserved.

alter table public.businesses add column if not exists version bigint not null default 1;

create table if not exists public.customers (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  phone text not null,
  email text,
  notes text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (business_id, id),
  check (char_length(trim(name)) > 0),
  check (char_length(phone) > 0)
);

create table if not exists public.invoices (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  invoice_number text not null,
  issued_at timestamptz not null,
  due_at timestamptz,
  subtotal_paise bigint not null,
  discount_paise bigint not null default 0,
  interest_paise bigint not null default 0,
  paid_paise bigint not null default 0,
  notes text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (business_id, id),
  unique (business_id, invoice_number),
  foreign key (business_id, customer_id) references public.customers(business_id, id) on delete restrict,
  check (subtotal_paise >= 0 and discount_paise >= 0 and interest_paise >= 0 and paid_paise >= 0),
  check (discount_paise <= subtotal_paise + interest_paise),
  check (paid_paise <= subtotal_paise - discount_paise + interest_paise)
);

create table if not exists public.invoice_items (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  description text not null,
  quantity_milliunits integer not null,
  unit_price_paise bigint not null,
  line_total_paise bigint not null,
  sort_order integer not null,
  check (char_length(trim(description)) > 0),
  check (quantity_milliunits > 0 and unit_price_paise >= 0 and line_total_paise >= 0)
);

create table if not exists public.payments (
  id uuid primary key,
  owner_id uuid not null references auth.users(id),
  business_id uuid not null references public.businesses(id) on delete restrict,
  invoice_id uuid not null,
  amount_paise bigint not null,
  method text not null,
  note text,
  received_at timestamptz not null,
  created_at timestamptz not null,
  deleted_at timestamptz,
  foreign key (business_id, invoice_id) references public.invoices(business_id, id) on delete restrict,
  check (amount_paise > 0),
  check (char_length(trim(method)) > 0)
);

create table if not exists public.income_entries (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  amount_paise bigint not null check (amount_paise > 0),
  description text,
  income_date timestamptz not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);
create table if not exists public.expenses (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  amount_paise bigint not null check (amount_paise > 0),
  category text not null,
  description text,
  expense_date timestamptz not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);
create index if not exists expenses_business_date_idx on public.expenses(business_id, expense_date desc, deleted_at);
alter table public.expenses enable row level security;
drop policy if exists "Owners manage their expenses" on public.expenses;
create policy "Owners manage their expenses" on public.expenses for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create table if not exists public.inventory_products (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null, sku text, unit text not null default 'pcs',
  stock_milliunits integer not null default 0 check (stock_milliunits >= 0),
  low_stock_threshold_milliunits integer not null default 0 check (low_stock_threshold_milliunits >= 0),
  unit_cost_paise bigint not null default 0 check (unit_cost_paise >= 0),
  created_at timestamptz not null, updated_at timestamptz not null, deleted_at timestamptz,
  unique (business_id, id), check (char_length(trim(name)) > 0)
);
create table if not exists public.inventory_movements (
  id uuid primary key, owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete restrict,
  product_id uuid not null references public.inventory_products(id) on delete restrict,
  delta_milliunits integer not null, reason text not null, created_at timestamptz not null
);
create table if not exists public.suppliers (
  id uuid primary key, owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null, phone text not null, email text, address text, notes text,
  created_at timestamptz not null, updated_at timestamptz not null, deleted_at timestamptz,
  unique (business_id, id), check (char_length(trim(name)) > 0), check (char_length(trim(phone)) > 0)
);
create table if not exists public.supplier_payments (
  id uuid primary key, owner_id uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  amount_paise bigint not null check (amount_paise > 0), paid_at timestamptz not null,
  note text, created_at timestamptz not null, deleted_at timestamptz
);
create index if not exists inventory_products_business_idx on public.inventory_products(business_id, name) where deleted_at is null;
create index if not exists inventory_movements_product_idx on public.inventory_movements(product_id, created_at desc);
create index if not exists suppliers_business_idx on public.suppliers(business_id, name) where deleted_at is null;
create index if not exists supplier_payments_supplier_idx on public.supplier_payments(supplier_id, paid_at desc) where deleted_at is null;
alter table public.inventory_products enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.suppliers enable row level security;
alter table public.supplier_payments enable row level security;
drop policy if exists "Owners manage inventory products" on public.inventory_products;
create policy "Owners manage inventory products" on public.inventory_products for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage inventory movements" on public.inventory_movements;
create policy "Owners manage inventory movements" on public.inventory_movements for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage suppliers" on public.suppliers;
create policy "Owners manage suppliers" on public.suppliers for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage supplier payments" on public.supplier_payments;
create policy "Owners manage supplier payments" on public.supplier_payments for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create index if not exists income_entries_business_date_idx on public.income_entries(business_id, income_date desc, deleted_at);
alter table public.income_entries enable row level security;
drop policy if exists "Owners manage their income" on public.income_entries;
create policy "Owners manage their income" on public.income_entries for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create index if not exists customers_business_idx on public.customers(business_id, deleted_at);
create index if not exists invoices_business_issued_idx on public.invoices(business_id, issued_at desc, deleted_at);
create index if not exists invoice_items_invoice_idx on public.invoice_items(invoice_id, sort_order);
create index if not exists payments_invoice_received_idx on public.payments(invoice_id, received_at desc, deleted_at);

alter table public.customers enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;

drop policy if exists "Owners manage their customers" on public.customers;
create policy "Owners manage their customers" on public.customers for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage their invoices" on public.invoices;
create policy "Owners manage their invoices" on public.invoices for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage their invoice items" on public.invoice_items;
create policy "Owners manage their invoice items" on public.invoice_items for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "Owners manage their payments" on public.payments;
create policy "Owners manage their payments" on public.payments for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

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
  expected_version bigint;
  current_version bigint;
  existing_owner uuid;
  existing_payload jsonb;
  payment_amount bigint;
  invoice_total bigint;
  invoice_paid bigint;
begin
  if p_owner_id is null or p_device_id is null or op_id is null or entity_id is null or payload is null then
    raise exception using errcode = '22023', message = 'Invalid sync operation envelope';
  end if;
  if not exists (select 1 from public.businesses b where b.id = business_id and b.owner_id = p_owner_id) and op_type not like 'Business%' then
    raise exception using errcode = '42501', message = 'Business is not owned by the authenticated user';
  end if;

  select so.owner_id, so.payload into existing_owner, existing_payload
  from public.sync_operations so where so.operation_id = op_id for update;
  if found then
    if existing_owner <> p_owner_id then
      raise exception using errcode = '42501', message = 'Operation belongs to another account';
    end if;
    if existing_payload <> payload then
      raise exception using errcode = '40001', message = 'Operation retry payload conflicts with the original';
    end if;
    return jsonb_build_object('acknowledged', true, 'operationId', op_id, 'idempotent', true);
  end if;

  if op_type = 'BusinessCreated' then
    if exists (select 1 from public.businesses where id = entity_id) then
      raise exception using errcode = '40001', message = 'Business ID already exists with a different operation';
    end if;
    insert into public.businesses (id, owner_id, name, owner_name, business_type, phone, email, address, upi_id, preferred_language, created_at, updated_at, deleted_at)
    values (entity_id, p_owner_id, payload->>'name', payload->>'ownerName', payload->>'businessType', payload->>'phone', payload->>'email', payload->>'address', payload->>'upiId', coalesce(payload->>'preferredLanguage','en'), (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
  elsif op_type = 'BusinessUpdated' then
    expected_version := (payload->>'expectedVersion')::bigint;
    update public.businesses set name = payload->>'name', owner_name = payload->>'ownerName', business_type = payload->>'businessType', phone = payload->>'phone', email = payload->>'email', address = payload->>'address', upi_id = payload->>'upiId', preferred_language = coalesce(payload->>'preferredLanguage','en'), updated_at = (payload->>'updatedAt')::timestamptz, deleted_at = (payload->>'deletedAt')::timestamptz, version = version + 1 where id = entity_id and owner_id = p_owner_id and version = expected_version;
    if not found then raise exception using errcode = '40001', message = 'Business has a newer cloud version or is missing'; end if;
  elsif op_type in ('CustomerCreated', 'CustomerUpdated', 'CustomerArchived') then
    if op_type = 'CustomerCreated' then
      insert into public.customers (id, owner_id, business_id, name, phone, email, notes, created_at, updated_at, deleted_at)
      values (entity_id, p_owner_id, business_id, payload->>'name', payload->>'phone', payload->>'email', payload->>'notes', (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    else
      expected_version := (payload->>'expectedVersion')::bigint;
      select c.version into current_version from public.customers c where c.id = entity_id and c.business_id = fn.business_id and c.owner_id = p_owner_id for update;
      if not found then raise exception using errcode = 'P0002', message = 'Customer not found'; end if;
      if op_type = 'CustomerArchived' then
        update public.customers set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now(), version = version + 1 where id = entity_id and version = expected_version;
      else
        update public.customers set name = payload->>'name', phone = payload->>'phone', email = payload->>'email', notes = payload->>'notes', updated_at = (payload->>'updatedAt')::timestamptz, version = version + 1 where id = entity_id and version = expected_version;
      end if;
      if not found then raise exception using errcode = '40001', message = 'Customer has a newer cloud version'; end if;
    end if;
  elsif op_type = 'InvoiceCreated' then
    if exists (select 1 from public.invoices i where i.business_id = fn.business_id and i.invoice_number = payload->'invoice'->>'invoiceNumber') then
      raise exception using errcode = '40001', message = 'Invoice number already exists with different data';
    end if;
    insert into public.invoices (id, owner_id, business_id, customer_id, invoice_number, issued_at, due_at, subtotal_paise, discount_paise, interest_paise, paid_paise, notes, created_at, updated_at, deleted_at)
    values ((payload->'invoice'->>'id')::uuid, p_owner_id, business_id, (payload->'invoice'->>'customerId')::uuid, payload->'invoice'->>'invoiceNumber', (payload->'invoice'->>'issuedAt')::timestamptz, (payload->'invoice'->>'dueAt')::timestamptz, (payload->'invoice'->>'subtotalPaise')::bigint, coalesce((payload->'invoice'->>'discountPaise')::bigint,0), coalesce((payload->'invoice'->>'interestPaise')::bigint,0), coalesce((payload->'invoice'->>'paidPaise')::bigint,0), payload->'invoice'->>'notes', (payload->'invoice'->>'createdAt')::timestamptz, (payload->'invoice'->>'updatedAt')::timestamptz, (payload->'invoice'->>'deletedAt')::timestamptz);
    insert into public.invoice_items (id, owner_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
    select (item->>'id')::uuid, p_owner_id, (payload->'invoice'->>'id')::uuid, item->>'description', (item->>'quantityMilliunits')::integer, (item->>'unitPricePaise')::bigint, (item->>'lineTotalPaise')::bigint, (item->>'sortOrder')::integer from jsonb_array_elements(payload->'items') item;
  elsif op_type = 'InvoiceUpdated' then
    expected_version := (payload->'invoice'->>'expectedVersion')::bigint;
    update public.invoices set due_at = (payload->'invoice'->>'dueAt')::timestamptz,
      discount_paise = coalesce((payload->'invoice'->>'discountPaise')::bigint, 0),
      interest_paise = coalesce((payload->'invoice'->>'interestPaise')::bigint, 0),
      notes = payload->'invoice'->>'notes', updated_at = now(), version = version + 1
      where id = entity_id and owner_id = p_owner_id and paid_paise = 0 and version = expected_version;
    if not found then raise exception using errcode = '40001', message = 'Invoice has a newer version or payments'; end if;
    delete from public.invoice_items where invoice_id = entity_id and owner_id = p_owner_id;
    insert into public.invoice_items (id, owner_id, invoice_id, description, quantity_milliunits, unit_price_paise, line_total_paise, sort_order)
      select (item->>'id')::uuid, p_owner_id, entity_id, item->>'description', (item->>'quantityMilliunits')::integer,
        (item->>'unitPricePaise')::bigint, (item->>'lineTotalPaise')::bigint, (item->>'sortOrder')::integer
      from jsonb_array_elements(payload->'items') item;
  elsif op_type = 'InvoiceVoided' then
    expected_version := (payload->>'expectedVersion')::bigint;
    update public.invoices set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now(), version = version + 1 where id = entity_id and owner_id = p_owner_id and paid_paise = 0 and version = expected_version;
    if not found then raise exception using errcode = '40001', message = 'Invoice is newer, missing, or already has payments'; end if;
  elsif op_type = 'PaymentRecorded' then
    payment_amount := (payload->>'amountPaise')::bigint;
    select i.subtotal_paise - i.discount_paise + i.interest_paise, i.paid_paise into invoice_total, invoice_paid from public.invoices i where i.id = (payload->>'invoiceId')::uuid and i.business_id = fn.business_id and i.owner_id = p_owner_id and i.deleted_at is null for update;
    if not found or payment_amount <= 0 or payment_amount > invoice_total - invoice_paid then raise exception using errcode = '22003', message = 'Payment exceeds the active invoice balance'; end if;
    insert into public.payments (id, owner_id, business_id, invoice_id, amount_paise, method, note, received_at, created_at, deleted_at)
    values (entity_id, p_owner_id, business_id, (payload->>'invoiceId')::uuid, payment_amount, payload->>'method', payload->>'note', (payload->>'receivedAt')::timestamptz, (payload->>'createdAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    update public.invoices set paid_paise = paid_paise + payment_amount, updated_at = now(), version = version + 1 where id = (payload->>'invoiceId')::uuid;
  elsif op_type = 'PaymentReversed' then
    payment_amount := (payload->>'amountPaise')::bigint;
    update public.payments set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now())
      where id = entity_id and public.payments.business_id = fn.business_id and owner_id = p_owner_id and deleted_at is null;
    if not found then raise exception using errcode = '40001', message = 'Payment is missing or already reversed'; end if;
    update public.invoices set paid_paise = paid_paise - payment_amount, updated_at = now(), version = version + 1
      where id = (payload->>'invoiceId')::uuid and public.invoices.business_id = fn.business_id and owner_id = p_owner_id and paid_paise >= payment_amount;
    if not found then raise exception using errcode = '40001', message = 'Invoice payment balance is no longer valid'; end if;
  elsif op_type in ('IncomeCreated', 'IncomeUpdated', 'IncomeDeleted') then
    if op_type = 'IncomeCreated' then
      insert into public.income_entries (id, owner_id, business_id, amount_paise, description, income_date, created_at, updated_at, deleted_at)
      values (entity_id, p_owner_id, business_id, (payload->>'amountPaise')::bigint, payload->>'description', (payload->>'incomeDate')::timestamptz, (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    elsif op_type = 'IncomeUpdated' then
      update public.income_entries set amount_paise = (payload->>'amountPaise')::bigint, description = payload->>'description', income_date = (payload->>'incomeDate')::timestamptz, updated_at = (payload->>'updatedAt')::timestamptz where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Income record is missing or deleted'; end if;
    else
      update public.income_entries set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now() where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Income record is missing or already deleted'; end if;
    end if;
  elsif op_type in ('ExpenseCreated', 'ExpenseUpdated', 'ExpenseDeleted') then
    if op_type = 'ExpenseCreated' then
      insert into public.expenses (id, owner_id, business_id, amount_paise, category, description, expense_date, created_at, updated_at, deleted_at)
      values (entity_id, p_owner_id, business_id, (payload->>'amountPaise')::bigint, coalesce(payload->>'category', 'Other'), payload->>'description', (payload->>'expenseDate')::timestamptz, (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    elsif op_type = 'ExpenseUpdated' then
      update public.expenses
      set amount_paise = (payload->>'amountPaise')::bigint,
          category = coalesce(payload->>'category', 'Other'),
          description = payload->>'description',
          expense_date = (payload->>'expenseDate')::timestamptz,
          updated_at = (payload->>'updatedAt')::timestamptz
      where id = entity_id and owner_id = p_owner_id and public.expenses.business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Expense is missing or deleted'; end if;
    else
      update public.expenses
      set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now()
      where id = entity_id and owner_id = p_owner_id and public.expenses.business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Expense is missing or already deleted'; end if;
    end if;
  elsif op_type in ('InventoryProductCreated', 'InventoryProductUpdated', 'InventoryProductDeleted', 'InventoryAdjusted') then
    if op_type = 'InventoryProductCreated' then
      insert into public.inventory_products (id, owner_id, business_id, name, sku, unit, stock_milliunits, low_stock_threshold_milliunits, unit_cost_paise, created_at, updated_at, deleted_at)
      values (entity_id, p_owner_id, business_id, payload->>'name', payload->>'sku', coalesce(payload->>'unit','pcs'), coalesce((payload->>'stockMilliunits')::integer,0), coalesce((payload->>'lowStockThresholdMilliunits')::integer,0), coalesce((payload->>'unitCostPaise')::bigint,0), (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    elsif op_type = 'InventoryProductDeleted' then
      update public.inventory_products set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now() where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Inventory product is missing or already deleted'; end if;
    else
      update public.inventory_products set name = payload->>'name', sku = payload->>'sku', unit = coalesce(payload->>'unit','pcs'), stock_milliunits = coalesce((payload->>'stockMilliunits')::integer,0), low_stock_threshold_milliunits = coalesce((payload->>'lowStockThresholdMilliunits')::integer,0), unit_cost_paise = coalesce((payload->>'unitCostPaise')::bigint,0), updated_at = (payload->>'updatedAt')::timestamptz where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Inventory product is missing or deleted'; end if;
    end if;
  elsif op_type in ('SupplierCreated', 'SupplierUpdated', 'SupplierDeleted') then
    if op_type = 'SupplierCreated' then
      insert into public.suppliers (id, owner_id, business_id, name, phone, email, address, notes, created_at, updated_at, deleted_at)
      values (entity_id, p_owner_id, business_id, payload->>'name', payload->>'phone', payload->>'email', payload->>'address', payload->>'notes', (payload->>'createdAt')::timestamptz, (payload->>'updatedAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
    elsif op_type = 'SupplierDeleted' then
      update public.suppliers set deleted_at = coalesce((payload->>'deletedAt')::timestamptz, now()), updated_at = now() where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Supplier is missing or already deleted'; end if;
    else
      update public.suppliers set name = payload->>'name', phone = payload->>'phone', email = payload->>'email', address = payload->>'address', notes = payload->>'notes', updated_at = (payload->>'updatedAt')::timestamptz where id = entity_id and owner_id = p_owner_id and business_id = fn.business_id and deleted_at is null;
      if not found then raise exception using errcode = '40001', message = 'Supplier is missing or deleted'; end if;
    end if;
  elsif op_type = 'SupplierPaymentRecorded' then
    insert into public.supplier_payments (id, owner_id, business_id, supplier_id, amount_paise, paid_at, note, created_at, deleted_at)
    values (entity_id, p_owner_id, business_id, (payload->>'supplierId')::uuid, (payload->>'amountPaise')::bigint, (payload->>'paidAt')::timestamptz, payload->>'note', (payload->>'createdAt')::timestamptz, (payload->>'deletedAt')::timestamptz);
  else
    raise exception using errcode = '0A000', message = 'Unsupported operation type';
  end if;

  insert into public.sync_operations (operation_id, owner_id, business_id, entity_type, entity_id, operation_type, payload, device_id, occurred_at)
  values (op_id, p_owner_id, business_id, p_operation->>'entityType', entity_id, op_type, payload, p_device_id, (p_operation->>'occurredAt')::timestamptz);
  return jsonb_build_object('acknowledged', true, 'operationId', op_id, 'idempotent', false);
exception when unique_violation then
  raise exception using errcode = '40001', message = 'A conflicting cloud record already exists';
end;
$$;

revoke all on function public.apply_sync_operation(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_sync_operation(uuid, uuid, jsonb) to service_role;

-- Consistent, account-scoped snapshot used when a second device signs in.
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
    'payments', coalesce((select jsonb_agg(to_jsonb(p)) from public.payments p where p.owner_id = auth.uid()), '[]'::jsonb)
    , 'income_entries', coalesce((select jsonb_agg(to_jsonb(ie)) from public.income_entries ie where ie.owner_id = auth.uid()), '[]'::jsonb)
    , 'expenses', coalesce((select jsonb_agg(to_jsonb(ex)) from public.expenses ex where ex.owner_id = auth.uid()), '[]'::jsonb)
    , 'inventory_products', coalesce((select jsonb_agg(to_jsonb(ip)) from public.inventory_products ip where ip.owner_id = auth.uid()), '[]'::jsonb)
    , 'inventory_movements', coalesce((select jsonb_agg(to_jsonb(im)) from public.inventory_movements im where im.owner_id = auth.uid()), '[]'::jsonb)
    , 'suppliers', coalesce((select jsonb_agg(to_jsonb(s)) from public.suppliers s where s.owner_id = auth.uid()), '[]'::jsonb)
    , 'supplier_payments', coalesce((select jsonb_agg(to_jsonb(sp)) from public.supplier_payments sp where sp.owner_id = auth.uid()), '[]'::jsonb)
  );
$$;
revoke all on function public.get_sync_snapshot() from public, anon;
grant execute on function public.get_sync_snapshot() to authenticated;
