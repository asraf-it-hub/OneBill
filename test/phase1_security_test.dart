import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/features/businesses/data/business_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late BusinessRepository businesses;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    businesses = BusinessRepository(database);
  });

  tearDown(() => database.close());

  test('business queries stay isolated between accounts', () async {
    final now = DateTime.now().toUtc();
    for (final account in const ['account-a', 'account-b']) {
      await database
          .into(database.userAccounts)
          .insert(
            UserAccountsCompanion.insert(
              id: account,
              displayName: account,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await database
        .into(database.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: 'business-a',
            accountId: 'account-a',
            ownerName: 'A',
            name: 'A Shop',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: 'business-b',
            accountId: 'account-b',
            ownerName: 'B',
            name: 'B Shop',
            createdAt: now,
            updatedAt: now,
          ),
        );

    final accountABusinesses = await businesses
        .watchBusinesses('account-a')
        .first;
    expect(accountABusinesses.map((b) => b.id), ['business-a']);
  });

  test(
    'deleting one account business never switches to another account',
    () async {
      final now = DateTime.now().toUtc();
      await database
          .into(database.userAccounts)
          .insert(
            UserAccountsCompanion.insert(
              id: 'account-a',
              displayName: 'A',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.userAccounts)
          .insert(
            UserAccountsCompanion.insert(
              id: 'account-b',
              displayName: 'B',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: 'business-a',
              accountId: 'account-a',
              ownerName: 'A',
              name: 'A Shop',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: 'business-b',
              accountId: 'account-b',
              ownerName: 'B',
              name: 'B Shop',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.localSessions)
          .insert(
            LocalSessionsCompanion.insert(
              accountId: const Value('account-a'),
              activeBusinessId: const Value('business-a'),
              updatedAt: now,
            ),
          );

      await businesses.deleteBusiness(businessId: 'business-a');
      final session = await database.select(database.localSessions).getSingle();
      expect(session.accountId, 'account-a');
      expect(session.activeBusinessId, isNull);
      expect(
        await (database.select(
          database.businesses,
        )..where((b) => b.id.equals('business-b'))).getSingle(),
        isNotNull,
      );
    },
  );

  test(
    'security migration contains server-side tenant and financial guards',
    () {
      final sql = File(
        'supabase/migrations/202610210001_phase1_security_hardening.sql',
      ).readAsStringSync();
      expect(sql, contains("auth.role() = 'authenticated'"));
      expect(sql, contains('Business belongs to another account'));
      expect(
        sql,
        contains('Invoice customer does not belong to this business'),
      );
      expect(sql, contains('Payment exceeds the permitted invoice balance'));
      expect(sql, contains('Invalid invoice totals'));
      expect(sql, contains('Stale invoice update'));
      expect(sql, contains('amount_paise > 0'));
      expect(sql, contains('apply_sync_operation_legacy'));
    },
  );
}
