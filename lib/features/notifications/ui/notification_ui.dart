import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../data/notification_constants.dart';
import '../data/notification_repository.dart';

class NotificationBellIcon extends ConsumerWidget {
  const NotificationBellIcon({
    super.key,
    required this.businessId,
    this.onOpenOverdue,
  });
  final String? businessId;
  final VoidCallback? onOpenOverdue;

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
  });
  final String? businessId;
  final VoidCallback? onOpenOverdue;

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
                    return _NotificationTile(
                      notification: item,
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
          action == 'view_customers') {
        Navigator.pop(context);
      }
    } catch (_) {
      Navigator.pop(context);
    }
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.onTap,
  });

  final AppNotification notification;
  final VoidCallback onTap;

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
          ListTile(
            title: Text(
              tr(context, 'Quiet Hours'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(tr(context, 'Silence scheduled reminders during night hours')),
          ),
          SwitchListTile(
            title: Text(tr(context, 'Enable Quiet Hours')),
            subtitle: Text(
              'Shift reminders between ${settings?.quietHoursStart ?? '22:00'} and ${settings?.quietHoursEnd ?? '07:00'} to morning',
            ),
            value: quietHoursEnabled,
            onChanged: masterEnabled
                ? (val) => repo.updateSettings(quietHoursEnabled: val)
                : null,
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
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceCreated,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceSentShared,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceDueSoon,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceDueToday,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.invoiceOverdue,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.paymentReceived,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.partialPayment,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.paymentReminder,
          ),
          ..._buildCategorySwitch(
            context,
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
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.dailySummary,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.weeklySummary,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.monthlySummary,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.syncCompleted,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.syncFailed,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.importantAlerts,
          ),
          ..._buildCategorySwitch(
            context,
            repo,
            prefs,
            masterEnabled,
            NotificationCategories.announcements,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(tr(context, 'Send Test Notification')),
              onPressed: () async {
                final service = ref.read(notificationServiceProvider);
                final granted =
                    await service.requestPermissionWithExplainer(context);
                await service.showTestNotification();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        granted
                            ? 'Test notification sent to phone banner & lock screen!'
                            : 'Test notification recorded in Notification Center (Permission needed for status bar).',
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  List<Widget> _buildCategorySwitch(
    BuildContext context,
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
            ? (val) => repo.setPreference(key, val)
            : null,
      ),
    ];
  }
}
