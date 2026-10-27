import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/config/app_environment.dart';
import '../../../core/database/app_database.dart';
import '../../../core/localization/app_localizations.dart';
import 'notification_constants.dart';
import 'notification_repository.dart';

class NotificationService {
  final AppDatabase _db;
  final NotificationRepository _repository;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  void Function(String payloadJson, String? actionId)? onNotificationSelect;

  NotificationService(this._db, this._repository);

  void _logNotificationError(String operation, Object error) {
    // Log only the exception type, never invoice/customer/authentication data.
    debugPrint('OneBill notification $operation failed: ${error.runtimeType}');
  }

  bool _isAuthenticated() {
    if (!AppEnvironment.cloudConfigured) return true;
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (error) {
      _logNotificationError('authentication check', error);
      return false;
    }
  }

  Future<String> _getLanguageCode([String? businessId]) async {
    try {
      if (businessId != null && businessId.isNotEmpty) {
        final biz = await (_db.select(
          _db.businesses,
        )..where((b) => b.id.equals(businessId))).getSingleOrNull();
        if (biz?.preferredLanguage != null &&
            biz!.preferredLanguage.isNotEmpty) {
          return biz.preferredLanguage;
        }
      }
      final active =
          await (_db.select(_db.businesses)
                ..where((b) => b.deletedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
      return active?.preferredLanguage ?? 'en';
    } catch (error) {
      _logNotificationError('language lookup', error);
      return 'en';
    }
  }

  Future<void> init({
    void Function(String payload, String? actionId)? onSelect,
  }) async {
    if (_initialized) return;
    onNotificationSelect = onSelect;
    tz.initializeTimeZones();
    try {
      final offsetMs = DateTime.now().timeZoneOffset.inMilliseconds;
      for (final loc in tz.timeZoneDatabase.locations.values) {
        if (loc.currentTimeZone.offset == offsetMs) {
          tz.setLocalLocation(loc);
          break;
        }
      }
    } catch (error) {
      _logNotificationError('timezone initialization', error);
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
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
          } catch (error) {
            _logNotificationError('notification action handling', error);
          }
        }
        if (payload != null && onNotificationSelect != null) {
          onNotificationSelect!(payload, actionId);
        }
      },
    );

