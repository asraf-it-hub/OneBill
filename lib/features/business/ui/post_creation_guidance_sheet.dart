import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import 'business_profile_screen.dart';

class PostCreationGuidanceSheet extends ConsumerWidget {
  const PostCreationGuidanceSheet({super.key, required this.businessId});
  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);

    return StreamBuilder<BusinessesData?>(
      stream: (db.select(db.businesses)..where((b) => b.id.equals(businessId)))
          .watchSingleOrNull(),
      builder: (context, snapshot) {
        final business = snapshot.data;
        int completedCount = 0;
        const totalCount = 9;

        if (business != null) {
          if (business.name.trim().isNotEmpty) completedCount++;
          if (business.ownerName.trim().isNotEmpty) completedCount++;
          if (business.phone != null && business.phone!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.email != null && business.email!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.address != null && business.address!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.logoImage != null &&
              business.logoImage!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.upiId != null && business.upiId!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.paymentQrImage != null &&
              business.paymentQrImage!.trim().isNotEmpty) {
            completedCount++;
          }
          if (business.gstin != null && business.gstin!.trim().isNotEmpty) {
            completedCount++;
          }
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.verified_outlined,
                      color: theme.colorScheme.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Make your invoices look professional',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Business Profile Setup',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Add a few business details so OneBill can automatically include them on your invoices, receipts, and UPI payment requests.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              // Progress Indicator
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Business Profile Status',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: completedCount / totalCount,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '$completedCount of $totalCount added',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder:
                          (_) => BusinessProfileScreen(businessId: businessId),
                    ),
                  );
                },
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Complete Profile'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        );
      },
    );
  }
}
