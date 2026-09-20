import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class PaperReceiptRepository {
  PaperReceiptRepository(
    this._database, {
    Future<Directory> Function()? baseDirectoryProvider,
  }) : _baseDirectoryProvider =
            baseDirectoryProvider ?? getApplicationDocumentsDirectory;

  final AppDatabase _database;
  final Future<Directory> Function() _baseDirectoryProvider;
  static const _uuid = Uuid();

  Stream<List<PaperReceipt>> watchReceiptsForCustomer({
    required String businessId,
    required String customerId,
  }) =>
      (_database.select(_database.paperReceipts)
            ..where(
              (r) =>
                  r.businessId.equals(businessId) &
                  r.customerId.equals(customerId) &
                  r.deletedAt.isNull(),
            )
            ..orderBy([(r) => OrderingTerm.desc(r.receiptDate)]))
          .watch();

  Stream<int> watchReceiptCountForCustomer({
    required String businessId,
    required String customerId,
  }) =>
      watchReceiptsForCustomer(
        businessId: businessId,
        customerId: customerId,
      ).map((list) => list.length);

  Future<PaperReceipt> createReceipt({
    required String businessId,
    required String customerId,
    required String sourceImagePath,
    DateTime? receiptDate,
    String? notes,
  }) async {
    final receiptId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final effectiveDate = (receiptDate ?? DateTime.now()).toUtc();

    // 1. Copy image into persistent app directory
    final appDir = await _baseDirectoryProvider();
    final receiptsDir = Directory('${appDir.path}/receipts');
    if (!await receiptsDir.exists()) {
      await receiptsDir.create(recursive: true);
    }
    final destFile = File('${receiptsDir.path}/$receiptId.jpg');
    final sourceFile = File(sourceImagePath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(destFile.path);
    } else {
      throw StateError('Source image file does not exist: $sourceImagePath');
    }

    final entry = PaperReceiptsCompanion.insert(
      id: receiptId,
      businessId: businessId,
      customerId: customerId,
      imagePath: destFile.path,
      notes: Value(notes?.trim().isEmpty == true ? null : notes?.trim()),
      receiptDate: effectiveDate,
      createdAt: now,
      updatedAt: now,
    );

    await _database.into(_database.paperReceipts).insert(entry);

    // 2. Enqueue offline sync operation
    await _database.into(_database.syncOperations).insert(
      SyncOperationsCompanion.insert(
        id: _uuid.v4(),
        businessId: Value(businessId),
        entityType: 'PaperReceipt',
        entityId: receiptId,
        operationType: 'PaperReceiptCreated',
        payloadJson: jsonEncode({
          'id': receiptId,
          'businessId': businessId,
          'customerId': customerId,
          'receiptDate': effectiveDate.toIso8601String(),
          'notes': notes?.trim(),
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        }),
        createdAt: now,
      ),
    );

    return (_database.select(_database.paperReceipts)
          ..where((r) => r.id.equals(receiptId)))
        .getSingle();
  }

  Future<void> deleteReceipt({
    required String businessId,
    required String receiptId,
  }) async {
    final now = DateTime.now().toUtc();
    final receipt = await (_database.select(_database.paperReceipts)
          ..where((r) => r.id.equals(receiptId) & r.businessId.equals(businessId)))
        .getSingleOrNull();

    if (receipt == null) return;

    // Soft delete locally
    await (_database.update(_database.paperReceipts)
          ..where((r) => r.id.equals(receiptId)))
        .write(PaperReceiptsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ));

    // Enqueue sync operation
    await _database.into(_database.syncOperations).insert(
      SyncOperationsCompanion.insert(
        id: _uuid.v4(),
        businessId: Value(businessId),
        entityType: 'PaperReceipt',
        entityId: receiptId,
        operationType: 'PaperReceiptDeleted',
        payloadJson: jsonEncode({
          'id': receiptId,
          'businessId': businessId,
          'deletedAt': now.toIso8601String(),
        }),
        createdAt: now,
      ),
    );

    // Optional: remove local image file
    try {
      final file = File(receipt.imagePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
