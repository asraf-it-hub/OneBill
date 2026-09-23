import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/core/localization/app_localizations.dart';
import 'package:onebill/features/businesses/data/business_repository.dart';
import 'package:onebill/features/invoices/services/pdf_invoice_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BusinessRepository bizRepo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bizRepo = BusinessRepository(db);

    final now = DateTime.now().toUtc();
    await db.into(db.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: 'user-1',
        displayName: 'Test Owner',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('updateLanguage preserves all business profile fields and only updates language', () async {
    final bizId = await bizRepo.createBusiness(
      accountId: 'user-1',
      ownerName: 'Asraf',
      businessName: 'OneBill Store',
      languageCode: 'en',
      phone: '9876543210',
    );

    // Update with full profile
    await bizRepo.updateBusiness(
      businessId: bizId,
      ownerName: 'Asraf',
      name: 'OneBill Store',
      languageCode: 'en',
      phone: '9876543210',
      email: 'test@onebill.app',
      address: '123 Market Street, Hyderabad',
      upiId: 'asraf@upi',
    );

    // Verify initial values
    var biz = await (db.select(db.businesses)..where((b) => b.id.equals(bizId))).getSingle();
    expect(biz.preferredLanguage, 'en');
    expect(biz.phone, '9876543210');
    expect(biz.email, 'test@onebill.app');
    expect(biz.address, '123 Market Street, Hyderabad');
    expect(biz.upiId, 'asraf@upi');

    // Update language to Telugu
    await bizRepo.updateLanguage(businessId: bizId, languageCode: 'te');

    // Verify all fields are preserved and untouched!
    biz = await (db.select(db.businesses)..where((b) => b.id.equals(bizId))).getSingle();
    expect(biz.preferredLanguage, 'te');
    expect(biz.phone, '9876543210');
    expect(biz.email, 'test@onebill.app');
    expect(biz.address, '123 Market Street, Hyderabad');
    expect(biz.upiId, 'asraf@upi');

    // Update language to Hindi
    await bizRepo.updateLanguage(businessId: bizId, languageCode: 'hi');

    biz = await (db.select(db.businesses)..where((b) => b.id.equals(bizId))).getSingle();
    expect(biz.preferredLanguage, 'hi');
    expect(biz.phone, '9876543210');
    expect(biz.email, 'test@onebill.app');
  });

  test('New localization keys are properly translated in Telugu and Hindi', () {
    expect(trLang('Overdue Payments', 'te'), 'గడువు ముగిసిన చెల్లింపులు');
    expect(trLang('Overdue Payments', 'hi'), 'अतिदेय भुगतान');

    expect(trLang('Customer name', 'te'), 'కస్టమర్ పేరు');
    expect(trLang('Customer name', 'hi'), 'ग्राहक का नाम');

    expect(trLang('Mobile number', 'te'), 'మొబైల్ నంబర్');
    expect(trLang('Mobile number', 'hi'), 'मोबाइल नंबर');

    expect(trLang('Save customer', 'te'), 'కస్టమర్‌ను సేవ్ చేయండి');
    expect(trLang('Save customer', 'hi'), 'ग्राहक सहेजें');

    expect(trLang('Income date', 'te'), 'ఆదాయం తేదీ');
    expect(trLang('Income date', 'hi'), 'आय की तारीख');

    expect(trLang('Description (optional)', 'te'), 'వివరణ (ఐచ్ఛికం)');
    expect(trLang('Description (optional)', 'hi'), 'विवरण (वैकल्पिक)');

    expect(trLang('Amount (₹)', 'te'), 'మొత్తం (₹)');
    expect(trLang('Amount (₹)', 'hi'), 'राशि (₹)');

    expect(trLang('day', 'te'), 'రోజు');
    expect(trLang('days', 'te'), 'రోజులు');

    expect(trLang('Fill in line items, payment terms, and adjustments below.', 'te'), 'క్రింద వస్తువులు, చెల్లింపు నిబంధనలు మరియు సర్దుబాట్లను పూరించండి.');
    expect(trLang('Fill in line items, payment terms, and adjustments below.', 'hi'), 'नीचे आइटम, भुगतान शर्तें और समायोजन भरें।');
    expect(trLang('Optional', 'te'), 'ఐచ్ఛికం');
    expect(trLang('Optional', 'hi'), 'वैकल्पिक');
    expect(trLang('Tap to change or remove', 'te'), 'మార్చడానికి లేదా తొలగించడానికి నొక్కండి');
    expect(trLang('Tap to change or remove', 'hi'), 'बदलने या हटाने के लिए टैप करें');
  });

  test('PdfInvoiceService includes invoice notes, business notes and terms in PDF and receipt', () async {
    final pdfService = PdfInvoiceService();
    final now = DateTime.now();
    final business = BusinessesData(
      id: 'biz-1',
      accountId: 'user-1',
      name: 'Sri Krishna Kirana',
      ownerName: 'Krishna',
      phone: '9876543210',
      invoiceNotes: 'Goods once sold cannot be returned without bill.',
      termsAndConditions: 'All disputes are subject to local jurisdiction.',
      preferredLanguage: 'te',
      createdAt: now,
      updatedAt: now,
    );
    final customer = Customer(
      id: 'cust-1',
      businessId: 'biz-1',
      name: 'Ramesh Babu',
      phone: '9123456780',
      createdAt: now,
      updatedAt: now,
    );
    final invoice = Invoice(
      id: 'inv-1',
      businessId: 'biz-1',
      customerId: 'cust-1',
      invoiceNumber: 'INV-2026-001',
      subtotalPaise: 100000,
      discountPaise: 5000,
      interestPaise: 0,
      paidPaise: 0,
      notes: 'Delivered via express delivery.',
      issuedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    final items = [
      InvoiceItem(
        id: 'item-1',
        invoiceId: 'inv-1',
        description: 'Rice Bag 25kg',
        quantityMilliunits: 1000,
        unitPricePaise: 100000,
        lineTotalPaise: 100000,
        sortOrder: 0,
      ),
    ];

    final invoicePdf = await pdfService.generate(
      business: business,
      customer: customer,
      invoice: invoice,
      items: items,
    );
    expect(invoicePdf.isNotEmpty, isTrue);

    final receiptPdf = await pdfService.generatePaperReceiptPdf(
      business: business,
      customer: customer,
      invoice: invoice,
      paperReceiptImage: 'data:image/jpeg;base64,dGVzdA==',
    );
    expect(receiptPdf.isNotEmpty, isTrue);
  });
}
