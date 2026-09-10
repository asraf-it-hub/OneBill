import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:onebill/features/auth/domain/auth_error_details.dart';

void main() {
  group('AuthErrorDetails Tests', () {
    test('maps socket exception to connectionProblem', () {
      final details = AuthErrorDetails.fromError('SocketException: Failed host lookup');
      expect(details.type, AuthErrorType.connectionProblem);
      expect(details.title, 'Connection problem');
      expect(details.message, contains('internet connection'));
    });

    test('maps rate limit AuthException to tooManyAttempts', () {
      final details = AuthErrorDetails.fromError(
        const AuthException('Rate limit exceeded', statusCode: '429', code: 'over_email_send_rate_limit'),
      );
      expect(details.type, AuthErrorType.tooManyAttempts);
      expect(details.title, 'Too many attempts');
    });

    test('maps invalid_credentials AuthException to incorrectPassword', () {
      final details = AuthErrorDetails.fromError(
        const AuthException('Invalid login credentials', code: 'invalid_credentials'),
      );
      expect(details.type, AuthErrorType.incorrectPassword);
      expect(details.title, 'Incorrect password');
      expect(details.message, contains('password you entered is incorrect'));
    });

    test('maps user_not_found AuthException to accountNotFound', () {
      final details = AuthErrorDetails.fromError(
        const AuthException('User not found', code: 'user_not_found'),
      );
      expect(details.type, AuthErrorType.accountNotFound);
      expect(details.title, 'No account found');
    });

    test('maps unknown exception to somethingWentWrong', () {
      final details = AuthErrorDetails.fromError(Exception('Random unexpected error'));
      expect(details.type, AuthErrorType.somethingWentWrong);
      expect(details.title, 'Something went wrong');
    });
  });
}
