import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthErrorType {
  accountNotFound,
  incorrectPassword,
  connectionProblem,
  tooManyAttempts,
  somethingWentWrong,
}

class AuthErrorDetails {
  final AuthErrorType type;
  final String title;
  final String message;

  const AuthErrorDetails({
    required this.type,
    required this.title,
    required this.message,
  });

  factory AuthErrorDetails.fromError(Object error) {
    final str = error.toString();

    // 1. Connection/Network errors
    if (str.contains('SocketException') ||
        str.contains('Failed host lookup') ||
        str.contains('ClientException') ||
        str.contains('HandshakeException') ||
        str.contains('TimeoutException') ||
        str.contains('No address associated with hostname')) {
      return const AuthErrorDetails(
        type: AuthErrorType.connectionProblem,
        title: 'Connection problem',
        message:
            "We couldn't connect to OneBill. Please check your internet connection and try again.",
      );
    }

    // 2. Supabase Auth Exceptions
    if (error is AuthException || error is AuthApiException) {
      final dynamic err = error;
      final code = (err.code as String?) ?? '';
      final status = (err.statusCode as String?) ?? '';
      final msg = (err.message as String?) ?? str;

      // Rate limiting / Too many attempts
      if (code == 'over_email_send_rate_limit' ||
          status == '429' ||
          str.contains('429') ||
          str.contains('rate limit') ||
          str.contains('Rate limit exceeded') ||
          str.contains('too_many_requests')) {
        return const AuthErrorDetails(
          type: AuthErrorType.tooManyAttempts,
          title: 'Too many attempts',
          message: 'Please wait a moment before trying again.',
        );
      }

      // Account not found (if safely provided by Supabase Auth response)
      if (code == 'user_not_found' ||
          code == 'email_not_found' ||
          msg.contains('User not found')) {
        return const AuthErrorDetails(
          type: AuthErrorType.accountNotFound,
          title: 'No account found',
          message:
              "We couldn't find a OneBill account with this email address. Please check your email or create a new account.",
        );
      }

      // Incorrect password / Invalid credentials
      if (code == 'invalid_credentials' ||
          code == 'invalid_grant' ||
          code == 'wrong_password' ||
          msg.contains('Invalid login credentials')) {
        return const AuthErrorDetails(
          type: AuthErrorType.incorrectPassword,
          title: 'Incorrect password',
          message: 'The password you entered is incorrect. Please try again.',
        );
      }
    }

    // 3. Fallback generic server/auth error
    return const AuthErrorDetails(
      type: AuthErrorType.somethingWentWrong,
      title: 'Something went wrong',
      message: "We couldn't sign you in right now. Please try again.",
    );
  }
}
