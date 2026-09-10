import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/features/auth/services/app_credential_manager.dart';

void main() {
  group('AppCredentialManager Tests', () {
    test('isSupported evaluates safely on desktop/test platform', () {
      final isSupported = AppCredentialManager.instance.isSupported;
      // In flutter test runner (Windows/Mac/Linux), isSupported should return false safely without throwing
      expect(isSupported, isFalse);
    });

    test('saveCredential handles non-Android platform silently', () async {
      await expectLater(
        AppCredentialManager.instance.saveCredential(
          email: 'user@onebill.app',
          password: 'password123',
        ),
        completes,
      );
    });

    test('getSavedCredential handles non-Android platform silently returning null', () async {
      final cred = await AppCredentialManager.instance.getSavedCredential();
      expect(cred, isNull);
    });
  });
}
