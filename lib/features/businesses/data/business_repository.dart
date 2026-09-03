import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class BusinessRepository {
  BusinessRepository(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  Stream<LocalSession?> watchSession() =>
      _database.select(_database.localSessions).watchSingleOrNull();

  Stream<List<BusinessesData>> watchBusinesses(String accountId) {
    return (_database.select(_database.businesses)
          ..where((b) => b.accountId.equals(accountId) & b.deletedAt.isNull())
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
    final localAccountId = accountId ?? _uuid.v4();
    final businessId = _uuid.v4();
    await _database.transaction(() async {
      await _database
          .into(_database.userAccounts)
          .insert(
            UserAccountsCompanion.insert(
              id: localAccountId,
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
              accountId: localAccountId,
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
              accountId: Value(localAccountId),
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
        payload: {'businessId': businessId},
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
    final session = await (_database.select(
      _database.localSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();
    if (session.accountId != business.accountId) {
      throw StateError('The selected business belongs to a different account.');
    }
    await (_database.update(
      _database.localSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      LocalSessionsCompanion(
        activeBusinessId: Value(businessId),
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
    await _database.transaction(() async {
      final account = await (_database.select(
        _database.userAccounts,
      )..where((entry) => entry.id.equals(accountId))).getSingleOrNull();
      if (account == null) {
        throw StateError('The active account is not available on this device.');
      }
      await _database
          .into(_database.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: businessId,
              accountId: accountId,
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
      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessCreated',
        payload: {'businessId': businessId},
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
    String? upiId,
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
          upiId: Value(_blankToNull(upiId)),
          preferredLanguage: Value(languageCode),
          updatedAt: Value(now),
        ),
      );
      await _enqueue(
        businessId: businessId,
        entityType: 'business',
        entityId: businessId,
        operationType: 'BusinessUpdated',
        payload: {'businessId': business.id},
        now: now,
      );
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
