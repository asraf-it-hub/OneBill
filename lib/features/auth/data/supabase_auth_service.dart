import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_environment.dart';

class SupabaseAuthService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: AppEnvironment.googleWebClientId,
  );

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
    final cleanEmail = email.trim();
    try {
      final result = await _client.auth.signInWithPassword(
        email: cleanEmail,
        password: password,
      );
      if (result.session == null) {
        throw StateError('Sign-in could not be completed.');
      }
    } catch (e) {
      if (e is AuthException) {
        final code = e.code?.toLowerCase() ?? '';
        final msg = e.message.toLowerCase();
        if (code == 'invalid_credentials' ||
            code == 'invalid_grant' ||
            msg.contains('invalid login credentials')) {
          try {
            final exists = await _client.rpc(
              'check_user_exists',
              params: {'p_email': cleanEmail},
            );
            if (exists == false) {
              throw const AuthException(
                'User not found',
                statusCode: '404',
                code: 'user_not_found',
              );
            }
          } catch (rpcErr) {
            if (rpcErr is AuthException && rpcErr.code == 'user_not_found') {
              rethrow;
            }
          }
        }
      }
      rethrow;
    }
  }

  Future<void> resetPassword({required String email}) async {
    final cleanEmail = email.trim();

    // 1. Verify user exists in database before dispatching email
    try {
      final result = await _client.rpc(
        'check_user_exists',
        params: {'p_email': cleanEmail},
      );
      if (result == false) {
        throw const AuthException(
          'User not found',
          statusCode: '404',
          code: 'user_not_found',
        );
      }
    } catch (e) {
      if (e is AuthException && e.code == 'user_not_found') {
        rethrow;
      }
    }

    // 2. User exists: send the password reset email
    await _client.auth.resetPasswordForEmail(
      cleanEmail,
      redirectTo: 'https://onebill.pages.dev/reset-password',
    );
  }

  Future<void> updatePassword({required String newPassword}) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  /// Native Android Google Sign-In with Supabase ID Token.
  /// Returns true if sign-in succeeded, false if user cancelled.
  Future<bool> signInWithGoogle() async {
    try {
      // Disconnect or sign out previous local Google session so user can pick account
      try {
        if (await _googleSignIn.isSignedIn()) {
          await _googleSignIn.signOut();
        }
      } catch (_) {}

      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // User backed out or cancelled the account chooser
        return false;
      }

      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) {
        throw const AuthException(
          'Could not retrieve Google ID token.',
          statusCode: '400',
        );
      }

      // ignore: avoid_print
      print(
        'DEBUG_AUTH: user=${googleUser.email}, idTokenLen=${idToken.length}, hasAccessToken=${accessToken != null}',
      );

      final response = await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );

      if (response.session == null) {
        throw const AuthException(
          'Failed to establish session with Supabase.',
          statusCode: '400',
        );
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.signOut();
      }
    } catch (_) {}
    await _client.auth.signOut();
  }

  /// Permanently deletes the authenticated user's account and all associated
  /// cloud data through the verified Edge Function. The function performs the
  /// ownership-bound RPC and private-file cleanup server-side.
  Future<void> deleteAccount() async {
    final session = currentSession;
    if (session == null) {
      throw const AuthException(
        'Authentication required. No active session found.',
        statusCode: '401',
      );
    }

    final response = await _client.functions.invoke('delete-account');
    if (response.status < 200 || response.status >= 300) {
      throw StateError('Account deletion could not be completed.');
    }
    final body = response.data;
    if (body is Map && body['success'] != true) {
      throw StateError('Account deletion could not be completed.');
    }
  }
}
