import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class InventoryRepository {
  InventoryRepository(this._db);
  final AppDatabase _db;
  static const _uuid = Uuid();

  Stream<List<InventoryProduct>> watchProducts(String businessId) =>
      (_db.select(_db.inventoryProducts)
            ..where(
              (p) => p.businessId.equals(businessId) & p.deletedAt.isNull(),
            )
            ..orderBy([(p) => OrderingTerm.asc(p.name)]))
          .watch();

  Stream<List<InventoryMovement>> watchMovements(String productId) =>
      (_db.select(_db.inventoryMovements)
            ..where((m) => m.productId.equals(productId))
            ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
          .watch();

  Future<String> addProduct({
    required String businessId,
    required String name,
    String? sku,
    String unit = 'pcs',
    int openingStockMilliunits = 0,
    int lowStockThresholdMilliunits = 0,
    int unitCostPaise = 0,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Product name is required.');
    if (openingStockMilliunits < 0 ||
        lowStockThresholdMilliunits < 0 ||
        unitCostPaise < 0) {
      throw ArgumentError('Inventory values cannot be negative.');
    }
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    await _db.transaction(() async {
      await _db
          .into(_db.inventoryProducts)
          .insert(
            InventoryProductsCompanion.insert(
              id: id,
              businessId: businessId,
              name: name.trim(),
              sku: Value(sku?.trim().isEmpty ?? true ? null : sku!.trim()),
              unit: Value(unit.trim().isEmpty ? 'pcs' : unit.trim()),
              stockMilliunits: Value(openingStockMilliunits),
              lowStockThresholdMilliunits: Value(lowStockThresholdMilliunits),
              unitCostPaise: Value(unitCostPaise),
              createdAt: now,
              updatedAt: now,
            ),
          );
      if (openingStockMilliunits != 0) {
        await _movement(
          id,
          businessId,
          openingStockMilliunits,
          'Opening stock',
          now,
        );
      }
      await _queue(id, businessId, 'InventoryProductCreated', now);
    });
    return id;
  }

  Future<void> updateProduct({
    required String businessId,
    required String id,
    required String name,
    String? sku,
    required String unit,
    required int lowStockThresholdMilliunits,
    required int unitCostPaise,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Product name is required.');
    if (lowStockThresholdMilliunits < 0 || unitCostPaise < 0) {
      throw ArgumentError('Inventory values cannot be negative.');
    }
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final count =
          await (_db.update(_db.inventoryProducts)..where(
                (p) =>
                    p.id.equals(id) &
                    p.businessId.equals(businessId) &
                    p.deletedAt.isNull(),
              ))
              .write(
                InventoryProductsCompanion(
                  name: Value(name.trim()),
                  sku: Value(sku?.trim().isEmpty ?? true ? null : sku!.trim()),
                  unit: Value(unit.trim().isEmpty ? 'pcs' : unit.trim()),
                  lowStockThresholdMilliunits: Value(
                    lowStockThresholdMilliunits,
                  ),
                  unitCostPaise: Value(unitCostPaise),
                  updatedAt: Value(now),
                ),
              );
      if (count == 0) {
        throw StateError('Product not found.');
      }
      await _queue(id, businessId, 'InventoryProductUpdated', now);
    });
  }

  Future<void> adjustStock({
    required String businessId,
    required String productId,
    required int deltaMilliunits,
    required String reason,
  }) async {
    if (deltaMilliunits == 0) {
      throw ArgumentError('Stock adjustment cannot be zero.');
    }
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final product =
          await (_db.select(_db.inventoryProducts)..where(
                (p) =>
                    p.id.equals(productId) &
                    p.businessId.equals(businessId) &
                    p.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (product == null) throw StateError('Product not found.');
      final next = product.stockMilliunits + deltaMilliunits;
      if (next < 0) throw ArgumentError('Stock cannot become negative.');
      await (_db.update(
        _db.inventoryProducts,
      )..where((p) => p.id.equals(productId))).write(
        InventoryProductsCompanion(
          stockMilliunits: Value(next),
          updatedAt: Value(now),
        ),
      );
      await _movement(productId, businessId, deltaMilliunits, reason, now);
      await _queue(productId, businessId, 'InventoryAdjusted', now);
    });
  }

  Future<void> deleteProduct({
    required String businessId,
    required String id,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      final count =
          await (_db.update(_db.inventoryProducts)..where(
                (p) =>
                    p.id.equals(id) &
                    p.businessId.equals(businessId) &
                    p.deletedAt.isNull(),
              ))
              .write(
                InventoryProductsCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (count == 0) throw StateError('Product not found.');
      await _queue(id, businessId, 'InventoryProductDeleted', now);
    });
  }

  Future<void> restoreProduct({
    required String businessId,
    required String id,
  }) async {
    final now = DateTime.now().toUtc();
    final count =
        await (_db.update(_db.inventoryProducts)..where(
              (p) =>
                  p.id.equals(id) &
                  p.businessId.equals(businessId) &
                  p.deletedAt.isNotNull(),
            ))
            .write(
              InventoryProductsCompanion(
                deletedAt: const Value(null),
                updatedAt: Value(now),
              ),
            );
    if (count == 0) throw StateError('Deleted product not found.');
    await _queue(id, businessId, 'InventoryProductUpdated', now);
  }

  Future<void> _movement(
    String productId,
    String businessId,
    int delta,
    String reason,
    DateTime now,
  ) => _db
      .into(_db.inventoryMovements)
      .insert(
        InventoryMovementsCompanion.insert(
          id: _uuid.v4(),
          businessId: businessId,
          productId: productId,
          deltaMilliunits: delta,
          reason: reason.trim().isEmpty ? 'Adjustment' : reason.trim(),
          createdAt: now,
        ),
      );

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
          entityType: 'inventory',
          entityId: id,
          operationType: type,
          payloadJson: jsonEncode({'productId': id}),
          createdAt: now,
        ),
      );
}
