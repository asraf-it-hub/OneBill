import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:drift/drift.dart' show Value;
import '../../../core/database/app_database.dart';
import 'notification_constants.dart';
import 'notification_repository.dart';

class NotificationService {
  final AppDatabase _db;
  final NotificationRepository _repository;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  void Function(String payloadJson)? onNotificationSelect;

  NotificationService(this._db, this._repository);

  Future<void> init({void Function(String payload)? onSelect}) async {
    if (_initialized) return;
    onNotificationSelect = onSelect;
    tz.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        final actionId = response.actionId;
        if (actionId == NotificationActionKeys.remindLater && payload != null) {
          try {
            final data = jsonDecode(payload) as Map<String, dynamic>;
            final invoiceId = data['invoiceId'] as String?;
            if (invoiceId != null) {
              snoozeInvoiceReminder(invoiceId);
            }
          } catch (_) {}
        }
        if (payload != null && onNotificationSelect != null) {
          onNotificationSelect!(payload);
        }
      },
    );

    await _createNotificationChannels();
    _initialized = true;
  }

  Future<void> _createNotificationChannels() async {
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return;

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        NotificationChannels.reminders,
        'Payment & Invoice Reminders',
        description: 'Scheduled reminders for due and overdue invoices',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        NotificationChannels.payments,
        'Payment Activity',
        description: 'Notifications when payments are recorded',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        NotificationChannels.summaries,
        'Business Summaries',
        description: 'Daily, weekly, and monthly performance summaries',
        importance: Importance.defaultImportance,
      ),
    );

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        NotificationChannels.sync,
        'Sync & Backup',
        description: 'Notifications for cloud sync operations and status',
        importance: Importance.defaultImportance,
      ),
    );

    await androidImpl.createNotificationChannel(
      const AndroidNotificationChannel(
        NotificationChannels.alerts,
        'Important OneBill Alerts',
        description: 'Critical system and business security alerts',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  Future<bool> checkPermission() async {
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await androidImpl?.areNotificationsEnabled() ?? false;
  }

  Future<bool> requestPermissionWithExplainer(BuildContext context) async {
    final granted = await checkPermission();
    if (granted) return true;

    final settings = await _repository.getSettings();
    if (settings.permissionRequested && context.mounted) {
      final shouldOpenSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Notifications are Disabled'),
          content: const Text(
            'To receive reminders for due invoices and payment alerts, please enable notifications in your phone Settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Go to Settings'),
            ),
          ],
        ),
      );
      if (shouldOpenSettings == true) {
        final androidImpl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await androidImpl?.requestNotificationsPermission();
      }
      return false;
    }

    if (!context.mounted) return false;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stay Updated with OneBill'),
        content: const Text(
          'Stay on top of your business with reminders for invoices, payments and important activity.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enable Notifications'),
          ),
        ],
      ),
    );

    await _repository.updateSettings(permissionRequested: true);

    if (proceed == true) {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final result = await androidImpl?.requestNotificationsPermission();
      return result ?? false;
    }

    return false;
  }

  int _generateDeterministicId(String key) {
    return (key.hashCode.abs()) % 2147483647;
  }

  Future<void> reconcileInvoice(String invoiceId) async {
    try {
      final invoice = await (_db.select(_db.invoices)
            ..where((i) => i.id.equals(invoiceId)))
          .getSingleOrNull();

      if (invoice == null || invoice.deletedAt != null) {
        await cancelInvoiceReminders(invoiceId);
        return;
      }

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final remainingPaise = totalPaise - invoice.paidPaise;

      if (remainingPaise <= 0) {
        await cancelInvoiceReminders(invoiceId);
        return;
      }

      final settings = await _repository.getSettings();
      if (!settings.masterEnabled) {
        await cancelInvoiceReminders(invoiceId);
        return;
      }

      final prefs = await _repository.getPreferences();
      final dueAt = invoice.dueAt;
      if (dueAt == null) return;

      final customer = await (_db.select(_db.customers)
            ..where((c) => c.id.equals(invoice.customerId)))
          .getSingleOrNull();
      final business = await (_db.select(_db.businesses)
            ..where((b) => b.id.equals(invoice.businessId)))
          .getSingleOrNull();
      final allBusinesses = await _db.select(_db.businesses).get();
      final isMultiBusiness = allBusinesses.length > 1;

      final customerName = customer?.name ?? 'Customer';
      final bizPrefix = isMultiBusiness && business != null ? '${business.name} · ' : '';

      final steps = <({int stepIndex, String categoryKey, DateTime scheduleDate, String title, String body})>[
        (
          stepIndex: 0,
          categoryKey: NotificationCategories.invoiceDueSoon,
          scheduleDate: dueAt.subtract(const Duration(days: 7)),
          title: '${bizPrefix}Invoice due in 7 days',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
        (
          stepIndex: 1,
          categoryKey: NotificationCategories.invoiceDueSoon,
          scheduleDate: dueAt.subtract(const Duration(days: 1)),
          title: '${bizPrefix}Invoice due tomorrow',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
        (
          stepIndex: 2,
          categoryKey: NotificationCategories.invoiceDueToday,
          scheduleDate: DateTime(dueAt.year, dueAt.month, dueAt.day, 9, 0),
          title: '${bizPrefix}Invoice due today',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
        (
          stepIndex: 3,
          categoryKey: NotificationCategories.paymentOverdue,
          scheduleDate: DateTime(dueAt.year, dueAt.month, dueAt.day + 1, 9, 0),
          title: '${bizPrefix}Payment overdue (1 day)',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
        (
          stepIndex: 4,
          categoryKey: NotificationCategories.paymentOverdue,
          scheduleDate: DateTime(dueAt.year, dueAt.month, dueAt.day + 3, 9, 0),
          title: '${bizPrefix}Payment overdue (3 days)',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
        (
          stepIndex: 5,
          categoryKey: NotificationCategories.paymentOverdue,
          scheduleDate: DateTime(dueAt.year, dueAt.month, dueAt.day + 7, 9, 0),
          title: '${bizPrefix}Payment overdue (7 days)',
          body: '$customerName · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        ),
      ];

      final now = DateTime.now();

      for (final step in steps) {
        final notifId = _generateDeterministicId('${invoiceId}_step_${step.stepIndex}');

        if (prefs[step.categoryKey] != true) {
          await _plugin.cancel(notifId);
          continue;
        }

        if (step.scheduleDate.isBefore(now)) {
          await _plugin.cancel(notifId);
          continue;
        }

        var targetDate = step.scheduleDate;
        if (settings.quietHoursEnabled) {
          targetDate = _adjustForQuietHours(
            targetDate,
            settings.quietHoursStart,
            settings.quietHoursEnd,
          );
        }

        final tzTarget = tz.TZDateTime.from(targetDate, tz.local);
        final payload = jsonEncode({
          'action': NotificationActionKeys.viewInvoice,
          'invoiceId': invoiceId,
          'businessId': invoice.businessId,
          'customerId': invoice.customerId,
        });

        await _plugin.zonedSchedule(
          notifId,
          step.title,
          step.body,
          tzTarget,
          NotificationDetails(
            android: AndroidNotificationDetails(
              NotificationChannels.reminders,
              'Payment & Invoice Reminders',
              importance: Importance.max,
              priority: Priority.high,
              visibility: NotificationVisibility.public,
              actions: const [
                AndroidNotificationAction(
                  NotificationActionKeys.viewInvoice,
                  'View Invoice',
                  showsUserInterface: true,
                ),
                AndroidNotificationAction(
                  NotificationActionKeys.remindLater,
                  'Remind me later',
                  showsUserInterface: false,
                ),
              ],
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload,
        );
      }
    } catch (_) {}
  }

  Future<void> cancelInvoiceReminders(String invoiceId) async {
    for (var stepIndex = 0; stepIndex < 6; stepIndex++) {
      final notifId = _generateDeterministicId('${invoiceId}_step_$stepIndex');
      await _plugin.cancel(notifId);
    }
    final snoozeId = _generateDeterministicId('${invoiceId}_snooze');
    await _plugin.cancel(snoozeId);
  }

  DateTime _adjustForQuietHours(DateTime target, String startStr, String endStr) {
    try {
      final startParts = startStr.split(':').map(int.parse).toList();
      final endParts = endStr.split(':').map(int.parse).toList();
      final start = DateTime(target.year, target.month, target.day, startParts[0], startParts[1]);
      var end = DateTime(target.year, target.month, target.day, endParts[0], endParts[1]);

      if (end.isBefore(start)) {
        if (target.isAfter(start) || target.isBefore(end)) {
          if (target.isAfter(start)) {
            end = end.add(const Duration(days: 1));
          }
          return end.add(const Duration(minutes: 5));
        }
      } else {
        if (target.isAfter(start) && target.isBefore(end)) {
          return end.add(const Duration(minutes: 5));
        }
      }
    } catch (_) {}
    return target;
  }

  Future<void> snoozeInvoiceReminder(String invoiceId) async {
    try {
      final invoice = await (_db.select(_db.invoices)
            ..where((i) => i.id.equals(invoiceId)))
          .getSingleOrNull();
      if (invoice == null || invoice.deletedAt != null) return;

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final remainingPaise = totalPaise - invoice.paidPaise;
      if (remainingPaise <= 0) return;

      final customer = await (_db.select(_db.customers)
            ..where((c) => c.id.equals(invoice.customerId)))
          .getSingleOrNull();

      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final snoozeTarget = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0);
      final notifId = _generateDeterministicId('${invoiceId}_snooze');

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewInvoice,
        'invoiceId': invoiceId,
        'businessId': invoice.businessId,
        'customerId': invoice.customerId,
      });

      await _plugin.zonedSchedule(
        notifId,
        'Payment reminder',
        '${customer?.name ?? 'Customer'} · ${_rupees(remainingPaise)} · Invoice #${invoice.invoiceNumber}',
        tz.TZDateTime.from(snoozeTarget, tz.local),
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.reminders,
            'Payment & Invoice Reminders',
            importance: Importance.max,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                'View Invoice',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );

      await _repository.addNotification(
        id: 'snooze_${DateTime.now().millisecondsSinceEpoch}',
        businessId: invoice.businessId,
        category: NotificationCategories.paymentReminder,
        title: 'Reminder scheduled for tomorrow',
        body: 'Invoice #${invoice.invoiceNumber} (${_rupees(remainingPaise)})',
        entityType: 'invoice',
        entityId: invoiceId,
        scheduledAt: snoozeTarget,
        payloadJson: payload,
      );
    } catch (_) {}
  }

  Future<void> reconcileAllReminders() async {
    try {
      final activeBusinesses = await (_db.select(_db.businesses)
            ..where((b) => b.deletedAt.isNull()))
          .get();
      if (activeBusinesses.isEmpty) return;

      final allInvoices = await (_db.select(_db.invoices)
            ..where((i) => i.deletedAt.isNull()))
          .get();

      final overdueInvoices = <Invoice>[];
      var totalOverduePaise = 0;
      final today = DateTime.now().toLocal();
      final todayStart = DateTime(today.year, today.month, today.day);

      for (final invoice in allInvoices) {
        final totalPaise =
            invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
        final remainingPaise = totalPaise - invoice.paidPaise;
        final dueAt = invoice.dueAt?.toLocal();

        if (remainingPaise > 0 &&
            dueAt != null &&
            DateTime(dueAt.year, dueAt.month, dueAt.day).isBefore(todayStart)) {
          overdueInvoices.add(invoice);
          totalOverduePaise += remainingPaise;
        }

        await reconcileInvoice(invoice.id);
      }

      final groupNotifId = _generateDeterministicId('grouped_overdue_invoices');
      final settings = await _repository.getSettings();

      if (overdueInvoices.isEmpty) {
        if (settings.lastOverdueSignature != null) {
          await _plugin.cancel(groupNotifId);
          await _repository.updateSettings(
            lastOverdueSignature: const Value(null),
          );
        }
        return;
      }

      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.paymentOverdue] != true ||
          !settings.masterEnabled) {
        return;
      }

      overdueInvoices.sort((a, b) => a.id.compareTo(b.id));
      final overdueIds = overdueInvoices.map((i) => i.id).join(',');
      final currentSignature =
          '${overdueInvoices.length}:$totalOverduePaise:$overdueIds';

      // Deduplication: If the overdue state signature has not changed, do NOT re-post the notification
      if (settings.lastOverdueSignature == currentSignature) {
        return;
      }

      final overdueCount = overdueInvoices.length;
      final title =
          '$overdueCount ${overdueCount == 1 ? 'invoice' : 'invoices'} overdue';
      final body = 'Total outstanding: ${_rupees(totalOverduePaise)}';
      final payload = jsonEncode({'action': 'view_overdue'});

      await _plugin.show(
        groupNotifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.reminders,
            'Payment & Invoice Reminders',
            importance: Importance.max,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                'View Outstanding',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'grouped_overdue_invoices',
        category: NotificationCategories.paymentOverdue,
        title: title,
        body: body,
        entityType: 'overdue_summary',
        payloadJson: payload,
      );

      await _repository.updateSettings(
        lastOverdueSignature: Value(currentSignature),
      );
    } catch (_) {}
  }

  Future<void> notifyPaymentRecorded({
    required Payment payment,
    required Invoice invoice,
    required Customer? customer,
    required bool isFullyPaid,
  }) async {
    try {
      await reconcileInvoice(invoice.id);

      final prefs = await _repository.getPreferences();
      final category = isFullyPaid
          ? NotificationCategories.paymentReceived
          : NotificationCategories.partialPayment;

      if (prefs[category] != true) return;

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final remainingPaise = totalPaise - invoice.paidPaise;
      final customerName = customer?.name ?? 'Customer';

      final title = 'Payment received';
      final body = isFullyPaid
          ? '$customerName · ${_rupees(payment.amountPaise)}\nInvoice #${invoice.invoiceNumber} · Fully paid'
          : '${_rupees(payment.amountPaise)} from $customerName\n${_rupees(remainingPaise)} remaining';

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewPayment,
        'paymentId': payment.id,
        'invoiceId': invoice.id,
        'businessId': invoice.businessId,
      });

      final notifId = _generateDeterministicId('payment_${payment.id}');

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.payments,
            'Payment Activity',
            importance: Importance.max,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction(
                NotificationActionKeys.viewPayment,
                'View Payment',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: payment.id,
        businessId: invoice.businessId,
        category: category,
        title: title,
        body: body,
        entityType: 'payment',
        entityId: payment.id,
        payloadJson: payload,
      );
    } catch (_) {}
  }

  Future<void> notifyInvoiceCreated(Invoice invoice, Customer? customer) async {
    try {
      await reconcileInvoice(invoice.id);

      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.invoiceCreated] != true) return;

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final customerName = customer?.name ?? 'Customer';
      final title = 'Invoice created';
      final body = 'Invoice #${invoice.invoiceNumber} · $customerName · ${_rupees(totalPaise)}';

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewInvoice,
        'invoiceId': invoice.id,
        'businessId': invoice.businessId,
      });

      final notifId = _generateDeterministicId('invoice_created_${invoice.id}');

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.reminders,
            'Payment & Invoice Reminders',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'created_${invoice.id}',
        businessId: invoice.businessId,
        category: NotificationCategories.invoiceCreated,
        title: title,
        body: body,
        entityType: 'invoice',
        entityId: invoice.id,
        payloadJson: payload,
      );
    } catch (_) {}
  }

  Future<void> notifyInvoiceSentShared(Invoice invoice, Customer? customer) async {
    try {
      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.invoiceSentShared] != true) return;

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final customerName = customer?.name ?? 'Customer';
      final title = 'Invoice shared';
      final body =
          'Invoice #${invoice.invoiceNumber} shared with $customerName · ${_rupees(totalPaise)}';

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewInvoice,
        'invoiceId': invoice.id,
        'businessId': invoice.businessId,
      });

      final notifId = _generateDeterministicId(
        'invoice_shared_${invoice.id}_${DateTime.now().millisecondsSinceEpoch}',
      );

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.reminders,
            'Payment & Invoice Reminders',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'shared_${invoice.id}_${DateTime.now().millisecondsSinceEpoch}',
        businessId: invoice.businessId,
        category: NotificationCategories.invoiceSentShared,
        title: title,
        body: body,
        entityType: 'invoice',
        entityId: invoice.id,
        payloadJson: payload,
      );
    } catch (_) {}
  }


  Future<void> notifySyncFailed(String userFriendlyMessage) async {
    try {
      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.syncFailed] != true) return;

      const title = 'Sync failed';
      final body = userFriendlyMessage;

      final payload = jsonEncode({'action': NotificationActionKeys.viewSync});
      final notifId = _generateDeterministicId('sync_failed_${DateTime.now().hour}');

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.sync,
            'Sync & Backup',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
            actions: const [
              AndroidNotificationAction(
                NotificationActionKeys.viewSync,
                'View Sync Status',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'sync_fail_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.syncFailed,
        title: title,
        body: body,
        entityType: 'sync',
        payloadJson: payload,
      );
    } catch (_) {}
  }

  Future<void> showTestNotification() async {
    try {
      const title = 'OneBill Test Notification';
      const body = 'Your notification system is working perfectly!';
      final notifId = _generateDeterministicId('test_${DateTime.now().millisecondsSinceEpoch}');

      await _plugin.show(
        notifId,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            NotificationChannels.alerts,
            'Important OneBill Alerts',
            importance: Importance.max,
            priority: Priority.high,
            visibility: NotificationVisibility.public,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: '{"action":"test"}',
      );

      await _repository.addNotification(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.importantAlerts,
        title: title,
        body: body,
      );
    } catch (_) {}
  }

  String _rupees(int paise) {
    final absolute = paise.abs();
    final sign = paise < 0 ? '-' : '';
    return '$sign₹${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
  }
}
