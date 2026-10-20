import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/core/database/app_database.dart';
import 'package:onebill/core/localization/app_localizations.dart';
import 'package:onebill/features/auth/domain/auth_error_details.dart';
import 'package:onebill/features/businesses/data/business_repository.dart';
import 'package:onebill/features/customers/data/customer_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Account Deletion Localization Tests', () {
    test('All required Account Deletion keys exist in Hindi and Telugu', () {
      final requiredKeys = [
        'Account',
        'Delete Account',
        'Permanently delete your account and associated data.',
        'Delete Account Permanently?',
        'PERMANENT ACCOUNT AND DATA DELETION',
        'You are about to permanently delete your OneBill account and the data associated with it.',
        'This will permanently delete:',
        '• Your account profile and login credentials',
        '• All businesses and workspaces owned by this account',
        '• All customer records, invoices, and payments',
        '• All income entries and expense tracking records',
        '• All cloud backups and sync history',
        'This action cannot be undone. Data that exists only on this device and has not been synchronized may also be permanently lost. Legally required records, if any, may be retained as disclosed in the privacy policy.',
        'To confirm account deletion, please type DELETE below:',
        'Type DELETE to confirm',
        'Deleting account...',
        'Account deleted successfully',
        'Internet connection is required to delete your account. Please check your network and try again.',
        'Could not delete account',
        'Account deletion cancelled',
        'You have {count} unsynchronized change(s) that will be permanently lost.',
      ];

      for (final key in requiredKeys) {
        expect(appTranslations.containsKey(key), isTrue, reason: 'Missing translation key: "$key"');
        final hi = trLang(key, 'hi');
        final te = trLang(key, 'te');
        expect(hi, isNotEmpty, reason: 'Hindi translation is empty for "$key"');
        expect(te, isNotEmpty, reason: 'Telugu translation is empty for "$key"');
        expect(hi, isNot(equals(key)), reason: 'Hindi translation should not be untranslated key: "$key"');
        expect(te, isNot(equals(key)), reason: 'Telugu translation should not be untranslated key: "$key"');
      }
    });

    test('Confirmation input requires exact word DELETE', () {
      bool isConfirmed(String input) => input.trim() == 'DELETE';

      expect(isConfirmed('DELETE'), isTrue);
      expect(isConfirmed('  DELETE  '), isTrue);
      expect(isConfirmed('delete'), isFalse);
      expect(isConfirmed('DEL'), isFalse);
      expect(isConfirmed('Delete'), isFalse);
      expect(isConfirmed(''), isFalse);
      expect(isConfirmed('DELETE NOW'), isFalse);
      expect(isConfirmed('DELET'), isFalse);
    });
  });

  group('Account Deletion Local Database Cleanup Tests', () {
    late AppDatabase db;
    late BusinessRepository bizRepo;
    late CustomerRepository custRepo;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      bizRepo = BusinessRepository(db);
      custRepo = CustomerRepository(db);

      final now = DateTime.now().toUtc();
      // Setup Account 1
      await db.into(db.userAccounts).insert(
        UserAccountsCompanion.insert(
          id: 'user-1',
          displayName: 'Owner One',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Setup Account 2 (to test data isolation during account deletion)
      await db.into(db.userAccounts).insert(
        UserAccountsCompanion.insert(
          id: 'user-2',
          displayName: 'Owner Two',
          createdAt: now,
          updatedAt: now,
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('deleteAccountData cleans up all user businesses and records while preserving other accounts', () async {
      // 1. Create businesses for user-1
      final b1 = await bizRepo.createBusiness(
        accountId: 'user-1',
        ownerName: 'Owner One',
        businessName: 'Business 1A',
        languageCode: 'en',
      );
      final b2 = await bizRepo.createBusiness(
        accountId: 'user-1',
        ownerName: 'Owner One',
        businessName: 'Business 1B',
        languageCode: 'en',
      );

      // 2. Create customer for business b1
      await custRepo.create(
        businessId: b1,
        name: 'Customer Alice',
        phone: '9999988888',
      );

      // 3. Create business for user-2
      final bOther = await bizRepo.createBusiness(
        accountId: 'user-2',
        ownerName: 'Owner Two',
        businessName: 'Business 2 Safe',
        languageCode: 'te',
      );
      await custRepo.create(
        businessId: bOther,
        name: 'Customer Bob',
        phone: '7777766666',
      );

      // Verify records exist before deletion
      final allBizBefore = await db.select(db.businesses).get();
      expect(allBizBefore.length, 3);
      final allCustBefore = await db.select(db.customers).get();
      expect(allCustBefore.length, 2);

      // 4. Delete user-1's account
      await db.deleteAccountData('user-1');

      // 5. Verify user-1 is completely wiped locally
      final user1 = await (db.select(db.userAccounts)..where((u) => u.id.equals('user-1'))).getSingleOrNull();
      expect(user1, isNull);

      final user1Biz = await (db.select(db.businesses)..where((b) => b.accountId.equals('user-1'))).get();
      expect(user1Biz, isEmpty);

      final custAlice = await (db.select(db.customers)..where((c) => c.businessId.equals(b1))).get();
      expect(custAlice, isEmpty);

      // 6. Verify user-2's data is 100% INTACT
      final user2 = await (db.select(db.userAccounts)..where((u) => u.id.equals('user-2'))).getSingleOrNull();
      expect(user2, isNotNull);
      expect(user2!.displayName, 'Owner Two');

      final user2Biz = await (db.select(db.businesses)..where((b) => b.accountId.equals('user-2'))).get();
      expect(user2Biz.length, 1);
      expect(user2Biz.first.name, 'Business 2 Safe');

      final custBob = await (db.select(db.customers)..where((c) => c.businessId.equals(bOther))).get();
      expect(custBob.length, 1);
      expect(custBob.first.name, 'Customer Bob');
    });

    test('AuthErrorDetails detects offline network conditions for deletion prevention', () {
      final offlineError = const SocketException('Failed host lookup: supabase.co');
      final details = AuthErrorDetails.fromError(offlineError);
      expect(details.type, AuthErrorType.connectionProblem);
      expect(details.title, 'Connection problem');
    });
  });
}
