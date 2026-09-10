import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Device-local app-lock credentials. Nothing in this service is synced.
class SecurityService {
  const SecurityService();
  static const _pinHashKey = 'onebill.app.pin.hash';
  static const _pinSaltKey = 'onebill.app.pin.salt';
  static const _pinLengthKey = 'onebill.app.pin.length';
  static const _legacyPinKey = 'onebill.app.pin';
  static const _biometricKey = 'onebill.app.biometric';
  static const _timeoutKey = 'onebill.app.lock.timeout';
  static const _backgroundKey = 'onebill.app.lock.background';
  static const _storage = FlutterSecureStorage();
  static final _auth = LocalAuthentication();

  Future<bool> isPinEnabled() async =>
      (await _storage.read(key: _pinHashKey)) != null ||
      (await _storage.read(key: _legacyPinKey)) != null;

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 4 to 6 digits.');
    }
    final salt = base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(
      key: _pinHashKey,
      value: sha256.convert(utf8.encode('$salt:$pin')).toString(),
    );
    await _storage.write(key: _pinLengthKey, value: pin.length.toString());
    await _storage.delete(key: _legacyPinKey);
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinLengthKey);
    await _storage.delete(key: _legacyPinKey);
  }

  Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _pinSaltKey);
    final hash = await _storage.read(key: _pinHashKey);
    if (salt != null && hash != null) {
      return sha256.convert(utf8.encode('$salt:$pin')).toString() == hash;
    }
    final legacy = await _storage.read(key: _legacyPinKey);
    if (legacy != null && legacy == pin) {
      await setPin(pin);
      return true;
    }
    return false;
  }

  Future<int?> pinLength() async =>
      int.tryParse(await _storage.read(key: _pinLengthKey) ?? '') ??
      (await _storage.read(key: _legacyPinKey))?.length;
  Future<bool> isBiometricEnabled() async =>
      (await _storage.read(key: _biometricKey)) == 'true';
  Future<void> setBiometricEnabled(bool enabled) =>
      _storage.write(key: _biometricKey, value: enabled ? 'true' : 'false');

  Future<bool> biometricAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometrics() async {
    try {
      if (!await biometricAvailable()) return false;
      return await _auth.authenticate(
        localizedReason: 'Authenticate to unlock OneBill',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<Duration> lockTimeout() async => Duration(
    seconds:
        int.tryParse(await _storage.read(key: _timeoutKey) ?? '120') ?? 120,
  );
  Future<void> setLockTimeout(Duration timeout) =>
      _storage.write(key: _timeoutKey, value: timeout.inSeconds.toString());
  Future<void> markBackgrounded() => _storage.write(
    key: _backgroundKey,
    value: DateTime.now().toUtc().toIso8601String(),
  );
  Future<void> markAuthenticated() => _storage.delete(key: _backgroundKey);

  Future<bool> shouldLockOnResume() async {
    if (!await isPinEnabled()) return false;
    final value = await _storage.read(key: _backgroundKey);
    if (value == null) return false;
    final when = DateTime.tryParse(value);
    return when == null ||
        DateTime.now().toUtc().difference(when) >= await lockTimeout();
  }
}
