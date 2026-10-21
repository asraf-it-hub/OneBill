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
  TextColumn get paymentQrImage => text().nullable()();
  TextColumn get logoImage => text().nullable()();
  TextColumn get website => text().nullable()();
  TextColumn get gstin => text().nullable()();
  TextColumn get upiName => text().nullable()();
  TextColumn get invoiceNotes => text().nullable()();
  TextColumn get termsAndConditions => text().nullable()();
  TextColumn get tagline => text().nullable()();
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
  TextColumn get paperReceiptImage => text().nullable()();
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

class AppNotifications extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().nullable()();
  TextColumn get category => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get entityType => text().nullable()();
  TextColumn get entityId => text().nullable()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isHandled => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get scheduledAt => dateTime().nullable()();
  TextColumn get payloadJson => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class NotificationPreferences extends Table {
  TextColumn get categoryKey => text()();
  BoolColumn get isEnabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {categoryKey};
}

class NotificationSettings extends Table {
  TextColumn get id => text()();
  BoolColumn get masterEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get quietHoursEnabled =>
      boolean().withDefault(const Constant(true))();
  TextColumn get quietHoursStart =>
      text().withDefault(const Constant('22:00'))();
  TextColumn get quietHoursEnd => text().withDefault(const Constant('07:00'))();
  IntColumn get retentionDays => integer().withDefault(const Constant(365))();
  BoolColumn get permissionRequested =>
      boolean().withDefault(const Constant(false))();
  TextColumn get lastOverdueSignature => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}

class InvoiceSequences extends Table {
  TextColumn get businessId => text().references(Businesses, #id)();
  IntColumn get lastSequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {businessId};
}

class PaperReceipts extends Table {
  TextColumn get id => text()();
  TextColumn get businessId => text().references(Businesses, #id)();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get imagePath => text()();
  TextColumn get remoteImageUrl => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get receiptDate => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

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
    SyncOperations,
    AppNotifications,
    NotificationPreferences,
    NotificationSettings,
    InvoiceSequences,
    PaperReceipts,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'onebill'));
  AppDatabase.forTesting(super.executor);
  @override
  int get schemaVersion => 12;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(incomeEntries);
      if (from < 3) await m.createTable(expenses);
      if (from < 5) {
        await m.addColumn(businesses, businesses.paymentQrImage);
      }
      if (from < 6) {
        await m.createTable(appNotifications);
        await m.createTable(notificationPreferences);
        await m.createTable(notificationSettings);
      }
      if (from < 7) {
        await m.createTable(invoiceSequences);
      }
      if (from < 8) {
        await m.addColumn(
          notificationSettings,
          notificationSettings.lastOverdueSignature,
        );
      }
      if (from < 9) {
        await m.addColumn(businesses, businesses.logoImage);
        await m.addColumn(businesses, businesses.website);
        await m.addColumn(businesses, businesses.gstin);
        await m.addColumn(businesses, businesses.upiName);
        await m.addColumn(businesses, businesses.invoiceNotes);
        await m.addColumn(businesses, businesses.termsAndConditions);
        await m.addColumn(businesses, businesses.tagline);
      }
      if (from < 10) {
        await m.createTable(paperReceipts);
      }
      if (from < 11) {
        await m.addColumn(invoices, invoices.paperReceiptImage);
      }
      if (from < 12) {
        // Inventory and supplier features were removed from the product, but
        // old installations may still contain user data in these legacy
        // tables. Leave them untouched during upgrade: they are not exposed
        // by the current schema or repositories, and preserving them avoids
        // destructive data loss. Fresh databases never create these tables.
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON;');
      await customStatement('PRAGMA journal_mode = WAL;');
    },
  );

  Future<void> clearAllTables() async {
    await customStatement('PRAGMA foreign_keys = OFF;');
    try {
      await transaction(() async {
        for (final table in allTables) {
          await delete(table).go();
        }
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON;');
    }
  }

  /// Deletes all local records associated with [accountId], preserving any other accounts.
  Future<void> deleteAccountData(String accountId) async {
    await customStatement('PRAGMA foreign_keys = OFF;');
    try {
      await transaction(() async {
        final businessRows = await (select(
          businesses,
        )..where((b) => b.accountId.equals(accountId))).get();
        final businessIds = businessRows.map((b) => b.id).toList();

        if (businessIds.isNotEmpty) {
          final invoiceRows = await (select(
            invoices,
          )..where((i) => i.businessId.isIn(businessIds))).get();
          final invoiceIds = invoiceRows.map((i) => i.id).toList();
          if (invoiceIds.isNotEmpty) {
            await (delete(
              invoiceItems,
            )..where((it) => it.invoiceId.isIn(invoiceIds))).go();
          }
          await (delete(
            payments,
          )..where((p) => p.businessId.isIn(businessIds))).go();
          await (delete(
            invoices,
          )..where((i) => i.businessId.isIn(businessIds))).go();
          await (delete(
            paperReceipts,
          )..where((r) => r.businessId.isIn(businessIds))).go();
          await (delete(
            customers,
          )..where((c) => c.businessId.isIn(businessIds))).go();
          await (delete(
            expenses,
          )..where((e) => e.businessId.isIn(businessIds))).go();
          await (delete(
            incomeEntries,
          )..where((ie) => ie.businessId.isIn(businessIds))).go();
          await (delete(
            syncOperations,
          )..where((s) => s.businessId.isIn(businessIds))).go();
          await (delete(
            appNotifications,
          )..where((n) => n.businessId.isIn(businessIds))).go();
          await (delete(
            invoiceSequences,
          )..where((seq) => seq.businessId.isIn(businessIds))).go();
          await (delete(businesses)..where((b) => b.id.isIn(businessIds))).go();
        }

        await (delete(
          localSessions,
        )..where((s) => s.accountId.equals(accountId))).go();
        await (delete(userAccounts)..where((u) => u.id.equals(accountId))).go();

        final remainingAccounts = await select(userAccounts).get();
        if (remainingAccounts.isEmpty) {
          await delete(notificationPreferences).go();
          await delete(notificationSettings).go();
        }
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON;');
    }
  }
}
