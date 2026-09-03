import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class IncomeRepository {
  IncomeRepository(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  Stream<List<IncomeEntry>> watch(String businessId) =>
      (_database.select(_database.incomeEntries)
            ..where(
              (e) => e.businessId.equals(businessId) & e.deletedAt.isNull(),
            )
            ..orderBy([(e) => OrderingTerm.desc(e.incomeDate)]))
          .watch();

  Future<void> add({
    required String businessId,
    required int amountPaise,
    String? description,
    required DateTime incomeDate,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('Amount must be greater than zero.');
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _database.transaction(() async {
      await _database
          .into(_database.incomeEntries)
          .insert(
            IncomeEntriesCompanion.insert(
              id: id,
              businessId: businessId,
              amountPaise: amountPaise,
              description: Value(
                description?.trim().isEmpty ?? true
                    ? null
                    : description!.trim(),
              ),
              incomeDate: incomeDate.toUtc(),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _enqueue(id, businessId, 'IncomeCreated', now);
    });
  }

  Future<void> update({
    required String businessId,
    required String id,
    required int amountPaise,
    String? description,
    required DateTime incomeDate,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('Amount must be greater than zero.');
    }
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.incomeEntries)..where(
                (e) =>
                    e.id.equals(id) &
                    e.businessId.equals(businessId) &
                    e.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (existing == null) throw StateError('Income record not found.');
      await (_database.update(
        _database.incomeEntries,
      )..where((e) => e.id.equals(id))).write(
        IncomeEntriesCompanion(
          amountPaise: Value(amountPaise),
          description: Value(
            description?.trim().isEmpty ?? true ? null : description!.trim(),
          ),
          incomeDate: Value(incomeDate.toUtc()),
          updatedAt: Value(now),
        ),
      );
      await _enqueue(id, businessId, 'IncomeUpdated', now);
    });
  }

  Future<void> delete({required String businessId, required String id}) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.incomeEntries)..where(
                (e) =>
                    e.id.equals(id) &
                    e.businessId.equals(businessId) &
                    e.deletedAt.isNull(),
              ))
              .write(
                IncomeEntriesCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (changed == 0) throw StateError('Income record not found.');
      await _enqueue(id, businessId, 'IncomeDeleted', now);
    });
  }

  Future<void> _enqueue(
    String id,
    String businessId,
    String type,
    DateTime now,
  ) => _database
      .into(_database.syncOperations)
      .insert(
        SyncOperationsCompanion.insert(
          id: _uuid.v4(),
          businessId: Value(businessId),
          entityType: 'income',
          entityId: id,
          operationType: type,
          payloadJson: jsonEncode({'incomeId': id}),
          createdAt: now,
        ),
      );
}
