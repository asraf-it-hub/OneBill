import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/ui/app_toast.dart';
import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../data/notification_constants.dart';
import '../data/notification_repository.dart';

class NotificationBellIcon extends ConsumerWidget {
  const NotificationBellIcon({
    super.key,
    required this.businessId,
    this.onOpenOverdue,
    this.onOpenInvoice,
    this.onOpenCustomer,
    this.onOpenSync,
    this.onOpenReports,
  });
  final String? businessId;
  final VoidCallback? onOpenOverdue;
  final void Function(String invoiceId, String? businessId)? onOpenInvoice;
  final void Function(String customerId, String? businessId)? onOpenCustomer;
  final VoidCallback? onOpenSync;
  final VoidCallback? onOpenReports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadAsync = ref.watch(unreadNotificationCountProvider(businessId));
    final unread = unreadAsync.valueOrNull ?? 0;

    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: 'Notifications',
          icon: const Icon(Icons.notifications_outlined),
          onPressed: () {
            showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => NotificationCenterSheet(
                businessId: businessId,
                onOpenOverdue: onOpenOverdue,
                onOpenInvoice: onOpenInvoice,
                onOpenCustomer: onOpenCustomer,
                onOpenSync: onOpenSync,
                onOpenReports: onOpenReports,
              ),
            );
          },
        ),
        if (unread > 0)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Color(0xFFEF4444),
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}

class NotificationCenterSheet extends ConsumerStatefulWidget {
  const NotificationCenterSheet({
    super.key,
    this.businessId,
    this.onOpenOverdue,
    this.onOpenInvoice,
    this.onOpenCustomer,
    this.onOpenSync,
    this.onOpenReports,
  });
  final String? businessId;
  final VoidCallback? onOpenOverdue;
  final void Function(String invoiceId, String? businessId)? onOpenInvoice;
  final void Function(String customerId, String? businessId)? onOpenCustomer;
  final VoidCallback? onOpenSync;
  final VoidCallback? onOpenReports;

  @override
  ConsumerState<NotificationCenterSheet> createState() =>
      _NotificationCenterSheetState();
}

