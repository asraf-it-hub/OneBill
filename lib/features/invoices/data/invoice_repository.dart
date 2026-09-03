import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class InvoiceRepository {
  InvoiceRepository(this._database);
  final AppDatabase _database;
  static const _uuid = Uuid();

  int total(Invoice invoice) =>
      invoice.subtotalPaise - invoice.discountPaise + invoice.interestPaise;
  int balance(Invoice invoice) => total(invoice) - invoice.paidPaise;

  InvoicePaymentStatus status(Invoice invoice, {DateTime? now}) {
    if (balance(invoice) == 0) return InvoicePaymentStatus.paid;
    final today = (now ?? DateTime.now()).toLocal();
    final dueAt = invoice.dueAt?.toLocal();
    if (dueAt != null &&
        DateTime(
          dueAt.year,
          dueAt.month,
          dueAt.day,
        ).isBefore(DateTime(today.year, today.month, today.day))) {
      return InvoicePaymentStatus.overdue;
    }
    return invoice.paidPaise > 0
        ? InvoicePaymentStatus.partiallyPaid
        : InvoicePaymentStatus.unpaid;
  }

  Stream<List<Invoice>> watchInvoicesForCustomer({
    required String businessId,
    required String customerId,
  }) =>
      (_database.select(_database.invoices)
            ..where(
              (invoice) =>
                  invoice.businessId.equals(businessId) &
                  invoice.customerId.equals(customerId) &
                  invoice.deletedAt.isNull(),
            )
            ..orderBy([(invoice) => OrderingTerm.desc(invoice.issuedAt)]))
          .watch();

  Stream<BillingSummary> watchBusinessSummary(String businessId) =>
      (_database.select(_database.invoices)..where(
            (invoice) =>
                invoice.businessId.equals(businessId) &
                invoice.deletedAt.isNull(),
          ))
          .watch()
          .map(BillingSummary.fromInvoices);

  Stream<Invoice?> watchInvoice({
    required String businessId,
    required String invoiceId,
  }) =>
      (_database.select(_database.invoices)..where(
            (i) => i.id.equals(invoiceId) & i.businessId.equals(businessId),
          ))
          .watchSingleOrNull();

  Stream<int> watchOutstandingForCustomer({
    required String businessId,
    required String customerId,
  }) => watchInvoicesForCustomer(businessId: businessId, customerId: customerId)
      .map(
        (invoices) =>
            invoices.fold<int>(0, (sum, invoice) => sum + balance(invoice)),
      );

  Stream<List<Payment>> watchPayments({
    required String businessId,
    required String invoiceId,
  }) =>
      (_database.select(_database.payments)
            ..where(
              (payment) =>
                  payment.businessId.equals(businessId) &
                  payment.invoiceId.equals(invoiceId) &
                  payment.deletedAt.isNull(),
            )
            ..orderBy([(payment) => OrderingTerm.desc(payment.receivedAt)]))
          .watch();

  Stream<List<Payment>> watchAllPayments(String businessId) =>
      (_database.select(_database.payments)
            ..where((p) => p.businessId.equals(businessId) & p.deletedAt.isNull())
            ..orderBy([(p) => OrderingTerm.desc(p.receivedAt)]))
          .watch();

  Stream<List<InvoiceItem>> watchInvoiceItems(String invoiceId) =>
      (_database.select(_database.invoiceItems)
            ..where((item) => item.invoiceId.equals(invoiceId))
            ..orderBy([(item) => OrderingTerm.asc(item.sortOrder)]))
          .watch();

  Future<String> createInvoice({
    required String businessId,
    required String customerId,
    required List<InvoiceLineInput> items,
    int discountPaise = 0,
    int interestPaise = 0,
    DateTime? dueAt,
    String? notes,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('Add at least one invoice item.');
    }
    if (discountPaise < 0 || interestPaise < 0) {
      throw ArgumentError('Discount and interest cannot be negative.');
    }
    final now = DateTime.now().toUtc();
    final customer =
        await (_database.select(_database.customers)..where(
              (customer) =>
                  customer.id.equals(customerId) &
                  customer.businessId.equals(businessId) &
                  customer.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (customer == null) {
      throw StateError('Customer not found in the active business.');
    }
    final subtotal = items.fold<int>(
      0,
      (sum, item) => sum + item.lineTotalPaise,
    );
    if (discountPaise > subtotal + interestPaise) {
      throw ArgumentError('Discount cannot make an invoice total negative.');
    }
    final invoiceId = _uuid.v4();
    final invoiceNumber =
        'OB-${now.millisecondsSinceEpoch}-${invoiceId.substring(0, 8).toUpperCase()}';
    await _database.transaction(() async {
      await _database
          .into(_database.invoices)
          .insert(
            InvoicesCompanion.insert(
              id: invoiceId,
              businessId: businessId,
              customerId: customerId,
              invoiceNumber: invoiceNumber,
              issuedAt: now,
              dueAt: Value(dueAt?.toUtc()),
              subtotalPaise: subtotal,
              discountPaise: Value(discountPaise),
              interestPaise: Value(interestPaise),
              notes: Value(
                notes?.trim().isEmpty ?? true ? null : notes!.trim(),
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        await _database
            .into(_database.invoiceItems)
            .insert(
              InvoiceItemsCompanion.insert(
                id: _uuid.v4(),
                invoiceId: invoiceId,
                description: item.description.trim(),
                quantityMilliunits: item.quantityMilliunits,
                unitPricePaise: item.unitPricePaise,
                lineTotalPaise: item.lineTotalPaise,
                sortOrder: index,
              ),
            );
      }
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'invoice',
              entityId: invoiceId,
              operationType: 'InvoiceCreated',
              payloadJson: jsonEncode({'invoiceId': invoiceId}),
              createdAt: now,
            ),
          );
    });
    return invoiceId;
  }

  Future<void> recordPayment({
    required String businessId,
    required String invoiceId,
    required int amountPaise,
    required String method,
    String? note,
  }) async {
    if (amountPaise <= 0) {
      throw ArgumentError.value(
        amountPaise,
        'amountPaise',
        'Payment amount must be positive.',
      );
    }
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final invoice =
          await (_database.select(_database.invoices)..where(
                (i) =>
                    i.id.equals(invoiceId) &
                    i.businessId.equals(businessId) &
                    i.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (invoice == null) {
        throw StateError('Invoice not found in the active business.');
      }
      final remaining = balance(invoice);
      if (amountPaise > remaining) {
        throw ArgumentError('Payment cannot exceed the outstanding balance.');
      }
      final paymentId = _uuid.v4();
      await _database
          .into(_database.payments)
          .insert(
            PaymentsCompanion.insert(
              id: paymentId,
              businessId: businessId,
              invoiceId: invoiceId,
              amountPaise: amountPaise,
              method: method,
              note: Value(note),
              receivedAt: now,
              createdAt: now,
            ),
          );
      await (_database.update(
        _database.invoices,
      )..where((i) => i.id.equals(invoiceId))).write(
        InvoicesCompanion(
          paidPaise: Value(invoice.paidPaise + amountPaise),
          updatedAt: Value(now),
        ),
      );
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'payment',
              entityId: paymentId,
              operationType: 'PaymentRecorded',
              payloadJson: jsonEncode({
                'paymentId': paymentId,
                'invoiceId': invoiceId,
              }),
              createdAt: now,
            ),
          );
    });
  }

  Future<void> reversePayment({
    required String businessId,
    required String paymentId,
  }) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final payment =
          await (_database.select(_database.payments)..where(
                (p) =>
                    p.id.equals(paymentId) &
                    p.businessId.equals(businessId) &
                    p.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (payment == null) {
        throw StateError('Payment not found or already reversed.');
      }
      final invoice =
          await (_database.select(_database.invoices)..where(
                (i) =>
                    i.id.equals(payment.invoiceId) &
                    i.businessId.equals(businessId),
              ))
              .getSingle();
      await (_database.update(_database.payments)
            ..where((p) => p.id.equals(paymentId)))
          .write(PaymentsCompanion(deletedAt: Value(now)));
      await (_database.update(
        _database.invoices,
      )..where((i) => i.id.equals(invoice.id))).write(
        InvoicesCompanion(
          paidPaise: Value(invoice.paidPaise - payment.amountPaise),
          updatedAt: Value(now),
        ),
      );
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'payment',
              entityId: paymentId,
              operationType: 'PaymentReversed',
              payloadJson: jsonEncode({
                'paymentId': paymentId,
                'invoiceId': payment.invoiceId,
                'amountPaise': payment.amountPaise,
                'reversedAt': now.toIso8601String(),
              }),
              createdAt: now,
            ),
          );
    });
  }

  Future<void> voidInvoice({
    required String businessId,
    required String invoiceId,
  }) async {
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final invoice =
          await (_database.select(_database.invoices)..where(
                (entry) =>
                    entry.id.equals(invoiceId) &
                    entry.businessId.equals(businessId) &
                    entry.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (invoice == null) {
        throw StateError('Invoice not found in the active business.');
      }
      if (invoice.paidPaise > 0) {
        throw StateError('An invoice with payments cannot be voided.');
      }
      await (_database.update(
        _database.invoices,
      )..where((entry) => entry.id.equals(invoiceId))).write(
        InvoicesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'invoice',
              entityId: invoiceId,
              operationType: 'InvoiceVoided',
              payloadJson: jsonEncode({'invoiceId': invoiceId}),
              createdAt: now,
            ),
          );
    });
  }

  Future<void> updateInvoiceDetails({
    required String businessId,
    required String invoiceId,
    required int discountPaise,
    required int interestPaise,
    required DateTime? dueAt,
    required String? notes,
    List<InvoiceLineInput>? items,
  }) async {
    if (discountPaise < 0 || interestPaise < 0) {
      throw ArgumentError('Discount and interest cannot be negative.');
    }
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      final invoice =
          await (_database.select(_database.invoices)..where(
                (i) => i.id.equals(invoiceId) & i.businessId.equals(businessId),
              ))
              .getSingleOrNull();
      if (invoice == null) throw StateError('Invoice not found.');
      if (invoice.paidPaise > 0) {
        throw StateError('Paid invoices cannot be edited.');
      }
      final subtotal =
          items?.fold<int>(0, (sum, item) => sum + item.lineTotalPaise) ??
          invoice.subtotalPaise;
      if (discountPaise > subtotal + interestPaise) {
        throw ArgumentError('Discount cannot make the invoice negative.');
      }
      await (_database.update(
        _database.invoices,
      )..where((i) => i.id.equals(invoiceId))).write(
        InvoicesCompanion(
          subtotalPaise: items == null ? const Value.absent() : Value(subtotal),
          discountPaise: Value(discountPaise),
          interestPaise: Value(interestPaise),
          dueAt: Value(dueAt?.toUtc()),
          notes: Value(notes?.trim().isEmpty ?? true ? null : notes!.trim()),
          updatedAt: Value(now),
        ),
      );
      if (items != null) {
        await (_database.delete(
          _database.invoiceItems,
        )..where((i) => i.invoiceId.equals(invoiceId))).go();
        for (var index = 0; index < items.length; index++) {
          final item = items[index];
          await _database
              .into(_database.invoiceItems)
              .insert(
                InvoiceItemsCompanion.insert(
                  id: _uuid.v4(),
                  invoiceId: invoiceId,
                  description: item.description.trim(),
                  quantityMilliunits: item.quantityMilliunits,
                  unitPricePaise: item.unitPricePaise,
                  lineTotalPaise: item.lineTotalPaise,
                  sortOrder: index,
                ),
              );
        }
      }
      await _database
          .into(_database.syncOperations)
          .insert(
            SyncOperationsCompanion.insert(
              id: _uuid.v4(),
              businessId: Value(businessId),
              entityType: 'invoice',
              entityId: invoiceId,
              operationType: 'InvoiceUpdated',
              payloadJson: jsonEncode({'invoiceId': invoiceId}),
              createdAt: now,
            ),
          );
    });
  }
}

