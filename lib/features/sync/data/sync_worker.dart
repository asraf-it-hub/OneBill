import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';

class SyncWorker {
  SyncWorker(this._database, this._client);
  final AppDatabase _database;
  final SupabaseClient _client;
  bool _running = false;
  StreamSubscription? _autoSyncSubscription;

  void listenToPendingOperations() {
    _autoSyncSubscription?.cancel();
    _autoSyncSubscription = (_database.select(_database.syncOperations)
          ..where((op) => op.status.equals('pending')))
        .watch()
        .listen((pendingOps) {
      if (pendingOps.isNotEmpty && !_running) {
        final businessIds =
            pendingOps.map((op) => op.businessId).whereType<String>().toSet();
        for (final bId in businessIds) {
          syncBusiness(bId);
        }
      }
    });
  }

  void dispose() {
    _autoSyncSubscription?.cancel();
  }

  Future<void> restoreAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) return;

    final now = DateTime.now().toUtc();
    await _requeueTransientFailures(force: true);

    // 0. Align local sessions and businesses to the current user ID
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
    final existingSessions = await _database.select(_database.localSessions).get();
    final existingBusinesses = await _database.select(_database.businesses).get();
    for (final b in existingBusinesses) {
      if (b.accountId != user.id) {
        await (_database.update(_database.businesses)
              ..where((row) => row.id.equals(b.id)))
            .write(BusinessesCompanion(accountId: Value(user.id)));
      }
    }
    for (final s in existingSessions) {
      if (s.accountId != user.id) {
        await (_database.update(_database.localSessions)
              ..where((row) => row.id.equals(s.id)))
            .write(LocalSessionsCompanion(accountId: Value(user.id)));
      }
    }

    // 1. Inspect local database for businesses belonging to THIS user account.
    final localBusinesses = await (_database.select(_database.businesses)
          ..where((b) => b.accountId.equals(user.id) & b.deletedAt.isNull())
          ..orderBy([(b) => OrderingTerm.asc(b.name)]))
        .get();

    if (localBusinesses.isNotEmpty) {
      final activeId = localBusinesses.first.id;

      final sessions = await _database.select(_database.localSessions).get();
      if (sessions.isEmpty) {
        await _database.into(_database.localSessions).insert(
          LocalSessionsCompanion.insert(
            accountId: Value(user.id),
            activeBusinessId: Value(activeId),
            localeCode: Value(localBusinesses.first.preferredLanguage),
            updatedAt: now,
          ),
        );
      } else {
        final keep = sessions.first;
        if (keep.accountId != user.id || keep.activeBusinessId != activeId) {
          await (_database.update(_database.localSessions)
                ..where((row) => row.id.equals(keep.id)))
              .write(
            LocalSessionsCompanion(
              accountId: Value(user.id),
              activeBusinessId: Value(activeId),
              updatedAt: Value(now),
            ),
          );
        }
      }

      syncBusiness(activeId);
    }

    // 2. Fetch cloud snapshot. Wrapped in try-catch so network RPC delays or timeouts
    // never block access to local data or force the user onto a creation screen.
    dynamic rawSnapshot;
    try {
      rawSnapshot = await _client
          .rpc('get_sync_snapshot')
          .timeout(const Duration(seconds: 15));
    } catch (_) {}

    if (rawSnapshot == null ||
        rawSnapshot is! Map ||
        (rawSnapshot['businesses'] as List? ?? []).isEmpty) {
      // Fallback: Query Supabase tables directly if RPC is unavailable or empty
      try {
        final bList = await _client
            .from('businesses')
            .select()
            .eq('owner_id', user.id);
        if (bList.isNotEmpty) {
          final cList = await _client
              .from('customers')
              .select()
              .eq('owner_id', user.id);
          final iList = await _client
              .from('invoices')
              .select()
              .eq('owner_id', user.id);
          final iiList = await _client
              .from('invoice_items')
              .select()
              .eq('owner_id', user.id);
          final pList = await _client
              .from('payments')
              .select()
              .eq('owner_id', user.id);
          final ieList = await _client
              .from('income_entries')
              .select()
              .eq('owner_id', user.id);
          final exList = await _client
              .from('expenses')
              .select()
              .eq('owner_id', user.id);
          final ipList = await _client
              .from('inventory_products')
              .select()
              .eq('owner_id', user.id);
          final imList = await _client
              .from('inventory_movements')
              .select()
              .eq('owner_id', user.id);
          final sList = await _client
              .from('suppliers')
              .select()
              .eq('owner_id', user.id);
          final spList = await _client
              .from('supplier_payments')
              .select()
              .eq('owner_id', user.id);
          rawSnapshot = {
            'businesses': bList,
            'customers': cList,
            'invoices': iList,
            'invoice_items': iiList,
            'payments': pList,
            'income_entries': ieList,
            'expenses': exList,
            'inventory_products': ipList,
            'inventory_movements': imList,
            'suppliers': sList,
            'supplier_payments': spList,
          };
        }
      } catch (_) {
        if (rawSnapshot == null || rawSnapshot is! Map) return;
      }
    }

    if (rawSnapshot == null || rawSnapshot is! Map) return;
    final snapshot = Map<String, dynamic>.from(rawSnapshot);
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

    await _database.customStatement('PRAGMA foreign_keys = OFF;');
    try {
      await _database.transaction(() async {
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

        String? getVal(Map<String, dynamic> r, String sKey, String cKey) {
          final v = r[sKey] ?? r[cKey];
          return v?.toString();
        }

        int getInt(Map<String, dynamic> r, String sKey, String cKey, [int def = 0]) {
          final v = r[sKey] ?? r[cKey];
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v) ?? def;
          return def;
        }

        DateTime getDate(Map<String, dynamic> r, String sKey, String cKey) {
          final v = r[sKey] ?? r[cKey];
          if (v is String && v.isNotEmpty) {
            try { return DateTime.parse(v).toUtc(); } catch (_) {}
          }
          return now;
        }

        DateTime? getDateOpt(Map<String, dynamic> r, String sKey, String cKey) {
          final v = r[sKey] ?? r[cKey];
          if (v is String && v.isNotEmpty) {
            try { return DateTime.parse(v).toUtc(); } catch (_) {}
          }
          return null;
        }

        for (final row in businesses) {
          final bId = getVal(row, 'id', 'id');
          if (bId == null) continue;
          final existing = await (_database.select(_database.businesses)
                ..where((b) => b.id.equals(bId)))
              .getSingleOrNull();
          final langToUse = existing?.preferredLanguage ??
              (getVal(row, 'preferred_language', 'preferredLanguage') ?? 'en');
          await _database
              .into(_database.businesses)
              .insertOnConflictUpdate(
                BusinessesCompanion.insert(
                  id: bId,
                  accountId: user.id,
                  ownerName: getVal(row, 'owner_name', 'ownerName') ?? 'Owner',
                  name: getVal(row, 'name', 'name') ?? 'My Business',
                  businessType: Value(getVal(row, 'business_type', 'businessType')),
                  phone: Value(getVal(row, 'phone', 'phone')),
                  email: Value(getVal(row, 'email', 'email')),
                  address: Value(getVal(row, 'address', 'address')),
                  website: Value(getVal(row, 'website', 'website')),
                  tagline: Value(getVal(row, 'tagline', 'tagline')),
                  gstin: Value(getVal(row, 'gstin', 'gstin')),
                  upiId: Value(getVal(row, 'upi_id', 'upiId')),
                  upiName: Value(getVal(row, 'upi_name', 'upiName')),
                  invoiceNotes: Value(getVal(row, 'invoice_notes', 'invoiceNotes')),
                  termsAndConditions: Value(getVal(row, 'terms_and_conditions', 'termsAndConditions')),
                  logoImage: Value(getVal(row, 'logo_image', 'logoImage')),
                  paymentQrImage: Value(getVal(row, 'payment_qr_image', 'paymentQrImage')),
                  preferredLanguage: Value(langToUse),
                  createdAt: getDate(row, 'created_at', 'createdAt'),
                  updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                  deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                ),
              );
        }
        final activeBusinesses = businesses
            .where((r) => getDateOpt(r, 'deleted_at', 'deletedAt') == null)
            .toList();
        final businessIds = (activeBusinesses.isNotEmpty ? activeBusinesses : businesses)
            .map((r) => getVal(r, 'id', 'id'))
            .whereType<String>()
            .toList();
        if (businessIds.isEmpty) return;

        for (final businessId in businessIds) {
          final customers = allCustomers.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in customers) {
            final cId = getVal(row, 'id', 'id');
            if (cId == null) continue;
            await _database
                .into(_database.customers)
                .insertOnConflictUpdate(
                  CustomersCompanion.insert(
                    id: cId,
                    businessId: businessId,
                    name: getVal(row, 'name', 'name') ?? 'Customer',
                    phone: getVal(row, 'phone', 'phone') ?? '',
                    email: Value(getVal(row, 'email', 'email')),
                    notes: Value(getVal(row, 'notes', 'notes')),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final invoices = allInvoices.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in invoices) {
            final invId = getVal(row, 'id', 'id');
            if (invId == null) continue;
            var custId = getVal(row, 'customer_id', 'customerId');
            if (custId == null || custId.trim().isEmpty) {
              custId = '00000000-0000-0000-0000-000000000000';
            }
            await _database
                .into(_database.invoices)
                .insertOnConflictUpdate(
                  InvoicesCompanion.insert(
                    id: invId,
                    businessId: businessId,
                    customerId: custId,
                    invoiceNumber: getVal(row, 'invoice_number', 'invoiceNumber') ?? 'INV-001',
                    issuedAt: getDate(row, 'issued_at', 'issuedAt'),
                    dueAt: Value(getDateOpt(row, 'due_at', 'dueAt')),
                    subtotalPaise: getInt(row, 'subtotal_paise', 'subtotalPaise'),
                    discountPaise: Value(getInt(row, 'discount_paise', 'discountPaise')),
                    interestPaise: Value(getInt(row, 'interest_paise', 'interestPaise')),
                    paidPaise: Value(getInt(row, 'paid_paise', 'paidPaise')),
                    notes: Value(getVal(row, 'notes', 'notes')),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final items = allItems.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId || getVal(r, 'invoice_id', 'invoiceId') != null,
          );
          for (final row in items) {
            final itemId = getVal(row, 'id', 'id');
            final invId = getVal(row, 'invoice_id', 'invoiceId');
            if (itemId == null || invId == null || invId.trim().isEmpty) continue;
            await _database
                .into(_database.invoiceItems)
                .insertOnConflictUpdate(
                  InvoiceItemsCompanion.insert(
                    id: itemId,
                    invoiceId: invId,
                    description: getVal(row, 'description', 'description') ?? '',
                    quantityMilliunits: getInt(row, 'quantity_milliunits', 'quantityMilliunits'),
                    unitPricePaise: getInt(row, 'unit_price_paise', 'unitPricePaise'),
                    lineTotalPaise: getInt(row, 'line_total_paise', 'lineTotalPaise'),
                    sortOrder: getInt(row, 'sort_order', 'sortOrder'),
                  ),
                );
          }
          final payments = allPayments.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in payments) {
            final pId = getVal(row, 'id', 'id');
            final invId = getVal(row, 'invoice_id', 'invoiceId');
            if (pId == null || invId == null || invId.trim().isEmpty) continue;
            await _database
                .into(_database.payments)
                .insertOnConflictUpdate(
                  PaymentsCompanion.insert(
                    id: pId,
                    businessId: businessId,
                    invoiceId: invId,
                    amountPaise: getInt(row, 'amount_paise', 'amountPaise'),
                    method: getVal(row, 'method', 'method') ?? 'cash',
                    note: Value(getVal(row, 'note', 'note')),
                    receivedAt: getDate(row, 'received_at', 'receivedAt'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final income = allIncome.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in income) {
            final incId = getVal(row, 'id', 'id');
            if (incId == null) continue;
            await _database
                .into(_database.incomeEntries)
                .insertOnConflictUpdate(
                  IncomeEntriesCompanion.insert(
                    id: incId,
                    businessId: businessId,
                    amountPaise: getInt(row, 'amount_paise', 'amountPaise'),
                    description: Value(getVal(row, 'description', 'description')),
                    incomeDate: getDate(row, 'income_date', 'incomeDate'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final expenses = allExpenses.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in expenses) {
            final expId = getVal(row, 'id', 'id');
            if (expId == null) continue;
            await _database
                .into(_database.expenses)
                .insertOnConflictUpdate(
                  ExpensesCompanion.insert(
                    id: expId,
                    businessId: businessId,
                    amountPaise: getInt(row, 'amount_paise', 'amountPaise'),
                    category: getVal(row, 'category', 'category') ?? 'General',
                    description: Value(getVal(row, 'description', 'description')),
                    expenseDate: getDate(row, 'expense_date', 'expenseDate'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final inventory = allInventory.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in inventory) {
            final prodId = getVal(row, 'id', 'id');
            if (prodId == null) continue;
            await _database
                .into(_database.inventoryProducts)
                .insertOnConflictUpdate(
                  InventoryProductsCompanion.insert(
                    id: prodId,
                    businessId: businessId,
                    name: getVal(row, 'name', 'name') ?? '',
                    sku: Value(getVal(row, 'sku', 'sku')),
                    unit: Value(getVal(row, 'unit', 'unit') ?? 'pcs'),
                    stockMilliunits: Value(getInt(row, 'stock_milliunits', 'stockMilliunits')),
                    lowStockThresholdMilliunits: Value(getInt(row, 'low_stock_threshold_milliunits', 'lowStockThresholdMilliunits')),
                    unitCostPaise: Value(getInt(row, 'unit_cost_paise', 'unitCostPaise')),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final movements = allMovements.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in movements) {
            final movId = getVal(row, 'id', 'id');
            final prodId = getVal(row, 'product_id', 'productId');
            if (movId == null || prodId == null || prodId.trim().isEmpty) continue;
            await _database
                .into(_database.inventoryMovements)
                .insertOnConflictUpdate(
                  InventoryMovementsCompanion.insert(
                    id: movId,
                    businessId: businessId,
                    productId: prodId,
                    deltaMilliunits: getInt(row, 'delta_milliunits', 'deltaMilliunits'),
                    reason: getVal(row, 'reason', 'reason') ?? 'adjustment',
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                  ),
                );
          }
          final suppliers = allSuppliers.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in suppliers) {
            final supId = getVal(row, 'id', 'id');
            if (supId == null) continue;
            await _database
                .into(_database.suppliers)
                .insertOnConflictUpdate(
                  SuppliersCompanion.insert(
                    id: supId,
                    businessId: businessId,
                    name: getVal(row, 'name', 'name') ?? '',
                    phone: getVal(row, 'phone', 'phone') ?? '',
                    email: Value(getVal(row, 'email', 'email')),
                    address: Value(getVal(row, 'address', 'address')),
                    notes: Value(getVal(row, 'notes', 'notes')),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
          final supplierPayments = allSupplierPayments.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          for (final row in supplierPayments) {
            final spId = getVal(row, 'id', 'id');
            final supId = getVal(row, 'supplier_id', 'supplierId');
            if (spId == null || supId == null || supId.trim().isEmpty) continue;
            await _database
                .into(_database.supplierPayments)
                .insertOnConflictUpdate(
                  SupplierPaymentsCompanion.insert(
                    id: spId,
                    businessId: businessId,
                    supplierId: supId,
                    amountPaise: getInt(row, 'amount_paise', 'amountPaise'),
                    paidAt: getDate(row, 'paid_at', 'paidAt'),
                    note: Value(getVal(row, 'note', 'note')),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    deletedAt: Value(getDateOpt(row, 'deleted_at', 'deletedAt')),
                  ),
                );
          }
        }
        final preferredLanguage =
            businesses.firstWhere(
                  (business) => business['id'] == businessIds.first,
                )['preferred_language']
                as String? ??
            'en';
        final sessions = await _database.select(_database.localSessions).get();
        if (sessions.isEmpty) {
          await _database
              .into(_database.localSessions)
              .insert(
                LocalSessionsCompanion.insert(
                  accountId: Value(user.id),
                  activeBusinessId: Value(businessIds.first),
                  localeCode: Value(preferredLanguage),
                  updatedAt: now,
                ),
              );
        } else {
          final keep = sessions.first;
          if (keep.accountId != user.id ||
              keep.activeBusinessId != businessIds.first) {
            await (_database.update(
              _database.localSessions,
            )..where((row) => row.id.equals(keep.id))).write(
              LocalSessionsCompanion(
                accountId: Value(user.id),
                activeBusinessId: Value(businessIds.first),
                updatedAt: Value(now),
              ),
            );
          }
          if (sessions.length > 1) {
            final duplicateIds = sessions.skip(1).map((session) => session.id);
            await (_database.delete(
              _database.localSessions,
            )..where((row) => row.id.isIn(duplicateIds))).go();
          }
        }
      });
    } finally {
      await _database.customStatement('PRAGMA foreign_keys = ON;');
    }
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
    if (_running) return;
    var session = _client.auth.currentSession;
    if (session == null || session.isExpired) {
      try {
        final res = await _client.auth.refreshSession();
        session = res.session;
      } catch (_) {}
    }
    if (session == null) return;
    final userId = session.user.id;
    final unalignedBusinesses = await (_database.select(_database.businesses)
          ..where((row) => row.accountId.equals(userId).not()))
        .get();
    if (unalignedBusinesses.isNotEmpty) {
      final now = DateTime.now().toUtc();
      await _database
          .into(_database.userAccounts)
          .insertOnConflictUpdate(
            UserAccountsCompanion.insert(
              id: userId,
              displayName: session.user.email ?? 'Owner',
              email: Value(session.user.email),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final ub in unalignedBusinesses) {
        await (_database.update(_database.businesses)
              ..where((row) => row.id.equals(ub.id)))
            .write(BusinessesCompanion(accountId: Value(userId)));
      }
    }

    _running = true;
    try {
      int processedBatches = 0;
      while (processedBatches < 20) {
        final operations =
            await (_database.select(_database.syncOperations)
                  ..where(
                    (operation) => operation.status.equals('pending'),
                  )
                  ..orderBy([
                    (operation) => OrderingTerm.asc(operation.createdAt),
                  ])
                  ..limit(50))
                .get();
        if (operations.isEmpty) break;
        processedBatches++;
        final deviceId = session.user.id;
        final payload = <Map<String, Object?>>[];
        final buildableOperations = <SyncOperation>[];
        for (final operation in operations) {
          try {
            final item = await _toPayload(operation);
            if (item != null) {
              payload.add(item);
              buildableOperations.add(operation);
            } else {
              await _markSynced(operation.id);
            }
          } catch (error) {
            await _markFailed(operation.id, 'Unbuildable payload: $error');
          }
        }
        if (payload.isEmpty) break;
      bool edgeSucceeded = false;
      FunctionResponse? result;
      try {
        result = await _client.functions.invoke(
          'sync',
          body: {'deviceId': deviceId, 'operations': payload},
        );
        if (result.status == 200 &&
            result.data is Map &&
            (result.data as Map).containsKey('acknowledgedOperationIds')) {
          edgeSucceeded = true;
        }
      } on FunctionException catch (fe) {
        if (fe.status == 401) {
          try {
            final refreshed = await _client.auth.refreshSession();
            if (refreshed.session != null) {
              result = await _client.functions.invoke(
                'sync',
                body: {
                  'deviceId': refreshed.session!.user.id,
                  'operations': payload,
                },
              );
              if (result.status == 200 &&
                  result.data is Map &&
                  (result.data as Map).containsKey('acknowledgedOperationIds')) {
                edgeSucceeded = true;
              }
            }
          } catch (_) {}
        }
      } catch (_) {}

      if (edgeSucceeded && result != null) {
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
        for (final operation in buildableOperations) {
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
            final reason = (conflict?['reason'] ??
                    failure?['reason'] ??
                    'Sync was not acknowledged')
                .toString();
            if (_isAlreadyApplied(operation.operationType, reason)) {
              await _markSynced(operation.id);
            } else {
              await _markFailed(operation.id, reason);
            }
          }
        }
      } else {
        // Direct RPC fallback per operation when Edge Function is unavailable
        final user = _client.auth.currentUser;
        if (user != null) {
          for (int i = 0; i < buildableOperations.length; i++) {
            final operation = buildableOperations[i];
            final opPayload = payload[i];
            try {
              final rpcRes = await _client.rpc(
                'apply_sync_operation',
                params: {
                  'p_owner_id': user.id,
                  'p_device_id': deviceId,
                  'p_operation': opPayload,
                },
              );
              if (rpcRes is Map && rpcRes['acknowledged'] == true) {
                await _markSynced(operation.id);
              } else {
                final reason =
                    (rpcRes is Map ? rpcRes['reason'] : null)?.toString() ??
                        'Operation rejected by cloud RPC';
                if (_isAlreadyApplied(operation.operationType, reason)) {
                  await _markSynced(operation.id);
                } else {
                  await _markFailed(operation.id, reason);
                }
              }
            } catch (error) {
              // RPC failed due to network outage or permissions; keep pending to retry
            }
          }
        }
      }
      }
    } catch (error) {
      // Network outages, 503 errors, timeouts, or socket exceptions do NOT
      // mark pending items as failed in SQLite. They remain 'pending' so they
      // automatically sync as soon as connectivity is restored.
    } finally {
      _running = false;
    }
  }


  Future<void> retryFailedOperations([String? businessId]) async {
    await _requeueTransientFailures(businessId: businessId, force: true);
    if (businessId != null && businessId.isNotEmpty) {
      await syncBusiness(businessId);
    }
  }

  Future<void> _requeueTransientFailures({
    String? businessId,
    bool force = false,
  }) async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final query = _database.select(_database.syncOperations);
    if (force) {
      query.where((operation) => operation.status.like('failed%'));
    } else {
      query.where(
        (operation) =>
            operation.status.like('failed%') &
            operation.attemptCount.isSmallerThan(const Constant(10)) &
            (operation.lastAttemptAt.isNull() |
                operation.lastAttemptAt.isSmallerThan(Variable(cutoff))),
      );
    }
    if (businessId != null && businessId.isNotEmpty) {
      query.where((operation) => operation.businessId.equals(businessId));
    }
    final operations = await query.get();
    for (final operation in operations) {
      await (_database.update(_database.syncOperations)
            ..where((row) => row.id.equals(operation.id)))
          .write(const SyncOperationsCompanion(
            status: Value('pending'),
            attemptCount: Value(0),
          ));
    }
  }

  bool _isAlreadyApplied(String opType, String reason) {
    final r = reason.toLowerCase();
    return r.contains('already exists') ||
        r.contains('duplicate key') ||
        r.contains('unique constraint') ||
        r.contains('idempotent') ||
        r.contains('already applied');
  }

  Future<Map<String, Object?>?> _toPayload(SyncOperation operation) async {
    final database = _database;
    final entityType = operation.entityType;
    final entityId = operation.entityId;

    Map<String, Object?>? payload;

    switch (operation.operationType) {
      case 'BusinessCreated':
        final b = await (database.select(database.businesses)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) {
          payload = _businessPayload(b);
        } else if (operation.payloadJson.isNotEmpty) {
          try {
            final raw = jsonDecode(operation.payloadJson) as Map<String, dynamic>;
            final lang = {'en', 'hi', 'te'}.contains(raw['preferredLanguage'])
                ? raw['preferredLanguage'] as String
                : 'en';
            payload = {
              'id': operation.entityId,
              'name': (raw['name'] as String?)?.trim().isNotEmpty == true ? (raw['name'] as String).trim() : 'My Business',
              'ownerName': (raw['ownerName'] as String?)?.trim().isNotEmpty == true ? (raw['ownerName'] as String).trim() : 'Owner',
              'preferredLanguage': lang,
              'preferred_language': lang,
              'createdAt': operation.createdAt.toUtc().toIso8601String(),
              'updatedAt': operation.createdAt.toUtc().toIso8601String(),
            };
          } catch (_) {}
        }
        break;

      case 'BusinessUpdated':
        final b = await (database.select(database.businesses)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) payload = {..._businessPayload(b), 'expectedVersion': 1};
        break;

      case 'BusinessDeleted':
        final b = await (database.select(database.businesses)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) {
          payload = {
            ..._businessPayload(b),
            'deletedAt': (b.deletedAt ?? DateTime.now().toUtc()).toIso8601String(),
          };
        } else {
          payload = {
            'id': entityId,
            'deletedAt': DateTime.now().toUtc().toIso8601String(),
          };
        }
        break;

      case 'CustomerCreated':
      case 'CustomerUpdated':
      case 'CustomerArchived':
        final c = await (database.select(database.customers)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (c != null) payload = _customerPayload(c, expectedVersion: 1);
        break;

      case 'InvoiceCreated':
      case 'InvoiceUpdated':
        final inv = await (database.select(database.invoices)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (inv != null) {
          final items = await (database.select(database.invoiceItems)..where((e) => e.invoiceId.equals(entityId))).get();
          payload = _invoicePayload(inv, items);
        }
        break;

      case 'InvoiceVoided':
        payload = {
          'expectedVersion': 1,
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        };
        break;

      case 'PaymentRecorded':
      case 'PaymentReversed':
        final p = await (database.select(database.payments)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (p != null) payload = _paymentPayload(p);
        break;

      case 'IncomeCreated':
      case 'IncomeUpdated':
      case 'IncomeDeleted':
        final inc = await (database.select(database.incomeEntries)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (inc != null) payload = _incomePayload(inc);
        break;

      case 'ExpenseCreated':
      case 'ExpenseUpdated':
      case 'ExpenseDeleted':
        final exp = await (database.select(database.expenses)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (exp != null) payload = _expensePayload(exp);
        break;

      case 'InventoryProductCreated':
      case 'InventoryProductUpdated':
      case 'InventoryProductDeleted':
      case 'InventoryAdjusted':
        final prod = await (database.select(database.inventoryProducts)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (prod != null) payload = _inventoryPayload(prod);
        break;

      case 'SupplierCreated':
      case 'SupplierUpdated':
      case 'SupplierDeleted':
        final sup = await (database.select(database.suppliers)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (sup != null) payload = _supplierPayload(sup);
        break;

      case 'SupplierPaymentRecorded':
        final sp = await (database.select(database.supplierPayments)..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (sp != null) payload = _supplierPaymentPayload(sp);
        break;
    }

    if (payload == null && operation.payloadJson.isNotEmpty) {
      try {
        final raw = jsonDecode(operation.payloadJson);
        if (raw is Map) {
          payload = Map<String, Object?>.from(raw);
        }
      } catch (_) {}
    }

    if (payload == null) {
      return null;
    }

    return {
      'operationId': operation.id,
      'businessId': (operation.businessId != null && operation.businessId!.isNotEmpty)
          ? operation.businessId!
          : (payload['businessId'] as String? ?? payload['id'] as String? ?? ''),
      'entityType': entityType,
      'entityId': entityId,
      'operationType': operation.operationType,
      'occurredAt': operation.createdAt.toUtc().toIso8601String(),
      'payload': payload,
    };
  }

  Map<String, Object?> _businessPayload(BusinessesData business) {
    final lang = {'en', 'hi', 'te'}.contains(business.preferredLanguage)
        ? business.preferredLanguage
        : 'en';
    final name = business.name.trim().isEmpty ? 'My Business' : business.name.trim();
    final ownerName = business.ownerName.trim().isEmpty ? 'Owner' : business.ownerName.trim();
    return {
      'id': business.id,
      'name': name,
      'ownerName': ownerName,
      'businessType': business.businessType,
      'phone': business.phone,
      'email': business.email,
      'address': business.address,
      'upiId': business.upiId,
      'logoImage': business.logoImage,
      'paymentQrImage': business.paymentQrImage,
      'website': business.website,
      'gstin': business.gstin,
      'upiName': business.upiName,
      'invoiceNotes': business.invoiceNotes,
      'termsAndConditions': business.termsAndConditions,
      'tagline': business.tagline,
      'preferredLanguage': lang,
      'preferred_language': lang,
      'createdAt': business.createdAt.toUtc().toIso8601String(),
      'updatedAt': business.updatedAt.toUtc().toIso8601String(),
      'deletedAt': business.deletedAt?.toUtc().toIso8601String(),
    };
  }

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
            'description': item.description.trim().isEmpty ? 'Item' : item.description.trim(),
            'quantityMilliunits': item.quantityMilliunits <= 0 ? 1000 : item.quantityMilliunits,
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

  Future<void> _markFailed(String id, String reason) async {
    final existing = await (_database.select(_database.syncOperations)
          ..where((op) => op.id.equals(id)))
        .getSingleOrNull();
    final nextCount = (existing?.attemptCount ?? 0) + 1;
    await (_database.update(
      _database.syncOperations,
    )..where((op) => op.id.equals(id))).write(
      SyncOperationsCompanion(
        status: Value('failed: ${_cleanReason(reason)}'),
        attemptCount: Value(nextCount),
        lastAttemptAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  String _cleanReason(String reason) {
    final cleaned = reason.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (cleaned.length <= 240) return cleaned;
    return '${cleaned.substring(0, 237)}...';
  }
}
