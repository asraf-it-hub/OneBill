import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/features/income/data/income_repository.dart';
import 'package:onebill/features/invoices/data/invoice_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late IncomeRepository incomeRepo;
  late InvoiceRepository invoiceRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    incomeRepo = IncomeRepository(db);
    invoiceRepo = InvoiceRepository(db);
  });

  tearDown(() => db.close());

  test('IncomeRepository.restore un-deletes income and queues sync op', () async {
    final now = DateTime.now().toUtc();
    const bizId = 'test-biz';
    const incId = 'income-123';

    await db.into(db.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: 'acc-1',
        displayName: 'Owner',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(
        id: bizId,
        accountId: 'acc-1',
        ownerName: 'Owner',
        name: 'My Shop',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.incomeEntries).insert(
      IncomeEntriesCompanion.insert(
        id: incId,
        businessId: bizId,
        amountPaise: 50000,
        incomeDate: now,
        createdAt: now,
        updatedAt: now,
        deletedAt: Value(now),
      ),
    );

    final deleted = await (db.select(db.incomeEntries)..where((e) => e.id.equals(incId))).getSingle();
    expect(deleted.deletedAt, isNotNull);

    await incomeRepo.restore(businessId: bizId, id: incId);

    final restored = await (db.select(db.incomeEntries)..where((e) => e.id.equals(incId))).getSingle();
    expect(restored.deletedAt, isNull);

    final ops = await (db.select(db.syncOperations)..where((op) => op.entityId.equals(incId))).get();
    expect(ops.any((op) => op.operationType == 'IncomeUpdated'), isTrue);
  });

  test('InvoiceRepository.restoreInvoice un-deletes invoice and queues sync op', () async {
    final now = DateTime.now().toUtc();
    const bizId = 'test-biz';
    const invId = 'inv-123';
    const custId = 'cust-123';

    await db.into(db.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: 'acc-1',
        displayName: 'Owner',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(
        id: bizId,
        accountId: 'acc-1',
        ownerName: 'Owner',
        name: 'My Shop',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: custId,
        businessId: bizId,
        name: 'Customer 1',
        phone: '9876543210',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.into(db.invoices).insert(
      InvoicesCompanion.insert(
        id: invId,
        businessId: bizId,
        customerId: custId,
        invoiceNumber: 'INV-001',
        subtotalPaise: 10000,
        discountPaise: const Value(0),
        interestPaise: const Value(0),
        paidPaise: const Value(0),
        issuedAt: now,
        createdAt: now,
        updatedAt: now,
        deletedAt: Value(now),
      ),
    );

    await invoiceRepo.restoreInvoice(businessId: bizId, invoiceId: invId);

    final restored = await (db.select(db.invoices)..where((i) => i.id.equals(invId))).getSingle();
    expect(restored.deletedAt, isNull);

    final ops = await (db.select(db.syncOperations)..where((op) => op.entityId.equals(invId))).get();
    expect(ops.any((op) => op.operationType == 'InvoiceUpdated'), isTrue);
  });
}
