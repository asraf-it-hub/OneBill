import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';

class ExpenseRepository {
  ExpenseRepository(this._db);
  final AppDatabase _db;
  static const _uuid = Uuid();
  Stream<List<Expense>> watch(String businessId) =>
      (_db.select(_db.expenses)
            ..where(
              (e) => e.businessId.equals(businessId) & e.deletedAt.isNull(),
            )
            ..orderBy([(e) => OrderingTerm.desc(e.expenseDate)]))
          .watch();
  Future<void> add({
    required String businessId,
    required int amountPaise,
    required String category,
    String? description,
    required DateTime expenseDate,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('Amount must be greater than zero.');
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.transaction(() async {
      await _db
          .into(_db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: id,
              businessId: businessId,
              amountPaise: amountPaise,
              category: category.trim(),
              description: Value(
                description?.trim().isEmpty ?? true
                    ? null
                    : description!.trim(),
              ),
              expenseDate: expenseDate.toUtc(),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _queue(id, businessId, 'ExpenseCreated', now);
    });
  }

  Future<void> update({
    required String businessId,
    required String id,
    required int amountPaise,
    required String category,
    String? description,
    required DateTime expenseDate,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('Amount must be greater than zero.');
    }
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final row =
          await (_db.select(_db.expenses)..where(
                (e) =>
                    e.id.equals(id) &
                    e.businessId.equals(businessId) &
                    e.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (row == null) throw StateError('Expense not found.');
      await (_db.update(_db.expenses)..where((e) => e.id.equals(id))).write(
        ExpensesCompanion(
          amountPaise: Value(amountPaise),
          category: Value(category.trim()),
          description: Value(
            description?.trim().isEmpty ?? true ? null : description!.trim(),
          ),
          expenseDate: Value(expenseDate.toUtc()),
          updatedAt: Value(now),
        ),
      );
      await _queue(id, businessId, 'ExpenseUpdated', now);
    });
  }

  Future<void> delete({required String businessId, required String id}) async {
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final count =
          await (_db.update(_db.expenses)..where(
                (e) =>
                    e.id.equals(id) &
                    e.businessId.equals(businessId) &
                    e.deletedAt.isNull(),
              ))
              .write(
                ExpensesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
              );
      if (count == 0) throw StateError('Expense not found.');
      await _queue(id, businessId, 'ExpenseDeleted', now);
    });
  }

  Future<void> restore({required String businessId, required String id}) async {
    final now = DateTime.now().toUtc();
    final count =
        await (_db.update(_db.expenses)..where(
              (e) =>
                  e.id.equals(id) &
                  e.businessId.equals(businessId) &
                  e.deletedAt.isNotNull(),
            ))
            .write(
              ExpensesCompanion(
                deletedAt: const Value(null),
                updatedAt: Value(now),
              ),
            );
    if (count == 0) throw StateError('Deleted expense not found.');
    await _queue(id, businessId, 'ExpenseUpdated', now);
  }

  Future<void> _queue(
    String id,
    String businessId,
    String type,
    DateTime now,
  ) => _db
      .into(_db.syncOperations)
      .insert(
        SyncOperationsCompanion.insert(
          id: _uuid.v4(),
          businessId: Value(businessId),
          entityType: 'expense',
          entityId: id,
          operationType: type,
          payloadJson: jsonEncode({'expenseId': id}),
          createdAt: now,
        ),
      );
}
