import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/features/backup/data/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BackupService backupService;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    backupService = BackupService(db);

    final now = DateTime.now().toUtc();
    // Insert test user and business
    await db.into(db.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: 'acc-1',
        displayName: 'Owner 1',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(
        id: 'biz-1',
        accountId: 'acc-1',
        ownerName: 'Owner 1',
        name: 'Super Mart',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'cust-1',
        businessId: 'biz-1',
        name: 'Ramesh Kumar',
        phone: '9876543210',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.invoices).insert(
      InvoicesCompanion.insert(
        id: 'inv-1',
        businessId: 'biz-1',
        customerId: 'cust-1',
        invoiceNumber: 'INV-100',
        issuedAt: now,
        subtotalPaise: 120000,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.invoiceItems).insert(
      InvoiceItemsCompanion.insert(
        id: 'item-1',
        invoiceId: 'inv-1',
        description: 'Rice Bag',
        quantityMilliunits: 1000,
        unitPricePaise: 120000,
        lineTotalPaise: 120000,
        sortOrder: 0,
      ),
    );

    await db.into(db.payments).insert(
      PaymentsCompanion.insert(
        id: 'pay-1',
        businessId: 'biz-1',
        invoiceId: 'inv-1',
        amountPaise: 50000,
        method: 'Cash',
        receivedAt: now,
        createdAt: now,
      ),
    );

    await db.into(db.incomeEntries).insert(
      IncomeEntriesCompanion.insert(
        id: 'inc-1',
        businessId: 'biz-1',
        amountPaise: 25000,
        incomeDate: now,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.expenses).insert(
      ExpensesCompanion.insert(
        id: 'exp-1',
        businessId: 'biz-1',
        amountPaise: 15000,
        category: 'Rent',
        expenseDate: now,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('BackupService Tests', () {
    test('exportBusiness produces complete schema v2 backup with items', () async {
      final jsonStr = await backupService.exportBusiness('biz-1');
      expect(jsonStr.contains('"format": "onebill-backup-v2"'), isTrue);
      expect(jsonStr.contains('Super Mart'), isTrue);
      expect(jsonStr.contains('Ramesh Kumar'), isTrue);
      expect(jsonStr.contains('INV-100'), isTrue);
      expect(jsonStr.contains('Rice Bag'), isTrue);
      expect(jsonStr.contains('Rent'), isTrue);
    });

    test('validateBackup verifies file integrity and counts', () async {
      final jsonStr = await backupService.exportBusiness('biz-1');
      final val = backupService.validateBackup(jsonStr);

      expect(val.businessName, 'Super Mart');
      expect(val.customersCount, 1);
      expect(val.invoicesCount, 1);
      expect(val.invoiceItemsCount, 1);
      expect(val.paymentsCount, 1);
      expect(val.incomeCount, 1);
      expect(val.expensesCount, 1);
    });

    test('validateBackup throws on corrupted JSON', () {
      expect(
        () => backupService.validateBackup('not valid json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('restoreBusiness restores all records into a target business', () async {
      final jsonStr = await backupService.exportBusiness('biz-1');

      // Create a fresh empty business
      final now = DateTime.now().toUtc();
      await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: 'biz-2',
          accountId: 'acc-1',
          ownerName: 'Owner 2',
          name: 'Target Business',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Restore into biz-2
      final res = await backupService.restoreBusiness(
        targetBusinessId: 'biz-2',
        jsonStr: jsonStr,
      );

      expect(res.customersCount, 1);
      expect(res.invoicesCount, 1);

      // Verify records are present under biz-2
      final restoredCust = await (db.select(db.customers)
            ..where((c) => c.businessId.equals('biz-2')))
          .get();
      expect(restoredCust.length, 1);
      expect(restoredCust.first.name, 'Ramesh Kumar');

      final restoredInvoices = await (db.select(db.invoices)
            ..where((i) => i.businessId.equals('biz-2')))
          .get();
      expect(restoredInvoices.length, 1);
      expect(restoredInvoices.first.invoiceNumber, 'INV-100');

      final restoredItems = await (db.select(db.invoiceItems)
            ..where((it) => it.invoiceId.equals(restoredInvoices.first.id)))
          .get();
      expect(restoredItems.length, 1);
      expect(restoredItems.first.description, 'Rice Bag');
    });
  });
}

