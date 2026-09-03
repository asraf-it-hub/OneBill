import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';

class SyncWorker {
  SyncWorker(this._database, this._client);
  final AppDatabase _database;
  final SupabaseClient _client;
  bool _running = false;

  Future<void> restoreAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    dynamic rawSnapshot;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        rawSnapshot = await _client.rpc('get_sync_snapshot');
        break;
      } on PostgrestException catch (error) {
        if (error.code != 'PGRST003' || attempt == 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
    final snapshot = Map<String, dynamic>.from(rawSnapshot as Map);
    final businesses = List<Map<String, dynamic>>.from(
      (snapshot['businesses'] as List? ?? []).map(
        (r) => Map<String, dynamic>.from(r as Map),
      ),
    );
    final allCustomers = _snapshotRows(snapshot, 'customers');
    final allInvoices = _snapshotRows(snapshot, 'invoices');
    final allItems = _snapshotRows(snapshot, 'invoice_items');
    final allPayments = _snapshotRows(snapshot, 'payments');
    final allIncome = _snapshotRows(snapshot, 'income_entries');
    final allExpenses = _snapshotRows(snapshot, 'expenses');
    final allInventory = _snapshotRows(snapshot, 'inventory_products');
    final allMovements = _snapshotRows(snapshot, 'inventory_movements');
    final allSuppliers = _snapshotRows(snapshot, 'suppliers');
    final allSupplierPayments = _snapshotRows(snapshot, 'supplier_payments');
    if (businesses.isEmpty) return;
    final now = DateTime.now().toUtc();
    await _database
        .into(_database.userAccounts)
        .insertOnConflictUpdate(
          UserAccountsCompanion.insert(
            id: user.id,
            displayName: user.email ?? 'Owner',
            email: Value(user.email),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final row in businesses) {
      await _database
          .into(_database.businesses)
          .insertOnConflictUpdate(
            BusinessesCompanion.insert(
              id: row['id'] as String,
              accountId: user.id,
              ownerName: row['owner_name'] as String? ?? '',
              name: row['name'] as String? ?? '',
              businessType: Value(row['business_type'] as String?),
              phone: Value(row['phone'] as String?),
              email: Value(row['email'] as String?),
              address: Value(row['address'] as String?),
              upiId: Value(row['upi_id'] as String?),
              preferredLanguage: Value(
                row['preferred_language'] as String? ?? 'en',
              ),
              createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
              updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
              deletedAt: Value(
                (row['deleted_at'] as String?) == null
                    ? null
                    : DateTime.parse(row['deleted_at'] as String).toUtc(),
              ),
            ),
          );
    }
    final businessIds = businesses.map((r) => r['id'] as String).toList();
    for (final businessId in businessIds) {
      final customers = allCustomers.where(
        (r) => r['business_id'] == businessId,
      );
      for (final row in customers) {
        await _database
            .into(_database.customers)
            .insertOnConflictUpdate(
              CustomersCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                name: row['name'] as String? ?? '',
                phone: row['phone'] as String? ?? '',
                email: Value(row['email'] as String?),
                notes: Value(row['notes'] as String?),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final invoices = allInvoices.where((r) => r['business_id'] == businessId);
      for (final row in invoices) {
        await _database
            .into(_database.invoices)
            .insertOnConflictUpdate(
              InvoicesCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                customerId: row['customer_id'] as String,
                invoiceNumber: row['invoice_number'] as String,
                issuedAt: DateTime.parse(row['issued_at'] as String).toUtc(),
                dueAt: Value(
                  (row['due_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['due_at'] as String).toUtc(),
                ),
                subtotalPaise: row['subtotal_paise'] as int,
                discountPaise: Value(row['discount_paise'] as int? ?? 0),
                interestPaise: Value(row['interest_paise'] as int? ?? 0),
                paidPaise: Value(row['paid_paise'] as int? ?? 0),
                notes: Value(row['notes'] as String?),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
        final items = allItems.where((r) => r['invoice_id'] == row['id']);
        for (final item in items) {
          await _database
              .into(_database.invoiceItems)
              .insertOnConflictUpdate(
                InvoiceItemsCompanion.insert(
                  id: item['id'] as String,
                  invoiceId: row['id'] as String,
                  description: item['description'] as String,
                  quantityMilliunits: item['quantity_milliunits'] as int,
                  unitPricePaise: item['unit_price_paise'] as int,
                  lineTotalPaise: item['line_total_paise'] as int,
                  sortOrder: item['sort_order'] as int,
                ),
              );
        }
      }
      final payments = allPayments.where((r) => r['business_id'] == businessId);
      for (final row in payments) {
        await _database
            .into(_database.payments)
            .insertOnConflictUpdate(
              PaymentsCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                invoiceId: row['invoice_id'] as String,
                amountPaise: row['amount_paise'] as int,
                method: row['method'] as String,
                note: Value(row['note'] as String?),
                receivedAt: DateTime.parse(
                  row['received_at'] as String,
                ).toUtc(),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final income = allIncome.where((r) => r['business_id'] == businessId);
      for (final row in income) {
        await _database
            .into(_database.incomeEntries)
            .insertOnConflictUpdate(
              IncomeEntriesCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                amountPaise: row['amount_paise'] as int,
                description: Value(row['description'] as String?),
                incomeDate: DateTime.parse(
                  row['income_date'] as String,
                ).toUtc(),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final expenses = allExpenses.where((r) => r['business_id'] == businessId);
      for (final row in expenses) {
        await _database
            .into(_database.expenses)
            .insertOnConflictUpdate(
              ExpensesCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                amountPaise: row['amount_paise'] as int,
                category: row['category'] as String? ?? 'Other',
                description: Value(row['description'] as String?),
                expenseDate: DateTime.parse(
                  row['expense_date'] as String,
                ).toUtc(),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final inventory = allInventory.where(
        (r) => r['business_id'] == businessId,
      );
      for (final row in inventory) {
        await _database
            .into(_database.inventoryProducts)
            .insertOnConflictUpdate(
              InventoryProductsCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                name: row['name'] as String? ?? '',
                sku: Value(row['sku'] as String?),
                unit: Value(row['unit'] as String? ?? 'pcs'),
                stockMilliunits: Value(row['stock_milliunits'] as int? ?? 0),
                lowStockThresholdMilliunits: Value(
                  row['low_stock_threshold_milliunits'] as int? ?? 0,
                ),
                unitCostPaise: Value(row['unit_cost_paise'] as int? ?? 0),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final movements = allMovements.where(
        (r) => r['business_id'] == businessId,
      );
      for (final row in movements) {
        await _database
            .into(_database.inventoryMovements)
            .insertOnConflictUpdate(
              InventoryMovementsCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                productId: row['product_id'] as String,
                deltaMilliunits: row['delta_milliunits'] as int,
                reason: row['reason'] as String? ?? 'Adjustment',
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
              ),
            );
      }
      final suppliers = allSuppliers.where(
        (r) => r['business_id'] == businessId,
      );
      for (final row in suppliers) {
        await _database
            .into(_database.suppliers)
            .insertOnConflictUpdate(
              SuppliersCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                name: row['name'] as String? ?? '',
                phone: row['phone'] as String? ?? '',
                email: Value(row['email'] as String?),
                address: Value(row['address'] as String?),
                notes: Value(row['notes'] as String?),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
      final supplierPayments = allSupplierPayments.where(
        (r) => r['business_id'] == businessId,
      );
      for (final row in supplierPayments) {
        await _database
            .into(_database.supplierPayments)
            .insertOnConflictUpdate(
              SupplierPaymentsCompanion.insert(
                id: row['id'] as String,
                businessId: businessId,
                supplierId: row['supplier_id'] as String,
                amountPaise: row['amount_paise'] as int,
                paidAt: DateTime.parse(row['paid_at'] as String).toUtc(),
                note: Value(row['note'] as String?),
                createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
                deletedAt: Value(
                  (row['deleted_at'] as String?) == null
                      ? null
                      : DateTime.parse(row['deleted_at'] as String).toUtc(),
                ),
              ),
            );
      }
    }
    await _database
        .into(_database.localSessions)
        .insert(
          LocalSessionsCompanion.insert(
            accountId: Value(user.id),
            activeBusinessId: Value(businessIds.first),
            updatedAt: now,
          ),
        );
  }

  List<Map<String, dynamic>> _snapshotRows(
    Map<String, dynamic> snapshot,
    String key,
  ) => List<Map<String, dynamic>>.from(
    (snapshot[key] as List? ?? []).map(
      (r) => Map<String, dynamic>.from(r as Map),
    ),
  );

  Future<void> syncBusiness(String businessId) async {
    if (_running || _client.auth.currentSession == null) return;
    _running = true;
    try {
      await _requeueTransientFailures(businessId);
      final operations =
          await (_database.select(_database.syncOperations)
                ..where(
                  (operation) =>
                      operation.businessId.equals(businessId) &
                      operation.status.equals('pending'),
                )
                ..orderBy([
                  (operation) => OrderingTerm.asc(operation.createdAt),
                ])
                ..limit(100))
              .get();
      if (operations.isEmpty) return;
      final deviceId = _client.auth.currentSession!.user.id;
      final payload = <Map<String, Object?>>[];
      for (final operation in operations) {
        try {
          payload.add(await _toPayload(operation));
        } catch (error) {
          await _markFailed(operation.id, 'Could not build snapshot: $error');
        }
      }
      if (payload.isEmpty) return;
      final result = await _client.functions.invoke(
        'sync',
        body: {'deviceId': deviceId, 'operations': payload},
      );
      final body = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      final acknowledged = (body['acknowledgedOperationIds'] as List? ?? [])
          .whereType<String>()
          .toSet();
      final conflicts = (body['conflicts'] as List? ?? [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      final failed = (body['failed'] as List? ?? [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      for (final operation in operations) {
        if (acknowledged.contains(operation.id)) {
          await _markSynced(operation.id);
        } else {
          final conflict = conflicts.cast<Map<String, dynamic>?>().firstWhere(
            (entry) => entry?['operationId'] == operation.id,
            orElse: () => null,
          );
          final failure = failed.cast<Map<String, dynamic>?>().firstWhere(
            (entry) => entry?['operationId'] == operation.id,
            orElse: () => null,
          );
          await _markFailed(
            operation.id,
            (conflict?['reason'] ??
                    failure?['reason'] ??
                    'Sync was not acknowledged')
                .toString(),
          );
        }
      }
    } catch (error) {
      final message = _formatSyncError(error);
      for (final operation in await _pending(businessId)) {
        await _markFailed(operation.id, message);
      }
    } finally {
      _running = false;
    }
  }

  Future<List<SyncOperation>> _pending(String businessId) =>
      (_database.select(_database.syncOperations)..where(
            (operation) =>
                operation.businessId.equals(businessId) &
                operation.status.equals('pending'),
          ))
          .get();

  Future<void> _requeueTransientFailures(String businessId) async {
    final retryBefore = DateTime.now().toUtc().subtract(
      const Duration(seconds: 30),
    );
    final query = _database.select(_database.syncOperations)
      ..where(
        (operation) =>
            operation.businessId.equals(businessId) &
            operation.status.like('%could not reach the server%') &
            (operation.lastAttemptAt.isNull() |
                operation.lastAttemptAt.isSmallerThanValue(retryBefore)),
      );
    final operations = await query.get();
    for (final operation in operations) {
      await (_database.update(_database.syncOperations)
            ..where((row) => row.id.equals(operation.id)))
          .write(const SyncOperationsCompanion(status: Value('pending')));
    }
  }

  Future<Map<String, Object?>> _toPayload(SyncOperation operation) async {
    final database = _database;
    final entityType = operation.entityType;
    final entityId = operation.entityId;
    final payload = switch (operation.operationType) {
      'BusinessCreated' => _businessPayload(
        await (database.select(
          database.businesses,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'BusinessUpdated' => {
        ..._businessPayload(
          await (database.select(
            database.businesses,
          )..where((e) => e.id.equals(entityId))).getSingle(),
        ),
        'expectedVersion': 1,
      },
      'CustomerCreated' ||
      'CustomerUpdated' ||
      'CustomerArchived' => _customerPayload(
        await (database.select(
          database.customers,
        )..where((e) => e.id.equals(entityId))).getSingle(),
        expectedVersion: 1,
      ),
      'InvoiceCreated' => _invoicePayload(
        await (database.select(
          database.invoices,
        )..where((e) => e.id.equals(entityId))).getSingle(),
        await (database.select(
          database.invoiceItems,
        )..where((e) => e.invoiceId.equals(entityId))).get(),
      ),
      'InvoiceUpdated' => _invoicePayload(
        await (database.select(
          database.invoices,
        )..where((e) => e.id.equals(entityId))).getSingle(),
        await (database.select(
          database.invoiceItems,
        )..where((e) => e.invoiceId.equals(entityId))).get(),
      ),
      'InvoiceVoided' => {
        'expectedVersion': 1,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      },
      'PaymentRecorded' || 'PaymentReversed' => _paymentPayload(
        await (database.select(
          database.payments,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'IncomeCreated' || 'IncomeUpdated' || 'IncomeDeleted' => _incomePayload(
        await (database.select(
          database.incomeEntries,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'ExpenseCreated' ||
      'ExpenseUpdated' ||
      'ExpenseDeleted' => _expensePayload(
        await (database.select(
          database.expenses,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'InventoryProductCreated' ||
      'InventoryProductUpdated' ||
      'InventoryProductDeleted' ||
      'InventoryAdjusted' => _inventoryPayload(
        await (database.select(
          database.inventoryProducts,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'SupplierCreated' ||
      'SupplierUpdated' ||
      'SupplierDeleted' => _supplierPayload(
        await (database.select(
          database.suppliers,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      'SupplierPaymentRecorded' => _supplierPaymentPayload(
        await (database.select(
          database.supplierPayments,
        )..where((e) => e.id.equals(entityId))).getSingle(),
      ),
      _ => throw StateError(
        'Unsupported operation type ${operation.operationType}',
      ),
    };
    return {
      'operationId': operation.id,
      'businessId': operation.businessId,
      'entityType': entityType,
      'entityId': entityId,
      'operationType': operation.operationType,
      'occurredAt': operation.createdAt.toUtc().toIso8601String(),
      'payload': payload,
    };
  }

  Map<String, Object?> _businessPayload(BusinessesData business) => {
    'id': business.id,
    'name': business.name,
    'ownerName': business.ownerName,
    'businessType': business.businessType,
    'phone': business.phone,
    'email': business.email,
    'address': business.address,
    'upiId': business.upiId,
    'preferredLanguage': business.preferredLanguage,
    'createdAt': business.createdAt.toUtc().toIso8601String(),
    'updatedAt': business.updatedAt.toUtc().toIso8601String(),
    'deletedAt': business.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _customerPayload(
    Customer customer, {
    required int expectedVersion,
  }) => {
    'id': customer.id,
    'businessId': customer.businessId,
    'name': customer.name,
    'phone': customer.phone,
    'email': customer.email,
    'notes': customer.notes,
    'createdAt': customer.createdAt.toUtc().toIso8601String(),
    'updatedAt': customer.updatedAt.toUtc().toIso8601String(),
    'deletedAt': customer.deletedAt?.toUtc().toIso8601String(),
    'expectedVersion': expectedVersion,
  };

  Map<String, Object?> _invoicePayload(
    Invoice invoice,
    List<InvoiceItem> items,
  ) => {
    'invoice': {
      'id': invoice.id,
      'businessId': invoice.businessId,
      'customerId': invoice.customerId,
      'invoiceNumber': invoice.invoiceNumber,
      'issuedAt': invoice.issuedAt.toUtc().toIso8601String(),
      'dueAt': invoice.dueAt?.toUtc().toIso8601String(),
      'subtotalPaise': invoice.subtotalPaise,
      'discountPaise': invoice.discountPaise,
      'interestPaise': invoice.interestPaise,
      'paidPaise': invoice.paidPaise,
      'notes': invoice.notes,
      'createdAt': invoice.createdAt.toUtc().toIso8601String(),
      'updatedAt': invoice.updatedAt.toUtc().toIso8601String(),
      'deletedAt': invoice.deletedAt?.toUtc().toIso8601String(),
    },
    'items': items
        .map(
          (item) => {
            'id': item.id,
            'description': item.description,
            'quantityMilliunits': item.quantityMilliunits,
            'unitPricePaise': item.unitPricePaise,
            'lineTotalPaise': item.lineTotalPaise,
            'sortOrder': item.sortOrder,
          },
        )
        .toList(),
  };

  Map<String, Object?> _paymentPayload(Payment payment) => {
    'id': payment.id,
    'businessId': payment.businessId,
    'invoiceId': payment.invoiceId,
    'amountPaise': payment.amountPaise,
    'method': payment.method,
    'note': payment.note,
    'receivedAt': payment.receivedAt.toUtc().toIso8601String(),
    'createdAt': payment.createdAt.toUtc().toIso8601String(),
    'deletedAt': payment.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _incomePayload(IncomeEntry income) => {
    'id': income.id,
    'businessId': income.businessId,
    'amountPaise': income.amountPaise,
    'description': income.description,
    'incomeDate': income.incomeDate.toUtc().toIso8601String(),
    'createdAt': income.createdAt.toUtc().toIso8601String(),
    'updatedAt': income.updatedAt.toUtc().toIso8601String(),
    'deletedAt': income.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _expensePayload(Expense expense) => {
    'id': expense.id,
    'businessId': expense.businessId,
    'amountPaise': expense.amountPaise,
    'category': expense.category,
    'description': expense.description,
    'expenseDate': expense.expenseDate.toUtc().toIso8601String(),
    'createdAt': expense.createdAt.toUtc().toIso8601String(),
    'updatedAt': expense.updatedAt.toUtc().toIso8601String(),
    'deletedAt': expense.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _inventoryPayload(InventoryProduct product) => {
    'id': product.id,
    'businessId': product.businessId,
    'name': product.name,
    'sku': product.sku,
    'unit': product.unit,
    'stockMilliunits': product.stockMilliunits,
    'lowStockThresholdMilliunits': product.lowStockThresholdMilliunits,
    'unitCostPaise': product.unitCostPaise,
    'createdAt': product.createdAt.toUtc().toIso8601String(),
    'updatedAt': product.updatedAt.toUtc().toIso8601String(),
    'deletedAt': product.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _supplierPayload(Supplier supplier) => {
    'id': supplier.id,
    'businessId': supplier.businessId,
    'name': supplier.name,
    'phone': supplier.phone,
    'email': supplier.email,
    'address': supplier.address,
    'notes': supplier.notes,
    'createdAt': supplier.createdAt.toUtc().toIso8601String(),
    'updatedAt': supplier.updatedAt.toUtc().toIso8601String(),
    'deletedAt': supplier.deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> _supplierPaymentPayload(SupplierPayment payment) => {
    'id': payment.id,
    'businessId': payment.businessId,
    'supplierId': payment.supplierId,
    'amountPaise': payment.amountPaise,
    'paidAt': payment.paidAt.toUtc().toIso8601String(),
    'note': payment.note,
    'createdAt': payment.createdAt.toUtc().toIso8601String(),
    'deletedAt': payment.deletedAt?.toUtc().toIso8601String(),
  };

  Future<void> _markSynced(String id) =>
      (_database.update(
        _database.syncOperations,
      )..where((op) => op.id.equals(id))).write(
        SyncOperationsCompanion(
          status: const Value('synced'),
          lastAttemptAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<void> _markFailed(String id, String reason) =>
      (_database.update(
        _database.syncOperations,
      )..where((op) => op.id.equals(id))).write(
        SyncOperationsCompanion(
          status: Value('failed: ${_cleanReason(reason)}'),
          attemptCount: const Value(1),
          lastAttemptAt: Value(DateTime.now().toUtc()),
        ),
      );

  String _cleanReason(String reason) {
    final cleaned = reason.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (cleaned.length <= 240) return cleaned;
    return '${cleaned.substring(0, 237)}...';
  }

  String _formatSyncError(Object error) {
    if (error is FunctionException) {
      if (error.status == 0) {
        return 'Sync request could not reach the server. Check internet connection and retry.';
      }
      final details = error.details?.toString().trim();
      if (details != null && details.isNotEmpty && details != 'null') {
        return 'Sync request failed (${error.status}): $details';
      }
      return 'Sync request failed (HTTP ${error.status}). Retry in a moment.';
    }
    if (error is AuthException) {
      return 'Sync sign-in expired. Sign in again and retry.';
    }
    if (error is PostgrestException) {
      return 'Sync database error: ${error.message}';
    }
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
