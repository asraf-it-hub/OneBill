import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class BusinessRepository {
  BusinessRepository(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  Stream<LocalSession?> watchSession() =>
      (_database.select(_database.localSessions)
            ..orderBy([(session) => OrderingTerm.desc(session.updatedAt)])
            ..limit(1))
          .watchSingleOrNull();

  User? get _currentUser {
    try {
      return Supabase.instance.client.auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  Stream<List<BusinessesData>> watchBusinesses(String accountId) {
    final activeUser = _currentUser;
    final effectiveId = activeUser?.id ?? accountId;
    return (_database.select(_database.businesses)
          ..where((b) => (b.accountId.equals(effectiveId) | b.accountId.equals(accountId)) & b.deletedAt.isNull())
          ..orderBy([(b) => OrderingTerm.asc(b.name)]))
        .watch();
  }

  Future<void> createLocalWorkspace({
    String? accountId,
    required String ownerName,
    required String businessName,
    required String languageCode,
    String? phone,
  }) async {
    final now = DateTime.now().toUtc();
    final activeUser = _currentUser;
    final effectiveAccountId = activeUser?.id ?? accountId ?? _uuid.v4();
    final businessId = _uuid.v4();
    await _database.transaction(() async {
      await _database
          .into(_database.userAccounts)
          .insertOnConflictUpdate(
            UserAccountsCompanion.insert(
              id: effectiveAccountId,
              displayName: ownerName.trim(),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _database
          .into(_database.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: businessId,
              accountId: effectiveAccountId,
              ownerName: ownerName.trim(),
              name: businessName.trim(),
              phone: Value(
                phone?.trim().isEmpty ?? true ? null : phone!.trim(),
              ),
              preferredLanguage: Value(languageCode),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _database
          .into(_database.localSessions)
          .insert(
            LocalSessionsCompanion.insert(
              accountId: Value(effectiveAccountId),
              activeBusinessId: Value(businessId),
              localeCode: Value(languageCode),
              updatedAt: now,
            ),
          );
      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessCreated',
        payload: {
          'id': businessId,
          'name': businessName.trim(),
          'ownerName': ownerName.trim(),
          'phone': _blankToNull(phone),
          'preferredLanguage': languageCode,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
        now: now,
      );
    });
  }

  Future<void> switchBusiness({
    required int sessionId,
    required String businessId,
  }) async {
    final business =
        await (_database.select(_database.businesses)
              ..where((b) => b.id.equals(businessId) & b.deletedAt.isNull()))
            .getSingle();
    await (_database.update(
      _database.localSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      LocalSessionsCompanion(
        accountId: Value(business.accountId),
        activeBusinessId: Value(businessId),
        localeCode: Value(business.preferredLanguage),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<String> createBusiness({
    required String accountId,
    required String ownerName,
    required String businessName,
    required String languageCode,
    String? phone,
  }) async {
    final now = DateTime.now().toUtc();
    final businessId = _uuid.v4();
    final activeUser = _currentUser;
    final effectiveAccountId = activeUser?.id ?? accountId;
    await _database.transaction(() async {
      var account = await (_database.select(
        _database.userAccounts,
      )..where((entry) => entry.id.equals(effectiveAccountId))).getSingleOrNull();
      if (account == null) {
        await _database.into(_database.userAccounts).insertOnConflictUpdate(
              UserAccountsCompanion.insert(
                id: effectiveAccountId,
                displayName: ownerName.trim(),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      await _database
          .into(_database.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: businessId,
              accountId: effectiveAccountId,
              ownerName: ownerName.trim(),
              name: businessName.trim(),
              phone: Value(
                phone?.trim().isEmpty ?? true ? null : phone!.trim(),
              ),
              preferredLanguage: Value(languageCode),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final sessions = await _database.select(_database.localSessions).get();
      for (final s in sessions) {
        if (s.accountId != effectiveAccountId) {
          await (_database.update(_database.localSessions)
                ..where((row) => row.id.equals(s.id)))
              .write(LocalSessionsCompanion(accountId: Value(effectiveAccountId)));
        }
      }
      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessCreated',
        payload: {
          'id': businessId,
          'name': businessName.trim(),
          'ownerName': ownerName.trim(),
          'phone': _blankToNull(phone),
          'preferredLanguage': languageCode,
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
        now: now,
      );
    });
    return businessId;
  }

  Future<void> updateBusiness({
    required String businessId,
    required String ownerName,
    required String name,
    required String languageCode,
    String? phone,
    String? email,
    String? address,
    String? website,
    String? tagline,
    String? gstin,
    String? upiId,
    String? upiName,
    String? invoiceNotes,
    String? termsAndConditions,
    String? logoImage,
    String? paymentQrImage,
  }) async {
    if (ownerName.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('Owner name and business name are required.');
    }
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final business =
          await (_database.select(_database.businesses)..where(
                (entry) =>
                    entry.id.equals(businessId) & entry.deletedAt.isNull(),
              ))
              .getSingle();
      await (_database.update(
        _database.businesses,
      )..where((entry) => entry.id.equals(businessId))).write(
        BusinessesCompanion(
          ownerName: Value(ownerName.trim()),
          name: Value(name.trim()),
          phone: Value(_blankToNull(phone)),
          email: Value(_blankToNull(email)),
          address: Value(_blankToNull(address)),
          website: Value(_blankToNull(website)),
          tagline: Value(_blankToNull(tagline)),
          gstin: Value(_blankToNull(gstin)),
          upiId: Value(_blankToNull(upiId)),
          upiName: Value(_blankToNull(upiName)),
          invoiceNotes: Value(_blankToNull(invoiceNotes)),
          termsAndConditions: Value(_blankToNull(termsAndConditions)),
          logoImage: Value(_blankToNull(logoImage)),
          paymentQrImage: Value(_blankToNull(paymentQrImage)),
          preferredLanguage: Value(languageCode),
          updatedAt: Value(now),
        ),
      );
      await (_database.update(
        _database.localSessions,
      )..where((session) => session.activeBusinessId.equals(businessId))).write(
        LocalSessionsCompanion(
          localeCode: Value(languageCode),
          updatedAt: Value(now),
        ),
      );
      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessUpdated',
        payload: {
          'id': businessId,
          'name': name.trim(),
          'ownerName': ownerName.trim(),
          'phone': _blankToNull(phone),
          'email': _blankToNull(email),
          'address': _blankToNull(address),
          'website': _blankToNull(website),
          'tagline': _blankToNull(tagline),
          'gstin': _blankToNull(gstin),
          'upiId': _blankToNull(upiId),
          'upiName': _blankToNull(upiName),
          'invoiceNotes': _blankToNull(invoiceNotes),
          'termsAndConditions': _blankToNull(termsAndConditions),
          'logoImage': _blankToNull(logoImage),
          'paymentQrImage': _blankToNull(paymentQrImage),
          'preferredLanguage': languageCode,
          'createdAt': business.createdAt.toUtc().toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
        now: now,
      );
    });
  }

  Future<void> deleteBusiness({required String businessId}) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final business = await (_database.select(_database.businesses)
            ..where((entry) => entry.id.equals(businessId)))
          .getSingleOrNull();
      if (business == null) return;

      await (_database.update(_database.businesses)
            ..where((entry) => entry.id.equals(businessId)))
          .write(
        BusinessesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessDeleted',
        payload: {
          'id': businessId,
          'deletedAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
        now: now,
      );

      final remainingBusinesses = await (_database.select(_database.businesses)
            ..where(
              (b) =>
                  b.accountId.equals(business.accountId) &
                  b.deletedAt.isNull(),
            )
            ..orderBy([(b) => OrderingTerm.asc(b.name)]))
          .get();

      final session = await (_database.select(_database.localSessions)
            ..where((s) => s.accountId.equals(business.accountId)))
          .getSingleOrNull();

      if (session != null) {
        if (remainingBusinesses.isNotEmpty) {
          final nextId = remainingBusinesses.first.id;
          final lang = remainingBusinesses.first.preferredLanguage;
          await (_database.update(_database.localSessions)
                ..where((s) => s.id.equals(session.id)))
              .write(
            LocalSessionsCompanion(
              activeBusinessId: Value(nextId),
              localeCode: Value(lang),
              updatedAt: Value(now),
            ),
          );
        } else {
          await (_database.update(_database.localSessions)
                ..where((s) => s.id.equals(session.id)))
              .write(
            LocalSessionsCompanion(
              activeBusinessId: const Value(null),
              updatedAt: Value(now),
            ),
          );
        }
      }
    });
  }

  String? _blankToNull(String? value) =>

      value == null || value.trim().isEmpty ? null : value.trim();

  Future<void> _enqueue({
    required String businessId,
    required String entityType,
    required String entityId,
    required String operationType,
    required Map<String, Object?> payload,
    required DateTime now,
  }) {
    return _database
        .into(_database.syncOperations)
        .insert(
          SyncOperationsCompanion.insert(
            id: _uuid.v4(),
            businessId: Value(businessId),
            entityType: entityType,
            entityId: entityId,
            operationType: operationType,
            payloadJson: jsonEncode(payload),
            createdAt: now,
          ),
        );
  }
}
