import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

class UserAccounts extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get email => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}

class Businesses extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text().references(UserAccounts, #id)();
  TextColumn get ownerName => text()();
  TextColumn get name => text()();
  TextColumn get businessType => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get upiId => text().nullable()();
  TextColumn get preferredLanguage =>
      text().withDefault(const Constant('en'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class LocalSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId => text().nullable().references(UserAccounts, #id)();
  TextColumn get activeBusinessId =>
      text().nullable().references(Businesses, #id)();
  TextColumn get localeCode => text().withDefault(const Constant('en'))();
  DateTimeColumn get updatedAt => dateTime()();
}

class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get phone => text()();
  TextColumn get email => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class Invoices extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get invoiceNumber => text()();
  DateTimeColumn get issuedAt => dateTime()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  IntColumn get subtotalPaise => integer()();
  IntColumn get discountPaise => integer().withDefault(const Constant(0))();
  IntColumn get interestPaise => integer().withDefault(const Constant(0))();
  IntColumn get paidPaise => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class InvoiceItems extends Table {
  TextColumn get id => text()();
  TextColumn get invoiceId => text().references(Invoices, #id)();
  TextColumn get description => text()();
  IntColumn get quantityMilliunits => integer()();
  IntColumn get unitPricePaise => integer()();
  IntColumn get lineTotalPaise => integer()();
  IntColumn get sortOrder => integer()();
  @override
  Set<Column> get primaryKey => {id};
}

class Payments extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get invoiceId => text().references(Invoices, #id)();
  IntColumn get amountPaise => integer()();
  TextColumn get method => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get receivedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class IncomeEntries extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  IntColumn get amountPaise => integer()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get incomeDate => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class Expenses extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  IntColumn get amountPaise => integer()();
  TextColumn get category => text()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get expenseDate => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class InventoryProducts extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get sku => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get stockMilliunits => integer().withDefault(const Constant(0))();
  IntColumn get lowStockThresholdMilliunits =>
      integer().withDefault(const Constant(0))();
  IntColumn get unitCostPaise => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class InventoryMovements extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get productId => text().references(InventoryProducts, #id)();
  IntColumn get deltaMilliunits => integer()();
  TextColumn get reason => text()();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}

class Suppliers extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get name => text()();
  TextColumn get phone => text()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class SupplierPayments extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  IntColumn get amountPaise => integer()();
  DateTimeColumn get paidAt => dateTime()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class SyncOperations extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().nullable()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operationType => text()();
  TextColumn get payloadJson => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    UserAccounts,
    Businesses,
    LocalSessions,
    Customers,
    Invoices,
    InvoiceItems,
    Payments,
    IncomeEntries,
    Expenses,
    InventoryProducts,
    InventoryMovements,
    Suppliers,
    SupplierPayments,
    SyncOperations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'onebill'));
  AppDatabase.forTesting(super.executor);
  @override
  int get schemaVersion => 4;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(incomeEntries);
      if (from < 3) await m.createTable(expenses);
      if (from < 4) {
        await m.createTable(inventoryProducts);
        await m.createTable(inventoryMovements);
        await m.createTable(suppliers);
        await m.createTable(supplierPayments);
      }
    },
    beforeOpen: (details) async => customStatement('PRAGMA foreign_keys = ON'),
  );
}
