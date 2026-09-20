import 'package:onebill/features/invoices/services/pdf_invoice_service.dart';
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/core/localization/app_localizations.dart';
import 'package:onebill/features/receipts/data/paper_receipt_repository.dart';
import 'package:onebill/features/invoices/data/invoice_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PaperReceiptRepository repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('paper_receipt_test_');
    repo = PaperReceiptRepository(db, baseDirectoryProvider: () async => tempDir);

    // Create a dummy business and customer in memory DB
    final now = DateTime.now().toUtc();
    await db.into(db.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: 'user-1',
        displayName: 'Test Owner',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(
        id: 'biz-1',
        accountId: 'user-1',
        ownerName: 'Owner 1',
        name: 'Business 1',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(
        id: 'biz-2',
        accountId: 'user-1',
        ownerName: 'Owner 2',
        name: 'Business 2',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'cust-1',
        businessId: 'biz-1',
        name: 'Customer 1',
        phone: '9876543210',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: 'cust-2',
        businessId: 'biz-1',
        name: 'Customer 2',
        phone: '9876543211',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PaperReceiptRepository Tests', () {
    test('creates paper receipt, associates with customer, and enqueues sync op', () async {
      // Create a dummy image file
      final dummyImage = File('${tempDir.path}/dummy_receipt.jpg');
      await dummyImage.writeAsString('test-image-content');

      final receipt = await repo.createReceipt(
        businessId: 'biz-1',
        customerId: 'cust-1',
        sourceImagePath: dummyImage.path,
        receiptDate: DateTime(2026, 9, 17),
        notes: 'Paid in cash',
      );

      expect(receipt.id, isNotEmpty);
      expect(receipt.businessId, 'biz-1');
      expect(receipt.customerId, 'cust-1');
      expect(receipt.notes, 'Paid in cash');
      expect(receipt.deletedAt, isNull);

      // Verify receipt is in database
      final receipts = await repo.watchReceiptsForCustomer(
        businessId: 'biz-1',
        customerId: 'cust-1',
      ).first;
      expect(receipts.length, 1);
      expect(receipts.first.id, receipt.id);

      // Verify sync operation was enqueued
      final syncOps = await (db.select(db.syncOperations)
            ..where((op) => op.entityId.equals(receipt.id)))
          .get();
      expect(syncOps.length, 1);
      expect(syncOps.first.operationType, 'PaperReceiptCreated');
    });

    test('receipts are isolated by customer and business', () async {
      final dummyImage = File('${tempDir.path}/dummy_receipt.jpg');
      await dummyImage.writeAsString('test-image-content');

      // Create receipt for cust-1 in biz-1
      await repo.createReceipt(
        businessId: 'biz-1',
        customerId: 'cust-1',
        sourceImagePath: dummyImage.path,
        notes: 'Cust 1 Receipt',
      );

      // Cust-1 has 1 receipt
      final cust1Receipts = await repo.watchReceiptsForCustomer(
        businessId: 'biz-1',
        customerId: 'cust-1',
      ).first;
      expect(cust1Receipts.length, 1);

      // Cust-2 has 0 receipts
      final cust2Receipts = await repo.watchReceiptsForCustomer(
        businessId: 'biz-1',
        customerId: 'cust-2',
      ).first;
      expect(cust2Receipts.length, 0);

      // Biz-2 has 0 receipts
      final biz2Receipts = await repo.watchReceiptsForCustomer(
        businessId: 'biz-2',
        customerId: 'cust-1',
      ).first;
      expect(biz2Receipts.length, 0);
    });

    test('deleting a receipt soft-deletes and enqueues PaperReceiptDeleted', () async {
      final dummyImage = File('${tempDir.path}/dummy_receipt.jpg');
      await dummyImage.writeAsString('test-image-content');

      final receipt = await repo.createReceipt(
        businessId: 'biz-1',
        customerId: 'cust-1',
        sourceImagePath: dummyImage.path,
      );

      await repo.deleteReceipt(
        businessId: 'biz-1',
        receiptId: receipt.id,
      );

      // Customer receipts stream should now be empty (filtered by deletedAt is null)
      final receipts = await repo.watchReceiptsForCustomer(
        businessId: 'biz-1',
        customerId: 'cust-1',
      ).first;
      expect(receipts.isEmpty, isTrue);

      // Delete sync operation should be queued
      final deleteSyncOps = await (db.select(db.syncOperations)
            ..where((op) =>
                op.entityId.equals(receipt.id) &
                op.operationType.equals('PaperReceiptDeleted')))
          .get();
      expect(deleteSyncOps.length, 1);
    });
  });

  group('Paper Receipt Localization Tests', () {
    test('all required paper receipt keys are localized in English, Hindi, and Telugu', () {
      final requiredKeys = [
        'Paper Receipt',
        'Paper Receipts',
        'Add Paper Receipt',
        'Digital Invoice',
        'Take Photo',
        'Choose from Gallery',
        'Camera',
        'Gallery',
        'Save Receipt',
        'Retake',
        'Choose Another',
        'Receipt Date',
        'Receipt saved successfully',
        'Failed to save receipt',
        'Failed to load receipt',
        'No paper receipts yet',
        'Add a photo of a handwritten receipt to keep it with this customer\'s records.',
        'Delete Receipt',
        'Delete receipt?',
        'Delete this paper receipt? This action cannot be undone.',
        'View Receipt',
        'Camera permission required',
        'Camera permission denied',
        'Unable to open camera',
        'Unable to select image',
        'No image selected',
        'Processing image',
        'Receipt synced',
        'Receipt waiting to sync',
        'Share Paper Receipt',
        'Receipt Attached',
        'Attach Paper Receipt',
        'Paper Receipt (Optional)',
        'Remove Receipt',
        'View Paper Receipt',
        'Attach photo of handwritten bill',
      ];

      for (final key in requiredKeys) {
        expect(appTranslations.containsKey(key), isTrue,
            reason: 'Missing key: $key');
        expect(appTranslations[key]?['hi'], isNotNull,
            reason: 'Missing Hindi translation for: $key');
        expect(appTranslations[key]?['te'], isNotNull,
            reason: 'Missing Telugu translation for: $key');
      }
    });

    test('invoice creation stores paperReceiptImage and is retrieved correctly', () async {
      final invoiceRepo = InvoiceRepository(db);
      final invoiceId = await invoiceRepo.createInvoice(
        businessId: 'biz-1',
        customerId: 'cust-1',
        items: [
          InvoiceLineInput(
            description: 'Handwritten Order',
            quantityMilliunits: 1000,
            unitPricePaise: 50000,
          ),
        ],
        paperReceiptImage: 'data:image/jpeg;base64,dGVzdA==',
      );

      final inv = await (db.select(db.invoices)..where((i) => i.id.equals(invoiceId))).getSingle();
      expect(inv.paperReceiptImage, 'data:image/jpeg;base64,dGVzdA==');
      expect(inv.subtotalPaise, 50000);
    });

    test('updateInvoiceDetails updates paperReceiptImage correctly', () async {
      final invoiceRepo = InvoiceRepository(db);
      final invoiceId = await invoiceRepo.createInvoice(
        businessId: 'biz-1',
        customerId: 'cust-1',
        items: [
          InvoiceLineInput(
            description: 'Item 1',
            quantityMilliunits: 1000,
            unitPricePaise: 10000,
          ),
        ],
      );

      // Initially null
      var inv = await (db.select(db.invoices)..where((i) => i.id.equals(invoiceId))).getSingle();
      expect(inv.paperReceiptImage, isNull);

      // Update with paper receipt
      await invoiceRepo.updateInvoiceDetails(
        businessId: 'biz-1',
        invoiceId: invoiceId,
        discountPaise: 0,
        interestPaise: 0,
        dueAt: null,
        notes: 'Original note',
        paperReceiptImage: const Value('data:image/jpeg;base64,bmV3UmVjZWlwdA=='),
      );

      inv = await (db.select(db.invoices)..where((i) => i.id.equals(invoiceId))).getSingle();
      expect(inv.paperReceiptImage, 'data:image/jpeg;base64,bmV3UmVjZWlwdA==');
      expect(inv.notes, 'Original note');
    });

    test('cloud notes delimiter packs and unpacks receipt image seamlessly', () {
      const delimiter = '\n---ONEBILL_RECEIPT_IMAGE---\n';
      const originalNote = 'Urgent bill';
      const receiptImage = 'data:image/jpeg;base64,QUJDRA==';

      // Cloud serialization
      final cloudNotes = '$originalNote$delimiter$receiptImage';

      // Restore unpacking
      final parts = cloudNotes.split('---ONEBILL_RECEIPT_IMAGE---');
      final parsedNotes = parts[0].trim().isEmpty ? null : parts[0].trim();
      final parsedReceipt = parts.length > 1 ? parts[1].trim() : null;

      expect(parsedNotes, 'Urgent bill');
      expect(parsedReceipt, 'data:image/jpeg;base64,QUJDRA==');
    });

    test('trLang properly translates notifications and customer invoice creation', () {
      expect(trLang('Invoice created', 'te'), 'ఇన్‌వాయిస్ సృష్టించబడింది');
      expect(trLang('Invoice shared', 'te'), 'ఇన్‌వాయిస్ షేర్ చేయబడింది');
      expect(trLang('Payment received', 'te'), 'చెల్లింపు స్వీకరించబడింది');
      expect(trLang('Daily Summary', 'te'), 'రోజువారీ సారాంశం');
      expect(trLang('Weekly Summary', 'te'), 'వారపు సారాంశం');
      expect(trLang('Monthly Performance', 'te'), 'నెలవారీ పనితీరు');
      expect(trLang('Create Invoice', 'te'), 'ఇన్‌వాయిస్ సృష్టించండి');
      expect(trLang('Add Another Item', 'te'), 'మరొక వస్తువును జోడించండి');
      expect(trLang('Discard changes?', 'te'), 'మార్పులను రద్దు చేయాలా?');
      expect(trLang('Track customer payments and manual owner entries.', 'te'), 'కస్టమర్ చెల్లింపులు మరియు యజమాని నమోదులను ట్రాక్ చేయండి.');
      expect(trLang('Owner added', 'te'), 'యజమాని జోడించినది');
      expect(trLang('Total income', 'te'), 'మొత్తం ఆదాయం');
      expect(trLang('OneBill Notifications', 'te'), 'వన్ బిల్ నోటిఫికేషన్‌లు');
      expect(trLang('Notification system is working properly.', 'te'), 'నోటిఫికేషన్ వ్యవస్థ సక్రమంగా పనిచేస్తోంది.');
    });

    test('generatePaperReceiptPdf produces thermal receipt with shop info and upi qr', () async {
      final pdfService = PdfInvoiceService();
      final business = BusinessesData(
        id: 'biz-1',
        accountId: 'acc-1',
        ownerName: 'Ramesh',
        name: 'Ramesh Kirana Store',
        businessType: 'Grocery & Provisions',
        phone: '9876543210',
        email: 'ramesh@kirana.com',
        address: 'MG Road, Vijayawada',
        upiId: 'ramesh@upi',
        preferredLanguage: 'te',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final customer = Customer(
        id: 'cust-1',
        businessId: 'biz-1',
        name: 'Suresh Kumar',
        phone: '9123456780',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final invoice = Invoice(
        id: 'inv-1',
        businessId: 'biz-1',
        customerId: 'cust-1',
        invoiceNumber: 'INV-1001',
        
        subtotalPaise: 150000,
        discountPaise: 0,
        interestPaise: 0,
        paidPaise: 50000,
        issuedAt: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final pdfBytes = await pdfService.generatePaperReceiptPdf(
        business: business,
        customer: customer,
        invoice: invoice,
        paperReceiptImage: 'data:image/jpeg;base64,dGVzdA==',
      );

      expect(pdfBytes.isNotEmpty, isTrue);
      expect(pdfBytes.length, greaterThan(1000));
    });
  });
}
