import 'package:drift/drift.dart';
import '../../../core/database/app_database.dart';
import 'notification_constants.dart';

class NotificationRepository {
  final AppDatabase _db;
  NotificationRepository(this._db);

  Stream<List<AppNotification>> watchNotifications({String? businessId}) {
    final query = _db.select(_db.appNotifications);
    if (businessId != null && businessId.isNotEmpty) {
      query.where(
        (tbl) =>
            tbl.businessId.equals(businessId) | tbl.businessId.isNull(),
      );
    }
    query.orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]);
    return query.watch();
  }

  Stream<int> watchUnreadCount({String? businessId}) {
    final query = _db.select(_db.appNotifications)
      ..where((tbl) => tbl.isRead.equals(false));
    if (businessId != null && businessId.isNotEmpty) {
      query.where(
        (tbl) =>
            tbl.businessId.equals(businessId) | tbl.businessId.isNull(),
      );
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
    await _db.into(_db.appNotifications).insertOnConflictUpdate(
          AppNotificationsCompanion.insert(
            id: id,
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
    await (_db.update(_db.appNotifications)..where((tbl) => tbl.id.equals(id)))
        .write(const AppNotificationsCompanion(isRead: Value(true)));
  }

  Future<void> markAllAsRead({String? businessId}) async {
    final query = _db.update(_db.appNotifications)
      ..where((tbl) => tbl.isRead.equals(false));
    if (businessId != null && businessId.isNotEmpty) {
      query.where(
        (tbl) =>
            tbl.businessId.equals(businessId) | tbl.businessId.isNull(),
      );
    }
    await query.write(const AppNotificationsCompanion(isRead: Value(true)));
  }

  Future<void> markAsHandled(String id) async {
    await (_db.update(_db.appNotifications)..where((tbl) => tbl.id.equals(id)))
        .write(const AppNotificationsCompanion(
          isRead: Value(true),
          isHandled: Value(true),
        ));
  }

  Future<void> clearAllNotifications({String? businessId}) async {
    final query = _db.delete(_db.appNotifications);
    if (businessId != null && businessId.isNotEmpty) {
      query.where(
        (tbl) =>
            tbl.businessId.equals(businessId) | tbl.businessId.isNull(),
      );
    }
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
    await _db.into(_db.notificationPreferences).insertOnConflictUpdate(
          NotificationPreferencesCompanion.insert(
            categoryKey: categoryKey,
            isEnabled: Value(enabled),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Stream<NotificationSetting?> watchSettings() {
    return (_db.select(_db.notificationSettings)
          ..where((tbl) => tbl.id.equals('global')))
        .watchSingleOrNull();
  }

  Future<NotificationSetting> getSettings() async {
    final setting = await (_db.select(_db.notificationSettings)
          ..where((tbl) => tbl.id.equals('global')))
        .getSingleOrNull();
    if (setting != null) return setting;

    // Insert default settings row
    await _db.into(_db.notificationSettings).insert(
          NotificationSettingsCompanion.insert(
            id: 'global',
            masterEnabled: const Value(true),
            quietHoursEnabled: const Value(true),
            quietHoursStart: const Value('22:00'),
            quietHoursEnd: const Value('07:00'),
            retentionDays: const Value(365),
            permissionRequested: const Value(false),
            updatedAt: DateTime.now(),
          ),
        );
    return (await (_db.select(_db.notificationSettings)
          ..where((tbl) => tbl.id.equals('global')))
        .getSingle());
  }

  Future<void> updateSettings({
    bool? masterEnabled,
    bool? quietHoursEnabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    int? retentionDays,
    bool? permissionRequested,
    Value<String?>? lastOverdueSignature,
  }) async {
    final current = await getSettings();
    await _db.into(_db.notificationSettings).insertOnConflictUpdate(
          NotificationSettingsCompanion.insert(
            id: 'global',
            masterEnabled: Value(masterEnabled ?? current.masterEnabled),
            quietHoursEnabled:
                Value(quietHoursEnabled ?? current.quietHoursEnabled),
            quietHoursStart: Value(quietHoursStart ?? current.quietHoursStart),
            quietHoursEnd: Value(quietHoursEnd ?? current.quietHoursEnd),
            retentionDays: Value(retentionDays ?? current.retentionDays),
            permissionRequested:
                Value(permissionRequested ?? current.permissionRequested),
            lastOverdueSignature:
                lastOverdueSignature ?? Value(current.lastOverdueSignature),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> cleanupOldNotifications([int retentionDays = 365]) async {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    await (_db.delete(_db.appNotifications)
          ..where((tbl) => tbl.createdAt.isSmallerThan(Variable(cutoff))))
        .go();
  }
}
