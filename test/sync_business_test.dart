import 'dart:convert';

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

  test('createLocalWorkspace enqueues complete BusinessCreated sync payload', () async {
    await businesses.createLocalWorkspace(
      ownerName: 'Alice Owner',
      businessName: 'Alice Bakery',
      phone: '9876543210',
      languageCode: 'en',
    );

    final ops = await database.select(database.syncOperations).get();
    expect(ops, hasLength(1));
    final op = ops.first;
    expect(op.operationType, 'BusinessCreated');
    expect(op.entityType, 'business');

    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    expect(payload['name'], 'Alice Bakery');
    expect(payload['ownerName'], 'Alice Owner');
    expect(payload['phone'], '9876543210');
    expect(payload['preferredLanguage'], 'en');
    expect(payload['id'], isNotNull);
    expect(payload['createdAt'], isNotNull);
    expect(payload['updatedAt'], isNotNull);
  });

  test('createBusiness enqueues complete BusinessCreated sync payload', () async {
    final accountId = 'account-123';
    final now = DateTime.now().toUtc();
    await database.into(database.userAccounts).insert(
      UserAccountsCompanion.insert(
        id: accountId,
        displayName: 'Account User',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final bizId = await businesses.createBusiness(
      accountId: accountId,
      ownerName: 'Bob Owner',
      businessName: 'Bob Hardware',
      phone: '9123456789',
      languageCode: 'hi',
    );

    final ops = await database.select(database.syncOperations).get();
    expect(ops, hasLength(1));
    final op = ops.first;
    expect(op.operationType, 'BusinessCreated');
    expect(op.entityId, bizId);

    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    expect(payload['id'], bizId);
    expect(payload['name'], 'Bob Hardware');
    expect(payload['ownerName'], 'Bob Owner');
    expect(payload['phone'], '9123456789');
    expect(payload['preferredLanguage'], 'hi');
  });
}
