import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_environment.dart';
import 'database/app_database.dart';
import '../features/businesses/data/business_repository.dart';
import '../features/customers/data/customer_repository.dart';
import '../features/invoices/data/invoice_repository.dart';
import '../features/auth/data/supabase_auth_service.dart';
import '../features/invoices/services/pdf_invoice_service.dart';
import '../features/sync/data/sync_worker.dart';
import '../features/income/data/income_repository.dart';
import '../features/expenses/data/expense_repository.dart';
import '../features/inventory/data/inventory_repository.dart';
import '../features/suppliers/data/supplier_repository.dart';
import '../features/security/data/security_service.dart';
import '../features/backup/data/backup_service.dart';
import '../features/notifications/data/notification_repository.dart';
import '../features/notifications/data/notification_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final businessRepositoryProvider = Provider<BusinessRepository>(
  (ref) => BusinessRepository(ref.watch(databaseProvider)),
);
final customerRepositoryProvider = Provider<CustomerRepository>(
  (ref) => CustomerRepository(ref.watch(databaseProvider)),
);
final invoiceRepositoryProvider = Provider<InvoiceRepository>(
  (ref) => InvoiceRepository(ref.watch(databaseProvider)),
);
final incomeRepositoryProvider = Provider<IncomeRepository>(
  (ref) => IncomeRepository(ref.watch(databaseProvider)),
);
final incomeEntriesProvider = StreamProvider.family<List<IncomeEntry>, String>(
  (ref, businessId) => ref.watch(incomeRepositoryProvider).watch(businessId),
);
final expenseRepositoryProvider = Provider<ExpenseRepository>(
  (ref) => ExpenseRepository(ref.watch(databaseProvider)),
);
final expensesProvider = StreamProvider.family<List<Expense>, String>(
  (ref, businessId) => ref.watch(expenseRepositoryProvider).watch(businessId),
);
final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepository(ref.watch(databaseProvider)),
);
final inventoryProductsProvider =
    StreamProvider.family<List<InventoryProduct>, String>(
      (ref, businessId) =>
          ref.watch(inventoryRepositoryProvider).watchProducts(businessId),
    );
final supplierRepositoryProvider = Provider<SupplierRepository>(
  (ref) => SupplierRepository(ref.watch(databaseProvider)),
);
final suppliersProvider = StreamProvider.family<List<Supplier>, String>(
  (ref, businessId) => ref.watch(supplierRepositoryProvider).watch(businessId),
);
final securityServiceProvider = Provider<SecurityService>(
  (ref) => const SecurityService(),
);
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(databaseProvider)),
);

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(databaseProvider)),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(
    ref.watch(databaseProvider),
    ref.watch(notificationRepositoryProvider),
  ),
);

final unreadNotificationCountProvider =
    StreamProvider.family<int, String?>(
  (ref, businessId) => ref
      .watch(notificationRepositoryProvider)
      .watchUnreadCount(businessId: businessId),
);

final notificationListProvider =
    StreamProvider.family<List<AppNotification>, String?>(
  (ref, businessId) => ref
      .watch(notificationRepositoryProvider)
      .watchNotifications(businessId: businessId),
);

final notificationPreferencesProvider = StreamProvider<Map<String, bool>>(
  (ref) => ref.watch(notificationRepositoryProvider).watchPreferences(),
);

final notificationSettingsProvider = StreamProvider<NotificationSetting?>(
  (ref) => ref.watch(notificationRepositoryProvider).watchSettings(),
);

final syncWorkerProvider = Provider<SyncWorker>((ref) {
  final worker = SyncWorker(ref.watch(databaseProvider), Supabase.instance.client);
  worker.listenToPendingOperations();
  ref.onDispose(worker.dispose);
  return worker;
});

final isSigningOutProvider = StateProvider<bool>((ref) => false);

final authServiceProvider = Provider<SupabaseAuthService>(
  (ref) => SupabaseAuthService(),
);

final pdfInvoiceServiceProvider = Provider<PdfInvoiceService>(
  (ref) => PdfInvoiceService(),
);

final authSessionProvider = StreamProvider<Session?>((ref) {
  if (!AppEnvironment.cloudConfigured) {
    return Stream.value(null);
  }
  return ref
      .watch(authServiceProvider)
      .authStateChanges
      .map((state) => state.session);
});

final sessionProvider = StreamProvider<LocalSession?>(
  (ref) => ref.watch(businessRepositoryProvider).watchSession(),
);

final businessesProvider = StreamProvider.family<List<BusinessesData>, String>(
  (ref, accountId) =>
      ref.watch(businessRepositoryProvider).watchBusinesses(accountId),
);

final customersProvider = StreamProvider.family<List<Customer>, String>(
  (ref, businessId) =>
      ref.watch(customerRepositoryProvider).watchCustomers(businessId),
);

final customerInvoicesProvider =
    StreamProvider.family<
      List<Invoice>,
      ({String businessId, String customerId})
    >(
      (ref, ids) => ref
          .watch(invoiceRepositoryProvider)
          .watchInvoicesForCustomer(
            businessId: ids.businessId,
            customerId: ids.customerId,
          ),
    );

final customerOutstandingProvider =
    StreamProvider.family<int, ({String businessId, String customerId})>(
      (ref, ids) => ref
          .watch(invoiceRepositoryProvider)
          .watchOutstandingForCustomer(
            businessId: ids.businessId,
            customerId: ids.customerId,
          ),
    );

final businessBillingSummaryProvider =
    StreamProvider.family<BillingSummary, String>(
      (ref, businessId) =>
          ref.watch(invoiceRepositoryProvider).watchBusinessSummary(businessId),
    );

final syncQueueStatusProvider = StreamProvider.family<SyncQueueStatus, String>(
  (ref, businessId) =>
      (ref
              .watch(databaseProvider)
              .select(ref.watch(databaseProvider).syncOperations)
            ..where((operation) => operation.businessId.equals(businessId)))
          .watch()
          .map(
            (operations) => SyncQueueStatus(
              pending: operations
                  .where((operation) => operation.status == 'pending')
                  .length,
              failed: operations
                  .where((operation) => operation.status.startsWith('failed'))
                  .length,
            ),
          ),
);

final syncOperationsProvider =
    StreamProvider.family<List<SyncOperation>, String>(
      (ref, businessId) =>
          (ref
                  .watch(databaseProvider)
                  .select(ref.watch(databaseProvider).syncOperations)
                ..where((operation) => operation.businessId.equals(businessId)))
              .watch(),
    );

class SyncQueueStatus {
  const SyncQueueStatus({required this.pending, required this.failed});
  final int pending;
  final int failed;
}

final invoicePaymentsProvider =
    StreamProvider.family<
      List<Payment>,
      ({String businessId, String invoiceId})
    >(
      (ref, ids) => ref
          .watch(invoiceRepositoryProvider)
          .watchPayments(businessId: ids.businessId, invoiceId: ids.invoiceId),
    );

final invoiceProvider =
    StreamProvider.family<Invoice?, ({String businessId, String invoiceId})>(
      (ref, ids) => ref
          .watch(invoiceRepositoryProvider)
          .watchInvoice(businessId: ids.businessId, invoiceId: ids.invoiceId),
    );

final invoiceItemsProvider = StreamProvider.family<List<InvoiceItem>, String>(
  (ref, invoiceId) =>
      ref.watch(invoiceRepositoryProvider).watchInvoiceItems(invoiceId),
);
final businessPaymentsProvider = StreamProvider.family<List<Payment>, String>(
  (ref, businessId) =>
      ref.watch(invoiceRepositoryProvider).watchAllPayments(businessId),
);
