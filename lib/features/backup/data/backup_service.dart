import 'dart:convert';
import '../../../core/database/app_database.dart';

class BackupService {
  BackupService(this._db);
  final AppDatabase _db;
  Future<String> exportBusiness(String businessId) async {
    final businesses = await (_db.select(
      _db.businesses,
    )..where((b) => b.id.equals(businessId))).get();
    final customers = await (_db.select(
      _db.customers,
    )..where((c) => c.businessId.equals(businessId))).get();
    final invoices = await (_db.select(
      _db.invoices,
    )..where((i) => i.businessId.equals(businessId))).get();
    final payments = await (_db.select(
      _db.payments,
    )..where((p) => p.businessId.equals(businessId))).get();
    final income = await (_db.select(
      _db.incomeEntries,
    )..where((e) => e.businessId.equals(businessId))).get();
    final expenses = await (_db.select(
      _db.expenses,
    )..where((e) => e.businessId.equals(businessId))).get();
    final products = await (_db.select(
      _db.inventoryProducts,
    )..where((p) => p.businessId.equals(businessId))).get();
    final suppliers = await (_db.select(
      _db.suppliers,
    )..where((s) => s.businessId.equals(businessId))).get();
    String dt(DateTime v) => v.toUtc().toIso8601String();
    return jsonEncode({
      'format': 'onebill-backup-v1',
      'exportedAt': dt(DateTime.now()),
      'businessId': businessId,
      'businesses': businesses
          .map(
            (b) => {
              'id': b.id,
              'name': b.name,
              'ownerName': b.ownerName,
              'businessType': b.businessType,
              'phone': b.phone,
              'email': b.email,
              'address': b.address,
              'upiId': b.upiId,
              'paymentQrImage': b.paymentQrImage,
              'preferredLanguage': b.preferredLanguage,
            },
          )
          .toList(),
      'customers': customers
          .map(
            (c) => {
              'id': c.id,
              'name': c.name,
              'phone': c.phone,
              'email': c.email,
              'notes': c.notes,
              'createdAt': dt(c.createdAt),
              'updatedAt': dt(c.updatedAt),
            },
          )
          .toList(),
      'invoices': invoices
          .map(
            (i) => {
              'id': i.id,
              'customerId': i.customerId,
              'invoiceNumber': i.invoiceNumber,
              'issuedAt': dt(i.issuedAt),
              'subtotalPaise': i.subtotalPaise,
              'discountPaise': i.discountPaise,
              'interestPaise': i.interestPaise,
              'paidPaise': i.paidPaise,
            },
          )
          .toList(),
      'payments': payments
          .map(
            (p) => {
              'id': p.id,
              'invoiceId': p.invoiceId,
              'amountPaise': p.amountPaise,
              'method': p.method,
              'receivedAt': dt(p.receivedAt),
            },
          )
          .toList(),
      'income': income
          .map(
            (e) => {
              'id': e.id,
              'amountPaise': e.amountPaise,
              'description': e.description,
              'incomeDate': dt(e.incomeDate),
            },
          )
          .toList(),
      'expenses': expenses
          .map(
            (e) => {
              'id': e.id,
              'amountPaise': e.amountPaise,
              'category': e.category,
              'description': e.description,
              'expenseDate': dt(e.expenseDate),
            },
          )
          .toList(),
      'inventory': products
          .map(
            (p) => {
              'id': p.id,
              'name': p.name,
              'sku': p.sku,
              'unit': p.unit,
              'stockMilliunits': p.stockMilliunits,
              'lowStockThresholdMilliunits': p.lowStockThresholdMilliunits,
              'unitCostPaise': p.unitCostPaise,
            },
          )
          .toList(),
      'suppliers': suppliers
          .map(
            (s) => {
              'id': s.id,
              'name': s.name,
              'phone': s.phone,
              'email': s.email,
            },
          )
          .toList(),
    });
  }
}
