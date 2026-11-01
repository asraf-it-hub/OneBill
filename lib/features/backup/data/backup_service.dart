import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class BackupValidationResult {
  const BackupValidationResult({
    required this.businessName,
    required this.exportedAt,
    required this.customersCount,
    required this.invoicesCount,
    required this.invoiceItemsCount,
    required this.paymentsCount,
    required this.incomeCount,
    required this.expensesCount,
  });

  final String businessName;
  final DateTime? exportedAt;
  final int customersCount;
  final int invoicesCount;
  final int invoiceItemsCount;
  final int paymentsCount;
  final int incomeCount;
  final int expensesCount;
}

class BackupService {
  BackupService(this._db);
  final AppDatabase _db;
  static const _uuid = Uuid();

  Future<String> exportBusiness(String businessId) async {
    final businesses = await (_db.select(
      _db.businesses,
    )..where((b) => b.id.equals(businessId))).get();

    final customers = await (_db.select(
      _db.customers,
    )..where((c) => c.businessId.equals(businessId) & c.deletedAt.isNull())).get();

    final invoices = await (_db.select(
      _db.invoices,
    )..where((i) => i.businessId.equals(businessId) & i.deletedAt.isNull())).get();

    final invoiceIds = invoices.map((i) => i.id).toList();

    List<InvoiceItem> invoiceItems = [];
    if (invoiceIds.isNotEmpty) {
      invoiceItems = await (_db.select(
        _db.invoiceItems,
      )..where((it) => it.invoiceId.isIn(invoiceIds))).get();
    }

    final payments = await (_db.select(
      _db.payments,
    )..where((p) => p.businessId.equals(businessId) & p.deletedAt.isNull())).get();

    final income = await (_db.select(
      _db.incomeEntries,
    )..where((e) => e.businessId.equals(businessId) & e.deletedAt.isNull())).get();

    final expenses = await (_db.select(
      _db.expenses,
    )..where((e) => e.businessId.equals(businessId) & e.deletedAt.isNull())).get();

    String dt(DateTime v) => v.toUtc().toIso8601String();
    String? dtOpt(DateTime? v) => v?.toUtc().toIso8601String();

    return const JsonEncoder.withIndent('  ').convert({
      'app': 'OneBill',
      'format': 'onebill-backup-v2',
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
              'upiName': b.upiName,
              'paymentQrImage': b.paymentQrImage,
              'logoImage': b.logoImage,
              'website': b.website,
              'gstin': b.gstin,
              'invoiceNotes': b.invoiceNotes,
              'termsAndConditions': b.termsAndConditions,
              'tagline': b.tagline,
              'preferredLanguage': b.preferredLanguage,
              'createdAt': dt(b.createdAt),
              'updatedAt': dt(b.updatedAt),
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
              'dueAt': dtOpt(i.dueAt),
              'subtotalPaise': i.subtotalPaise,
              'discountPaise': i.discountPaise,
              'interestPaise': i.interestPaise,
              'paidPaise': i.paidPaise,
              'notes': i.notes,
              'paperReceiptImage': i.paperReceiptImage,
              'createdAt': dt(i.createdAt),
              'updatedAt': dt(i.updatedAt),
            },
          )
          .toList(),
      'invoiceItems': invoiceItems
          .map(
            (it) => {
              'id': it.id,
              'invoiceId': it.invoiceId,
              'description': it.description,
              'quantityMilliunits': it.quantityMilliunits,
              'unitPricePaise': it.unitPricePaise,
              'lineTotalPaise': it.lineTotalPaise,
              'sortOrder': it.sortOrder,
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
              'note': p.note,
              'receivedAt': dt(p.receivedAt),
              'createdAt': dt(p.createdAt),
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
              'createdAt': dt(e.createdAt),
              'updatedAt': dt(e.updatedAt),
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
              'createdAt': dt(e.createdAt),
              'updatedAt': dt(e.updatedAt),
            },
          )
          .toList(),
    });
  }

  Future<File> exportToFile(String businessId, {String? businessName}) async {
    final jsonString = await exportBusiness(businessId);
    final tempDir = await getTemporaryDirectory();
    final safeName = (businessName ?? 'business')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${tempDir.path}/onebill_backup_${safeName}_$timestamp.json');
    await file.writeAsString(jsonString);
    return file;
  }

  BackupValidationResult validateBackup(String jsonStr) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw const FormatException('The selected file is not a valid JSON document.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid OneBill backup file format.');
    }

    final format = decoded['format'] as String?;
    if (format != 'onebill-backup-v1' && format != 'onebill-backup-v2') {
      throw const FormatException('Unrecognized OneBill backup format.');
    }

    final businesses = decoded['businesses'] as List? ?? [];
    String bizName = 'Unknown Business';
    if (businesses.isNotEmpty && businesses.first is Map) {
      bizName = (businesses.first['name'] as String?)?.trim() ?? bizName;
    }

    final customers = decoded['customers'] as List? ?? [];
    final invoices = decoded['invoices'] as List? ?? [];
    final invoiceItems = decoded['invoiceItems'] as List? ?? [];
    final payments = decoded['payments'] as List? ?? [];
    final income = decoded['income'] as List? ?? [];
    final expenses = decoded['expenses'] as List? ?? [];

    DateTime? exportedAt;
    final dtStr = decoded['exportedAt'] as String?;
    if (dtStr != null) {
      exportedAt = DateTime.tryParse(dtStr);
    }

    return BackupValidationResult(
      businessName: bizName,
      exportedAt: exportedAt,
      customersCount: customers.length,
      invoicesCount: invoices.length,
      invoiceItemsCount: invoiceItems.length,
      paymentsCount: payments.length,
      incomeCount: income.length,
      expensesCount: expenses.length,
    );
  }

  Future<BackupValidationResult> restoreBusiness({
    required String targetBusinessId,
    required String jsonStr,
  }) async {
    final validation = validateBackup(jsonStr);
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('Invalid backup file structure.');
    }

    final sourceBusinessId = decoded['businessId']?.toString();
    final bool isCrossBusiness = sourceBusinessId == null || sourceBusinessId != targetBusinessId;

    final now = DateTime.now().toUtc();
    final customers = (decoded['customers'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final invoices = (decoded['invoices'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final invoiceItems = (decoded['invoiceItems'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final payments = (decoded['payments'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final incomeEntries = (decoded['income'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final expenses = (decoded['expenses'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    await _db.transaction(() async {
      final existingCustOtherBiz = (await (_db.select(_db.customers)
            ..where((c) => c.businessId.isNotValue(targetBusinessId)))
          .get())
          .map((c) => c.id)
          .toSet();

      final existingInvOtherBiz = (await (_db.select(_db.invoices)
            ..where((i) => i.businessId.isNotValue(targetBusinessId)))
          .get())
          .map((i) => i.id)
          .toSet();

      final customerIdMap = <String, String>{};
      final invoiceIdMap = <String, String>{};

      // 1. Restore Customers
      for (final c in customers) {
        final originalId = (c['id'] as String?)?.trim() ?? '';
        final String effectiveId;
        if (isCrossBusiness || originalId.isEmpty || existingCustOtherBiz.contains(originalId)) {
          effectiveId = _uuid.v4();
        } else {
          effectiveId = originalId;
        }
        if (originalId.isNotEmpty) {
          customerIdMap[originalId] = effectiveId;
        }

        final name = (c['name'] as String?)?.trim() ?? 'Customer';
        final phone = (c['phone'] as String?)?.trim() ?? '';
        final email = (c['email'] as String?)?.trim();
        final notes = (c['notes'] as String?)?.trim();
        final createdAt = DateTime.tryParse(c['createdAt'] as String? ?? '')?.toUtc() ?? now;
        final updatedAt = DateTime.tryParse(c['updatedAt'] as String? ?? '')?.toUtc() ?? now;

        await _db.into(_db.customers).insertOnConflictUpdate(
          CustomersCompanion.insert(
            id: effectiveId,
            businessId: targetBusinessId,
            name: name,
            phone: phone,
            email: Value(email?.isEmpty == true ? null : email),
            notes: Value(notes?.isEmpty == true ? null : notes),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );

        await _db.into(_db.syncOperations).insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(targetBusinessId),
            entityType: 'customer',
            entityId: effectiveId,
            operationType: 'CustomerCreated',
            payloadJson: jsonEncode({
              'customer': {
                'id': effectiveId,
                'businessId': targetBusinessId,
                'name': name,
                'phone': phone,
                'email': email,
                'notes': notes,
                'createdAt': createdAt.toIso8601String(),
                'updatedAt': updatedAt.toIso8601String(),
              },
            }),
            createdAt: now,
          ),
        );
      }

      String? fallbackCustomerId;
      Future<String> ensureCustomerId(String originalCustId) async {
        if (originalCustId.isNotEmpty && customerIdMap.containsKey(originalCustId)) {
          return customerIdMap[originalCustId]!;
        }
        if (originalCustId.isNotEmpty) {
          final found = await (_db.select(_db.customers)
                ..where((c) => c.id.equals(originalCustId) & c.businessId.equals(targetBusinessId)))
              .getSingleOrNull();
          if (found != null) {
            customerIdMap[originalCustId] = found.id;
            return found.id;
          }
        }
        if (fallbackCustomerId != null) return fallbackCustomerId!;
        fallbackCustomerId = _uuid.v4();
        await _db.into(_db.customers).insertOnConflictUpdate(
          CustomersCompanion.insert(
            id: fallbackCustomerId!,
            businessId: targetBusinessId,
            name: 'Restored Customer',
            phone: '',
            createdAt: now,
            updatedAt: now,
          ),
        );
        if (originalCustId.isNotEmpty) {
          customerIdMap[originalCustId] = fallbackCustomerId!;
        }
        return fallbackCustomerId!;
      }

      // 2. Restore Invoices
      for (final inv in invoices) {
        final originalId = (inv['id'] as String?)?.trim() ?? '';
        final String effectiveId;
        if (isCrossBusiness || originalId.isEmpty || existingInvOtherBiz.contains(originalId)) {
          effectiveId = _uuid.v4();
        } else {
          effectiveId = originalId;
        }
        if (originalId.isNotEmpty) {
          invoiceIdMap[originalId] = effectiveId;
        }

        final originalCustomerId = (inv['customerId'] as String?)?.trim() ?? '';
        final customerId = await ensureCustomerId(originalCustomerId);

        final invoiceNumber = (inv['invoiceNumber'] as String?)?.trim().isNotEmpty == true
            ? (inv['invoiceNumber'] as String).trim()
            : 'INV-${DateTime.now().millisecondsSinceEpoch}';
        final issuedAt = DateTime.tryParse(inv['issuedAt'] as String? ?? '')?.toUtc() ?? now;
        final dueAt = DateTime.tryParse(inv['dueAt'] as String? ?? '')?.toUtc();
        final subtotal = (inv['subtotalPaise'] as num?)?.toInt() ?? 0;
        final discount = (inv['discountPaise'] as num?)?.toInt() ?? 0;
        final interest = (inv['interestPaise'] as num?)?.toInt() ?? 0;
        final paid = (inv['paidPaise'] as num?)?.toInt() ?? 0;
        final notes = (inv['notes'] as String?)?.trim();
        final receipt = (inv['paperReceiptImage'] as String?)?.trim();
        final createdAt = DateTime.tryParse(inv['createdAt'] as String? ?? '')?.toUtc() ?? now;
        final updatedAt = DateTime.tryParse(inv['updatedAt'] as String? ?? '')?.toUtc() ?? now;

        await _db.into(_db.invoices).insertOnConflictUpdate(
          InvoicesCompanion.insert(
            id: effectiveId,
            businessId: targetBusinessId,
            customerId: customerId,
            invoiceNumber: invoiceNumber,
            issuedAt: issuedAt,
            dueAt: Value(dueAt),
            subtotalPaise: subtotal,
            discountPaise: Value(discount),
            interestPaise: Value(interest),
            paidPaise: Value(paid),
            notes: Value(notes?.isEmpty == true ? null : notes),
            paperReceiptImage: Value(receipt?.isEmpty == true ? null : receipt),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );

        await _db.into(_db.syncOperations).insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(targetBusinessId),
            entityType: 'invoice',
            entityId: effectiveId,
            operationType: 'InvoiceCreated',
            payloadJson: jsonEncode({
              'invoice': {
                'id': effectiveId,
                'businessId': targetBusinessId,
                'customerId': customerId,
                'invoiceNumber': invoiceNumber,
                'subtotalPaise': subtotal,
                'discountPaise': discount,
                'interestPaise': interest,
                'paidPaise': paid,
                'notes': notes,
                'issuedAt': issuedAt.toIso8601String(),
                'dueAt': dueAt?.toIso8601String(),
                'createdAt': createdAt.toIso8601String(),
                'updatedAt': updatedAt.toIso8601String(),
              },
            }),
            createdAt: now,
          ),
        );
      }

      // 3. Restore Invoice Items
      for (final it in invoiceItems) {
        final originalInvoiceId = (it['invoiceId'] as String?)?.trim() ?? '';
        final effectiveInvoiceId = invoiceIdMap[originalInvoiceId] ?? originalInvoiceId;
        final invoiceExists = (invoiceIdMap.values.contains(effectiveInvoiceId)) ||
            ((await (_db.select(_db.invoices)..where((i) => i.id.equals(effectiveInvoiceId))).getSingleOrNull()) != null);
        if (!invoiceExists) continue;

        final itemId = isCrossBusiness ? _uuid.v4() : ((it['id'] as String?) ?? _uuid.v4());
        final description = (it['description'] as String?)?.trim() ?? 'Item';
        final quantity = (it['quantityMilliunits'] as num?)?.toInt() ?? 1000;
        final unitPrice = (it['unitPricePaise'] as num?)?.toInt() ?? 0;
        final lineTotal = (it['lineTotalPaise'] as num?)?.toInt() ?? (quantity * unitPrice ~/ 1000);
        final sortOrder = (it['sortOrder'] as num?)?.toInt() ?? 0;

        await _db.into(_db.invoiceItems).insertOnConflictUpdate(
          InvoiceItemsCompanion.insert(
            id: itemId,
            invoiceId: effectiveInvoiceId,
            description: description,
            quantityMilliunits: quantity,
            unitPricePaise: unitPrice,
            lineTotalPaise: lineTotal,
            sortOrder: sortOrder,
          ),
        );
      }

      // 4. Restore Payments
      for (final p in payments) {
        final originalInvoiceId = (p['invoiceId'] as String?)?.trim() ?? '';
        final effectiveInvoiceId = invoiceIdMap[originalInvoiceId] ?? originalInvoiceId;
        final invoiceExists = (invoiceIdMap.values.contains(effectiveInvoiceId)) ||
            ((await (_db.select(_db.invoices)..where((i) => i.id.equals(effectiveInvoiceId))).getSingleOrNull()) != null);
        if (!invoiceExists) continue;

        final paymentId = isCrossBusiness ? _uuid.v4() : ((p['id'] as String?) ?? _uuid.v4());
        final amount = (p['amountPaise'] as num?)?.toInt() ?? 0;
        final method = (p['method'] as String?)?.trim() ?? 'Cash';
        final note = (p['note'] as String?)?.trim();
        final receivedAt = DateTime.tryParse(p['receivedAt'] as String? ?? '')?.toUtc() ?? now;
        final createdAt = DateTime.tryParse(p['createdAt'] as String? ?? '')?.toUtc() ?? now;

        await _db.into(_db.payments).insertOnConflictUpdate(
          PaymentsCompanion.insert(
            id: paymentId,
            businessId: targetBusinessId,
            invoiceId: effectiveInvoiceId,
            amountPaise: amount,
            method: method,
            note: Value(note?.isEmpty == true ? null : note),
            receivedAt: receivedAt,
            createdAt: createdAt,
          ),
        );

        await _db.into(_db.syncOperations).insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(targetBusinessId),
            entityType: 'payment',
            entityId: paymentId,
            operationType: 'PaymentRecorded',
            payloadJson: jsonEncode({'paymentId': paymentId}),
            createdAt: now,
          ),
        );
      }

      // 5. Restore Income Entries
      for (final inc in incomeEntries) {
        final incomeId = isCrossBusiness ? _uuid.v4() : ((inc['id'] as String?) ?? _uuid.v4());
        final amount = (inc['amountPaise'] as num?)?.toInt() ?? 0;
        final description = (inc['description'] as String?)?.trim();
        final incomeDate = DateTime.tryParse(inc['incomeDate'] as String? ?? '')?.toUtc() ?? now;
        final createdAt = DateTime.tryParse(inc['createdAt'] as String? ?? '')?.toUtc() ?? now;
        final updatedAt = DateTime.tryParse(inc['updatedAt'] as String? ?? '')?.toUtc() ?? now;

        await _db.into(_db.incomeEntries).insertOnConflictUpdate(
          IncomeEntriesCompanion.insert(
            id: incomeId,
            businessId: targetBusinessId,
            amountPaise: amount,
            description: Value(description?.isEmpty == true ? null : description),
            incomeDate: incomeDate,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );

        await _db.into(_db.syncOperations).insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(targetBusinessId),
            entityType: 'income',
            entityId: incomeId,
            operationType: 'IncomeCreated',
            payloadJson: jsonEncode({'incomeId': incomeId}),
            createdAt: now,
          ),
        );
      }

      // 6. Restore Expenses
      for (final exp in expenses) {
        final expenseId = isCrossBusiness ? _uuid.v4() : ((exp['id'] as String?) ?? _uuid.v4());
        final amount = (exp['amountPaise'] as num?)?.toInt() ?? 0;
        final category = (exp['category'] as String?)?.trim() ?? 'General';
        final description = (exp['description'] as String?)?.trim();
        final expenseDate = DateTime.tryParse(exp['expenseDate'] as String? ?? '')?.toUtc() ?? now;
        final createdAt = DateTime.tryParse(exp['createdAt'] as String? ?? '')?.toUtc() ?? now;
        final updatedAt = DateTime.tryParse(exp['updatedAt'] as String? ?? '')?.toUtc() ?? now;

        await _db.into(_db.expenses).insertOnConflictUpdate(
          ExpensesCompanion.insert(
            id: expenseId,
            businessId: targetBusinessId,
            amountPaise: amount,
            category: category,
            description: Value(description?.isEmpty == true ? null : description),
            expenseDate: expenseDate,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );

        await _db.into(_db.syncOperations).insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(targetBusinessId),
            entityType: 'expense',
            entityId: expenseId,
            operationType: 'ExpenseCreated',
            payloadJson: jsonEncode({'expenseId': expenseId}),
            createdAt: now,
          ),
        );
      }
    });

    return validation;
  }
}
