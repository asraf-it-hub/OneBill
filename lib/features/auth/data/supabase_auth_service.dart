import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_environment.dart';

class SupabaseAuthService {
  SupabaseClient get _client {
    if (!AppEnvironment.cloudConfigured) {
      throw StateError(
        'Cloud authentication has not been configured for this build.',
      );
    }
    return Supabase.instance.client;
  }

  Session? get currentSession => _client.auth.currentSession;
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<void> register({
    required String email,
    required String password,
  }) async {
    final result = await _client.auth.signUp(
      email: email.trim(),
      password: password,
    );
    if (result.user == null) {
      throw StateError('Account registration could not be completed.');
    }
    if (result.session == null) {
      await signIn(email: email, password: password);
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    final result = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    if (result.session == null) {
      throw StateError('Sign-in could not be completed.');
    }
  }

  Future<void> resetPassword({required String email}) async {
    await _client.auth.resetPasswordForEmail(email.trim());
  }

  Future<bool> signInWithGoogle() async {
    return await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'onebill://login-callback/',
    );
  }

  Future<void> signOut() => _client.auth.signOut();
}
