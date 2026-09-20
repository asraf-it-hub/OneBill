import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:onebill/core/providers.dart';

void main() {
  group('Password Reset & Recovery Providers', () {
    test('isPasswordRecoveryProvider defaults to false and updates cleanly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(isPasswordRecoveryProvider), isFalse);

      container.read(isPasswordRecoveryProvider.notifier).state = true;
      expect(container.read(isPasswordRecoveryProvider), isTrue);

      container.read(isPasswordRecoveryProvider.notifier).state = false;
      expect(container.read(isPasswordRecoveryProvider), isFalse);
    });
  });
}
