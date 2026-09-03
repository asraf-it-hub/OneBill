import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class CustomerRepository {
  CustomerRepository(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  Stream<List<Customer>> watchCustomers(String businessId) =>
      (_database.select(_database.customers)
            ..where(
              (c) => c.businessId.equals(businessId) & c.deletedAt.isNull(),
            )
            ..orderBy([(c) => OrderingTerm.asc(c.name)]))
          .watch();

  Future<String> create({
    required String businessId,
    required String name,
    required String phone,
    String? email,
    String? notes,
  }) async {
    final normalizedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (!RegExp(r'^[6-9][0-9]{9}$').hasMatch(normalizedPhone)) {
      throw ArgumentError('Enter a valid 10-digit Indian mobile number.');
    }
    final existing =
        await (_database.select(_database.customers)..where(
              (c) =>
                  c.businessId.equals(businessId) &
                  c.phone.equals(normalizedPhone) &
                  c.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (existing != null) {
      throw StateError(
        'A customer with this mobile number already exists in this business.',
      );
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _database.transaction(() async {
      await _database
          .into(_database.customers)
          .insert(
            CustomersCompanion.insert(
              id: id,
              businessId: businessId,
              name: name.trim(),
              phone: normalizedPhone,
              email: Value(
                email?.trim().isEmpty ?? true ? null : email!.trim(),
              ),
              notes: Value(
                notes?.trim().isEmpty ?? true ? null : notes!.trim(),
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'customer',
              entityId: id,
              operationType: 'CustomerCreated',
              payloadJson: jsonEncode({'customerId': id}),
              createdAt: now,
            ),
          );
    });
    return id;
  }

  Future<void> update({
    required String businessId,
    required String customerId,
    required String name,
    required String phone,
    String? email,
    String? notes,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Customer name is required.');
    }
    final normalizedPhone = _normalizedPhone(phone);
    final customer =
        await (_database.select(_database.customers)..where(
              (entry) =>
                  entry.id.equals(customerId) &
                  entry.businessId.equals(businessId) &
                  entry.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (customer == null) {
      throw StateError('Customer not found in the active business.');
    }
    final existing =
        await (_database.select(_database.customers)..where(
              (entry) =>
                  entry.businessId.equals(businessId) &
                  entry.phone.equals(normalizedPhone) &
                  entry.deletedAt.isNull() &
                  entry.id.equals(customerId).not(),
            ))
            .getSingleOrNull();
    if (existing != null) {
      throw StateError(
        'A customer with this mobile number already exists in this business.',
      );
    }
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      await (_database.update(
        _database.customers,
      )..where((entry) => entry.id.equals(customerId))).write(
        CustomersCompanion(
          name: Value(name.trim()),
          phone: Value(normalizedPhone),
          email: Value(_blankToNull(email)),
          notes: Value(_blankToNull(notes)),
          updatedAt: Value(now),
        ),
      );
      await _enqueue(
        businessId: businessId,
        customerId: customerId,
        operationType: 'CustomerUpdated',
        now: now,
      );
    });
  }

  Future<void> archive({
    required String businessId,
    required String customerId,
  }) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.customers)..where(
                (entry) =>
                    entry.id.equals(customerId) &
                    entry.businessId.equals(businessId) &
                    entry.deletedAt.isNull(),
              ))
              .write(
                CustomersCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (changed != 1) {
        throw StateError('Customer not found in the active business.');
      }
      await _enqueue(
        businessId: businessId,
        customerId: customerId,
        operationType: 'CustomerArchived',
        now: now,
      );
    });
  }

  Future<void> restore({
    required String businessId,
    required String customerId,
  }) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.customers)..where(
                (entry) =>
                    entry.id.equals(customerId) &
                    entry.businessId.equals(businessId) &
                    entry.deletedAt.isNotNull(),
              ))
              .write(
                CustomersCompanion(
                  deletedAt: const Value(null),
                  updatedAt: Value(now),
                ),
              );
      if (changed != 1) {
        throw StateError('Deleted customer not found.');
      }
      await _enqueue(
        businessId: businessId,
        customerId: customerId,
        operationType: 'CustomerUpdated',
        now: now,
      );
    });
  }

  String _normalizedPhone(String phone) {
    final normalizedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (!RegExp(r'^[6-9][0-9]{9}$').hasMatch(normalizedPhone)) {
      throw ArgumentError('Enter a valid 10-digit Indian mobile number.');
    }
    return normalizedPhone;
  }

  String? _blankToNull(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  Future<void> _enqueue({
    required String businessId,
    required String customerId,
    required String operationType,
    required DateTime now,
  }) => _database
      .into(_database.syncOperations)
      .insert(
        SyncOperationsCompanion.insert(
          id: _uuid.v4(),
          businessId: Value(businessId),
          entityType: 'customer',
          entityId: customerId,
          operationType: operationType,
          payloadJson: jsonEncode({'customerId': customerId}),
          createdAt: now,
        ),
      );
}
