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
  static const _kdfKey = 'onebill.app.pin.kdf';
  static const _failedAttemptsKey = 'onebill.app.pin.failed-attempts';
  static const _lockedUntilKey = 'onebill.app.pin.locked-until';
  static const _kdfIterations = 120000;
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
      value: base64UrlEncode(
        _pbkdf2(pin, base64Url.decode(salt), _kdfIterations),
      ),
    );
    await _storage.write(key: _kdfKey, value: 'pbkdf2-sha256-$_kdfIterations');
    await _storage.write(key: _pinLengthKey, value: pin.length.toString());
    await _storage.delete(key: _legacyPinKey);
    await _resetPinFailures();
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinLengthKey);
    await _storage.delete(key: _kdfKey);
    await _storage.delete(key: _failedAttemptsKey);
    await _storage.delete(key: _lockedUntilKey);
    await _storage.delete(key: _legacyPinKey);
  }

  Future<bool> verifyPin(String pin) async {
    final lockedUntil = DateTime.tryParse(
      await _storage.read(key: _lockedUntilKey) ?? '',
    );
    if (lockedUntil != null && lockedUntil.isAfter(DateTime.now().toUtc())) {
      return false;
    }
    final salt = await _storage.read(key: _pinSaltKey);
    final hash = await _storage.read(key: _pinHashKey);
    if (salt != null && hash != null) {
      final kdf = await _storage.read(key: _kdfKey);
      final valid = kdf == null
          ? _constantTimeEquals(
              sha256.convert(utf8.encode('$salt:$pin')).toString(),
              hash,
            )
          : _constantTimeEquals(
              base64UrlEncode(
                _pbkdf2(pin, base64Url.decode(salt), _kdfIterations),
              ),
              hash,
            );
      if (valid) {
        if (kdf == null) await setPin(pin);
        await _resetPinFailures();
        return true;
      }
      await _recordPinFailure();
      return false;
    }
    final legacy = await _storage.read(key: _legacyPinKey);
    if (legacy != null && legacy == pin) {
      await setPin(pin);
      return true;
    }
    await _recordPinFailure();
    return false;
  }

  Future<Duration?> pinLockRemaining() async {
    final value = DateTime.tryParse(
      await _storage.read(key: _lockedUntilKey) ?? '',
    );
    if (value == null) return null;
    final remaining = value.difference(DateTime.now().toUtc());
    return remaining.isNegative ? null : remaining;
  }

  Future<void> _recordPinFailure() async {
    final attempts =
        (int.tryParse(await _storage.read(key: _failedAttemptsKey) ?? '') ??
            0) +
        1;
    await _storage.write(key: _failedAttemptsKey, value: attempts.toString());
    // Do not label a single typo as an attack. Begin progressive throttling
    // only after three consecutive failures.
    if (attempts >= 3) {
      final seconds = min(300, 2 << min(attempts - 3, 8));
      await _storage.write(
        key: _lockedUntilKey,
        value: DateTime.now()
            .toUtc()
            .add(Duration(seconds: seconds))
            .toIso8601String(),
      );
    }
  }

  Future<void> _resetPinFailures() async {
    await _storage.delete(key: _failedAttemptsKey);
    await _storage.delete(key: _lockedUntilKey);
  }

  List<int> _pbkdf2(String pin, List<int> salt, int iterations) {
    final mac = Hmac(sha256, utf8.encode(pin));
    final first = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final output = List<int>.from(first);
    var previous = first;
    for (var i = 1; i < iterations; i++) {
      previous = mac.convert(previous).bytes;
      for (var j = 0; j < output.length; j++) {
        output[j] ^= previous[j];
      }
    }
    return output;
  }

  bool _constantTimeEquals(String a, String b) {
    final aa = utf8.encode(a);
    final bb = utf8.encode(b);
    var diff = aa.length ^ bb.length;
    final length = min(aa.length, bb.length);
    for (var i = 0; i < length; i++) {
      diff |= aa[i] ^ bb[i];
    }
    return diff == 0;
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

  Future<bool> authenticateBiometrics({String? reason}) async {
    try {
      if (!await biometricAvailable()) return false;
      return await _auth.authenticate(
        localizedReason: reason ?? 'Authenticate to unlock OneBill',
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
