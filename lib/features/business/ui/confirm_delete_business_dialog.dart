import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';

/// Shows a confirmation dialog to delete a business permanently.
/// Requires the user to type the exact business name to confirm.
/// 
/// Places [Cancel] on the left and [Delete Business] on the right.
/// Styled for high contrast and readability in both dark and light modes.
Future<bool?> showConfirmDeleteBusinessDialog(
  BuildContext context, {
  required String businessName,
}) {
  final cleanName = businessName.trim().isNotEmpty ? businessName.trim() : 'this business';
  final confirmController = TextEditingController();
  final isDark = Theme.of(context).brightness == Brightness.dark;

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final isMatch = confirmController.text.trim().toLowerCase() ==
              cleanName.toLowerCase();

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
                    tr(dialogContext, 'Delete Business Permanently?'),
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
                          tr(dialogContext, '⚠️ DANGER: PERMANENT DATA LOSS'),
                          style: TextStyle(
                            color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${tr(dialogContext, 'You are about to delete')} "$cleanName" '
                          '${tr(dialogContext, 'and all associated records on this device and in the cloud:')}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? const Color(0xFFFECACA) : const Color(0xFF7F1D1D),
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• ${tr(dialogContext, 'Invoices, Line Items & Payments')}\n'
                          '• ${tr(dialogContext, 'Customer Accounts')}\n'
                          '• ${tr(dialogContext, 'Income & Expense Reports')}\n'
                          '• ${tr(dialogContext, 'Cloud Backups & Sync Records')}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? const Color(0xFFF87171) : const Color(0xFF991B1B),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${tr(dialogContext, 'To confirm deletion, please type')} "$cleanName" '
                    '${tr(dialogContext, 'below:')}',
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
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: cleanName,
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                      prefixIcon: const Icon(
                        Icons.edit_note,
                        color: Color(0xFFDC2626),
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF141419) : const Color(0xFFF8FAFC),
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
                          color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
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
                  // Cancel Option on the LEFT
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
                  // Delete Business Option on the RIGHT
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isMatch ? () => Navigator.pop(dialogContext, true) : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: isDark
                            ? const Color(0xFF3B1515)
                            : const Color(0xFFFEE2E2),
                        disabledForegroundColor: isDark
                            ? const Color(0xFFE57373)
                            : const Color(0x99DC2626),
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
                                ? const Color(0xFFE57373)
                                : const Color(0x99DC2626)),
                      ),
                      label: Text(
                        tr(dialogContext, 'Delete'),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isMatch
                              ? Colors.white
                              : (isDark
                                  ? const Color(0xFFE57373)
                                  : const Color(0x99DC2626)),
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
