import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/features/businesses/data/business_repository.dart';
import 'package:onebill/features/customers/data/customer_repository.dart';
import 'package:onebill/features/invoices/data/invoice_repository.dart';
import 'package:onebill/features/invoices/services/pdf_invoice_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late BusinessRepository businesses;
  late CustomerRepository customers;
  late InvoiceRepository invoices;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    businesses = BusinessRepository(database);
    customers = CustomerRepository(database);
    invoices = InvoiceRepository(database);
  });

  tearDown(() => database.close());

  test('customers are isolated by business', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'First shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final firstBusinessId = session.activeBusinessId!;
    await customers.create(
      businessId: firstBusinessId,
      name: 'Rahul',
      phone: '9876543210',
    );

    final firstBusiness = await (database.select(
      database.businesses,
    )..where((b) => b.id.equals(firstBusinessId))).getSingle();
    final secondBusinessId = 'business-2';
    final now = DateTime.now().toUtc();
    await database
        .into(database.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: secondBusinessId,
            accountId: firstBusiness.accountId,
            ownerName: 'Owner',
            name: 'Second shop',
            createdAt: now,
            updatedAt: now,
          ),
        );

    expect(await database.select(database.customers).get(), hasLength(1));
    expect(
      await (database.select(
        database.customers,
      )..where((c) => c.businessId.equals(secondBusinessId))).get(),
      isEmpty,
    );
  });

  test(
    'customer edit persists and archive is safe and business-scoped',
    () async {
      await businesses.createLocalWorkspace(
        ownerName: 'Owner',
        businessName: 'First shop',
        languageCode: 'en',
      );
      final session = await database.select(database.localSessions).getSingle();
      final firstBusinessId = session.activeBusinessId!;
      final customerId = await customers.create(
        businessId: firstBusinessId,
        name: 'Rahul',
        phone: '9876543210',
      );
      await customers.update(
        businessId: firstBusinessId,
        customerId: customerId,
        name: 'Rahul Kumar',
        phone: '9876543211',
        email: 'rahul@example.com',
        notes: 'Regular customer',
      );
      final updated = await (database.select(
        database.customers,
      )..where((entry) => entry.id.equals(customerId))).getSingle();
      expect(updated.name, 'Rahul Kumar');
      expect(updated.phone, '9876543211');
      expect(updated.notes, 'Regular customer');

      await expectLater(
        customers.archive(
          businessId: 'another-business',
          customerId: customerId,
        ),
        throwsStateError,
      );
      await customers.archive(
        businessId: firstBusinessId,
        customerId: customerId,
      );
      final archived = await (database.select(
        database.customers,
      )..where((entry) => entry.id.equals(customerId))).getSingle();
      expect(archived.deletedAt, isNotNull);
      expect(await customers.watchCustomers(firstBusinessId).first, isEmpty);
      expect(
        await (database.select(
          database.syncOperations,
        )..where((entry) => entry.entityId.equals(customerId))).get(),
        hasLength(3),
      );
    },
  );

  test('a new business begins empty and can become active', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'First',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final firstId = session.activeBusinessId!;
    await customers.create(
      businessId: firstId,
      name: 'Rahul',
      phone: '9876543210',
    );
    final secondId = await businesses.createBusiness(
      accountId: session.accountId!,
      ownerName: 'Owner',
      businessName: 'Second',
      languageCode: 'te',
    );
    expect(
      await (database.select(
        database.customers,
      )..where((entry) => entry.businessId.equals(secondId))).get(),
      isEmpty,
    );
    await businesses.switchBusiness(
      sessionId: session.id,
      businessId: secondId,
    );
    final updatedSession = await database
        .select(database.localSessions)
        .getSingle();
    expect(updatedSession.activeBusinessId, secondId);
  });

  test('business settings update persists with UPI and language', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'Shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    await businesses.updateBusiness(
      businessId: session.activeBusinessId!,
      ownerName: 'New owner',
      name: 'Updated shop',
      languageCode: 'te',
      phone: '9876543210',
      email: 'owner@example.com',
      address: 'Hyderabad',
      upiId: 'owner@upi',
    );
    final business =
        await (database.select(database.businesses)
              ..where((entry) => entry.id.equals(session.activeBusinessId!)))
            .getSingle();
    expect(business.name, 'Updated shop');
    expect(business.upiId, 'owner@upi');
    expect(business.preferredLanguage, 'te');
  });

  test('payment cannot exceed the invoice balance', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'దుకాణం Shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final businessId = session.activeBusinessId!;
    final customerId = await customers.create(
      businessId: businessId,
      name: 'కిరణ్ Kiran',
      phone: '9876543210',
    );
    final now = DateTime.now().toUtc();
    await database
        .into(database.invoices)
        .insert(
          InvoicesCompanion.insert(
            id: 'invoice-1',
            businessId: businessId,
            customerId: customerId,
            invoiceNumber: 'INV-1',
            issuedAt: now,
            subtotalPaise: 10000,
            createdAt: now,
            updatedAt: now,
          ),
        );

    await expectLater(
      invoices.recordPayment(
        businessId: businessId,
        invoiceId: 'invoice-1',
        amountPaise: 10001,
        method: 'cash',
      ),
      throwsArgumentError,
    );
    final invoice = await (database.select(
      database.invoices,
    )..where((i) => i.id.equals('invoice-1'))).getSingle();
    expect(invoice.paidPaise, 0);
    expect(await database.select(database.payments).get(), isEmpty);
  });

  test('unpaid invoice details can be edited and queued for sync', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'Shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final businessId = session.activeBusinessId!;
    final customerId = await customers.create(
      businessId: businessId,
      name: 'Kiran',
      phone: '9876543210',
    );
    final invoiceId = await invoices.createInvoice(
      businessId: businessId,
      customerId: customerId,
      items: const [
        InvoiceLineInput(
          description: 'Tea',
          quantityMilliunits: 1000,
          unitPricePaise: 1000,
        ),
      ],
    );
    await invoices.updateInvoiceDetails(
      businessId: businessId,
      invoiceId: invoiceId,
      discountPaise: 100,
      interestPaise: 50,
      dueAt: DateTime.utc(2026, 9, 1),
      notes: 'Updated',
    );
    final invoice = await (database.select(
      database.invoices,
    )..where((entry) => entry.id.equals(invoiceId))).getSingle();
    expect(invoice.discountPaise, 100);
    expect(invoice.notes, 'Updated');
    expect(
      await (database.select(
        database.syncOperations,
      )..where((entry) => entry.operationType.equals('InvoiceUpdated'))).get(),
      hasLength(1),
    );
  });

  test(
    'invoice creation stores integer money totals, items, and sync work',
    () async {
      await businesses.createLocalWorkspace(
        ownerName: 'Owner',
        businessName: 'Shop',
        languageCode: 'en',
      );
      final session = await database.select(database.localSessions).getSingle();
      final businessId = session.activeBusinessId!;
      final customerId = await customers.create(
        businessId: businessId,
        name: 'Kiran',
        phone: '9876543210',
      );
      final invoiceId = await invoices.createInvoice(
        businessId: businessId,
        customerId: customerId,
        items: const [
          InvoiceLineInput(
            description: 'Tea',
            quantityMilliunits: 1500,
            unitPricePaise: 2000,
          ),
        ],
        discountPaise: 500,
      );

      final invoice = await (database.select(
        database.invoices,
      )..where((entry) => entry.id.equals(invoiceId))).getSingle();
      expect(invoice.subtotalPaise, 3000);
      expect(invoices.total(invoice), 2500);
      expect(
        await (database.select(
          database.invoiceItems,
        )..where((item) => item.invoiceId.equals(invoiceId))).get(),
        hasLength(1),
      );
      expect(
        await (database.select(
          database.syncOperations,
        )..where((operation) => operation.entityId.equals(invoiceId))).get(),
        hasLength(1),
      );
    },
  );

  test('partial payments accumulate and retain their history', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'దుకాణం Shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final businessId = session.activeBusinessId!;
    final customerId = await customers.create(
      businessId: businessId,
      name: 'కిరణ్ Kiran',
      phone: '9876543210',
    );
    final invoiceId = await invoices.createInvoice(
      businessId: businessId,
      customerId: customerId,
      items: const [
        InvoiceLineInput(
          description: 'సేవ Service',
          quantityMilliunits: 1000,
          unitPricePaise: 10000,
        ),
      ],
    );

    await invoices.recordPayment(
      businessId: businessId,
      invoiceId: invoiceId,
      amountPaise: 3000,
      method: 'Cash',
    );
    await invoices.recordPayment(
      businessId: businessId,
      invoiceId: invoiceId,
      amountPaise: 2000,
      method: 'UPI',
    );
    final invoice = await (database.select(
      database.invoices,
    )..where((entry) => entry.id.equals(invoiceId))).getSingle();
    expect(invoice.paidPaise, 5000);
    expect(invoices.balance(invoice), 5000);
    expect(
      await (database.select(
        database.payments,
      )..where((payment) => payment.invoiceId.equals(invoiceId))).get(),
      hasLength(2),
    );
  });

  test(
    'invoice status and customer outstanding reflect payment and due date',
    () async {
      await businesses.createLocalWorkspace(
        ownerName: 'Owner',
        businessName: 'Shop',
        languageCode: 'en',
      );
      final session = await database.select(database.localSessions).getSingle();
      final businessId = session.activeBusinessId!;
      final customerId = await customers.create(
        businessId: businessId,
        name: 'Kiran',
        phone: '9876543210',
      );
      final invoiceId = await invoices.createInvoice(
        businessId: businessId,
        customerId: customerId,
        dueAt: DateTime(2020, 1, 1),
        items: const [
          InvoiceLineInput(
            description: 'Service',
            quantityMilliunits: 1500,
            unitPricePaise: 10000,
          ),
        ],
      );
      final created = await (database.select(
        database.invoices,
      )..where((entry) => entry.id.equals(invoiceId))).getSingle();
      expect(invoices.total(created), 15000);
      expect(invoices.status(created), InvoicePaymentStatus.overdue);

      await invoices.recordPayment(
        businessId: businessId,
        invoiceId: invoiceId,
        amountPaise: 5000,
        method: 'Cash',
      );
      final partlyPaid = await (database.select(
        database.invoices,
      )..where((entry) => entry.id.equals(invoiceId))).getSingle();
      expect(invoices.balance(partlyPaid), 10000);
      expect(invoices.status(partlyPaid), InvoicePaymentStatus.overdue);

      await invoices.recordPayment(
        businessId: businessId,
        invoiceId: invoiceId,
        amountPaise: 10000,
        method: 'Cash',
      );
      final paid = await (database.select(
        database.invoices,
      )..where((entry) => entry.id.equals(invoiceId))).getSingle();
      expect(invoices.status(paid), InvoicePaymentStatus.paid);
    },
  );

  test('PDF invoice is generated from stored invoice data', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Owner',
      businessName: 'Shop',
      languageCode: 'en',
    );
    final session = await database.select(database.localSessions).getSingle();
    final businessId = session.activeBusinessId!;
    final customerId = await customers.create(
      businessId: businessId,
      name: 'Kiran',
      phone: '9876543210',
    );
    final invoiceId = await invoices.createInvoice(
      businessId: businessId,
      customerId: customerId,
      items: const [
        InvoiceLineInput(
          description: 'Service',
          quantityMilliunits: 1000,
          unitPricePaise: 10000,
        ),
      ],
    );
    final business = await (database.select(
      database.businesses,
    )..where((entry) => entry.id.equals(businessId))).getSingle();
    final customer = await (database.select(
      database.customers,
    )..where((entry) => entry.id.equals(customerId))).getSingle();
    final invoice = await (database.select(
      database.invoices,
    )..where((entry) => entry.id.equals(invoiceId))).getSingle();
    final items = await (database.select(
      database.invoiceItems,
    )..where((entry) => entry.invoiceId.equals(invoiceId))).get();

    final bytes = await PdfInvoiceService().generate(
      business: business,
      customer: customer,
      invoice: invoice,
      items: items,
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });
}