    await _createNotificationChannels();
    _initialized = true;
  }

  AndroidNotificationDetails _buildAndroidDetails({
    required String channelId,
    required String channelName,
    String? channelDescription,
    Importance importance = Importance.max,
    Priority priority = Priority.high,
    bool playSound = true,
    bool enableVibration = true,
    List<AndroidNotificationAction>? actions,
  }) {
    return AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: importance,
      priority: priority,
      playSound: playSound,
      enableVibration: enableVibration,
      icon: 'ic_notification',
      color: const Color(0xFF126E5D),
      visibility: NotificationVisibility.public,
      actions: actions,
    );
  }

  Future<AndroidScheduleMode> _scheduleMode() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final exactAllowed = await android?.canScheduleExactNotifications() ?? true;
    return exactAllowed
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  Future<NotificationAppLaunchDetails?> getLaunchDetails() =>
      _plugin.getNotificationAppLaunchDetails();

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (error) {
      _logNotificationError('cancel all', error);
    }
  }

  Future<void> _createNotificationChannels() async {
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
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
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
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
          title: Text(tr(ctx, 'Notifications are Disabled')),
          content: Text(
            tr(
              ctx,
              'To receive reminders for due invoices and payment alerts, please enable notifications in your phone Settings.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Not now')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Go to Settings')),
            ),
          ],
        ),
      );
      if (shouldOpenSettings == true) {
        final androidImpl = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await androidImpl?.requestNotificationsPermission();
      }
      return false;
    }

    if (!context.mounted) return false;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Stay Updated with OneBill')),
        content: Text(
          tr(
            ctx,
            'Stay on top of your business with reminders for invoices, payments and important activity.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Not now')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Enable Notifications')),
          ),
        ],
      ),
    );

    await _repository.updateSettings(permissionRequested: true);

    if (proceed == true) {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final result = await androidImpl?.requestNotificationsPermission();
      return result ?? false;
    }

    return false;
  }

  int _generateDeterministicId(String key) {
    return (key.hashCode.abs()) % 2147483647;
  }

  Future<void> reconcileInvoice(String invoiceId) async {
    if (!_isAuthenticated()) return;
    try {
      final invoice = await (_db.select(
        _db.invoices,
      )..where((i) => i.id.equals(invoiceId))).getSingleOrNull();

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

      final customer = await (_db.select(
        _db.customers,
      )..where((c) => c.id.equals(invoice.customerId))).getSingleOrNull();
      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();

      final customerName = customer?.name ?? 'Customer';
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';
      final lang = await _getLanguageCode(invoice.businessId);

      final steps =
          <
            ({
              int stepIndex,
              String categoryKey,
              DateTime scheduleDate,
              String title,
              String body,
            })
          >[
            (
              stepIndex: 0,
              categoryKey: NotificationCategories.invoiceDueSoon,
              scheduleDate: dueAt.subtract(const Duration(days: 7)),
              title: '$bizPrefix${trLang('Invoice due in 7 days', lang)}',
              body:
                  '$customerName · ${_rupees(remainingPaise)} · ${trLang('Invoice', lang)} #${invoice.invoiceNumber}',
            ),
            (
              stepIndex: 1,
              categoryKey: NotificationCategories.invoiceDueSoon,
              scheduleDate: dueAt.subtract(const Duration(days: 1)),
              title: '$bizPrefix${trLang('Invoice due tomorrow', lang)}',
              body:
                  '$customerName · ${_rupees(remainingPaise)} · ${trLang('Invoice', lang)} #${invoice.invoiceNumber}',
            ),
            (
              stepIndex: 2,
              categoryKey: NotificationCategories.invoiceDueToday,
              scheduleDate: DateTime(dueAt.year, dueAt.month, dueAt.day, 9, 0),
              title: '$bizPrefix${trLang('Invoice due today', lang)}',
              body:
                  '$customerName · ${_rupees(remainingPaise)} · ${trLang('Invoice', lang)} #${invoice.invoiceNumber}',
            ),
            for (var day = 1; day <= 7; day++)
              (
                stepIndex: 2 + day,
                categoryKey: NotificationCategories.invoiceOverdue,
                scheduleDate: DateTime(
                  dueAt.year,
                  dueAt.month,
                  dueAt.day + day,
                  9,
                  0,
                ),
                title: day == 1
                    ? '$bizPrefix${trLang('Payment overdue (1 day)', lang)}'
                    : '$bizPrefix${trLang('Payment overdue', lang)} ($day days)',
                body:
                    '$customerName · ${_rupees(remainingPaise)} · ${trLang('Invoice', lang)} #${invoice.invoiceNumber}',
              ),
          ];

      final now = DateTime.now();

      for (final step in steps) {
        final notifId = _generateDeterministicId(
          '${invoiceId}_step_${step.stepIndex}',
        );

        final isEnabled = prefs[step.categoryKey] == true;
        if (!isEnabled) {
          await _plugin.cancel(notifId);
          continue;
        }

        if (step.scheduleDate.isBefore(now)) {
          await _plugin.cancel(notifId);
          continue;
        }

        final tzTarget = tz.TZDateTime.from(step.scheduleDate, tz.local);
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
            android: _buildAndroidDetails(
              channelId: NotificationChannels.reminders,
              channelName: 'Payment & Invoice Reminders',
              actions: [
                AndroidNotificationAction(
                  NotificationActionKeys.viewInvoice,
                  trLang('View Invoice', lang),
                  showsUserInterface: true,
                ),
              ],
            ),
          ),
          androidScheduleMode: await _scheduleMode(),
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload,
        );
      }
    } catch (error) {
      _logNotificationError('notification operation', error);
    }
  }

  Future<void> cancelInvoiceReminders(String invoiceId) async {
    for (var stepIndex = 0; stepIndex < 10; stepIndex++) {
      final notifId = _generateDeterministicId('${invoiceId}_step_$stepIndex');
      await _plugin.cancel(notifId);
    }
    final snoozeId = _generateDeterministicId('${invoiceId}_snooze');
    await _plugin.cancel(snoozeId);
  }

  Future<void> snoozeInvoiceReminder(
    String invoiceId, [
    DateTime? targetDate,
  ]) async {
    try {
      final settings = await _repository.getSettings();
      final prefs = await _repository.getPreferences();
      if (!settings.masterEnabled ||
          prefs[NotificationCategories.paymentReminder] != true) {
        return;
      }
      final invoice = await (_db.select(
        _db.invoices,
      )..where((i) => i.id.equals(invoiceId))).getSingleOrNull();
      if (invoice == null || invoice.deletedAt != null) return;

      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final remainingPaise = totalPaise - invoice.paidPaise;
      if (remainingPaise <= 0) return;

      final customer = await (_db.select(
        _db.customers,
      )..where((c) => c.id.equals(invoice.customerId))).getSingleOrNull();

      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final snoozeTarget =
          targetDate ??
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0);
      final notifId = _generateDeterministicId('${invoiceId}_snooze');

      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';
      final lang = await _getLanguageCode(invoice.businessId);

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewInvoice,
        'invoiceId': invoiceId,
        'businessId': invoice.businessId,
        'customerId': invoice.customerId,
      });

      await _plugin.zonedSchedule(
        notifId,
        '$bizPrefix${trLang('Payment reminder', lang)}',
        '${customer?.name ?? trLang('Customer', lang)} · ${_rupees(remainingPaise)} · ${trLang('Invoice', lang)} #${invoice.invoiceNumber}',
        tz.TZDateTime.from(snoozeTarget, tz.local),
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.reminders,
            channelName: 'Payment & Invoice Reminders',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                trLang('View Invoice', lang),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        androidScheduleMode: await _scheduleMode(),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );

      final isTomorrow =
          snoozeTarget.day == tomorrow.day &&
          snoozeTarget.month == tomorrow.month &&
          snoozeTarget.year == tomorrow.year;
      final title = isTomorrow
          ? trLang('Reminder scheduled for tomorrow', lang)
          : trLang('Reminder scheduled', lang);

      await _repository.addNotification(
        id: 'snooze_${DateTime.now().millisecondsSinceEpoch}',
        businessId: invoice.businessId,
        category: NotificationCategories.paymentReminder,
        title: title,
        body: 'Invoice #${invoice.invoiceNumber} (${_rupees(remainingPaise)})',
        entityType: 'invoice',
        entityId: invoiceId,
        scheduledAt: snoozeTarget,
        payloadJson: payload,
      );
    } catch (error) {
      _logNotificationError('notification operation', error);
    }
  }

  Future<void> reconcileAllReminders() async {
    if (!_isAuthenticated()) return;
    try {
      // Scope reminder reconciliation to the currently selected local account.
      // The database is shared across sign-in cycles, so querying every
      // non-deleted business can surface another account's old invoices in a
      // newly created account.
      final session =
          await (_db.select(_db.localSessions)
                ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)])
                ..limit(1))
              .getSingleOrNull();
      var accountId = session?.accountId;
      if (AppEnvironment.cloudConfigured) {
        try {
          accountId =
              Supabase.instance.client.auth.currentUser?.id ?? accountId;
        } catch (error) {
          _logNotificationError('account resolution', error);
        }
      }
      if (accountId == null || accountId.isEmpty) {
        await _clearGroupedOverdueSummary();
        return;
      }
      final resolvedAccountId = accountId;

      final activeBusinesses =
          await (_db.select(_db.businesses)..where(
                (b) =>
                    b.accountId.equals(resolvedAccountId) &
                    b.deletedAt.isNull(),
              ))
              .get();
      final settings = await _repository.getSettings();
      if (!settings.masterEnabled) {
        for (final business in activeBusinesses) {
          final invoices =
              await (_db.select(_db.invoices)..where(
                    (i) =>
                        i.businessId.equals(business.id) & i.deletedAt.isNull(),
                  ))
                  .get();
          for (final invoice in invoices) {
            await cancelInvoiceReminders(invoice.id);
          }
        }
        await _clearGroupedOverdueSummary();
        await reconcileSummaries();
        return;
      }
      if (activeBusinesses.isEmpty) {
        await _clearGroupedOverdueSummary();
        return;
      }
      final businessIds = activeBusinesses.map((b) => b.id).toList();

      final allInvoices =
          await (_db.select(_db.invoices)..where(
                (i) => i.businessId.isIn(businessIds) & i.deletedAt.isNull(),
              ))
              .get();

      final overdueInvoices = <Invoice>[];
      var totalOverduePaise = 0;
      final today = DateTime.now().toLocal();
      final todayStart = DateTime(today.year, today.month, today.day);

      for (final invoice in allInvoices) {
        final totalPaise =
            invoice.subtotalPaise +
            invoice.interestPaise -
            invoice.discountPaise;
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

      try {
        final groupNotifId = _generateDeterministicId(
          'grouped_overdue_invoices',
        );
        final settings = await _repository.getSettings();

        if (overdueInvoices.isEmpty) {
          await _plugin.cancel(groupNotifId);
          await _repository.deleteNotification('grouped_overdue_invoices');
          if (settings.lastOverdueSignature != null) {
            await _repository.updateSettings(
              lastOverdueSignature: const Value(null),
            );
          }
        } else {
          final prefs = await _repository.getPreferences();
          if (prefs[NotificationCategories.invoiceOverdue] == true &&
              settings.masterEnabled) {
            overdueInvoices.sort((a, b) => a.id.compareTo(b.id));
            final overdueIds = overdueInvoices.map((i) => i.id).join(',');
            final currentSignature =
                '${overdueInvoices.length}:$totalOverduePaise:$overdueIds';

            if (settings.lastOverdueSignature != currentSignature) {
              final overdueBizIds = overdueInvoices
                  .map((i) => i.businessId)
                  .toSet();
              String bizPrefix = '';
              String? primaryBizId;
              if (overdueBizIds.length == 1) {
                primaryBizId = overdueBizIds.first;
                final b = await (_db.select(
                  _db.businesses,
                )..where((x) => x.id.equals(primaryBizId!))).getSingleOrNull();
                if (b != null && b.name.trim().isNotEmpty) {
                  bizPrefix = '${b.name.trim()} · ';
                }
              }
              final lang = await _getLanguageCode(primaryBizId);
              final overdueCount = overdueInvoices.length;
              final invoiceWord = overdueCount == 1
                  ? trLang('invoice', lang)
                  : trLang('invoices', lang);
              final title =
                  '$bizPrefix$overdueCount $invoiceWord ${trLang('overdue', lang)}';
              final body =
                  '${trLang('Total Due', lang)}: ${_rupees(totalOverduePaise)}';
              final payload = jsonEncode({
                'action': 'view_overdue',
                'businessId': ?primaryBizId,
              });

              await _plugin.show(
                groupNotifId,
                title,
                body,
                NotificationDetails(
                  android: _buildAndroidDetails(
                    channelId: NotificationChannels.reminders,
                    channelName: 'Payment & Invoice Reminders',
                    actions: [
                      AndroidNotificationAction(
                        NotificationActionKeys.viewInvoice,
                        trLang('View Outstanding', lang),
                        showsUserInterface: true,
                      ),
                    ],
                  ),
                ),
                payload: payload,
              );

              await _repository.addNotification(
                id: 'grouped_overdue_invoices',
                businessId: primaryBizId,
                category: NotificationCategories.paymentOverdue,
                title: title,
                body: body,
                entityType: 'overdue_summary',
                payloadJson: payload,
              );

              await _repository.updateSettings(
                lastOverdueSignature: Value(currentSignature),
              );
            }
          }
        }
      } catch (error) {
        _logNotificationError('overdue summary', error);
      }

      await reconcileSummaries();
    } catch (error) {
      _logNotificationError('reminder reconciliation', error);
    }
  }

  Future<void> _clearGroupedOverdueSummary() async {
    try {
      await _plugin.cancel(
        _generateDeterministicId('grouped_overdue_invoices'),
      );
      await _repository.deleteNotification('grouped_overdue_invoices');
      final settings = await _repository.getSettings();
      if (settings.lastOverdueSignature != null) {
        await _repository.updateSettings(
          lastOverdueSignature: const Value(null),
        );
      }
    } catch (error) {
      _logNotificationError('notification cleanup', error);
    }
  }

  Future<void> reconcileSummaries() async {
    try {
      final settings = await _repository.getSettings();
      final prefs = await _repository.getPreferences();
      final session =
          await (_db.select(_db.localSessions)
                ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)])
                ..limit(1))
              .getSingleOrNull();
      var accountId = session?.accountId;
      if (AppEnvironment.cloudConfigured) {
        accountId = Supabase.instance.client.auth.currentUser?.id ?? accountId;
      }
      if (accountId == null || accountId.isEmpty) return;

      // A user may own several businesses. Keep all of that user's businesses,
      // but never schedule summaries for another account left in local storage.
      final businesses =
          await (_db.select(_db.businesses)..where(
                (b) => b.accountId.equals(accountId!) & b.deletedAt.isNull(),
              ))
              .get();

      if (!settings.masterEnabled) {
        for (final business in businesses) {
          await _plugin.cancel(
            _generateDeterministicId('${business.id}_daily_summary'),
          );
          await _plugin.cancel(
            _generateDeterministicId('${business.id}_weekly_summary'),
          );
          await _plugin.cancel(
            _generateDeterministicId('${business.id}_monthly_summary'),
          );
        }
        return;
      }

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final weekStart = todayStart.subtract(Duration(days: now.weekday - 1));
      final monthStart = DateTime(now.year, now.month, 1);

      for (final business in businesses) {
        final lang = await _getLanguageCode(business.id);
        final bizPrefix = business.name.trim().isNotEmpty
            ? '${business.name.trim()} · '
            : '';

        final bizInvoices =
            await (_db.select(_db.invoices)..where(
                  (i) =>
                      i.businessId.equals(business.id) & i.deletedAt.isNull(),
                ))
                .get();

        final bizPayments = await (_db.select(
          _db.payments,
        )..where((p) => p.businessId.equals(business.id))).get();

        final dailyNotifId = _generateDeterministicId(
          '${business.id}_daily_summary',
        );
        final weeklyNotifId = _generateDeterministicId(
          '${business.id}_weekly_summary',
        );
        final monthlyNotifId = _generateDeterministicId(
          '${business.id}_monthly_summary',
        );

        final todayPayments = bizPayments.where((p) {
          final dt = p.createdAt.toLocal();
          return dt.year == now.year &&
              dt.month == now.month &&
              dt.day == now.day;
        }).toList();
        final todayInvoices = bizInvoices.where((i) {
          final dt = i.createdAt.toLocal();
          return dt.year == now.year &&
              dt.month == now.month &&
              dt.day == now.day;
        }).toList();
        final weekPayments = bizPayments
            .where((p) => !p.createdAt.toLocal().isBefore(weekStart))
            .toList();
        final weekInvoices = bizInvoices
            .where((i) => !i.createdAt.toLocal().isBefore(weekStart))
            .toList();
        final monthPayments = bizPayments
            .where((p) => !p.createdAt.toLocal().isBefore(monthStart))
            .toList();
        final monthInvoices = bizInvoices
            .where((i) => !i.createdAt.toLocal().isBefore(monthStart))
            .toList();

        // 1. Daily summary
        if (prefs[NotificationCategories.dailySummary] == true) {
          final todayCollectedPaise = todayPayments.fold<int>(
            0,
            (sum, p) => sum + p.amountPaise,
          );
          final title = '$bizPrefix${trLang('Daily Summary', lang)}';
          final body = lang == 'te'
              ? 'ఈరోజు వసూలైన మొత్తం ${_rupees(todayCollectedPaise)} · ${todayInvoices.length} ఇన్‌వాయిస్‌లు సృష్టించబడ్డాయి'
              : lang == 'hi'
              ? 'आज एकत्रित राशि ${_rupees(todayCollectedPaise)} · ${todayInvoices.length} चालान बनाए गए'
              : 'Collected ${_rupees(todayCollectedPaise)} today · ${todayInvoices.length} ${todayInvoices.length == 1 ? 'invoice' : 'invoices'} created';

          var target = DateTime(now.year, now.month, now.day, 20, 0); // 8:00 PM
          if (target.isBefore(now)) {
            target = target.add(const Duration(days: 1));
          }

          final payload = jsonEncode({
            'action': NotificationActionKeys.viewSummary,
            'businessId': business.id,
          });

          await _plugin.zonedSchedule(
            dailyNotifId,
            title,
            body,
            tz.TZDateTime.from(target, tz.local),
            NotificationDetails(
              android: _buildAndroidDetails(
                channelId: NotificationChannels.summaries,
                channelName: 'Business Summaries',
                importance: Importance.defaultImportance,
                actions: [
                  AndroidNotificationAction(
                    NotificationActionKeys.viewSummary,
                    trLang('View Reports', lang),
                    showsUserInterface: true,
                  ),
                ],
              ),
            ),
            androidScheduleMode: await _scheduleMode(),
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.time,
            payload: payload,
          );
        } else {
          await _plugin.cancel(dailyNotifId);
        }

        // 2. Weekly summary
        if (prefs[NotificationCategories.weeklySummary] == true) {
          final weekCollectedPaise = weekPayments.fold<int>(
            0,
            (sum, p) => sum + p.amountPaise,
          );
          final title = '$bizPrefix${trLang('Weekly Summary', lang)}';
          final body = lang == 'te'
              ? 'ఈ వారం వసూళ్లు: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} ఇన్‌వాయిస్‌లు'
              : lang == 'hi'
              ? 'इस सप्ताह का संग्रह: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} चालान'
              : 'Week collections: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} invoices';

          var daysUntilSunday = (DateTime.sunday - now.weekday) % 7;
          if (daysUntilSunday == 0 && now.hour >= 20) {
            daysUntilSunday = 7;
          }
          var target = DateTime(
            now.year,
            now.month,
            now.day + daysUntilSunday,
            20,
            0,
          );

          final payload = jsonEncode({
            'action': NotificationActionKeys.viewSummary,
            'businessId': business.id,
          });

          await _plugin.zonedSchedule(
            weeklyNotifId,
            title,
            body,
            tz.TZDateTime.from(target, tz.local),
            NotificationDetails(
              android: _buildAndroidDetails(
                channelId: NotificationChannels.summaries,
                channelName: 'Business Summaries',
                importance: Importance.defaultImportance,
                actions: [
                  AndroidNotificationAction(
                    NotificationActionKeys.viewSummary,
                    trLang('View Reports', lang),
                    showsUserInterface: true,
                  ),
                ],
              ),
            ),
            androidScheduleMode: await _scheduleMode(),
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: payload,
          );
        } else {
          await _plugin.cancel(weeklyNotifId);
        }

        // 3. Monthly summary
        if (prefs[NotificationCategories.monthlySummary] == true) {
          final monthCollectedPaise = monthPayments.fold<int>(
            0,
            (sum, p) => sum + p.amountPaise,
          );
          final title = '$bizPrefix${trLang('Monthly Performance', lang)}';
          final body = lang == 'te'
              ? 'ఈ నెల వసూళ్లు: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} ఇన్‌వాయిస్‌లు'
              : lang == 'hi'
              ? 'इस महीने का संग्रह: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} चालान'
              : 'Month collections: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} invoices';

          final nextMonth = now.month == 12 ? 1 : now.month + 1;
          final nextYear = now.month == 12 ? now.year + 1 : now.year;
          var target = DateTime(nextYear, nextMonth, 1, 9, 0);

          final payload = jsonEncode({
            'action': NotificationActionKeys.viewSummary,
            'businessId': business.id,
          });

          await _plugin.zonedSchedule(
            monthlyNotifId,
            title,
            body,
            tz.TZDateTime.from(target, tz.local),
            NotificationDetails(
              android: _buildAndroidDetails(
                channelId: NotificationChannels.summaries,
                channelName: 'Business Summaries',
                importance: Importance.defaultImportance,
                actions: [
                  AndroidNotificationAction(
                    NotificationActionKeys.viewSummary,
                    trLang('View Reports', lang),
                    showsUserInterface: true,
                  ),
                ],
              ),
            ),
            androidScheduleMode: await _scheduleMode(),
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
            payload: payload,
          );
        } else {
          await _plugin.cancel(monthlyNotifId);
        }
      }
    } catch (error) {
      _logNotificationError('summary reconciliation', error);
    }
  }

  Future<void> notifyPaymentRecorded({
    required Payment payment,
    required Invoice invoice,
    required Customer? customer,
    required bool isFullyPaid,
    String? langCode,
  }) async {
    try {
      if (!(await _repository.getSettings()).masterEnabled) return;
      await reconcileInvoice(invoice.id);
      await reconcileSummaries();

      final prefs = await _repository.getPreferences();
      // One user-facing payment setting controls both partial and completed
      // payments. The message still distinguishes the remaining balance.
      const category = NotificationCategories.paymentReceived;

      if (prefs[category] != true) return;

      final lang = langCode ?? await _getLanguageCode(invoice.businessId);
      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final remainingPaise = totalPaise - invoice.paidPaise;
      final customerName = customer?.name ?? trLang('Customer', lang);

      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';

      final title = '$bizPrefix${trLang('Payment received', lang)}';
      final body = isFullyPaid
          ? '$customerName · ${_rupees(payment.amountPaise)}\n${trLang('Invoice', lang)} #${invoice.invoiceNumber} · ${trLang('Fully paid', lang)}'
          : '${_rupees(payment.amountPaise)} ${trLang('from', lang)} $customerName\n${_rupees(remainingPaise)} ${trLang('remaining', lang)}';

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
          android: _buildAndroidDetails(
            channelId: NotificationChannels.payments,
            channelName: 'Payment Activity',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewPayment,
                trLang('View Payment', lang),
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                trLang('View Invoice', lang),
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
    } catch (error) {
      _logNotificationError('payment notification', error);
    }
  }

  Future<void> notifyInvoiceCreated(
    Invoice invoice,
    Customer? customer, [
    String? langCode,
  ]) async {
    try {
      if (!(await _repository.getSettings()).masterEnabled) return;
      await reconcileInvoice(invoice.id);
      await reconcileSummaries();

      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.invoiceCreated] != true) return;

      final lang = langCode ?? await _getLanguageCode(invoice.businessId);
      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final customerName = customer?.name ?? trLang('Customer', lang);

      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';

      final title = '$bizPrefix${trLang('Invoice created', lang)}';
      final body =
          '${trLang('Invoice', lang)} #${invoice.invoiceNumber} · $customerName · ${_rupees(totalPaise)}';

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
          android: _buildAndroidDetails(
            channelId: NotificationChannels.reminders,
            channelName: 'Payment & Invoice Reminders',
            importance: Importance.high,
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                trLang('View Invoice', lang),
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                NotificationActionKeys.shareInvoice,
                trLang('Share', lang),
                showsUserInterface: true,
              ),
            ],
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
    } catch (error) {
      _logNotificationError('invoice notification', error);
    }
  }

  Future<void> notifyInvoiceSentShared(
    Invoice invoice,
    Customer? customer, [
    String? langCode,
  ]) async {
    try {
      if (!(await _repository.getSettings()).masterEnabled) return;
      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.invoiceSentShared] == false) return;

      final lang = langCode ?? await _getLanguageCode(invoice.businessId);
      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final customerName = customer?.name ?? trLang('Customer', lang);

      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';

      final title = '$bizPrefix${trLang('Invoice shared', lang)}';
      final body =
          '${trLang('Invoice', lang)} #${invoice.invoiceNumber} ${trLang('shared with', lang)} $customerName · ${_rupees(totalPaise)}';

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
          android: _buildAndroidDetails(
            channelId: NotificationChannels.reminders,
            channelName: 'Payment & Invoice Reminders',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                trLang('View Invoice', lang),
                showsUserInterface: true,
              ),
            ],
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
    } catch (error) {
      _logNotificationError('share notification', error);
    }
  }

  Future<void> notifyPaperReceiptShared(
    Invoice invoice,
    Customer? customer, [
    String? langCode,
  ]) async {
    try {
      if (!(await _repository.getSettings()).masterEnabled) return;
      final prefs = await _repository.getPreferences();
      if (prefs[NotificationCategories.invoiceSentShared] == false) return;

      final lang = langCode ?? await _getLanguageCode(invoice.businessId);
      final totalPaise =
          invoice.subtotalPaise + invoice.interestPaise - invoice.discountPaise;
      final customerName = customer?.name ?? trLang('Customer', lang);

      final business = await (_db.select(
        _db.businesses,
      )..where((b) => b.id.equals(invoice.businessId))).getSingleOrNull();
      final bizPrefix = (business != null && business.name.trim().isNotEmpty)
          ? '${business.name.trim()} · '
          : '';

      final title = '$bizPrefix${trLang('Paper receipt shared', lang)}';
      final body =
          '${trLang('Paper receipt', lang)} #${invoice.invoiceNumber} ${trLang('shared with', lang)} $customerName \u2022 ${_rupees(totalPaise)}';

      final payload = jsonEncode({
        'action': NotificationActionKeys.viewInvoice,
        'invoiceId': invoice.id,
        'businessId': invoice.businessId,
      });

      final notifId = _generateDeterministicId(
        'receipt_shared_${invoice.id}_${DateTime.now().millisecondsSinceEpoch}',
      );

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.reminders,
            channelName: 'Payment & Invoice Reminders',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                trLang('View Invoice', lang),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'shared_receipt_${invoice.id}_${DateTime.now().millisecondsSinceEpoch}',
        businessId: invoice.businessId,
        category: NotificationCategories.invoiceSentShared,
        title: title,
        body: body,
        entityType: 'invoice',
        entityId: invoice.id,
        payloadJson: payload,
      );
    } catch (error) {
      _logNotificationError('paper receipt notification', error);
    }
  }

  Future<void> showTestNotification({
    String? title,
    String? body,
    String? actionLabel,
  }) async {
    try {
      final lang = await _getLanguageCode();
      final notifTitle = title ?? trLang('OneBill Notifications', lang);
      final notifBody =
          body ?? trLang('Notification system is working properly.', lang);
      final notifAction = actionLabel ?? trLang('Open OneBill', lang);
      final notifId = _generateDeterministicId(
        'test_${DateTime.now().millisecondsSinceEpoch}',
      );

      await _plugin.show(
        notifId,
        notifTitle,
        notifBody,
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.reminders,
            channelName: 'Payment & Invoice Reminders',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewInvoice,
                notifAction,
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: '{"action":"test"}',
      );

      await _repository.addNotification(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.invoiceDueSoon,
        title: notifTitle,
        body: notifBody,
      );
    } catch (error) {
      _logNotificationError('test notification', error);
    }
  }

  Future<void> showTestDailySummary({
    String? langCode,
    String? businessId,
  }) async {
    try {
      String? bizId = businessId;
      if (bizId == null) {
        final session = await (_db.select(
          _db.localSessions,
        )..limit(1)).getSingleOrNull();
        bizId = session?.activeBusinessId;
      }
      final active = bizId != null
          ? await (_db.select(
              _db.businesses,
            )..where((b) => b.id.equals(bizId!))).getSingleOrNull()
          : await (_db.select(_db.businesses)
                  ..where((b) => b.deletedAt.isNull())
                  ..limit(1))
                .getSingleOrNull();
      final lang = langCode ?? await _getLanguageCode(active?.id);
      final effectiveBizId = active?.id;

      final now = DateTime.now();

      final bizInvoices = effectiveBizId != null
          ? await (_db.select(_db.invoices)..where(
                  (i) =>
                      i.businessId.equals(effectiveBizId) &
                      i.deletedAt.isNull(),
                ))
                .get()
          : <Invoice>[];

      final bizPayments = effectiveBizId != null
          ? await (_db.select(
              _db.payments,
            )..where((p) => p.businessId.equals(effectiveBizId))).get()
          : <Payment>[];

      final todayPayments = bizPayments.where((p) {
        final dt = p.createdAt.toLocal();
        return dt.year == now.year &&
            dt.month == now.month &&
            dt.day == now.day;
      }).toList();
      final todayCollectedPaise = todayPayments.fold<int>(
        0,
        (sum, p) => sum + p.amountPaise,
      );
      final todayInvoices = bizInvoices.where((i) {
        final dt = i.createdAt.toLocal();
        return dt.year == now.year &&
            dt.month == now.month &&
            dt.day == now.day;
      }).toList();

      final bizPrefix = (active != null && active.name.trim().isNotEmpty)
          ? '${active.name.trim()} · '
          : '';
      final title = '$bizPrefix${trLang('Daily Summary', lang)}';
      final body = lang == 'te'
          ? 'ఈరోజు వసూలైన మొత్తం ${_rupees(todayCollectedPaise)} · ${todayInvoices.length} ఇన్‌వాయిస్‌లు సృష్టించబడ్డాయి'
          : lang == 'hi'
          ? 'आज एकत्रित राशि ${_rupees(todayCollectedPaise)} · ${todayInvoices.length} चालान बनाए गए'
          : 'Collected ${_rupees(todayCollectedPaise)} today · ${todayInvoices.length} ${todayInvoices.length == 1 ? 'invoice' : 'invoices'} created';

      final notifId = _generateDeterministicId(
        'test_daily_${DateTime.now().millisecondsSinceEpoch}',
      );
      final payload = jsonEncode({
        'action': 'view_summary',
        'businessId': ?bizId,
      });

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.summaries,
            channelName: 'Business Summaries',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewSummary,
                trLang('View Reports', lang),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'test_daily_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.dailySummary,
        title: title,
        body: body,
        entityType: 'summary',
        payloadJson: payload,
      );
    } catch (error) {
      _logNotificationError('daily summary test', error);
    }
  }

  Future<void> showTestWeeklySummary({
    String? langCode,
    String? businessId,
  }) async {
    try {
      String? bizId = businessId;
      if (bizId == null) {
        final session = await (_db.select(
          _db.localSessions,
        )..limit(1)).getSingleOrNull();
        bizId = session?.activeBusinessId;
      }
      final active = bizId != null
          ? await (_db.select(
              _db.businesses,
            )..where((b) => b.id.equals(bizId!))).getSingleOrNull()
          : await (_db.select(_db.businesses)
                  ..where((b) => b.deletedAt.isNull())
                  ..limit(1))
                .getSingleOrNull();
      final lang = langCode ?? await _getLanguageCode(active?.id);
      final effectiveBizId = active?.id;

      final now = DateTime.now();
      final weekStart = now.subtract(Duration(days: now.weekday - 1));
      final weekStartDate = DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day,
      );

      final bizInvoices = effectiveBizId != null
          ? await (_db.select(_db.invoices)..where(
                  (i) =>
                      i.businessId.equals(effectiveBizId) &
                      i.deletedAt.isNull(),
                ))
                .get()
          : <Invoice>[];

      final bizPayments = effectiveBizId != null
          ? await (_db.select(
              _db.payments,
            )..where((p) => p.businessId.equals(effectiveBizId))).get()
          : <Payment>[];

      final weekPayments = bizPayments
          .where((p) => p.createdAt.isAfter(weekStartDate))
          .toList();
      final weekCollectedPaise = weekPayments.fold<int>(
        0,
        (sum, p) => sum + p.amountPaise,
      );
      final weekInvoices = bizInvoices
          .where((i) => i.createdAt.isAfter(weekStartDate))
          .toList();

      final bizPrefix = (active != null && active.name.trim().isNotEmpty)
          ? '${active.name.trim()} · '
          : '';
      final title = '$bizPrefix${trLang('Weekly Summary', lang)}';
      final body = lang == 'te'
          ? 'ఈ వారం వసూళ్లు: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} ఇన్‌వాయిస్‌లు'
          : lang == 'hi'
          ? 'इस सप्ताह का संग्रह: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} चालान'
          : 'Week collections: ${_rupees(weekCollectedPaise)} · ${weekInvoices.length} ${weekInvoices.length == 1 ? 'invoice' : 'invoices'}';

      final notifId = _generateDeterministicId(
        'test_weekly_${DateTime.now().millisecondsSinceEpoch}',
      );
      final payload = jsonEncode({
        'action': 'view_summary',
        'businessId': ?bizId,
      });

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.summaries,
            channelName: 'Business Summaries',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewSummary,
                trLang('View Reports', lang),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'test_weekly_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.weeklySummary,
        title: title,
        body: body,
        entityType: 'summary',
        payloadJson: payload,
      );
    } catch (error) {
      _logNotificationError('weekly summary test', error);
    }
  }

  Future<void> showTestMonthlySummary({
    String? langCode,
    String? businessId,
  }) async {
    try {
      String? bizId = businessId;
      if (bizId == null) {
        final session = await (_db.select(
          _db.localSessions,
        )..limit(1)).getSingleOrNull();
        bizId = session?.activeBusinessId;
      }
      final active = bizId != null
          ? await (_db.select(
              _db.businesses,
            )..where((b) => b.id.equals(bizId!))).getSingleOrNull()
          : await (_db.select(_db.businesses)
                  ..where((b) => b.deletedAt.isNull())
                  ..limit(1))
                .getSingleOrNull();
      final lang = langCode ?? await _getLanguageCode(active?.id);
      final effectiveBizId = active?.id;

      final now = DateTime.now();
      final monthStart = DateTime(now.year, now.month, 1);

      final bizInvoices = effectiveBizId != null
          ? await (_db.select(_db.invoices)..where(
                  (i) =>
                      i.businessId.equals(effectiveBizId) &
                      i.deletedAt.isNull(),
                ))
                .get()
          : <Invoice>[];

      final bizPayments = effectiveBizId != null
          ? await (_db.select(
              _db.payments,
            )..where((p) => p.businessId.equals(effectiveBizId))).get()
          : <Payment>[];

      final monthPayments = bizPayments
          .where((p) => p.createdAt.isAfter(monthStart))
          .toList();
      final monthCollectedPaise = monthPayments.fold<int>(
        0,
        (sum, p) => sum + p.amountPaise,
      );
      final monthInvoices = bizInvoices
          .where((i) => i.createdAt.isAfter(monthStart))
          .toList();

      final bizPrefix = (active != null && active.name.trim().isNotEmpty)
          ? '${active.name.trim()} · '
          : '';
      final title = '$bizPrefix${trLang('Monthly Performance', lang)}';
      final body = lang == 'te'
          ? 'ఈ నెల వసూళ్లు: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} ఇన్‌వాయిస్‌లు'
          : lang == 'hi'
          ? 'इस महीने का संग्रह: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} चालान'
          : 'Month collections: ${_rupees(monthCollectedPaise)} · ${monthInvoices.length} ${monthInvoices.length == 1 ? 'invoice' : 'invoices'}';

      final notifId = _generateDeterministicId(
        'test_monthly_${DateTime.now().millisecondsSinceEpoch}',
      );
      final payload = jsonEncode({
        'action': 'view_summary',
        'businessId': ?bizId,
      });

      await _plugin.show(
        notifId,
        title,
        body,
        NotificationDetails(
          android: _buildAndroidDetails(
            channelId: NotificationChannels.summaries,
            channelName: 'Business Summaries',
            actions: [
              AndroidNotificationAction(
                NotificationActionKeys.viewSummary,
                trLang('View Reports', lang),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
        payload: payload,
      );

      await _repository.addNotification(
        id: 'test_monthly_${DateTime.now().millisecondsSinceEpoch}',
        category: NotificationCategories.monthlySummary,
        title: title,
        body: body,
        entityType: 'summary',
        payloadJson: payload,
      );
    } catch (error) {
      _logNotificationError('monthly summary test', error);
    }
  }

  String _rupees(int paise) {
    final absolute = paise.abs();
    final sign = paise < 0 ? '-' : '';
    return '$sign₹${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
  }
}