class _NotificationCenterSheetState
    extends ConsumerState<NotificationCenterSheet> {
  bool _showOnlyUnread = false;

  @override
  Widget build(BuildContext context) {
    final notificationsAsync =
        ref.watch(notificationListProvider(widget.businessId));
    final repo = ref.read(notificationRepositoryProvider);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, 'Notifications'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      repo.markAllAsRead(businessId: widget.businessId),
                  child: Text(tr(context, 'Mark all read')),
                ),
                IconButton(
                  tooltip: 'Clear notifications',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(tr(context, 'Clear all notifications?')),
                        content: Text(
                          tr(context, 'This will remove all notification history stored on this device.'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(tr(context, 'Cancel')),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(tr(context, 'Clear')),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await repo.clearAllNotifications(
                          businessId: widget.businessId);
                    }
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                FilterChip(
                  label: Text(tr(context, 'All')),
                  selected: !_showOnlyUnread,
                  onSelected: (val) => setState(() => _showOnlyUnread = false),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr(context, 'Unread')),
                  selected: _showOnlyUnread,
                  onSelected: (val) => setState(() => _showOnlyUnread = true),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Notification settings',
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NotificationSettingsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notificationsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err')),
              data: (list) {
                final filtered = _showOnlyUnread
                    ? list.where((n) => !n.isRead).toList()
                    : list;

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _showOnlyUnread
                              ? tr(context, 'No unread notifications')
                              : tr(context, 'No notifications yet'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tr(context, 'Important reminders and activity will appear here.'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    String? invoiceId;
                    try {
                      if (item.payloadJson != null) {
                        final data =
                            jsonDecode(item.payloadJson!) as Map<String, dynamic>;
                        invoiceId = data['invoiceId'] as String?;
                      }
                    } catch (_) {}
                    invoiceId ??=
                        (item.entityType == 'invoice' ? item.entityId : null);

                    final isSnoozeable = invoiceId != null &&
                        (item.category == NotificationCategories.invoiceDueSoon ||
                            item.category == NotificationCategories.invoiceDueToday ||
                            item.category == NotificationCategories.paymentOverdue ||
                            item.category == NotificationCategories.paymentReminder);

                    return _NotificationTile(
                      notification: item,
                      onSnooze: isSnoozeable
                          ? () => showSnoozeBottomSheet(context, ref, invoiceId!)
                          : null,
                      onTap: () async {
                        await repo.markAsHandled(item.id);
                        if (context.mounted) {
                          _handlePayloadNavigation(context, item);
                        }
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _handlePayloadNavigation(
    BuildContext context,
    AppNotification notification,
  ) {
    try {
      final payloadJson = notification.payloadJson;
      final data = payloadJson != null
          ? jsonDecode(payloadJson) as Map<String, dynamic>
          : <String, dynamic>{};
      final action = data['action'] as String?;

      if (action == 'view_overdue' ||
          notification.category == NotificationCategories.paymentOverdue) {
        Navigator.pop(context);
        if (widget.onOpenOverdue != null) {
          widget.onOpenOverdue!();
        }
      } else if (action == NotificationActionKeys.viewInvoice ||
          action == NotificationActionKeys.viewPayment ||
          notification.entityType == 'invoice' ||
          data['invoiceId'] != null) {
        Navigator.pop(context);
        final invoiceId = (data['invoiceId'] as String?) ??
            (notification.entityType == 'invoice' ? notification.entityId : null);
        if (invoiceId != null && widget.onOpenInvoice != null) {
          widget.onOpenInvoice!(
            invoiceId,
            (data['businessId'] as String?) ?? notification.businessId,
          );
        }
      } else if (action == NotificationActionKeys.viewCustomer ||
          action == 'view_customers' ||
          notification.entityType == 'customer' ||
          data['customerId'] != null) {
        Navigator.pop(context);
        final customerId = (data['customerId'] as String?) ??
            (notification.entityType == 'customer' ? notification.entityId : null);
        if (customerId != null && widget.onOpenCustomer != null) {
          widget.onOpenCustomer!(
            customerId,
            (data['businessId'] as String?) ?? notification.businessId,
          );
        }
      } else if (action == NotificationActionKeys.viewSync ||
          notification.category == NotificationCategories.syncFailed) {
        Navigator.pop(context);
        if (widget.onOpenSync != null) {
          widget.onOpenSync!();
        }
      } else if (action == NotificationActionKeys.viewSummary ||
          action == 'view_summary' ||
          action == 'view_reports' ||
          notification.category == NotificationCategories.dailySummary ||
          notification.category == NotificationCategories.weeklySummary ||
          notification.category == NotificationCategories.monthlySummary) {
        Navigator.pop(context);
        if (widget.onOpenReports != null) {
          widget.onOpenReports!();
        }
      } else {
        Navigator.pop(context);
      }
    } catch (_) {
      Navigator.pop(context);
    }
  }
}

Future<void> showSnoozeBottomSheet(
  BuildContext context,
  WidgetRef ref,
  String invoiceId,
) async {
  final now = DateTime.now();
  final tomorrow = now.add(const Duration(days: 1));
  final in3Days = now.add(const Duration(days: 3));

  final options = [
    (
      title: 'Tomorrow · 9:00 AM (Default)',
      dateTime: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0),
      isDefault: true,
    ),
    (
      title: 'Tomorrow · 2:00 PM',
      dateTime: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 14, 0),
      isDefault: false,
    ),
    (
      title: 'Tomorrow · 6:00 PM',
      dateTime: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18, 0),
      isDefault: false,
    ),
    (
      title: 'In 3 days',
      dateTime: DateTime(in3Days.year, in3Days.month, in3Days.day, 9, 0),
      isDefault: false,
    ),
  ];

  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                const Icon(Icons.snooze_rounded),
                const SizedBox(width: 8),
                Text(
                  tr(context, 'Remind me later'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),
          const Divider(),
          ...options.map(
            (opt) => ListTile(
              leading: Icon(
                opt.isDefault
                    ? Icons.alarm_on_rounded
                    : Icons.access_time_rounded,
                color: opt.isDefault
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(
                tr(context, opt.title),
                style: TextStyle(
                  fontWeight:
                      opt.isDefault ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await ref
                    .read(notificationServiceProvider)
                    .snoozeInvoiceReminder(invoiceId, opt.dateTime);
                if (context.mounted) {
                  AppToast.showSuccess(
                    context,
                    '${tr(context, 'Reminder scheduled for')} ${tr(context, opt.title)}',
                  );
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: Text(tr(context, 'Choose date & time')),
            onTap: () async {
              Navigator.pop(ctx);
              final pickedDate = await showDatePicker(
                context: context,
                initialDate: tomorrow,
                firstDate: now,
                lastDate: now.add(const Duration(days: 365)),
              );
              if (pickedDate == null || !context.mounted) return;
              final pickedTime = await showTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 9, minute: 0),
                builder: (context, child) {
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(alwaysUse24HourFormat: false),
                    child: Localizations.override(
                      context: context,
                      locale: const Locale('en', 'US'),
                      child: child!,
                    ),
                  );
                },
              );
              if (pickedTime == null || !context.mounted) return;
              final target = DateTime(
                pickedDate.year,
                pickedDate.month,
                pickedDate.day,
                pickedTime.hour,
                pickedTime.minute,
              );
              await ref
                  .read(notificationServiceProvider)
                  .snoozeInvoiceReminder(invoiceId, target);
              if (context.mounted) {
                AppToast.showSuccess(
                  context,
                  tr(context, 'Custom reminder scheduled'),
                );
              }
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.onTap,
    this.onSnooze,
  });

  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback? onSnooze;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = _categoryIconAndColor(notification.category);

    return Card(
      color: notification.isRead
          ? theme.colorScheme.surface
          : theme.colorScheme.primaryContainer.withOpacity(0.12),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.15),
          foregroundColor: color,
          child: Icon(icon, size: 20),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                notification.title,
                style: TextStyle(
                  fontWeight: notification.isRead
                      ? FontWeight.w500
                      : FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            if (!notification.isRead)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF3B82F6),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              notification.body,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatRelativeTime(notification.createdAt),
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                fontSize: 11,
              ),
            ),
          ],
        ),
        trailing: onSnooze != null
            ? IconButton(
                tooltip: 'Remind me later',
                icon: const Icon(Icons.snooze_rounded, size: 20),
                onPressed: onSnooze,
              )
            : null,
      ),
    );
  }

  (IconData, Color) _categoryIconAndColor(String category) {
    return switch (category) {
      NotificationCategories.paymentReceived ||
      NotificationCategories.partialPayment =>
        (Icons.payment_rounded, const Color(0xFF10B981)),
      NotificationCategories.invoiceOverdue ||
      NotificationCategories.paymentOverdue =>
        (Icons.warning_amber_rounded, const Color(0xFFEF4444)),
      NotificationCategories.invoiceDueSoon ||
      NotificationCategories.invoiceDueToday ||
      NotificationCategories.paymentReminder =>
        (Icons.event_note_rounded, const Color(0xFFF59E0B)),
      NotificationCategories.syncFailed =>
        (Icons.sync_problem_rounded, const Color(0xFFEF4444)),
      NotificationCategories.weeklySummary ||
      NotificationCategories.dailySummary =>
        (Icons.analytics_rounded, const Color(0xFF3B82F6)),
      _ => (Icons.notifications_rounded, const Color(0xFF126E5D)),
    };
  }

  String _formatRelativeTime(DateTime time) {
    final diff = DateTime.now().difference(time.toLocal());
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }
}

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(notificationSettingsProvider);
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final repo = ref.read(notificationRepositoryProvider);
    final theme = Theme.of(context);

    final settings = settingsAsync.valueOrNull;
    final prefs = prefsAsync.valueOrNull ?? NotificationCategories.defaults;
    final masterEnabled = settings?.masterEnabled ?? true;
    final quietHoursEnabled = settings?.quietHoursEnabled ?? true;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Notification Settings')),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          SwitchListTile(
            title: Text(
              tr(context, 'Master Control'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(tr(context, 'Enable or disable all app notifications')),
            value: masterEnabled,
            onChanged: (val) => repo.updateSettings(masterEnabled: val),
          ),
          const Divider(),
          SwitchListTile(
            title: Text(
              tr(context, 'Quiet Hours'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              tr(context, 'Silence scheduled reminders during night hours'),
            ),
            value: quietHoursEnabled,
            onChanged: masterEnabled
                ? (val) {
                    repo.updateSettings(quietHoursEnabled: val);
                    ref
                        .read(notificationServiceProvider)
                        .reconcileAllReminders();
                  }
                : null,
          ),
          if (quietHoursEnabled)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, "Don't disturb me between"),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        _formatTimeStr(settings?.quietHoursStart ?? '22:00'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Divider(
                            color: theme.colorScheme.primary.withOpacity(0.7),
                            thickness: 2,
                          ),
                        ),
                      ),
                      Text(
                        _formatTimeStr(settings?.quietHoursEnd ?? '07:00'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.bedtime_outlined, size: 16),
                          label: Text(
                            '${tr(context, 'Start')}: ${_formatTimeStr(settings?.quietHoursStart ?? '22:00')}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: masterEnabled
                              ? () async {
                                  final currentParts =
                                      (settings?.quietHoursStart ?? '22:00')
                                          .split(':')
                                          .map(int.parse)
                                          .toList();
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(
                                      hour: currentParts[0],
                                      minute: currentParts[1],
                                    ),
                                    builder: (context, child) {
                                      return MediaQuery(
                                        data: MediaQuery.of(context)
                                            .copyWith(alwaysUse24HourFormat: false),
                                        child: Localizations.override(
                                          context: context,
                                          locale: const Locale('en', 'US'),
                                          child: child!,
                                        ),
                                      );
                                    },
                                  );
                                  if (picked != null) {
                                    final formatted =
                                        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                    await repo.updateSettings(
                                        quietHoursStart: formatted);
                                    ref
                                        .read(notificationServiceProvider)
                                        .reconcileAllReminders();
                                  }
                                }
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.wb_sunny_outlined, size: 16),
                          label: Text(
                            '${tr(context, 'End')}: ${_formatTimeStr(settings?.quietHoursEnd ?? '07:00')}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: masterEnabled
                              ? () async {
                                  final currentParts =
                                      (settings?.quietHoursEnd ?? '07:00')
                                          .split(':')
                                          .map(int.parse)
                                          .toList();
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(
                                      hour: currentParts[0],
                                      minute: currentParts[1],
                                    ),
                                    builder: (context, child) {
                                      return MediaQuery(
                                        data: MediaQuery.of(context)
                                            .copyWith(alwaysUse24HourFormat: false),
                                        child: Localizations.override(
                                          context: context,
                                          locale: const Locale('en', 'US'),
                                          child: child!,
                                        ),
                                      );
                                    },
                                  );
                                  if (picked != null) {
                                    final formatted =
                                        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                                    await repo.updateSettings(
                                        quietHoursEnd: formatted);
                                    ref
                                        .read(notificationServiceProvider)
                                        .reconcileAllReminders();
                                  }
                                }
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              tr(context, 'Invoice & Payment Alerts'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceCreated,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceSentShared,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceDueSoon,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceDueToday,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceOverdue,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.paymentReceived,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.partialPayment,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.paymentReminder,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.paymentOverdue,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              tr(context, 'Summaries & System'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.dailySummary,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.weeklySummary,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.monthlySummary,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.syncCompleted,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.syncFailed,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.importantAlerts,
          ),
          ..._buildCategorySwitch(
            context,
            ref,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.announcements,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'Notification Preview'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.6),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.asset(
                              'assets/OneBillLogo.png',
                              width: 18,
                              height: 18,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.receipt_long,
                                size: 18,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'OneBill',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            ' · ${tr(context, 'Just now')}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            tr(context, 'OneBill Notifications'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr(context, 'Notification system is working properly.'),
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        tr(context, 'All summary alerts and due reminders are active.'),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: null,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: Text(
                          tr(context, 'View Status'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: Text(tr(context, 'Send Test Notification')),
                  onPressed: () async {
                    final service = ref.read(notificationServiceProvider);
                    final testTitle = tr(context, 'OneBill Notifications');
                    final testBody = tr(context, 'Notification system is working properly.');
                    final testAction = tr(context, 'View Status');
                    final grantedMsg = tr(context, 'Test notification sent to phone banner & lock screen!');
                    final deniedMsg = tr(context, 'Test notification recorded in Notification Center (Permission needed for status bar).');

                    final granted =
                        await service.requestPermissionWithExplainer(context);
                    await service.showTestNotification(
                      title: testTitle,
                      body: testBody,
                      actionLabel: testAction,
                    );
                    if (context.mounted) {
                      if (granted) {
                        AppToast.showSuccess(context, grantedMsg);
                      } else {
                        AppToast.showInfo(context, deniedMsg);
                      }
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.today_outlined),
                  label: Text(tr(context, 'Test Daily Summary')),
                  onPressed: () async {
                    final service = ref.read(notificationServiceProvider);
                    await service.requestPermissionWithExplainer(context);
                    await service.showTestDailySummary();
                    if (context.mounted) {
                      AppToast.showSuccess(
                        context,
                        tr(context, 'Daily summary test notification triggered!'),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.date_range_outlined),
                  label: Text(tr(context, 'Test Weekly Summary')),
                  onPressed: () async {
                    final service = ref.read(notificationServiceProvider);
                    await service.requestPermissionWithExplainer(context);
                    await service.showTestWeeklySummary();
                    if (context.mounted) {
                      AppToast.showSuccess(
                        context,
                        tr(context, 'Weekly summary test notification triggered!'),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text(tr(context, 'Test Monthly Summary')),
                  onPressed: () async {
                    final service = ref.read(notificationServiceProvider);
                    await service.requestPermissionWithExplainer(context);
                    await service.showTestMonthlySummary();
                    if (context.mounted) {
                      AppToast.showSuccess(
                        context,
                        tr(context, 'Monthly performance test notification triggered!'),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _formatTimeStr(String hhmm) {
    try {
      final parts = hhmm.split(':').map(int.parse).toList();
      final hour = parts[0] % 12 == 0 ? 12 : parts[0] % 12;
      final ampm = parts[0] >= 12 ? 'PM' : 'AM';
      return '$hour:${parts[1].toString().padLeft(2, '0')} $ampm';
    } catch (_) {
      return hhmm;
    }
  }

  List<Widget> _buildCategorySwitch(
    BuildContext context,
    WidgetRef ref,
    NotificationRepository repo,
    Map<String, bool> prefs,
    bool masterEnabled,
    String key,
  ) {
    final label = NotificationCategories.labels[key] ?? key;
    final enabled = prefs[key] ?? NotificationCategories.defaults[key] ?? true;

    return [
      SwitchListTile(
        dense: true,
        title: Text(tr(context, label)),
        value: enabled,
        onChanged: masterEnabled
            ? (val) async {
                await repo.setPreference(key, val);
                final service = ref.read(notificationServiceProvider);
                if (key == NotificationCategories.dailySummary ||
                    key == NotificationCategories.weeklySummary ||
                    key == NotificationCategories.monthlySummary) {
                  await service.reconcileSummaries();
                } else {
                  await service.reconcileAllReminders();
                }
              }
            : null,
      ),
    ];
  }
}
