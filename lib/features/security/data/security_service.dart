import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class SecurityService {
  const SecurityService();
  static const _pinKey = 'onebill.app.pin';
  static const _biometricKey = 'onebill.app.biometric';
  static const _storage = FlutterSecureStorage();
  static final _auth = LocalAuthentication();

  Future<bool> isPinEnabled() async =>
      (await _storage.read(key: _pinKey)) != null;
  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 4 to 6 digits.');
    }
    await _storage.write(key: _pinKey, value: pin);
    final saved = await _storage.read(key: _pinKey);
    if (saved != pin) {
      throw StateError(
        'The PIN could not be saved securely. Please try again.',
      );
    }
  }

  Future<void> clearPin() => _storage.delete(key: _pinKey);
  Future<bool> verifyPin(String pin) async =>
      await _storage.read(key: _pinKey) == pin;
  Future<int?> pinLength() async => (await _storage.read(key: _pinKey))?.length;
  Future<bool> isBiometricEnabled() async =>
      (await _storage.read(key: _biometricKey)) == 'true';
  Future<void> setBiometricEnabled(bool enabled) async =>
      _storage.write(key: _biometricKey, value: enabled ? 'true' : 'false');

  Future<bool> authenticateBiometrics() async {
    try {
      if (!await _auth.canCheckBiometrics && !await _auth.isDeviceSupported()) {
        return false;
      }
      return await _auth.authenticate(
        localizedReason: 'Authenticate to unlock OneBill',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
