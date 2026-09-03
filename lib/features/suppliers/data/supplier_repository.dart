import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class SupplierRepository {
  SupplierRepository(this._db);
  final AppDatabase _db;
  static const _uuid = Uuid();

  Stream<List<Supplier>> watch(String businessId) =>
      (_db.select(_db.suppliers)
            ..where(
              (s) => s.businessId.equals(businessId) & s.deletedAt.isNull(),
            )
            ..orderBy([(s) => OrderingTerm.asc(s.name)]))
          .watch();

  Stream<List<SupplierPayment>> watchPayments(String supplierId) =>
      (_db.select(_db.supplierPayments)
            ..where(
              (p) => p.supplierId.equals(supplierId) & p.deletedAt.isNull(),
            )
            ..orderBy([(p) => OrderingTerm.desc(p.paidAt)]))
          .watch();

  Future<String> add({
    required String businessId,
    required String name,
    required String phone,
    String? email,
    String? address,
    String? notes,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Supplier name is required.');
    if (phone.trim().isEmpty) {
      throw ArgumentError('Supplier phone is required.');
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.transaction(() async {
      await _db
          .into(_db.suppliers)
          .insert(
            SuppliersCompanion.insert(
              id: id,
              businessId: businessId,
              name: name.trim(),
              phone: phone.trim(),
              email: Value(
                email?.trim().isEmpty ?? true ? null : email!.trim(),
              ),
              address: Value(
                address?.trim().isEmpty ?? true ? null : address!.trim(),
              ),
              notes: Value(
                notes?.trim().isEmpty ?? true ? null : notes!.trim(),
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _queue(id, businessId, 'SupplierCreated', now);
    });
    return id;
  }

  Future<void> update({
    required String businessId,
    required String id,
    required String name,
    required String phone,
    String? email,
    String? address,
    String? notes,
  }) async {
    if (name.trim().isEmpty || phone.trim().isEmpty) {
      throw ArgumentError('Supplier name and phone are required.');
    }
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final count =
          await (_db.update(_db.suppliers)..where(
                (s) =>
                    s.id.equals(id) &
                    s.businessId.equals(businessId) &
                    s.deletedAt.isNull(),
              ))
              .write(
                SuppliersCompanion(
                  name: Value(name.trim()),
                  phone: Value(phone.trim()),
                  email: Value(
                    email?.trim().isEmpty ?? true ? null : email!.trim(),
                  ),
                  address: Value(
                    address?.trim().isEmpty ?? true ? null : address!.trim(),
                  ),
                  notes: Value(
                    notes?.trim().isEmpty ?? true ? null : notes!.trim(),
                  ),
                  updatedAt: Value(now),
                ),
              );
      if (count == 0) {
        throw StateError('Supplier not found.');
      }
      await _queue(id, businessId, 'SupplierUpdated', now);
    });
  }

  Future<void> delete({required String businessId, required String id}) async {
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final count =
          await (_db.update(_db.suppliers)..where(
                (s) =>
                    s.id.equals(id) &
                    s.businessId.equals(businessId) &
                    s.deletedAt.isNull(),
              ))
              .write(
                SuppliersCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (count == 0) {
        throw StateError('Supplier not found.');
      }
      await _queue(id, businessId, 'SupplierDeleted', now);
    });
  }

  Future<void> restore({required String businessId, required String id}) async {
    final now = DateTime.now().toUtc();
    final count =
        await (_db.update(_db.suppliers)..where(
              (s) =>
                  s.id.equals(id) &
                  s.businessId.equals(businessId) &
                  s.deletedAt.isNotNull(),
            ))
            .write(
              SuppliersCompanion(
                deletedAt: const Value(null),
                updatedAt: Value(now),
              ),
            );
    if (count == 0) throw StateError('Deleted supplier not found.');
    await _queue(id, businessId, 'SupplierUpdated', now);
  }

  Future<void> recordPayment({
    required String businessId,
    required String supplierId,
    required int amountPaise,
    required DateTime paidAt,
    String? note,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError('Payment must be greater than zero.');
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.transaction(() async {
      final supplier =
          await (_db.select(_db.suppliers)..where(
                (s) =>
                    s.id.equals(supplierId) &
                    s.businessId.equals(businessId) &
                    s.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (supplier == null) {
        throw StateError('Supplier not found.');
      }
      await _db
          .into(_db.supplierPayments)
          .insert(
            SupplierPaymentsCompanion.insert(
              id: id,
              businessId: businessId,
              supplierId: supplierId,
              amountPaise: amountPaise,
              paidAt: paidAt.toUtc(),
              note: Value(note),
              createdAt: now,
            ),
          );
      await _queue(id, businessId, 'SupplierPaymentRecorded', now);
    });
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
          entityType: 'supplier',
          entityId: id,
          operationType: type,
          payloadJson: jsonEncode({'entityId': id}),
          createdAt: now,
        ),
      );
}