class BillingSummary {
  const BillingSummary({
    required this.invoiceCount,
    required this.totalBilledPaise,
    required this.totalReceivedPaise,
    required this.totalOutstandingPaise,
    required this.overduePaise,
    required this.overdueInvoiceCount,
  });

  factory BillingSummary.fromInvoices(List<Invoice> invoices) {
    var billed = 0;
    var received = 0;
    var overdue = 0;
    var overdueCount = 0;
    final today = DateTime.now();
    for (final invoice in invoices) {
      billed +=
          invoice.subtotalPaise - invoice.discountPaise + invoice.interestPaise;
      received += invoice.paidPaise;
      final balance =
          invoice.subtotalPaise -
          invoice.discountPaise +
          invoice.interestPaise -
          invoice.paidPaise;
      final dueAt = invoice.dueAt?.toLocal();
      if (balance > 0 &&
          dueAt != null &&
          DateTime(
            dueAt.year,
            dueAt.month,
            dueAt.day,
          ).isBefore(DateTime(today.year, today.month, today.day))) {
        overdue += balance;
        overdueCount++;
      }
    }
    return BillingSummary(
      invoiceCount: invoices.length,
      totalBilledPaise: billed,
      totalReceivedPaise: received,
      totalOutstandingPaise: billed - received,
      overduePaise: overdue,
      overdueInvoiceCount: overdueCount,
    );
  }

  final int invoiceCount;
  final int totalBilledPaise;
  final int totalReceivedPaise;
  final int totalOutstandingPaise;
  final int overduePaise;
  final int overdueInvoiceCount;
}

enum InvoicePaymentStatus { unpaid, partiallyPaid, paid, overdue }

class InvoiceLineInput {
  const InvoiceLineInput({
    required this.description,
    required this.quantityMilliunits,
    required this.unitPricePaise,
  });
  final String description;
  final int quantityMilliunits;
  final int unitPricePaise;
  int get lineTotalPaise {
    if (description.trim().isEmpty ||
        quantityMilliunits <= 0 ||
        unitPricePaise < 0) {
      throw ArgumentError(
        'Invoice items must have a description, quantity, and valid price.',
      );
    }
    return (quantityMilliunits * unitPricePaise) ~/ 1000;
  }
}
