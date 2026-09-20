import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppLanguageNotifier extends StateNotifier<String> {
  AppLanguageNotifier() : super('en') {
    _loadLanguage();
  }

  static const _storage = FlutterSecureStorage();
  static const _key = 'onebill.app.preferred_language';

  Future<void> _loadLanguage() async {
    try {
      final saved = await _storage.read(key: _key);
      if (saved != null && {'en', 'hi', 'te'}.contains(saved)) {
        state = saved;
      }
    } catch (_) {}
  }

  Future<void> setLanguage(String lang) async {
    if (!{'en', 'hi', 'te'}.contains(lang)) return;
    state = lang;
    try {
      await _storage.write(key: _key, value: lang);
    } catch (_) {}
  }
}

final appLanguageProvider = StateNotifierProvider<AppLanguageNotifier, String>(
  (ref) => AppLanguageNotifier(),
);
