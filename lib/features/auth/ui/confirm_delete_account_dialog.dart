import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';

/// Shows a high-contrast, professional confirmation dialog for permanent account deletion.
/// Requires the user to type exact "DELETE" to enable the destructive action button.
Future<bool?> showConfirmDeleteAccountDialog(
  BuildContext context, {
  int pendingSyncCount = 0,
}) {
  final confirmController = TextEditingController();
  final isDark = Theme.of(context).brightness == Brightness.dark;

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final isMatch = confirmController.text.trim() == 'DELETE';
          final hasConfirmationText = confirmController.text.trim().isNotEmpty;

          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFDC2626), width: 1.5),
            ),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            actionsPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            title: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFDC2626),
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr(dialogContext, 'Delete Account Permanently?'),
                    style: TextStyle(
                      color: isDark ? const Color(0xFFF87171) : const Color(0xFF991B1B),
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF261212) : const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFCA5A5),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(dialogContext, 'PERMANENT ACCOUNT AND DATA DELETION'),
                          style: TextStyle(
                            color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr(dialogContext, 'You are about to permanently delete your OneBill account and the data associated with it.'),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? const Color(0xFFFECACA) : const Color(0xFF7F1D1D),
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${tr(dialogContext, '• Your account profile and login credentials')}\n'
                          '${tr(dialogContext, '• All businesses and workspaces owned by this account')}\n'
                          '${tr(dialogContext, '• All customer records, invoices, and payments')}\n'
                          '${tr(dialogContext, '• All income entries and expense tracking records')}\n'
                          '${tr(dialogContext, '• All cloud backups and sync history')}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? const Color(0xFFF87171) : const Color(0xFF991B1B),
                            height: 1.45,
                          ),
                        ),
                        if (pendingSyncCount > 0) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF450A0A) : const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tr(dialogContext, 'You have {count} unsynchronized change(s) that will be permanently lost.')
                                  .replaceAll('{count}', '$pendingSyncCount'),
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr(dialogContext, 'This action cannot be undone. Data that exists only on this device and has not been synchronized may also be permanently lost. Legally required records, if any, may be retained as disclosed in the privacy policy.'),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontStyle: FontStyle.italic,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr(dialogContext, 'To confirm account deletion, please type DELETE below:'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmController,
                    onChanged: (_) => setDialogState(() {}),
                    autocorrect: false,
                    enableSuggestions: false,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: 'DELETE',
                      helperText: isMatch
                          ? tr(dialogContext, 'Confirmation accepted. You can now delete the account.')
                          : hasConfirmationText
                              ? tr(dialogContext, 'Type DELETE exactly to enable account deletion.')
                              : tr(dialogContext, 'Type DELETE to enable account deletion.'),
                      helperStyle: TextStyle(
                        color: isMatch
                            ? (isDark ? const Color(0xFF86EFAC) : const Color(0xFF15803D))
                            : (hasConfirmationText
                                ? (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C))
                                : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
                        fontWeight: FontWeight.w600,
                      ),
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                      prefixIcon: const Icon(
                        Icons.edit_note,
                        color: Color(0xFFDC2626),
                      ),
                      filled: true,
                      fillColor: isMatch
                          ? (isDark ? const Color(0xFF0B2B1E) : const Color(0xFFF0FDF4))
                          : (isDark ? const Color(0xFF141419) : const Color(0xFFF8FAFC)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: Color(0xFFDC2626),
                          width: 2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isMatch
                              ? const Color(0xFF16A34A)
                              : (hasConfirmationText
                                  ? const Color(0xFFDC2626)
                                  : (isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1))),
                          width: isMatch || hasConfirmationText ? 2 : 1,
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        foregroundColor: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                        side: BorderSide(
                          color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        tr(dialogContext, 'Cancel'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isMatch ? () => Navigator.pop(dialogContext, true) : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: isDark
                            ? const Color(0xFF34343B)
                            : const Color(0xFFE2E8F0),
                        disabledForegroundColor: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                        elevation: isMatch ? 2 : 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: Icon(
                        Icons.delete_forever,
                        size: 18,
                        color: isMatch
                            ? Colors.white
                            : (isDark
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF64748B)),
                      ),
                      label: Text(
                        tr(dialogContext, 'Delete Account'),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isMatch
                              ? Colors.white
                              : (isDark
                                  ? const Color(0xFF9CA3AF)
                                  : const Color(0xFF64748B)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}
