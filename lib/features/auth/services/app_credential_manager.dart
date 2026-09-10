import 'dart:io';
import 'package:credential_manager/credential_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Helper wrapper around Android Credential Manager.
/// Delegating 100% of credential storage to the platform Android Credential Manager.
/// NO passwords are stored in Drift, SQLite, SharedPreferences, or local files.
class AppCredentialManager {
  static final AppCredentialManager instance = AppCredentialManager._();
  AppCredentialManager._();

  CredentialManager? _cm;

  CredentialManager get _manager {
    _cm ??= CredentialManager();
    return _cm!;
  }

  bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// Offers secure credential saving after successful authentication or registration.
  /// User cancellation or dismissal will be caught silently without disrupting the user.
  Future<void> saveCredential({
    required String email,
    required String password,
  }) async {
    if (!isSupported) return;
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) return;

    // Trigger Android platform autofill context save
    try {
      TextInput.finishAutofillContext(shouldSave: true);
    } catch (_) {}

    try {
      await _manager.init(preferImmediatelyAvailableCredentials: false);
      await _manager.savePasswordCredentials(
        PasswordCredential(
          username: trimmedEmail,
          password: password,
        ),
      );
      debugPrint('AppCredentialManager: Saved credential for $trimmedEmail');
    } catch (e) {
      debugPrint('AppCredentialManager.saveCredential handled: $e');
    }
  }

  /// Retrieves previously saved OneBill credentials via Android Credential Manager.
  /// Returns null if no credential was selected, or if user cancelled/dismissed.
  Future<({String email, String password})?> getSavedCredential() async {
    if (!isSupported) return null;

    try {
      await _manager.init(preferImmediatelyAvailableCredentials: false);
      final credentials = await _manager.getCredentials();
      final pwdCred = credentials.passwordCredential;
      final username = pwdCred?.username;
      final password = pwdCred?.password;
      if (username != null &&
          username.isNotEmpty &&
          password != null &&
          password.isNotEmpty) {
        return (email: username, password: password);
      }
    } catch (e) {
      debugPrint('AppCredentialManager.getSavedCredential handled: $e');
    }
    return null;
  }
}
