import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';

class SyncWorker {
  SyncWorker(this._database, this._client);
  final AppDatabase _database;
  final SupabaseClient _client;
  bool _running = false;
  // Serialize sync requests.  The profile screen waits for this future; the
  // previous implementation returned immediately when an automatic sync was
  // already running, which could show "sync successful" while the newly
  // queued profile update was still only local.
  Future<void> _syncChain = Future<void>.value();
  StreamSubscription? _autoSyncSubscription;

  void listenToPendingOperations() {
    _autoSyncSubscription?.cancel();
    _autoSyncSubscription =
        (_database.select(_database.syncOperations)
              ..where((op) => op.status.equals('pending')))
            .watch()
            .listen((pendingOps) {
              if (pendingOps.isNotEmpty && !_running) {
                final businessIds = pendingOps
                    .map((op) => op.businessId)
                    .whereType<String>()
                    .toSet();
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
    // Retry queued failures when the app starts, preserving the existing
    // offline-first behavior.
    await _requeueTransientFailures(force: true);

    // 0. Ensure strict account data isolation.
    // If the local database contains data belonging to a different user account,
    // clear local tables to prevent data mixing between accounts.
    final existingSessions = await _database
        .select(_database.localSessions)
        .get();
    final existingBusinesses = await _database
        .select(_database.businesses)
        .get();
    final hasForeignAccountData =
        existingBusinesses.any((b) => b.accountId != user.id) ||
        existingSessions.any((s) => s.accountId != user.id);

    if (hasForeignAccountData) {
      await _database.clearAllTables();
    }

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

    // 1. Inspect local database for businesses belonging to THIS user account.
    final localBusinesses =
        await (_database.select(_database.businesses)
              ..where((b) => b.accountId.equals(user.id) & b.deletedAt.isNull())
              ..orderBy([(b) => OrderingTerm.asc(b.name)]))
            .get();

    if (localBusinesses.isNotEmpty) {
      final sessions = await _database.select(_database.localSessions).get();
      final currentSession = sessions.firstOrNull;
      final existingActiveId = currentSession?.activeBusinessId;
      final bool hasValidActiveBusiness =
          existingActiveId != null &&
          localBusinesses.any((b) => b.id == existingActiveId);
      final activeId = hasValidActiveBusiness
          ? existingActiveId
          : localBusinesses.first.id;

      if (sessions.isEmpty) {
        await _database
            .into(_database.localSessions)
            .insert(
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
          await (_database.update(
            _database.localSessions,
          )..where((row) => row.id.equals(keep.id))).write(
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
          List<dynamic> receiptList = const [];
          try {
            receiptList = await _client.from('paper_receipts').select();
          } catch (_) {
            // Paper-receipt restoration is optional for older deployments.
            // Never discard core account/business restoration because that
            // table or its storage policy is not deployed yet.
          }
          rawSnapshot = {
            'businesses': bList,
            'customers': cList,
            'invoices': iList,
            'invoice_items': iiList,
            'payments': pList,
            'income_entries': ieList,
            'expenses': exList,
            'paper_receipts': receiptList,
          };
        }
      } catch (_) {
        if (rawSnapshot == null || rawSnapshot is! Map) return;
      }
    }

    if (rawSnapshot == null || rawSnapshot is! Map) return;
    final snapshot = Map<String, dynamic>.from(rawSnapshot);
    var businesses = List<Map<String, dynamic>>.from(
      (snapshot['businesses'] as List? ?? []).map(
        (r) => Map<String, dynamic>.from(r as Map),
      ),
    );

    // Refresh business profiles directly from the owner-scoped table. Older
    // deployed snapshot RPCs may omit newer profile fields or return a stale
    // shape even though the cloud row is current. This query is still bound
    // to the authenticated owner and is merged only by business ID.
    try {
      final cloudBusinesses = await _client
          .from('businesses')
          .select()
          .eq('owner_id', user.id);
      final merged = <String, Map<String, dynamic>>{
        for (final row in businesses)
          if (row['id'] != null) row['id'].toString(): row,
      };
      for (final row in cloudBusinesses) {
        final mapped = Map<String, dynamic>.from(row as Map);
        final id = mapped['id']?.toString();
        if (id != null) merged[id] = mapped;
      }
      businesses = merged.values.toList();
    } catch (_) {
      // Keep the snapshot result when the direct refresh is unavailable.
    }
    final allCustomers = _snapshotRows(snapshot, 'customers');
    final allInvoices = _snapshotRows(snapshot, 'invoices');
    final allItems = _snapshotRows(snapshot, 'invoice_items');
    final allPayments = _snapshotRows(snapshot, 'payments');
    final allIncome = _snapshotRows(snapshot, 'income_entries');
    final allExpenses = _snapshotRows(snapshot, 'expenses');
    final allPaperReceipts = _snapshotRows(snapshot, 'paper_receipts');
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

        int getInt(
          Map<String, dynamic> r,
          String sKey,
          String cKey, [
          int def = 0,
        ]) {
          final v = r[sKey] ?? r[cKey];
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v) ?? def;
          return def;
        }

        DateTime getDate(Map<String, dynamic> r, String sKey, String cKey) {
          final v = r[sKey] ?? r[cKey];
          if (v is String && v.isNotEmpty) {
            try {
              return DateTime.parse(v).toUtc();
            } catch (_) {}
          }
          return now;
        }

        DateTime? getDateOpt(Map<String, dynamic> r, String sKey, String cKey) {
          final v = r[sKey] ?? r[cKey];
          if (v is String && v.isNotEmpty) {
            try {
              return DateTime.parse(v).toUtc();
            } catch (_) {}
          }
          return null;
        }

        for (final row in businesses) {
          final bId = getVal(row, 'id', 'id');
          if (bId == null) continue;
          final existing = await (_database.select(
            _database.businesses,
          )..where((b) => b.id.equals(bId))).getSingleOrNull();

          final pendingDelete =
              await (_database.select(_database.syncOperations)..where(
                    (op) =>
                        op.entityType.equals('business') &
                        op.entityId.equals(bId) &
                        op.operationType.equals('BusinessDeleted'),
                  ))
                  .getSingleOrNull();

          // Never let a stale cloud snapshot overwrite a newer local profile
          // that is still queued for upload. This is especially important on
          // sign-out/sign-in: restoration must not make an offline edit look
          // lost while its operation is pending or failed.
          final pendingProfileUpdate =
              existing != null &&
              await (_database.select(_database.syncOperations)..where(
                        (op) =>
                            op.entityId.equals(bId) &
                            op.entityType.equals('business') &
                            (op.operationType.equals('BusinessUpdated') |
                                op.operationType.equals(
                                  'BusinessProfileUpdated',
                                )) &
                            op.status.isNotValue('synced'),
                      ))
                      .getSingleOrNull() !=
                  null;
          if (pendingProfileUpdate) continue;

          final cloudDeletedAt = getDateOpt(row, 'deleted_at', 'deletedAt');
          final isLocallyDeleted =
              existing?.deletedAt != null || pendingDelete != null;
          final effectiveDeletedAt = isLocallyDeleted
              ? (existing?.deletedAt ?? now)
              : cloudDeletedAt;

          final langToUse =
              existing?.preferredLanguage ??
              (getVal(row, 'preferred_language', 'preferredLanguage') ?? 'en');
          await _database
              .into(_database.businesses)
              .insertOnConflictUpdate(
                BusinessesCompanion.insert(
                  id: bId,
                  accountId: user.id,
                  ownerName: getVal(row, 'owner_name', 'ownerName') ?? 'Owner',
                  name: getVal(row, 'name', 'name') ?? 'My Business',
                  businessType: Value(
                    getVal(row, 'business_type', 'businessType'),
                  ),
                  phone: Value(getVal(row, 'phone', 'phone')),
                  email: Value(getVal(row, 'email', 'email')),
                  address: Value(getVal(row, 'address', 'address')),
                  website: Value(getVal(row, 'website', 'website')),
                  tagline: Value(getVal(row, 'tagline', 'tagline')),
                  gstin: Value(getVal(row, 'gstin', 'gstin')),
                  upiId: Value(getVal(row, 'upi_id', 'upiId')),
                  upiName: Value(getVal(row, 'upi_name', 'upiName')),
                  invoiceNotes: Value(
                    getVal(row, 'invoice_notes', 'invoiceNotes'),
                  ),
                  termsAndConditions: Value(
                    getVal(row, 'terms_and_conditions', 'termsAndConditions'),
                  ),
                  logoImage: Value(getVal(row, 'logo_image', 'logoImage')),
                  paymentQrImage: Value(
                    getVal(row, 'payment_qr_image', 'paymentQrImage'),
                  ),
                  preferredLanguage: Value(langToUse),
                  createdAt: getDate(row, 'created_at', 'createdAt'),
                  updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                  deletedAt: Value(effectiveDeletedAt),
                ),
              );
        }
        final localActiveBusinesses =
            await (_database.select(_database.businesses)
                  ..where(
                    (b) => b.accountId.equals(user.id) & b.deletedAt.isNull(),
                  )
                  ..orderBy([(b) => OrderingTerm.asc(b.name)]))
                .get();
        final businessIds = localActiveBusinesses.map((b) => b.id).toList();

        if (businessIds.isEmpty) {
          final sessions = await _database
              .select(_database.localSessions)
              .get();
          if (sessions.isEmpty) {
            await _database
                .into(_database.localSessions)
                .insert(
                  LocalSessionsCompanion.insert(
                    accountId: Value(user.id),
                    activeBusinessId: const Value(null),
                    localeCode: const Value('en'),
                    updatedAt: now,
                  ),
                );
          } else {
            final keep = sessions.first;
            await (_database.update(
              _database.localSessions,
            )..where((row) => row.id.equals(keep.id))).write(
              LocalSessionsCompanion(
                accountId: Value(user.id),
                activeBusinessId: const Value(null),
                updatedAt: Value(now),
              ),
            );
            if (sessions.length > 1) {
              final duplicateIds = sessions.skip(1).map((s) => s.id).toList();
              await (_database.delete(
                _database.localSessions,
              )..where((row) => row.id.isIn(duplicateIds))).go();
            }
          }
          return;
        }

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
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
                  ),
                );
          }
          final invoices = allInvoices
              .where(
                (r) => getVal(r, 'business_id', 'businessId') == businessId,
              )
              .toList();
          final invoiceIds = invoices
              .map((r) => getVal(r, 'id', 'id'))
              .whereType<String>()
              .toSet();
          for (final row in invoices) {
            final invId = getVal(row, 'id', 'id');
            if (invId == null) continue;
            var custId = getVal(row, 'customer_id', 'customerId');
            if (custId == null || custId.trim().isEmpty) {
              custId = '00000000-0000-0000-0000-000000000000';
            }
            final rawNotes = getVal(row, 'notes', 'notes');
            String? parsedNotes = rawNotes;
            String? parsedReceipt = getVal(
              row,
              'paper_receipt_image',
              'paperReceiptImage',
            );
            if (rawNotes != null &&
                rawNotes.contains('---ONEBILL_RECEIPT_IMAGE---')) {
              final parts = rawNotes.split('---ONEBILL_RECEIPT_IMAGE---');
              parsedNotes = parts[0].trim().isEmpty ? null : parts[0].trim();
              if (parts.length > 1 && parts[1].trim().isNotEmpty) {
                parsedReceipt ??= parts[1].trim();
              }
            }
            await _database
                .into(_database.invoices)
                .insertOnConflictUpdate(
                  InvoicesCompanion.insert(
                    id: invId,
                    businessId: businessId,
                    customerId: custId,
                    invoiceNumber:
                        getVal(row, 'invoice_number', 'invoiceNumber') ??
                        'INV-001',
                    issuedAt: getDate(row, 'issued_at', 'issuedAt'),
                    dueAt: Value(getDateOpt(row, 'due_at', 'dueAt')),
                    subtotalPaise: getInt(
                      row,
                      'subtotal_paise',
                      'subtotalPaise',
                    ),
                    discountPaise: Value(
                      getInt(row, 'discount_paise', 'discountPaise'),
                    ),
                    interestPaise: Value(
                      getInt(row, 'interest_paise', 'interestPaise'),
                    ),
                    paidPaise: Value(getInt(row, 'paid_paise', 'paidPaise')),
                    notes: Value(parsedNotes),
                    paperReceiptImage: Value(parsedReceipt),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
                  ),
                );
          }
          final items = allItems.where(
            (r) => invoiceIds.contains(getVal(r, 'invoice_id', 'invoiceId')),
          );
          for (final row in items) {
            final itemId = getVal(row, 'id', 'id');
            final invId = getVal(row, 'invoice_id', 'invoiceId');
            if (itemId == null || invId == null || invId.trim().isEmpty) {
              continue;
            }
            await _database
                .into(_database.invoiceItems)
                .insertOnConflictUpdate(
                  InvoiceItemsCompanion.insert(
                    id: itemId,
                    invoiceId: invId,
                    description:
                        getVal(row, 'description', 'description') ?? '',
                    quantityMilliunits: getInt(
                      row,
                      'quantity_milliunits',
                      'quantityMilliunits',
                    ),
                    unitPricePaise: getInt(
                      row,
                      'unit_price_paise',
                      'unitPricePaise',
                    ),
                    lineTotalPaise: getInt(
                      row,
                      'line_total_paise',
                      'lineTotalPaise',
                    ),
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
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
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
                    description: Value(
                      getVal(row, 'description', 'description'),
                    ),
                    incomeDate: getDate(row, 'income_date', 'incomeDate'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
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
                    description: Value(
                      getVal(row, 'description', 'description'),
                    ),
                    expenseDate: getDate(row, 'expense_date', 'expenseDate'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
                  ),
                );
          }
          final paperReceipts = allPaperReceipts.where(
            (r) => getVal(r, 'business_id', 'businessId') == businessId,
          );
          final receiptDirectory = Directory(
            '${(await getApplicationDocumentsDirectory()).path}/receipts',
          );
          await receiptDirectory.create(recursive: true);
          for (final row in paperReceipts) {
            final receiptId = getVal(row, 'id', 'id');
            final customerId = getVal(row, 'customer_id', 'customerId');
            if (receiptId == null || customerId == null) continue;
            final customer =
                await (_database.select(_database.customers)..where(
                      (c) =>
                          c.id.equals(customerId) &
                          c.businessId.equals(businessId),
                    ))
                    .getSingleOrNull();
            if (customer == null) {
              continue;
            }
            final existing = await (_database.select(
              _database.paperReceipts,
            )..where((r) => r.id.equals(receiptId))).getSingleOrNull();
            final pendingDelete =
                await (_database.select(_database.syncOperations)..where(
                      (op) =>
                          op.entityId.equals(receiptId) &
                          op.operationType.equals('PaperReceiptDeleted') &
                          op.status.isNotValue('synced'),
                    ))
                    .getSingleOrNull();
            if (pendingDelete != null || existing?.deletedAt != null) continue;
            final storagePath = getVal(row, 'image_url', 'imageUrl');
            final localPath = '${receiptDirectory.path}/$receiptId.jpg';
            if (storagePath != null && storagePath.isNotEmpty) {
              try {
                final bytes = await _client.storage
                    .from('paper-receipts')
                    .download(storagePath);
                await File(localPath).writeAsBytes(bytes, flush: true);
              } catch (_) {
                // Keep metadata and any existing local image if the network
                // is temporarily unavailable; the next restore can retry.
              }
            }
            await _database
                .into(_database.paperReceipts)
                .insertOnConflictUpdate(
                  PaperReceiptsCompanion.insert(
                    id: receiptId,
                    businessId: businessId,
                    customerId: customerId,
                    imagePath: existing?.imagePath ?? localPath,
                    remoteImageUrl: Value(storagePath),
                    notes: Value(getVal(row, 'notes', 'notes')),
                    receiptDate: getDate(row, 'receipt_date', 'receiptDate'),
                    createdAt: getDate(row, 'created_at', 'createdAt'),
                    updatedAt: getDate(row, 'updated_at', 'updatedAt'),
                    deletedAt: Value(
                      getDateOpt(row, 'deleted_at', 'deletedAt'),
                    ),
                  ),
                );
          }
        }
        final preferredLanguage = localActiveBusinesses.first.preferredLanguage;
        final sessions = await _database.select(_database.localSessions).get();
        final currentSession = sessions.firstOrNull;
        final existingActiveId = currentSession?.activeBusinessId;
        final hasValidActiveBusiness =
            existingActiveId != null && businessIds.contains(existingActiveId);
        final targetActiveId = hasValidActiveBusiness
            ? existingActiveId
            : businessIds.first;

        if (sessions.isEmpty) {
          await _database
              .into(_database.localSessions)
              .insert(
                LocalSessionsCompanion.insert(
                  accountId: Value(user.id),
                  activeBusinessId: Value(targetActiveId),
                  localeCode: Value(preferredLanguage),
                  updatedAt: now,
                ),
              );
        } else {
          final keep = sessions.first;
          if (keep.accountId != user.id ||
              keep.activeBusinessId != targetActiveId) {
            await (_database.update(
              _database.localSessions,
            )..where((row) => row.id.equals(keep.id))).write(
              LocalSessionsCompanion(
                accountId: Value(user.id),
                activeBusinessId: Value(targetActiveId),
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
    final previous = _syncChain;
    final done = Completer<void>();
    _syncChain = done.future;
    try {
      await previous;
      await _syncBusinessNow(businessId);
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _syncBusinessNow(String businessId) async {
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
    // A sync call must never re-parent local businesses to the current user.
    // That old repair path could upload another account's queue under this
    // account after a sign-out/sign-in transition.
    final ownedBusiness =
        await (_database.select(_database.businesses)..where(
              (row) => row.id.equals(businessId) & row.accountId.equals(userId),
            ))
            .getSingleOrNull();
    if (ownedBusiness == null) return;

    _running = true;
    try {
      // Automatic sync honours retry back-off. Explicit retryFailedOperations
      // performs the force requeue before calling this method.
      await _requeueTransientFailures(businessId: businessId, force: true);
      int processedBatches = 0;
      while (processedBatches < 20) {
        final operations =
            await (_database.select(_database.syncOperations)
                  ..where(
                    (operation) =>
                        operation.status.equals('pending') &
                        operation.businessId.equals(businessId),
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
                    (result.data as Map).containsKey(
                      'acknowledgedOperationIds',
                    )) {
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
              final conflict = conflicts
                  .cast<Map<String, dynamic>?>()
                  .firstWhere(
                    (entry) => entry?['operationId'] == operation.id,
                    orElse: () => null,
                  );
              final failure = failed.cast<Map<String, dynamic>?>().firstWhere(
                (entry) => entry?['operationId'] == operation.id,
                orElse: () => null,
              );
              final reason =
                  (conflict?['reason'] ??
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
      query.where(
        (operation) =>
            operation.status.isNotValue('pending') &
            operation.status.isNotValue('synced'),
      );
    } else {
      query.where(
        (operation) =>
            operation.status.isNotValue('pending') &
            operation.status.isNotValue('synced') &
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
      await (_database.update(
        _database.syncOperations,
      )..where((row) => row.id.equals(operation.id))).write(
        const SyncOperationsCompanion(
          status: Value('pending'),
          attemptCount: Value(0),
        ),
      );
    }
  }

  bool _isAlreadyApplied(String _, String reason) {
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
        final b = await (database.select(
          database.businesses,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) {
          payload = _businessPayload(b);
        } else if (operation.payloadJson.isNotEmpty) {
          try {
            final raw =
                jsonDecode(operation.payloadJson) as Map<String, dynamic>;
            final lang = {'en', 'hi', 'te'}.contains(raw['preferredLanguage'])
                ? raw['preferredLanguage'] as String
                : 'en';
            payload = {
              'id': operation.entityId,
              'name': (raw['name'] as String?)?.trim().isNotEmpty == true
                  ? (raw['name'] as String).trim()
                  : 'My Business',
              'ownerName':
                  (raw['ownerName'] as String?)?.trim().isNotEmpty == true
                  ? (raw['ownerName'] as String).trim()
                  : 'Owner',
              'preferredLanguage': lang,
              'preferred_language': lang,
              'createdAt': operation.createdAt.toUtc().toIso8601String(),
              'updatedAt': operation.createdAt.toUtc().toIso8601String(),
            };
          } catch (_) {}
        }
        break;

      case 'BusinessUpdated':
      case 'BusinessProfileUpdated':
        final b = await (database.select(
          database.businesses,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) payload = {..._businessPayload(b), 'expectedVersion': 1};
        break;

      case 'BusinessDeleted':
        final b = await (database.select(
          database.businesses,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (b != null) {
          payload = {
            ..._businessPayload(b),
            'deletedAt': (b.deletedAt ?? DateTime.now().toUtc())
                .toIso8601String(),
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
        final c = await (database.select(
          database.customers,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (c != null) payload = _customerPayload(c, expectedVersion: 1);
        break;

      case 'InvoiceCreated':
      case 'InvoiceUpdated':
        final inv = await (database.select(
          database.invoices,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (inv != null) {
          final items = await (database.select(
            database.invoiceItems,
          )..where((e) => e.invoiceId.equals(entityId))).get();
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
        final p = await (database.select(
          database.payments,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (p != null) payload = _paymentPayload(p);
        break;

      case 'PaymentReversed':
        final p = await (database.select(
          database.payments,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (p != null) {
          payload = {
            ..._paymentPayload(p),
            'reversedAt': (p.deletedAt ?? DateTime.now().toUtc())
                .toIso8601String(),
            'deletedAt': (p.deletedAt ?? DateTime.now().toUtc())
                .toIso8601String(),
          };
        } else if (operation.payloadJson.isNotEmpty) {
          try {
            final raw = jsonDecode(operation.payloadJson);
            if (raw is Map) {
              payload = Map<String, Object?>.from(raw);
            }
          } catch (_) {}
        }
        break;

      case 'IncomeCreated':
      case 'IncomeUpdated':
      case 'IncomeDeleted':
        final inc = await (database.select(
          database.incomeEntries,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (inc != null) payload = _incomePayload(inc);
        break;

      case 'ExpenseCreated':
      case 'ExpenseUpdated':
      case 'ExpenseDeleted':
        final exp = await (database.select(
          database.expenses,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (exp != null) payload = _expensePayload(exp);
        break;

      case 'PaperReceiptCreated':
        final r = await (database.select(
          database.paperReceipts,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (r != null) {
          final storagePath = await _uploadPaperReceiptImage(r);
          payload = {
            'id': r.id,
            'businessId': r.businessId,
            'customerId': r.customerId,
            'storagePath': storagePath,
            'receiptDate': r.receiptDate.toUtc().toIso8601String(),
            'notes': r.notes,
            'createdAt': r.createdAt.toUtc().toIso8601String(),
            'updatedAt': r.updatedAt.toUtc().toIso8601String(),
          };
        }
        break;

      case 'PaperReceiptDeleted':
        final r = await (database.select(
          database.paperReceipts,
        )..where((e) => e.id.equals(entityId))).getSingleOrNull();
        if (r != null) {
          payload = {
            'id': r.id,
            'businessId': r.businessId,
            'deletedAt': (r.deletedAt ?? DateTime.now().toUtc())
                .toIso8601String(),
          };
        }
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
      'businessId':
          (operation.businessId != null && operation.businessId!.isNotEmpty)
          ? operation.businessId!
          : (payload['businessId'] as String? ??
                payload['id'] as String? ??
                ''),
      'entityType': entityType,
      'entityId': entityId,
      'operationType': operation.operationType,
      'occurredAt': operation.createdAt.toUtc().toIso8601String(),
      'payload': payload,
    };
  }

  Future<String> _uploadPaperReceiptImage(PaperReceipt receipt) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('Not signed in for receipt upload');
    final file = File(receipt.imagePath);
    if (!await file.exists()) {
      throw StateError('Receipt image is missing locally');
    }
    final path = '${user.id}/${receipt.businessId}/${receipt.id}.jpg';
    await _client.storage
        .from('paper-receipts')
        .uploadBinary(
          path,
          await file.readAsBytes(),
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    return path;
  }

  Map<String, Object?> _businessPayload(BusinessesData business) {
    final lang = {'en', 'hi', 'te'}.contains(business.preferredLanguage)
        ? business.preferredLanguage
        : 'en';
    final name = business.name.trim().isEmpty
        ? 'My Business'
        : business.name.trim();
    final ownerName = business.ownerName.trim().isEmpty
        ? 'Owner'
        : business.ownerName.trim();
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
  ) {
    String? cloudNotes = invoice.notes;
    if (invoice.paperReceiptImage != null &&
        invoice.paperReceiptImage!.trim().isNotEmpty) {
      const delimiter = '\n---ONEBILL_RECEIPT_IMAGE---\n';
      cloudNotes = (cloudNotes != null && cloudNotes.trim().isNotEmpty)
          ? '${cloudNotes.trim()}$delimiter${invoice.paperReceiptImage!.trim()}'
          : '$delimiter${invoice.paperReceiptImage!.trim()}';
    }
    return {
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
        'notes': cloudNotes,
        'paperReceiptImage': invoice.paperReceiptImage,
        'createdAt': invoice.createdAt.toUtc().toIso8601String(),
        'updatedAt': invoice.updatedAt.toUtc().toIso8601String(),
        'deletedAt': invoice.deletedAt?.toUtc().toIso8601String(),
      },
      'items': items
          .map(
            (item) => {
              'id': item.id,
              'description': item.description.trim().isEmpty
                  ? 'Item'
                  : item.description.trim(),
              'quantityMilliunits': item.quantityMilliunits <= 0
                  ? 1000
                  : item.quantityMilliunits,
              'unitPricePaise': item.unitPricePaise,
              'lineTotalPaise': item.lineTotalPaise,
              'sortOrder': item.sortOrder,
            },
          )
          .toList(),
    };
  }

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
    final existing = await (_database.select(
      _database.syncOperations,
    )..where((op) => op.id.equals(id))).getSingleOrNull();
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
