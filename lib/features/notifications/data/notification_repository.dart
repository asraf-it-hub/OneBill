import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/database/app_database.dart';
import 'notification_constants.dart';

class NotificationRepository {
  final AppDatabase _db;
  NotificationRepository(this._db);

  String? _signedInAccountId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _accountIdForBusiness(String? businessId) async {
    final signedIn = _signedInAccountId();
    if (signedIn != null) return signedIn;
    final localSession =
        await (_db.select(_db.localSessions)
              ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (localSession?.accountId != null) return localSession!.accountId;
    if (businessId == null || businessId.isEmpty) return null;
    final business = await (_db.select(
      _db.businesses,
    )..where((b) => b.id.equals(businessId))).getSingleOrNull();
    return business?.accountId;
  }

  Stream<List<AppNotification>> watchNotifications({String? businessId}) {
    final query = _db.select(_db.appNotifications);
    final accountId = _signedInAccountId();
    if (accountId == null) {
      query.where((tbl) => tbl.accountId.isNull());
    } else {
      query.where((tbl) => tbl.accountId.equals(accountId));
    }
    if (businessId != null && businessId.isNotEmpty) {
      query.where((tbl) => tbl.businessId.equals(businessId));
    }
    query.orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]);
    return query.watch();
  }

  Stream<int> watchUnreadCount({String? businessId}) {
    final query = _db.select(_db.appNotifications)
      ..where((tbl) => tbl.isRead.equals(false));
    final accountId = _signedInAccountId();
    if (accountId == null) {
      query.where((tbl) => tbl.accountId.isNull());
    } else {
      query.where((tbl) => tbl.accountId.equals(accountId));
    }
    if (businessId != null && businessId.isNotEmpty) {
      query.where((tbl) => tbl.businessId.equals(businessId));
    }
    return query.watch().map((list) => list.length);
  }

  Future<void> addNotification({
    required String id,
    String? businessId,
    required String category,
    required String title,
    required String body,
    String? entityType,
    String? entityId,
    DateTime? scheduledAt,
    String? payloadJson,
  }) async {
    final accountId = await _accountIdForBusiness(businessId);
    await _db
        .into(_db.appNotifications)
        .insertOnConflictUpdate(
          AppNotificationsCompanion.insert(
            id: id,
            accountId: Value(accountId),
            businessId: Value(businessId),
            category: category,
            title: title,
            body: body,
            entityType: Value(entityType),
            entityId: Value(entityId),
            createdAt: DateTime.now(),
            scheduledAt: Value(scheduledAt),
            payloadJson: Value(payloadJson),
          ),
        );
  }

  Future<void> markAsRead(String id) async {
    final accountId = _signedInAccountId();
    final query = _db.update(_db.appNotifications)
      ..where((tbl) => tbl.id.equals(id));
    query.where(
      accountId == null
          ? (tbl) => tbl.accountId.isNull()
          : (tbl) => tbl.accountId.equals(accountId),
    );
    await query.write(const AppNotificationsCompanion(isRead: Value(true)));
  }

  Future<void> markAllAsRead({String? businessId}) async {
    final query = _db.update(_db.appNotifications)
      ..where((tbl) => tbl.isRead.equals(false));
    final accountId = _signedInAccountId();
    query.where(
      accountId == null
          ? (tbl) => tbl.accountId.isNull()
          : (tbl) => tbl.accountId.equals(accountId),
    );
    if (businessId != null && businessId.isNotEmpty) {
      query.where((tbl) => tbl.businessId.equals(businessId));
    }
    await query.write(const AppNotificationsCompanion(isRead: Value(true)));
  }

  Future<void> markAsHandled(String id) async {
    final accountId = _signedInAccountId();
    final query = _db.update(_db.appNotifications)
      ..where((tbl) => tbl.id.equals(id));
    query.where(
      accountId == null
          ? (tbl) => tbl.accountId.isNull()
          : (tbl) => tbl.accountId.equals(accountId),
    );
    await query.write(
      const AppNotificationsCompanion(
        isRead: Value(true),
        isHandled: Value(true),
      ),
    );
  }

  Future<void> clearAllNotifications({String? businessId}) async {
    final query = _db.delete(_db.appNotifications);
    final accountId = _signedInAccountId();
    query.where(
      accountId == null
          ? (tbl) => tbl.accountId.isNull()
          : (tbl) => tbl.accountId.equals(accountId),
    );
    if (businessId != null && businessId.isNotEmpty) {
      query.where((tbl) => tbl.businessId.equals(businessId));
    }
    await query.go();
  }

  Future<void> deleteNotification(String id) async {
    final accountId = _signedInAccountId();
    final query = _db.delete(_db.appNotifications)
      ..where((tbl) => tbl.id.equals(id));
    query.where(
      accountId == null
          ? (tbl) => tbl.accountId.isNull()
          : (tbl) => tbl.accountId.equals(accountId),
    );
    await query.go();
  }

  // Preferences & Settings
  Stream<Map<String, bool>> watchPreferences() {
    return _db.select(_db.notificationPreferences).watch().map((rows) {
      final map = Map<String, bool>.from(NotificationCategories.defaults);
      for (final row in rows) {
        map[row.categoryKey] = row.isEnabled;
      }
      return map;
    });
  }

  Future<Map<String, bool>> getPreferences() async {
    final rows = await _db.select(_db.notificationPreferences).get();
    final map = Map<String, bool>.from(NotificationCategories.defaults);
    for (final row in rows) {
      map[row.categoryKey] = row.isEnabled;
    }
    return map;
  }

  Future<void> setPreference(String categoryKey, bool enabled) async {
    await _db
        .into(_db.notificationPreferences)
        .insertOnConflictUpdate(
          NotificationPreferencesCompanion.insert(
            categoryKey: categoryKey,
            isEnabled: Value(enabled),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Stream<NotificationSetting?> watchSettings() {
    return (_db.select(
      _db.notificationSettings,
    )..where((tbl) => tbl.id.equals('global'))).watchSingleOrNull();
  }

  Future<NotificationSetting> getSettings() async {
    final setting = await (_db.select(
      _db.notificationSettings,
    )..where((tbl) => tbl.id.equals('global'))).getSingleOrNull();
    if (setting != null) return setting;

    // Insert default settings row
    await _db
        .into(_db.notificationSettings)
        .insert(
          NotificationSettingsCompanion.insert(
            id: 'global',
            masterEnabled: const Value(true),
            retentionDays: const Value(365),
            permissionRequested: const Value(false),
            updatedAt: DateTime.now(),
          ),
        );
    return (await (_db.select(
      _db.notificationSettings,
    )..where((tbl) => tbl.id.equals('global'))).getSingle());
  }

  Future<void> updateSettings({
    bool? masterEnabled,
    int? retentionDays,
    bool? permissionRequested,
    Value<String?>? lastOverdueSignature,
  }) async {
    final current = await getSettings();
    await _db
        .into(_db.notificationSettings)
        .insertOnConflictUpdate(
          NotificationSettingsCompanion.insert(
            id: 'global',
            masterEnabled: Value(masterEnabled ?? current.masterEnabled),
            retentionDays: Value(retentionDays ?? current.retentionDays),
            permissionRequested: Value(
              permissionRequested ?? current.permissionRequested,
            ),
            lastOverdueSignature:
                lastOverdueSignature ?? Value(current.lastOverdueSignature),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> cleanupOldNotifications([int retentionDays = 365]) async {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    await (_db.delete(
      _db.appNotifications,
    )..where((tbl) => tbl.createdAt.isSmallerThan(Variable(cutoff)))).go();
  }
}
