import '../core/ui/app_toast.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Expression, OrderingTerm, Value;
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_environment.dart';
import '../core/database/app_database.dart';
import '../core/providers.dart';
import '../features/invoices/data/invoice_repository.dart';
import '../features/invoices/services/invoice_file_name_service.dart';
import 'theme/app_theme.dart';
import 'theme/theme_provider.dart';
import '../features/notifications/data/notification_constants.dart';
import '../features/notifications/ui/notification_ui.dart';
import '../features/business/ui/business_profile_screen.dart';
import '../features/business/ui/post_creation_guidance_sheet.dart';
import '../features/auth/domain/auth_error_details.dart';
import '../features/auth/services/app_credential_manager.dart';
import '../core/localization/app_localizations.dart';
import '../core/localization/app_language_provider.dart';

class OneBillApp extends ConsumerWidget {
  const OneBillApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionLang = ref.watch(sessionProvider).valueOrNull?.localeCode;
    final savedLang = ref.watch(appLanguageProvider);
    final language = sessionLang ?? savedLang;
    final locale = {'en', 'hi', 'te'}.contains(language) ? language : 'en';
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'OneBill',
      debugShowCheckedModeBanner: false,
      theme: OneBillTheme.light,
      darkTheme: OneBillTheme.dark,
      themeMode: themeMode,
      locale: Locale(locale),
      supportedLocales: const [Locale('en'), Locale('hi'), Locale('te')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _StartupGate(),
    );
  }
}

String _tr(BuildContext context, String key) => tr(context, key);

String _cleanErrorMessage(Object error, [String? fallbackPrefix]) {
  final str = error.toString();
  if (str.contains('SocketException') ||
      str.contains('Failed host lookup') ||
      str.contains('ClientException') ||
      str.contains('HandshakeException') ||
      str.contains('TimeoutException') ||
      str.contains('NetworkImage') ||
      str.contains('No address associated with hostname')) {
    return 'No internet connection. Please check your network and try again.';
  }
  if (str.contains('HTTP 503') ||
      str.contains('503 Service') ||
      str.contains('connection pool')) {
    return 'Server is temporarily busy. Your data is saved locally and will sync automatically.';
  }
  if (error is AuthException || error is AuthApiException) {
    final dynamic err = error;
    final code = (err.code as String?) ?? '';
    final status = (err.statusCode as String?) ?? '';
    final msg = (err.message as String?) ?? str;

    if (code == 'over_email_send_rate_limit' ||
        status == '429' ||
        str.contains('429') ||
        str.contains('rate limit') ||
        str.contains('Rate limit exceeded') ||
        str.contains('too_many_requests')) {
      return "We've temporarily limited this request for security. Please wait a little while and try again.";
    }
    if (code == 'invalid_credentials' ||
        code == 'invalid_grant' ||
        msg.contains('Invalid login credentials')) {
      return 'Invalid email or password. Please check your credentials.';
    }
    if (code == 'user_already_exists' ||
        code == 'email_exists' ||
        msg.contains('User already registered')) {
      return 'An account with this email already exists. Please sign in instead.';
    }
    if (msg.isNotEmpty) return msg;
  }
  var cleaned = str;
  if (cleaned.startsWith('Exception: ')) cleaned = cleaned.substring(11);
  if (cleaned.startsWith('AuthException: ')) cleaned = cleaned.substring(15);
  if (cleaned.startsWith('AuthApiException: ')) cleaned = cleaned.substring(18);
  if (cleaned.startsWith('StateError: ')) cleaned = cleaned.substring(12);
  if (cleaned.startsWith('ArgumentError: ')) cleaned = cleaned.substring(15);
  if (cleaned.contains('\n')) cleaned = cleaned.split('\n').first;
  if (cleaned.length > 120) cleaned = '${cleaned.substring(0, 117)}...';

  if (fallbackPrefix != null && fallbackPrefix.isNotEmpty) {
    return '$fallbackPrefix: $cleaned';
  }
  return cleaned;
}

Future<bool> _showDiscardChangesDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text("Your changes haven't been saved."),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep Editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _StartupGate extends ConsumerWidget {
  const _StartupGate();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSigningOut = ref.watch(isSigningOutProvider);
    if (isSigningOut) return const _AuthScreen();

    final auth = ref.watch(authSessionProvider);
    if (AppEnvironment.cloudConfigured) {
      if (auth.isLoading) return const _LoadingScreen();
      if (auth.valueOrNull == null) return const _AuthScreen();
    }
    return ref
        .watch(sessionProvider)
        .when(
          loading: () => const _LoadingScreen(),
          error: (error, _) => _ErrorScreen(
            message:
                'Your local data is safe, but it could not be loaded.\n$error',
          ),
          data: (session) => session == null || session.activeBusinessId == null
              ? const _WorkspaceSetupScreen()
              : _HomeScreen(session: session),
        );
  }
}

class _AuthScreen extends ConsumerStatefulWidget {
  const _AuthScreen();
  @override
  ConsumerState<_AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<_AuthScreen> with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _submitting = false;
  bool _isGoogleAuthPending = false;
  bool _obscurePassword = true;
  AuthErrorDetails? _authErrorDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(isSigningOutProvider.notifier).state = false;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isGoogleAuthPending) {
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (!mounted) return;
        final session = ref.read(authServiceProvider).currentSession;
        if (_isGoogleAuthPending && session == null) {
          setState(() {
            _isGoogleAuthPending = false;
            _submitting = false;
            _authErrorDetails = const AuthErrorDetails(
              type: AuthErrorType.somethingWentWrong,
              title: 'Sign-in cancelled',
              message: 'Google Sign-In was interrupted or cancelled. Please try again.',
            );
          });
        }
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty || _emailValidator(email) != null) {
      setState(() {
        _authErrorDetails = const AuthErrorDetails(
          type: AuthErrorType.somethingWentWrong,
          title: 'Email required',
          message: 'Please enter a valid email address to reset password.',
        );
      });
      return;
    }
    setState(() {
      _submitting = true;
      _authErrorDetails = null;
    });
    try {
      await ref.read(authServiceProvider).resetPassword(email: email);
      if (mounted) {
        AppToast.showSuccess(
          context,
          _tr(context, 'Password reset instructions have been sent to your email address.'),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _authErrorDetails = AuthErrorDetails.fromError(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _authErrorDetails = null;
    });
    ref.read(isSigningOutProvider.notifier).state = false;
    final email = _email.text.trim();
    final password = _password.text;

    try {
      final auth = ref.read(authServiceProvider);
      if (_registering) {
        await auth.register(email: email, password: password);
      } else {
        await auth.signIn(email: email, password: password);
      }

      // Restore account data from Supabase immediately on sign in
      try {
        await ref.read(syncWorkerProvider).restoreAccount();
      } catch (_) {}

      // Save credentials via Android Credential Manager & Autofill
      await AppCredentialManager.instance.saveCredential(
        email: email,
        password: password,
      );

      if (_registering && mounted) {
        AppToast.showSuccess(
          context,
          _tr(context, 'Account created successfully! Welcome to OneBill.'),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _authErrorDetails = AuthErrorDetails.fromError(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _submitting = true;
      _isGoogleAuthPending = true;
      _authErrorDetails = null;
    });
    ref.read(isSigningOutProvider.notifier).state = false;
    try {
      final launched = await ref.read(authServiceProvider).signInWithGoogle();
      if (!launched && mounted) {
        setState(() {
          _submitting = false;
          _isGoogleAuthPending = false;
          _authErrorDetails = const AuthErrorDetails(
            type: AuthErrorType.somethingWentWrong,
            title: 'Google sign-in',
            message: 'Could not launch Google authentication browser.',
          );
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isGoogleAuthPending = false;
          _authErrorDetails = AuthErrorDetails.fromError(error);
          _submitting = false;
        });
      }
    }
  }

  Widget _buildErrorBox(ThemeData theme) {
    if (_authErrorDetails == null) return const SizedBox.shrink();
    final err = _authErrorDetails!;

    IconData icon;
    Color iconColor;

    switch (err.type) {
      case AuthErrorType.accountNotFound:
        icon = Icons.person_search_rounded;
        iconColor = Colors.orange.shade700;
        break;
      case AuthErrorType.incorrectPassword:
        icon = Icons.lock_reset_rounded;
        iconColor = Colors.red.shade700;
        break;
      case AuthErrorType.connectionProblem:
        icon = Icons.wifi_off_rounded;
        iconColor = Colors.amber.shade800;
        break;
      case AuthErrorType.tooManyAttempts:
        icon = Icons.hourglass_top_rounded;
        iconColor = Colors.deepOrange.shade700;
        break;
      case AuthErrorType.somethingWentWrong:
        icon = Icons.error_outline_rounded;
        iconColor = theme.colorScheme.error;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.error.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  err.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            err.message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer.withOpacity(0.9),
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (err.type == AuthErrorType.accountNotFound) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _submitting
                      ? null
                      : () {
                          setState(() {
                            _registering = true;
                            _authErrorDetails = null;
                          });
                        },
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Create account'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _authErrorDetails = null);
                  },
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ] else if (err.type == AuthErrorType.incorrectPassword) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _submitting ? null : _resetPassword,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Forgot password?'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer.withOpacity(0.25),
                            shape: BoxShape.circle,
                          ),
                          child: Image.asset(
                            'assets/OneBillLogo.png',
                            width: 64,
                            height: 64,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _registering
                            ? 'Create your OneBill account'
                            : 'Sign in to OneBill',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your business data stays available offline after setup.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      _buildErrorBox(theme),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [
                          AutofillHints.email,
                          AutofillHints.username,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: _emailValidator,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscurePassword,
                        autofillHints: const [
                          AutofillHints.password,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: _passwordValidator,
                      ),
                      if (!_registering &&
                          _authErrorDetails?.type != AuthErrorType.incorrectPassword) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _submitting ? null : _resetPassword,
                            child: const Text('Forgot password?'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(_registering ? 'Create account' : 'Sign in'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _submitting
                            ? null
                            : () {
                                setState(() {
                                  _registering = !_registering;
                                  _authErrorDetails = null;
                                });
                              },
                        child: Text(
                          _registering
                              ? 'Already have an account? Sign in'
                              : 'New to OneBill? Create an account',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'OR',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _submitting ? null : _signInWithGoogle,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          side: BorderSide(
                            color: theme.colorScheme.outline.withOpacity(0.5),
                          ),
                        ),
                        child: _isGoogleAuthPending
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'Connecting to Google...',
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const _GoogleIcon(size: 22),
                                  const SizedBox(width: 12),
                                  Text(
                                    'Continue with Google',
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleIcon extends StatelessWidget {
  const _GoogleIcon({this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GoogleIconPainter(),
      ),
    );
  }
}

class _GoogleIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 48.0;

    // Red Path (#EA4335)
    final redPath = Path()
      ..moveTo(24 * s, 9.5 * s)
      ..cubicTo(27.54 * s, 9.5 * s, 30.71 * s, 10.72 * s, 33.21 * s, 13.1 * s)
      ..lineTo(40.06 * s, 6.25 * s)
      ..cubicTo(35.9 * s, 2.38 * s, 30.47 * s, 0 * s, 24 * s, 0 * s)
      ..cubicTo(14.66 * s, 0 * s, 6.58 * s, 5.38 * s, 2.56 * s, 13.22 * s)
      ..lineTo(10.54 * s, 19.41 * s)
      ..cubicTo(12.43 * s, 13.72 * s, 17.74 * s, 9.5 * s, 24 * s, 9.5 * s)
      ..close();
    canvas.drawPath(redPath, Paint()..color = const Color(0xFFEA4335));

    // Blue Path (#4285F4)
    final bluePath = Path()
      ..moveTo(46.98 * s, 24.55 * s)
      ..cubicTo(46.98 * s, 22.98 * s, 46.83 * s, 21.46 * s, 46.6 * s, 20 * s)
      ..lineTo(24 * s, 20 * s)
      ..lineTo(24 * s, 29.02 * s)
      ..lineTo(36.94 * s, 29.02 * s)
      ..cubicTo(36.36 * s, 31.98 * s, 34.68 * s, 34.5 * s, 32.16 * s, 36.2 * s)
      ..lineTo(39.89 * s, 42.2 * s)
      ..cubicTo(44.4 * s, 38.02 * s, 46.98 * s, 31.84 * s, 46.98 * s, 24.55 * s)
      ..close();
    canvas.drawPath(bluePath, Paint()..color = const Color(0xFF4285F4));

    // Yellow Path (#FBBC05)
    final yellowPath = Path()
      ..moveTo(10.53 * s, 28.59 * s)
      ..cubicTo(10.05 * s, 27.14 * s, 9.77 * s, 25.6 * s, 9.77 * s, 24 * s)
      ..cubicTo(9.77 * s, 22.4 * s, 10.05 * s, 20.86 * s, 10.53 * s, 19.41 * s)
      ..lineTo(2.56 * s, 13.22 * s)
      ..cubicTo(0.92 * s, 16.46 * s, 0 * s, 20.12 * s, 0 * s, 24 * s)
      ..cubicTo(0 * s, 27.88 * s, 0.92 * s, 31.54 * s, 2.56 * s, 34.78 * s)
      ..lineTo(10.53 * s, 28.59 * s)
      ..close();
    canvas.drawPath(yellowPath, Paint()..color = const Color(0xFFFBBC05));

    // Green Path (#34A853)
    final greenPath = Path()
      ..moveTo(24 * s, 48 * s)
      ..cubicTo(30.48 * s, 48 * s, 35.93 * s, 45.87 * s, 39.89 * s, 42.19 * s)
      ..lineTo(32.16 * s, 36.2 * s)
      ..cubicTo(30.01 * s, 37.65 * s, 27.24 * s, 38.5 * s, 24 * s, 38.5 * s)
      ..cubicTo(17.74 * s, 38.5 * s, 12.43 * s, 34.28 * s, 10.53 * s, 28.59 * s)
      ..lineTo(2.56 * s, 34.78 * s)
      ..cubicTo(6.58 * s, 42.62 * s, 14.66 * s, 48 * s, 24 * s, 48 * s)
      ..close();
    canvas.drawPath(greenPath, Paint()..color = const Color(0xFF34A853));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LanguageChoiceCard extends StatelessWidget {
  const _LanguageChoiceCard({
    required this.code,
    required this.nativeTitle,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  final String code;
  final String nativeTitle;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? primary.withOpacity(0.12)
                : theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? primary
                  : theme.colorScheme.outlineVariant.withOpacity(0.5),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    nativeTitle,
                    style: TextStyle(
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.w600,
                      fontSize: 14,
                      color: isSelected ? primary : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.check_circle, size: 16, color: primary),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected
                      ? primary.withOpacity(0.85)
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSetupScreen extends ConsumerStatefulWidget {
  const _WorkspaceSetupScreen();
  @override
  ConsumerState<_WorkspaceSetupScreen> createState() =>
      _WorkspaceSetupScreenState();
}

class _WorkspaceSetupScreenState extends ConsumerState<_WorkspaceSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _owner = TextEditingController();
  final _business = TextEditingController();
  final _phone = TextEditingController();
  String _language = 'en';
  bool _saving = false;
  bool _restoring = false;
  String? _restoreError;

  @override
  void initState() {
    super.initState();
    final currentLang = ref.read(appLanguageProvider);
    if ({'en', 'hi', 'te'}.contains(currentLang)) {
      _language = currentLang;
    }
    if (AppEnvironment.cloudConfigured) {
      _restoring = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await ref.read(syncWorkerProvider).restoreAccount();
        } catch (error) {
          if (mounted) {
            setState(() {
              _restoreError =
                  _cleanErrorMessage(error, 'Could not restore cloud data');
            });
          }
        } finally {
          if (mounted) setState(() => _restoring = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _owner.dispose();
    _business.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(appLanguageProvider.notifier).setLanguage(_language);
      await ref
          .read(businessRepositoryProvider)
          .createLocalWorkspace(
            accountId: ref.read(authSessionProvider).valueOrNull?.user.id,
            ownerName: _owner.text,
            businessName: _business.text,
            phone: _phone.text,
            languageCode: _language,
          );
      final session = await ref.read(sessionProvider.future);
      if (session?.activeBusinessId != null) {
        await ref.read(syncWorkerProvider).retryFailedOperations(session!.activeBusinessId!);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _cleanErrorMessage(error, 'Could not create workspace'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_restoring) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withOpacity(0.25),
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Restoring your business data',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Syncing cloud backup with your device...',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withOpacity(0.25),
                          shape: BoxShape.circle,
                        ),
                        child: Image.asset(
                          'assets/OneBillLogo.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _tr(context, 'Welcome to OneBill'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _tr(context, 'Create your first business. Your information is saved on this device and works offline.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_restoreError != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _restoreError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    // Prominent Preferred Language Choice
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Choose your preferred language'),
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _LanguageChoiceCard(
                              code: 'en',
                              nativeTitle: 'English',
                              subtitle: 'English',
                              isSelected: _language == 'en',
                              onTap: () {
                                setState(() => _language = 'en');
                                ref.read(appLanguageProvider.notifier).setLanguage('en');
                              },
                            ),
                            const SizedBox(width: 8),
                            _LanguageChoiceCard(
                              code: 'te',
                              nativeTitle: 'తెలుగు',
                              subtitle: 'Telugu',
                              isSelected: _language == 'te',
                              onTap: () {
                                setState(() => _language = 'te');
                                ref.read(appLanguageProvider.notifier).setLanguage('te');
                              },
                            ),
                            const SizedBox(width: 8),
                            _LanguageChoiceCard(
                              code: 'hi',
                              nativeTitle: 'हिन्दी',
                              subtitle: 'Hindi',
                              isSelected: _language == 'hi',
                              onTap: () {
                                setState(() => _language = 'hi');
                                ref.read(appLanguageProvider.notifier).setLanguage('hi');
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _owner,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Owner name'),
                        prefixIcon: const Icon(Icons.person_outline_rounded),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _business,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Business or shop name'),
                        prefixIcon: const Icon(Icons.storefront_outlined),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Business phone (optional)'),
                        prefixIcon: const Icon(Icons.phone_outlined),
                      ),
                      validator: _phoneValidator,
                    ),
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: _saving ? null : _create,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(_tr(context, 'Create business')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeScreen extends ConsumerStatefulWidget {
  const _HomeScreen({required this.session});
  final LocalSession session;

  @override
  ConsumerState<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<_HomeScreen>
    with WidgetsBindingObserver {
  var _tab = 0;
  // Keeps the main navigation highlighted while a tool from the profile menu
  // is open.
  var _bottomTab = 0;
  DateTime? _lastBackPress;
  var _lockChecking = true;
  var _locked = false;
  var _biometricEnabled = false;
  String? _unlockError;
  final _lockPin = TextEditingController();
  bool _checkingPin = false;
  Timer? _syncTimer;
  ProviderSubscription<AsyncValue<SyncQueueStatus>>? _syncQueueSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAppLock();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final notifService = ref.read(notificationServiceProvider);
        await notifService.init(
          onSelect: (payload, actionId) {
            if (mounted) _handleNotificationPayload(payload, actionId);
          },
        );
        final launchDetails = await notifService.getLaunchDetails();
        if (launchDetails != null &&
            launchDetails.didNotificationLaunchApp &&
            launchDetails.notificationResponse != null) {
          final res = launchDetails.notificationResponse!;
          if (res.payload != null && mounted) {
            _handleNotificationPayload(res.payload!, res.actionId);
          }
        }
        await notifService.reconcileAllReminders();
        if (mounted) {
          await notifService.requestPermissionWithExplainer(context);
        }
      } catch (_) {}
    });
    if (AppEnvironment.cloudConfigured) {
      _syncQueueSubscription = ref.listenManual<AsyncValue<SyncQueueStatus>>(
        syncQueueStatusProvider(widget.session.activeBusinessId!),
        (previous, next) {
          final before = previous?.value?.pending ?? 0;
          final now = next.value?.pending ?? 0;
          if (now > 0 && now > before) _syncNow();
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // Rehydrate the account on every authenticated app start, including
        // sign-out/sign-in cycles where local data already exists.
        try {
          await ref.read(syncWorkerProvider).restoreAccount();
        } catch (_) {
          // Keep the app usable offline; the normal sync retry will handle
          // connectivity failures when the device is online.
        }
        if (mounted) _syncNow();
      });
      _syncTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _syncNow(),
      );
    }
  }

  void _openOverdueSheet() {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OverdueInvoicesSheet(
        businessId: widget.session.activeBusinessId!,
      ),
    );
  }

  void _openReportsTab() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _tab = 6);
  }

  void _handleNotificationPayload(String payloadStr, [String? actionId]) {
    try {
      final data = jsonDecode(payloadStr) as Map<String, dynamic>;
      final action = actionId ?? (data['action'] as String?);
      if (action == 'view_overdue' ||
          (action == NotificationActionKeys.viewInvoice &&
              data['invoiceId'] == null)) {
        _openOverdueSheet();
      } else if (action == NotificationActionKeys.viewSummary ||
          action == 'view_summary' ||
          action == 'view_reports') {
        _openReportsTab();
      }
    } catch (_) {}
  }

  void _syncNow() {
    if (!mounted) return;
    ref.read(syncWorkerProvider).syncBusiness(widget.session.activeBusinessId!);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncQueueSubscription?.close();
    _syncTimer?.cancel();
    _lockPin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final security = ref.read(securityServiceProvider);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      security.markBackgrounded();
    }
    if (state == AppLifecycleState.resumed) {
      _syncNow();
      security.shouldLockOnResume().then((shouldLock) {
        if (shouldLock && mounted) _checkAppLock(lockIfEnabled: true);
      });
    }
  }

  Future<void> _checkAppLock({bool lockIfEnabled = false}) async {
    final service = ref.read(securityServiceProvider);
    bool enabled = false;
    bool biometric = false;
    try {
      enabled = await service.isPinEnabled();
      biometric = await service.isBiometricEnabled();
    } catch (_) {
      if (mounted) {
        setState(() => _lockChecking = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'App lock storage is unavailable. Please disable and enable App Lock again.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _lockChecking = false;
      _biometricEnabled = biometric;
      if (enabled && (lockIfEnabled || !_locked)) _locked = true;
    });
    if (enabled && biometric && mounted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryBiometricUnlock(),
      );
    }
  }

  Future<void> _tryBiometricUnlock() async {
    if (!_locked || _checkingPin) return;
    final ok = await ref.read(securityServiceProvider).authenticateBiometrics();
    if (ok && mounted) {
      await ref.read(securityServiceProvider).markAuthenticated();
      setState(() => _locked = false);
    }
  }

  Future<void> _unlock() async {
    if (_checkingPin || _lockPin.text.trim().isEmpty) return;
    final value = _lockPin.text.trim();
    setState(() {
      _checkingPin = true;
      _unlockError = null;
    });
    try {
      if (await ref.read(securityServiceProvider).verifyPin(value)) {
        if (!mounted) return;
        await ref.read(securityServiceProvider).markAuthenticated();
        setState(() => _locked = false);
        return;
      }
      if (mounted) {
        setState(() => _unlockError = 'Incorrect PIN. Please try again.');
        _lockPin.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Incorrect PIN. Please try again.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not read the app PIN. Disable and enable App Lock again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingPin = false);
    }
  }

  void _onLockPinChanged(String value) async {
    final length = await ref.read(securityServiceProvider).pinLength();
    if (mounted && length != null && value.length == length) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted && _lockPin.text.length == length) _unlock();
    }
  }

  Future<void> _confirmDeleteBusiness(
    BuildContext context,
    BusinessesData business,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          size: 40,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text('${_tr(context, "Delete business")} "${business.name}"?'),
        content: Text(
          _tr(
            context,
            'Warning: Are you sure you want to delete this business? All associated customers, invoices, inventory, and transaction history will be removed. This action cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_tr(context, 'Delete Business')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(businessRepositoryProvider)
          .deleteBusiness(businessId: business.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_tr(context, "Business deleted:")} ${business.name}',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _cleanErrorMessage(error, 'Could not delete business'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_lockChecking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_locked) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 52),
              const SizedBox(height: 12),
              const Text('Unlock OneBill'),
              const SizedBox(height: 16),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _lockPin,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(labelText: 'Enter PIN'),
                  onChanged: _onLockPinChanged,
                  onSubmitted: (_) => _unlock(),
                ),
              ),
              FilledButton.icon(
                onPressed: _checkingPin ? null : _unlock,
                icon: const Icon(Icons.lock_open),
                label: Text(_checkingPin ? 'Checking...' : 'Unlock with PIN'),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                child: _unlockError == null
                    ? const SizedBox(height: 24)
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _unlockError!,
                          key: ValueKey(_unlockError),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              if (_biometricEnabled)
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await ref
                        .read(securityServiceProvider)
                        .authenticateBiometrics();
                    if (ok && mounted) {
                      await ref
                          .read(securityServiceProvider)
                          .markAuthenticated();
                      setState(() => _locked = false);
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Biometric authentication was cancelled or unavailable.',
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Use Biometric'),
                ),
            ],
          ),
        ),
      );
    }
    final session = widget.session;
    final customers = ref.watch(customersProvider(session.activeBusinessId!));
    final syncStatus = ref.watch(
      syncQueueStatusProvider(session.activeBusinessId!),
    );
    final summary = ref.watch(
      businessBillingSummaryProvider(session.activeBusinessId!),
    );
    final inventory = ref.watch(
      inventoryProductsProvider(session.activeBusinessId!),
    );
    final businesses = ref.watch(businessesProvider(session.accountId!));
    final activeName = businesses.maybeWhen(
      data: (items) => items
          .where((business) => business.id == session.activeBusinessId)
          .map((business) => business.name)
          .firstOrNull,
      orElse: () => null,
    );
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBackPressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(activeName ?? 'OneBill'),
          actions: [
            if (AppEnvironment.cloudConfigured)
              IconButton(
                tooltip: 'Sync status',
                icon: Icon(
                  syncStatus.maybeWhen(
                    data: (status) => status.failed > 0
                        ? Icons.sync_problem_outlined
                        : status.pending > 0
                        ? Icons.cloud_upload_outlined
                        : Icons.cloud_done_outlined,
                    orElse: () => Icons.cloud_off_outlined,
                  ),
                ),
                onPressed: () {
                  _syncNow();
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        _SyncQueueSheet(businessId: session.activeBusinessId!),
                  );
                },
              ),
            businesses.maybeWhen(
              data: (items) => PopupMenuButton<String>(
                tooltip: _tr(context, 'Switch business'),
                icon: const Icon(Icons.storefront_outlined),
                onSelected: (value) {
                  if (value == '__add_business__') {
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) =>
                          _AddBusinessSheet(accountId: session.accountId!),
                    );
                  } else if (value == '__delete_business__') {
                    final currentBiz = items.firstWhere(
                      (business) => business.id == session.activeBusinessId,
                      orElse: () => items.first,
                    );
                    _confirmDeleteBusiness(context, currentBiz);
                  } else {
                    ref
                        .read(businessRepositoryProvider)
                        .switchBusiness(
                          sessionId: session.id,
                          businessId: value,
                        );
                  }
                },
                itemBuilder: (context) => [
                  ...items.map(
                    (business) => CheckedPopupMenuItem(
                      value: business.id,
                      checked: business.id == session.activeBusinessId,
                      child: Text(business.name),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: '__add_business__',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.add_business_outlined),
                      title: Text(_tr(context, 'Add new business')),
                    ),
                  ),
                  if (items.isNotEmpty) ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: '__delete_business__',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.delete_forever_outlined,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        title: Text(
                          _tr(context, 'Delete current business'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            NotificationBellIcon(
              businessId: session.activeBusinessId,
              onOpenOverdue: _openOverdueSheet,
              onOpenReports: _openReportsTab,
            ),
            PopupMenuButton<String>(
              tooltip: 'Profile and tools',
              icon: const Icon(Icons.account_circle_outlined),
              position: PopupMenuPosition.under,
              onSelected: (value) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  switch (value) {
                    case 'business_profile':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BusinessProfileScreen(
                            businessId: session.activeBusinessId!,
                          ),
                        ),
                      );
                      break;
                    case 'settings':
                      final active = businesses.valueOrNull
                          ?.where(
                            (business) =>
                                business.id == session.activeBusinessId,
                          )
                          .firstOrNull;
                      if (active != null) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                _BusinessSettingsSheet(business: active),
                          ),
                        );
                      }
                      break;
                    case 'recycle_bin':
                      setState(() => _tab = 4);
                      break;
                    case 'activity':
                      setState(() => _tab = 5);
                      break;
                    case 'reports':
                      setState(() => _tab = 6);
                      break;
                    case 'sign_out':
                      _confirmSignOut(context, ref);
                      break;
                  }
                });
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'business_profile',
                  child: _ProfileMenuItem(
                    icon: Icons.storefront_outlined,
                    label: 'Business Profile',
                  ),
                ),
                const PopupMenuItem(
                  value: 'settings',
                  child: _ProfileMenuItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                  ),
                ),
                const PopupMenuItem(
                  value: 'recycle_bin',
                  child: _ProfileMenuItem(
                    icon: Icons.delete_sweep_outlined,
                    label: 'Recycle bin',
                  ),
                ),
                const PopupMenuItem(
                  value: 'activity',
                  child: _ProfileMenuItem(
                    icon: Icons.history_outlined,
                    label: 'Activity',
                  ),
                ),
                const PopupMenuItem(
                  value: 'reports',
                  child: _ProfileMenuItem(
                    icon: Icons.insights_outlined,
                    label: 'Reports',
                  ),
                ),
                if (AppEnvironment.cloudConfigured) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'sign_out',
                    child: _ProfileMenuItem(
                      icon: Icons.logout,
                      label: 'Sign out',
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(
            key: ValueKey<int>(_tab),
            child: _tab == 0
                ? _DashboardTab(
                    businessId: session.activeBusinessId!,
                    customers: customers,
                    summary: summary,
                    inventory: inventory,
                    onShowCustomers: () => setState(() {
                      _tab = 1;
                      _bottomTab = 1;
                    }),
                  )
                : _tab == 1
                ? _CustomersTab(
                    businessId: session.activeBusinessId!,
                    customers: customers,
                  )
                : _tab == 2
                ? _IncomeTab(businessId: session.activeBusinessId!)
                : _tab == 3
                ? _ExpensesTab(businessId: session.activeBusinessId!)
                : _tab == 4
                ? _RecycleBinTab(businessId: session.activeBusinessId!)
                : _tab == 5
                ? _ActivityTab(businessId: session.activeBusinessId!)
                : _ReportsTab(
                    businessId: session.activeBusinessId!,
                    summary: summary,
                    customers: customers,
                  ),
          ),
        ),
        floatingActionButton: (_tab >= 4)
            ? null
            : _tab == 2
            ? FloatingActionButton.extended(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      _IncomeEditor(businessId: session.activeBusinessId!),
                ),
                icon: const Icon(Icons.add),
                label: Text(_tr(context, 'Add income')),
              )
            : _tab == 3
            ? FloatingActionButton.extended(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      _ExpenseEditor(businessId: session.activeBusinessId!),
                ),
                icon: const Icon(Icons.add),
                label: Text(_tr(context, 'Add expense')),
              )
            : FloatingActionButton.extended(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      _AddCustomerSheet(businessId: session.activeBusinessId!),
                ),
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(_tr(context, 'Add customer')),
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _bottomTab,
          onDestinationSelected: (value) => setState(() {
            _tab = value;
            _bottomTab = value;
          }),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: _tr(context, 'Dashboard'),
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: _tr(context, 'Customers'),
            ),
            NavigationDestination(
              icon: Icon(Icons.attach_money_outlined),
              selectedIcon: Icon(Icons.attach_money),
              label: _tr(context, 'Income'),
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet),
              label: _tr(context, 'Expenses'),
            ),
          ],
        ),
      ),
    );
  }

  void _handleBackPressed() {
    final now = DateTime.now();
    final isSecondPress =
        _lastBackPress != null &&
        now.difference(_lastBackPress!) <= const Duration(seconds: 2);
    if (isSecondPress) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPress = now;
    if (_tab != 0) {
      setState(() {
        _tab = 0;
        _bottomTab = 0;
      });
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(_tr(context, 'Press back again to exit OneBill')),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Sign out?')),
        content: Text(
          _tr(context, 'You will need internet to sign in again. Local business data remains protected on this device.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_tr(context, 'Sign out')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final auth = ref.read(authServiceProvider);
      final db = ref.read(databaseProvider);
      ref.read(isSigningOutProvider.notifier).state = true;
      try {
        await auth.signOut();
      } catch (_) {}
      try {
        await db.clearAllTables();
      } catch (_) {}
      if (mounted) {
        ref.invalidate(sessionProvider);
        ref.invalidate(authSessionProvider);
      }
    }
  }
}

Future<void> _configurePin(BuildContext context, WidgetRef ref) async {
  bool enabled;
  try {
    enabled = await ref.read(securityServiceProvider).isPinEnabled();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(context, 'App lock storage is unavailable. Please restart the app and try again.'),
          ),
        ),
      );
    }
    return;
  }
  if (!context.mounted) return;
  if (enabled) {
    final authenticated = await _authenticateForSecurity(context, ref);
    if (!authenticated || !context.mounted) return;
    await Future<void>.delayed(Duration.zero);
    if (!context.mounted) return;
  }
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _PinSetupDialog(enabled: enabled),
  );
  if (result != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == 'disabled'
              ? _tr(context, 'App lock disabled')
              : _tr(context, 'App lock PIN saved'),
        ),
      ),
    );
  }
}

Future<bool> _authenticateForSecurity(
  BuildContext context,
  WidgetRef ref,
) async {
  final service = ref.read(securityServiceProvider);
  if (await service.isBiometricEnabled() &&
      await service.authenticateBiometrics()) {
    return true;
  }
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const _ConfirmPinDialog(),
  );
  return result == true;
}

class _PinSetupDialog extends ConsumerStatefulWidget {
  const _PinSetupDialog({required this.enabled});
  final bool enabled;

  @override
  ConsumerState<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends ConsumerState<_PinSetupDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _stepBiometric = false;
  bool _saving = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    final value = _pin.text.trim();
    final confirmation = _confirm.text.trim();
    if (!RegExp(r'^\d{4,6}$').hasMatch(value)) {
      setState(() => _error = 'PIN must contain 4 to 6 digits.');
      return;
    }
    if (value != confirmation) {
      setState(() => _error = "PINs don't match. Please try again.");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(securityServiceProvider).setPin(value);
      final available = await ref
          .read(securityServiceProvider)
          .biometricAvailable();
      if (available && mounted) {
        setState(() {
          _saving = false;
          _stepBiometric = true;
        });
      } else if (mounted) {
        Navigator.pop(context, 'saved');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save PIN: $e';
        });
      }
    }
  }

  Future<void> _setBiometric(bool enable) async {
    setState(() => _saving = true);
    try {
      await ref.read(securityServiceProvider).setBiometricEnabled(enable);
      if (mounted) Navigator.pop(context, 'saved');
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not update biometric setting: $e';
        });
      }
    }
  }

  Future<void> _disableAppLock() async {
    setState(() => _saving = true);
    try {
      await ref.read(securityServiceProvider).clearPin();
      await ref.read(securityServiceProvider).setBiometricEnabled(false);
      if (mounted) Navigator.pop(context, 'disabled');
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not disable app lock: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_stepBiometric) {
      return AlertDialog(
        title: const Text('Use Biometric?'),
        content: const Text(
          'Biometric will be the primary unlock method. Your PIN remains available as a fallback.',
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _setBiometric(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: _saving ? null : () => _setBiometric(true),
            child: Text(_saving ? 'Saving...' : 'Enable'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(widget.enabled ? 'Change PIN' : 'Secure OneBill'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Choose a secure 4–6 digit PIN for offline unlock.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Create PIN'),
          ),
          TextField(
            controller: _confirm,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Confirm PIN'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.enabled)
          TextButton(
            onPressed: _saving ? null : _disableAppLock,
            child: const Text('Disable'),
          ),
        FilledButton(
          onPressed: _saving ? null : _savePin,
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class _ConfirmPinDialog extends ConsumerStatefulWidget {
  const _ConfirmPinDialog();
  @override
  ConsumerState<_ConfirmPinDialog> createState() => _ConfirmPinDialogState();
}

class _ConfirmPinDialogState extends ConsumerState<_ConfirmPinDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _pin.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ok = await ref.read(securityServiceProvider).verifyPin(value);
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _checking = false;
          _error = 'Incorrect PIN. Please try again.';
          _pin.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'Could not verify PIN.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Confirm your PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Enter PIN'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _checking ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _checking ? null : _submit,
            child: Text(_checking ? 'Checking...' : 'Continue'),
          ),
        ],
      );
}

class _ProfileMenuItem extends StatelessWidget {
  const _ProfileMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 12),
      Text(_tr(context, label)),
    ],
  );
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({
    required this.businessId,
    required this.customers,
    required this.summary,
    required this.onShowCustomers,
    required this.inventory,
  });
  final String businessId;
  final AsyncValue<List<Customer>> customers;
  final AsyncValue<BillingSummary> summary;
  final VoidCallback onShowCustomers;
  final AsyncValue<List<InventoryProduct>> inventory;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        _tr(context, 'Business overview'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text(
        _tr(
          context,
          'All figures are calculated from data saved on this device.',
        ),
      ),
      const SizedBox(height: 20),
      if (summary.valueOrNull?.overduePaise case final overdue?
          when overdue > 0)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.warning_amber),
            title: Text(_tr(context, 'Overdue invoices')),
            subtitle: Text(
              _tr(context, '{amount} remains overdue. Tap to view and review payment status.').replaceAll('{amount}', _rupees(overdue)),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => _OverdueInvoicesSheet(
                businessId: businessId,
              ),
            ),
          ),
        ),
      inventory.whenOrNull(
            data: (items) {
              final low = items
                  .where(
                    (p) => p.stockMilliunits <= p.lowStockThresholdMilliunits,
                  )
                  .length;
              if (low == 0) return const SizedBox.shrink();
              return Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(_tr(context, 'Low-stock alert')),
                  subtitle: Text(
                    _tr(context, '{count} product(s) need restocking.').replaceAll('{count}', '$low'),
                  ),
                ),
              );
            },
          ) ??
          const SizedBox.shrink(),
      const SizedBox(height: 8),
      summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Text('Unable to load billing totals: $error'),
        data: (data) => Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: 'Billed',
                    value: _rupees(data.totalBilledPaise),
                    icon: Icons.receipt_long_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    label: 'Received',
                    value: _rupees(data.totalReceivedPaise),
                    icon: Icons.account_balance_wallet_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: 'Outstanding',
                    value: _rupees(data.totalOutstandingPaise),
                    icon: Icons.payments_outlined,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _OverdueInvoicesSheet(
                        businessId: businessId,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    label: 'Invoices',
                    value: '${data.invoiceCount}',
                    icon: Icons.description_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: 'Overdue',
                    value: _rupees(data.overduePaise),
                    icon: Icons.warning_amber_outlined,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _OverdueInvoicesSheet(
                        businessId: businessId,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    label: 'Collection rate',
                    value: data.totalBilledPaise == 0
                        ? '—'
                        : '${(data.totalReceivedPaise * 100 / data.totalBilledPaise).round()}%',
                    icon: Icons.trending_up_outlined,
                  ),
                ),
              ],
            ),
            if (data.overdueInvoiceCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _OverdueInvoicesSheet(
                      businessId: businessId,
                    ),
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${data.overdueInvoiceCount} invoice${data.overdueInvoiceCount == 1 ? '' : 's'} overdue',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      customers.when(
        loading: () => const SizedBox.shrink(),
        error: (error, _) => Text('Unable to load customers: $error'),
        data: (items) => Card(
          child: ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(_tr(context, 'Customers')),
            subtitle: Text(
              '${items.length} ${_tr(context, items.length == 1 ? 'active customer' : 'active customers')}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onShowCustomers,
          ),
        ),
      ),
    ],
  );
}

enum _IncomeSourceType { customer, owner }

class _CombinedIncomeItem {
  _CombinedIncomeItem.fromPayment(Payment p)
      : payment = p,
        ownerEntry = null,
        sourceType = _IncomeSourceType.customer,
        date = p.receivedAt,
        amountPaise = p.amountPaise;

  _CombinedIncomeItem.fromOwnerEntry(IncomeEntry o)
      : payment = null,
        ownerEntry = o,
        sourceType = _IncomeSourceType.owner,
        date = o.incomeDate,
        amountPaise = o.amountPaise;

  final Payment? payment;
  final IncomeEntry? ownerEntry;
  final _IncomeSourceType sourceType;
  final DateTime date;
  final int amountPaise;
}

class _IncomeTab extends ConsumerStatefulWidget {
  const _IncomeTab({required this.businessId});
  final String businessId;
  @override
  ConsumerState<_IncomeTab> createState() => _IncomeTabState();
}

class _IncomeTabState extends ConsumerState<_IncomeTab> {
  final search = TextEditingController();
  String _filterSource = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paymentsAsync = ref.watch(businessPaymentsProvider(widget.businessId));
    final ownerIncomeAsync = ref.watch(incomeEntriesProvider(widget.businessId));

    if (paymentsAsync.isLoading || ownerIncomeAsync.isLoading) {
      return const _SkeletonListLoader();
    }
    if (paymentsAsync.hasError) {
      return Center(child: Text('Unable to load customer payments.\n${paymentsAsync.error}'));
    }
    if (ownerIncomeAsync.hasError) {
      return Center(child: Text('Unable to load owner income entries.\n${ownerIncomeAsync.error}'));
    }

    final customerPayments = paymentsAsync.valueOrNull ?? [];
    final ownerEntries = ownerIncomeAsync.valueOrNull ?? [];

    final customerTotal = customerPayments.fold<int>(0, (s, e) => s + e.amountPaise);
    final ownerTotal = ownerEntries.fold<int>(0, (s, e) => s + e.amountPaise);
    final grandTotal = customerTotal + ownerTotal;

    final allCombined = <_CombinedIncomeItem>[
      ...customerPayments.map(_CombinedIncomeItem.fromPayment),
      ...ownerEntries.map(_CombinedIncomeItem.fromOwnerEntry),
    ]..sort((a, b) => b.date.compareTo(a.date));

    final query = search.text.trim().toLowerCase();
    final sourceFiltered = allCombined.where((item) {
      if (_filterSource == 'customer' && item.sourceType != _IncomeSourceType.customer) {
        return false;
      }
      if (_filterSource == 'owner' && item.sourceType != _IncomeSourceType.owner) {
        return false;
      }
      return true;
    }).toList();

    final filtered = query.isEmpty
        ? sourceFiltered
        : sourceFiltered.where((item) {
            final amountStr = _rupees(item.amountPaise).toLowerCase();
            final dateStr = _date(item.date).toLowerCase();
            if (item.sourceType == _IncomeSourceType.customer) {
              final p = item.payment!;
              return p.method.toLowerCase().contains(query) ||
                  (p.note ?? '').toLowerCase().contains(query) ||
                  amountStr.contains(query) ||
                  dateStr.contains(query);
            } else {
              final o = item.ownerEntry!;
              return (o.description ?? '').toLowerCase().contains(query) ||
                  amountStr.contains(query) ||
                  dateStr.contains(query);
            }
          }).toList();

    final months = <DateTime, List<_CombinedIncomeItem>>{};
    for (final item in filtered) {
      final monthKey = DateTime(item.date.year, item.date.month);
      (months[monthKey] ??= []).add(item);
    }
    final sortedMonths = months.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _tr(context, 'Income'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(_tr(context, 'Track customer payments and manual owner entries.')),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: _tr(context, 'Customer'),
                value: _rupees(customerTotal),
                icon: Icons.people_outline,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _MetricCard(
                label: _tr(context, 'Owner added'),
                value: _rupees(ownerTotal),
                icon: Icons.person_add_alt_1_outlined,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _MetricCard(
                label: _tr(context, 'Total income'),
                value: _rupees(grandTotal),
                icon: Icons.trending_up_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildFilterChip(
                context: context,
                key: 'all',
                label: _tr(context, 'All'),
                count: allCombined.length,
                icon: Icons.all_inbox_outlined,
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                context: context,
                key: 'customer',
                label: _tr(context, 'Customer'),
                count: customerPayments.length,
                icon: Icons.people_outline,
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                context: context,
                key: 'owner',
                label: _tr(context, 'Owner Added'),
                count: ownerEntries.length,
                icon: Icons.person_add_alt_1_outlined,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: _tr(context, 'Search income records'),
            suffixIcon: const Icon(Icons.tune_outlined),
          ),
        ),
        const SizedBox(height: 16),
        if (months.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  _filterSource == 'owner'
                      ? _tr(context, 'No manual owner income entries added yet. Tap "+ Add Income" above to add one.')
                      : _filterSource == 'customer'
                          ? _tr(context, 'No customer payments recorded yet.')
                          : _tr(context, 'No income records found.'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ...sortedMonths.map((entry) {
          final monthTotal = entry.value.fold<int>(0, (s, e) => s + e.amountPaise);
          final custCount = entry.value.where((e) => e.sourceType == _IncomeSourceType.customer).length;
          final ownerCount = entry.value.where((e) => e.sourceType == _IncomeSourceType.owner).length;
          return Card(
            child: ListTile(
              title: Text(_monthLabel(entry.key)),
              subtitle: Text(
                '${_rupees(monthTotal)} • $custCount ${_tr(context, 'Customer')} • $ownerCount ${_tr(context, 'Owner added')}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => _IncomeMonthSheet(
                  businessId: widget.businessId,
                  month: entry.key,
                  items: entry.value,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildFilterChip({
    required BuildContext context,
    required String key,
    required String label,
    required int count,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final isSelected = _filterSource == key;
    final primary = theme.colorScheme.primary;
    final onPrimary = theme.colorScheme.onPrimary;
    final containerColor = theme.colorScheme.surfaceContainerHighest;
    final onSurface = theme.colorScheme.onSurface;

    return ChoiceChip(
      avatar: Icon(
        icon,
        size: 18,
        color: isSelected ? onPrimary : primary,
      ),
      label: Text(
        '$label ($count)',
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? onPrimary : onSurface,
          fontSize: 13,
        ),
      ),
      selected: isSelected,
      selectedColor: primary,
      backgroundColor: containerColor,
      showCheckmark: false,
      side: BorderSide(
        color: isSelected ? primary : theme.colorScheme.outline.withOpacity(0.3),
      ),
      onSelected: (_) => setState(() => _filterSource = key),
    );
  }
}

class _IncomeMonthSheet extends StatelessWidget {
  const _IncomeMonthSheet({
    required this.businessId,
    required this.month,
    required this.items,
  });
  final String businessId;
  final DateTime month;
  final List<_CombinedIncomeItem> items;

  @override
  Widget build(BuildContext context) {
    final days = <DateTime, List<_CombinedIncomeItem>>{};
    for (final item in items) {
      final day = DateTime(
        item.date.year,
        item.date.month,
        item.date.day,
      );
      (days[day] ??= []).add(item);
    }
    final total = items.fold<int>(0, (sum, item) => sum + item.amountPaise);

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, controller) {
          final theme = Theme.of(context);
          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _monthLabel(month),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_tr(context, 'Total income')}: ${_rupees(total)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${items.length} ${items.length == 1 ? _tr(context, 'Entry') : _tr(context, 'Entries')}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...days.entries.map((entry) {
                final dayTotal = entry.value.fold<int>(
                  0,
                  (sum, item) => sum + item.amountPaise,
                );
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                  ),
                  child: Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                      title: Text(
                        _date(entry.key),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      subtitle: Text(
                        '${_tr(context, 'Day Total')}: ${_rupees(dayTotal)} • ${entry.value.length} ${entry.value.length == 1 ? _tr(context, 'entry') : _tr(context, 'entries')}',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                      ),
                      children: entry.value.map((item) {
                        final isCust = item.sourceType == _IncomeSourceType.customer;
                        final p = item.payment;
                        final o = item.ownerEntry;
                        final method = isCust ? _formatTitleCase(p?.method ?? 'Cash') : _tr(context, 'Owner Entry');
                        final note = isCust ? p?.note : o?.description;
                        final timeStr = TimeOfDay.fromDateTime(item.date).format(context);

                        return Container(
                          margin: const EdgeInsets.only(top: 8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _showIncomeDetailSheet(context, businessId: businessId, item: item),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor: isCust
                                          ? Colors.teal.withValues(alpha: 0.15)
                                          : theme.colorScheme.primary.withValues(alpha: 0.15),
                                      child: Icon(
                                        isCust ? Icons.receipt_long_outlined : Icons.person_add_alt_1_outlined,
                                        color: isCust ? Colors.teal : theme.colorScheme.primary,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                isCust ? _tr(context, 'Customer Payment') : _tr(context, 'Owner Entry'),
                                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                                decoration: BoxDecoration(
                                                  color: isCust
                                                      ? Colors.teal.withValues(alpha: 0.12)
                                                      : theme.colorScheme.primary.withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  method,
                                                  style: TextStyle(
                                                    color: isCust ? Colors.teal : theme.colorScheme.primary,
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            note != null && note.trim().isNotEmpty
                                                ? '$timeStr • ${_formatTitleCase(note.trim())}'
                                                : timeStr,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: theme.colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '+ ${_rupees(item.amountPaise)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isCust ? Colors.teal : theme.colorScheme.primary,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.outline),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

String _formatTitleCase(String text) {
  if (text.trim().isEmpty) return text;
  return text.trim().split(' ').map((word) {
    if (word.isEmpty) return word;
    return word[0].toUpperCase() + word.substring(1).toLowerCase();
  }).join(' ');
}

void _showIncomeDetailSheet(
  BuildContext context, {
  required String businessId,
  required _CombinedIncomeItem item,
}) {
  final isCustomer = item.sourceType == _IncomeSourceType.customer;
  final p = item.payment;
  final o = item.ownerEntry;

  final title = isCustomer
      ? '${_tr(context, 'Customer Payment')}${p?.method != null ? ' (${_formatTitleCase(p!.method)})' : ''}'
      : (o?.description != null && o!.description!.trim().isNotEmpty)
          ? _formatTitleCase(o.description!)
          : _tr(context, 'Owner Entry');

  final formattedDate = '${_date(item.date)} at ${TimeOfDay.fromDateTime(item.date).format(context)}';
  final note = isCustomer ? p?.note : o?.description;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: isCustomer
                        ? Colors.teal.withValues(alpha: 0.15)
                        : theme.primaryColor.withValues(alpha: 0.15),
                    radius: 22,
                    child: Icon(
                      isCustomer ? Icons.receipt_long_outlined : Icons.person_add_alt_1_outlined,
                      color: isCustomer ? Colors.teal : theme.primaryColor,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isCustomer
                                ? Colors.teal.withValues(alpha: 0.12)
                                : theme.primaryColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isCustomer ? _tr(context, 'Customer Payment') : _tr(context, 'Owner Entry'),
                            style: TextStyle(
                              color: isCustomer ? Colors.teal : theme.primaryColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _tr(context, 'Amount Received'),
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                          ),
                          Text(
                            '+ ${_rupees(item.amountPaise)}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isCustomer ? Colors.teal : theme.primaryColor,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _tr(context, 'Date & Time'),
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                          ),
                          Text(formattedDate, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ],
                      ),
                      if (isCustomer && p?.method != null) ...[
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _tr(context, 'Payment Method'),
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                            ),
                            Text(
                              _formatTitleCase(p!.method),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _tr(context, 'Description / Notes'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
                ),
                child: Text(
                  (note != null && note.trim().isNotEmpty)
                      ? _formatTitleCase(note.trim())
                      : (isCustomer ? _tr(context, 'Payment received for customer invoice.') : _tr(context, 'Manual income recorded by owner.')),
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                ),
              ),
              const SizedBox(height: 24),
              if (!isCustomer && o != null) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => _IncomeEditor(
                              businessId: businessId,
                              income: o,
                            ),
                          );
                        },
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(_tr(context, 'Edit Entry')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(_tr(context, 'Close')),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(_tr(context, 'Close')),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _IncomeEditor extends ConsumerStatefulWidget {
  const _IncomeEditor({required this.businessId, this.income});
  final String businessId;
  final IncomeEntry? income;
  @override
  ConsumerState<_IncomeEditor> createState() => _IncomeEditorState();
}

class _IncomeEditorState extends ConsumerState<_IncomeEditor> {
  late final TextEditingController amount, description;
  late DateTime date;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.income == null
          ? ''
          : (widget.income!.amountPaise / 100).toStringAsFixed(2),
    );
    description = TextEditingController(text: widget.income?.description ?? '');
    date = widget.income?.incomeDate ?? DateTime.now();
  }

  @override
  void dispose() {
    amount.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final paise = _parseOptionalRupees(amount.text);
    if (paise <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr(context, 'Enter an amount greater than zero.'))),
      );
      return;
    }
    setState(() => saving = true);
    try {
      final repo = ref.read(incomeRepositoryProvider);
      if (widget.income == null) {
        await repo.add(
          businessId: widget.businessId,
          amountPaise: paise,
          description: description.text,
          incomeDate: date,
        );
      } else {
        await repo.update(
          businessId: widget.businessId,
          id: widget.income!.id,
          amountPaise: paise,
          description: description.text,
          incomeDate: date,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(e, _tr(context, 'Failed to save income')))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr(context, 'Delete income entry?')),
        content: Text(_tr(context, 'Are you sure you want to delete this manual income entry?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(_tr(context, 'Delete')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => saving = true);
    try {
      await ref.read(incomeRepositoryProvider).delete(
        businessId: widget.businessId,
        id: widget.income!.id,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(e, 'Failed to delete income'))),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool get _isDirty =>
      amount.text.isNotEmpty ||
      description.text.isNotEmpty;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isDirty || saving,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final discard = await _showDiscardChangesDialog(context);
      if (discard && context.mounted) {
        Navigator.pop(context);
      }
    },
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            widget.income == null ? 'Add income' : 'Edit income',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (₹)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: description,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Income date'),
            subtitle: Text(_date(date)),
            onTap: saving
                ? null
                : () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null && mounted) setState(() => date = picked);
                  },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.income != null)
                OutlinedButton.icon(
                  onPressed: saving ? null : delete,
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              if (widget.income != null) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: saving ? null : save,
                  child: Text(
                    saving
                        ? 'Saving...'
                        : (widget.income == null ? 'Save income' : 'Update income'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ExpensesTab extends ConsumerStatefulWidget {
  const _ExpensesTab({required this.businessId});
  final String businessId;
  @override
  ConsumerState<_ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends ConsumerState<_ExpensesTab> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(expensesProvider(widget.businessId))
      .when(
        loading: () => const _SkeletonListLoader(),
        error: (e, _) => Center(child: Text('Unable to load expenses.\n$e')),
        data: (all) {
          final q = search.text.toLowerCase().trim();
          final list = q.isEmpty
              ? all
              : all
                    .where(
                      (e) =>
                          e.category.toLowerCase().contains(q) ||
                          (e.description ?? '').toLowerCase().contains(q) ||
                          e.amountPaise.toString().contains(q),
                    )
                    .toList();
          final total = all.fold<int>(0, (s, e) => s + e.amountPaise);
          final now = DateTime.now();
          final month = all
              .where(
                (e) =>
                    e.expenseDate.year == now.year &&
                    e.expenseDate.month == now.month,
              )
              .fold<int>(0, (s, e) => s + e.amountPaise);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                _tr(context, 'Expenses'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(_tr(context, 'Track your business spending.')),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'This month',
                      value: _rupees(month),
                      icon: Icons.calendar_month_outlined,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricCard(
                      label: 'Total',
                      value: _rupees(total),
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  labelText: _tr(context, 'Search expenses'),
                ),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(_tr(context, 'No expenses recorded yet.')),
                    ),
                  ),
                )
              else
                ...list.map(
                  (expense) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(_rupees(expense.amountPaise)),
                      subtitle: Text(
                        '${expense.category}${expense.description == null ? '' : ' • ${expense.description}'}\n${_date(expense.expenseDate)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'edit') {
                            await showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => _ExpenseEditor(
                                businessId: widget.businessId,
                                expense: expense,
                              ),
                            );
                          } else {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (d) => AlertDialog(
                                title: Text(_tr(context, 'Delete expense?')),
                                content: Text(
                                  _tr(context, 'This action cannot be undone.'),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(d, false),
                                    child: Text(_tr(context, 'Cancel')),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(d, true),
                                    child: Text(_tr(context, 'Delete')),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await ref
                                  .read(expenseRepositoryProvider)
                                  .delete(
                                    businessId: widget.businessId,
                                    id: expense.id,
                                  );
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(_tr(context, 'Edit'))),
                          PopupMenuItem(value: 'delete', child: Text(_tr(context, 'Delete'))),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

class _ExpenseEditor extends ConsumerStatefulWidget {
  const _ExpenseEditor({required this.businessId, this.expense});
  final String businessId;
  final Expense? expense;
  @override
  ConsumerState<_ExpenseEditor> createState() => _ExpenseEditorState();
}

class _ExpenseEditorState extends ConsumerState<_ExpenseEditor> {
  late final TextEditingController amount, category, description;
  late DateTime date;
  bool saving = false;
  String? _amountError;
  String? _categoryError;

  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.expense == null
          ? ''
          : (widget.expense!.amountPaise / 100).toStringAsFixed(2),
    );
    category = TextEditingController(text: widget.expense?.category ?? '');
    description = TextEditingController(
      text: widget.expense?.description ?? '',
    );
    date = widget.expense?.expenseDate ?? DateTime.now();
  }

  @override
  void dispose() {
    amount.dispose();
    category.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = _parseOptionalRupees(amount.text);
    final hasAmountError = value <= 0;
    final hasCategoryError = category.text.trim().isEmpty;

    if (hasAmountError || hasCategoryError) {
      setState(() {
        _amountError = hasAmountError
            ? (amount.text.trim().isEmpty
                ? _tr(context, 'Amount is required')
                : _tr(context, 'Enter a valid amount and category.'))
            : null;
        _categoryError = hasCategoryError
            ? _tr(context, 'Category is required')
            : null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_tr(context, 'Please fill all mandatory fields (Amount and Category).')),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }
    setState(() {
      _amountError = null;
      _categoryError = null;
      saving = true;
    });
    try {
      final repo = ref.read(expenseRepositoryProvider);
      if (widget.expense == null) {
        await repo.add(
          businessId: widget.businessId,
          amountPaise: value,
          category: category.text,
          description: description.text,
          expenseDate: date,
        );
      } else {
        await repo.update(
          businessId: widget.businessId,
          id: widget.expense!.id,
          amountPaise: value,
          category: category.text,
          description: description.text,
          expenseDate: date,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(e, 'Could not save expense'))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool get _isDirty =>
      amount.text.isNotEmpty ||
      category.text.isNotEmpty ||
      description.text.isNotEmpty;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isDirty || saving,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final discard = await _showDiscardChangesDialog(context);
      if (discard && context.mounted) {
        Navigator.pop(context);
      }
    },
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            _tr(context, widget.expense == null ? 'Add expense' : 'Edit expense'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _tr(context, 'Amount (₹)'),
              errorText: _amountError,
            ),
            onChanged: (_) {
              if (_amountError != null) setState(() => _amountError = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: category,
            decoration: InputDecoration(
              labelText: _tr(context, 'Category'),
              errorText: _categoryError,
            ),
            onChanged: (_) {
              if (_categoryError != null) setState(() => _categoryError = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: description,
            decoration: InputDecoration(
              labelText: _tr(context, 'Description (optional)'),
            ),
          ),
          const SizedBox(height: 12),
          _DatePickerField(
            label: _tr(context, 'Expense date'),
            selectedDate: date,
            onTap: saving
                ? () {}
                : () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (d != null && mounted) setState(() => date = d);
                  },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: saving ? null : save,
            child: Text(saving ? _tr(context, 'Saving...') : _tr(context, 'Save expense')),
          ),
        ],
      ),
    ),
  );
}

class _InventoryTab extends ConsumerWidget {
  const _InventoryTab({required this.businessId});
  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(inventoryProductsProvider(businessId));
    return products.when(
      loading: () => const _SkeletonListLoader(),
      error: (error, _) => Center(
        child: Text(
          'Unable to load inventory.\n$error',
          textAlign: TextAlign.center,
        ),
      ),
      data: (items) => items.isEmpty
          ? const _EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No inventory yet',
              message: 'Add products to track stock and low-stock levels.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final product = items[index];
                final low =
                    product.stockMilliunits <=
                    product.lowStockThresholdMilliunits;
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        low ? Icons.warning_amber : Icons.inventory_2_outlined,
                      ),
                    ),
                    title: Text(product.name),
                    subtitle: Text(
                      '${product.stockMilliunits / 1000} ${product.unit}${low ? ' • ${_tr(context, 'Low stock')}' : ''}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'edit') {
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => _InventoryEditor(
                              businessId: businessId,
                              product: product,
                            ),
                          );
                        }
                        if (action == 'adjust') {
                          _adjustStock(context, ref, product);
                        }
                        if (action == 'delete') {
                          _deleteProduct(context, ref, product);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(_tr(context, 'Edit product')),
                        ),
                        PopupMenuItem(
                          value: 'adjust',
                          child: Text(_tr(context, 'Adjust stock')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(_tr(context, 'Delete product')),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _adjustStock(
    BuildContext context,
    WidgetRef ref,
    InventoryProduct product,
  ) async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    final result = await showDialog<(int, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_tr(context, 'Adjust stock')}: ${product.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: InputDecoration(
                labelText: _tr(context, 'Change stock'),
                hintText: 'Use -10 to remove stock',
              ),
            ),
            TextField(
              controller: reason,
              decoration: InputDecoration(labelText: _tr(context, 'Reason')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(amount.text.trim());
              if (value != null && value != 0) {
                Navigator.pop(context, (value * 1000, reason.text));
              }
            },
            child: Text(_tr(context, 'Save')),
          ),
        ],
      ),
    );
    amount.dispose();
    reason.dispose();
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .adjustStock(
            businessId: businessId,
            productId: product.id,
            deltaMilliunits: result.$1,
            reason: result.$2,
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not adjust stock'))));
      }
    }
  }

  Future<void> _deleteProduct(
    BuildContext context,
    WidgetRef ref,
    InventoryProduct product,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Delete product?')),
        content: Text(
          'Remove ${product.name} from active inventory? It can be restored from Recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_tr(context, 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .deleteProduct(businessId: businessId, id: product.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not delete product'))));
      }
    }
  }
}

class _InventoryEditor extends ConsumerStatefulWidget {
  const _InventoryEditor({required this.businessId, this.product});
  final String businessId;
  final InventoryProduct? product;
  @override
  ConsumerState<_InventoryEditor> createState() => _InventoryEditorState();
}

class _InventoryEditorState extends ConsumerState<_InventoryEditor> {
  final name = TextEditingController();
  final sku = TextEditingController();
  final stock = TextEditingController();
  final threshold = TextEditingController();
  final cost = TextEditingController();
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    if (p != null) {
      name.text = p.name;
      sku.text = p.sku ?? '';
      threshold.text = (p.lowStockThresholdMilliunits / 1000)
          .round()
          .toString();
      cost.text = (p.unitCostPaise / 100).toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    name.dispose();
    sku.dispose();
    stock.dispose();
    threshold.dispose();
    cost.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      (widget.product == null
          ? name.text.isNotEmpty ||
              sku.text.isNotEmpty ||
              stock.text.isNotEmpty ||
              threshold.text.isNotEmpty ||
              cost.text.isNotEmpty
          : name.text != widget.product!.name ||
              sku.text != (widget.product!.sku ?? '') ||
              threshold.text != (widget.product!.lowStockThresholdMilliunits / 1000).round().toString() ||
              cost.text != (widget.product!.unitCostPaise / 100).toStringAsFixed(2));

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isDirty || saving,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final discard = await _showDiscardChangesDialog(context);
      if (discard && context.mounted) {
        Navigator.pop(context);
      }
    },
    child: Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _tr(context, widget.product == null
                ? 'Add inventory product'
                : 'Edit inventory product'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          TextField(
            controller: name,
            decoration: InputDecoration(labelText: _tr(context, 'Product name *')),
          ),
          TextField(
            controller: sku,
            decoration: InputDecoration(labelText: _tr(context, 'SKU (optional)')),
          ),
          TextField(
            controller: stock,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _tr(context, 'Opening stock')),
          ),
          TextField(
            controller: threshold,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _tr(context, 'Low-stock threshold')),
          ),
          TextField(
            controller: cost,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _tr(context, 'Unit cost (₹)')),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    try {
                      if (widget.product == null) {
                        await ref
                            .read(inventoryRepositoryProvider)
                            .addProduct(
                              businessId: widget.businessId,
                              name: name.text,
                              openingStockMilliunits:
                                  (int.tryParse(stock.text) ?? 0) * 1000,
                              lowStockThresholdMilliunits:
                                  (int.tryParse(threshold.text) ?? 0) * 1000,
                              unitCostPaise: ((double.tryParse(cost.text) ?? 0) * 100)
                                  .round(),
                            );
                      } else {
                        await ref
                            .read(inventoryRepositoryProvider)
                            .updateProduct(
                              businessId: widget.businessId,
                              id: widget.product!.id,
                              name: name.text,
                              sku: sku.text,
                              unit: widget.product!.unit,
                              lowStockThresholdMilliunits:
                                  (int.tryParse(threshold.text) ?? 0) * 1000,
                              unitCostPaise: ((double.tryParse(cost.text) ?? 0) * 100)
                                  .round(),
                            );
                      }
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not save product'))));
                      }
                    } finally {
                      if (mounted) setState(() => saving = false);
                    }
                  },
            child: Text(
              saving
                  ? _tr(context, 'Saving...')
                  : (widget.product == null ? _tr(context, 'Save product') : _tr(context, 'Save product')),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SuppliersTab extends ConsumerWidget {
  const _SuppliersTab({required this.businessId});
  final String businessId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suppliers = ref.watch(suppliersProvider(businessId));
    return suppliers.when(
      loading: () => const _SkeletonListLoader(),
      error: (e, _) => Center(
        child: Text(
          'Unable to load suppliers.\n$e',
          textAlign: TextAlign.center,
        ),
      ),
      data: (items) => items.isEmpty
          ? const _EmptyState(
              icon: Icons.local_shipping_outlined,
              title: 'No suppliers yet',
              message: 'Add supplier contacts to manage your purchases.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final s = items[i];
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.local_shipping_outlined),
                    ),
                    title: Text(s.name),
                    subtitle: Text(s.phone),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'edit') {
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => _SupplierEditor(
                              businessId: businessId,
                              supplier: s,
                            ),
                          );
                        }
                        if (action == 'payment') _payment(context, ref, s);
                        if (action == 'delete') {
                          _deleteSupplier(context, ref, s);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(_tr(context, 'Edit supplier')),
                        ),
                        PopupMenuItem(
                          value: 'payment',
                          child: Text(_tr(context, 'Record payment')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(_tr(context, 'Delete supplier')),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _payment(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
  ) async {
    final amount = TextEditingController();
    final result = await showDialog<int?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Payment to {name}').replaceAll('{name}', supplier.name)),
        content: TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: _tr(context, 'Amount (₹)')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(amount.text);
              if (value != null && value > 0) {
                Navigator.pop(context, (value * 100).round());
              }
            },
            child: Text(_tr(context, 'Save')),
          ),
        ],
      ),
    );
    amount.dispose();
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(supplierRepositoryProvider)
          .recordPayment(
            businessId: businessId,
            supplierId: supplier.id,
            amountPaise: result,
            paidAt: DateTime.now(),
          );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Supplier payment saved')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not save payment'))));
      }
    }
  }

  Future<void> _deleteSupplier(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Delete supplier?')),
        content: Text(
          _tr(context, 'Remove {name} from active suppliers? It can be restored from Recycle bin.').replaceAll('{name}', supplier.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_tr(context, 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(supplierRepositoryProvider)
          .delete(businessId: businessId, id: supplier.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not delete supplier'))));
      }
    }
  }
}

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({required this.businessId});
  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(syncOperationsProvider(businessId));
    return operations.when(
      loading: () => const _SkeletonListLoader(),
      error: (error, _) => Center(
        child: Text(
          'Unable to load activity.\n$error',
          textAlign: TextAlign.center,
        ),
      ),
      data: (items) => items.isEmpty
          ? const _EmptyState(
              icon: Icons.history,
              title: 'No activity yet',
              message: 'Your important business actions will appear here.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final status = item.status;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      status == 'synced'
                          ? Icons.cloud_done_outlined
                          : Icons.pending_actions,
                    ),
                    title: Text(item.operationType),
                    subtitle: Text(
                      '${item.entityType} • ${item.createdAt.toLocal()}',
                    ),
                    trailing: Text(
                      status,
                      style: TextStyle(
                        color: status.startsWith('failed')
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard({this.height = 72.0});
  final double height;

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.25, end: 0.65).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Container(
        height: widget.height,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: baseColor.withOpacity(_animation.value),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

class _SkeletonListLoader extends StatelessWidget {
  const _SkeletonListLoader({this.itemCount = 5, double? cardHeight})
      : cardHeight = cardHeight ?? 72.0;
  final int itemCount;
  final double cardHeight;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 12),
    itemCount: itemCount,
    physics: const NeverScrollableScrollPhysics(),
    itemBuilder: (_, __) => _SkeletonCard(height: cardHeight),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, title),
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _tr(context, message),
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplierEditor extends ConsumerStatefulWidget {
  const _SupplierEditor({required this.businessId, this.supplier});
  final String businessId;
  final Supplier? supplier;
  @override
  ConsumerState<_SupplierEditor> createState() => _SupplierEditorState();
}

class _SupplierEditorState extends ConsumerState<_SupplierEditor> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.supplier;
    if (s != null) {
      name.text = s.name;
      phone.text = s.phone;
      email.text = s.email ?? '';
    }
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    email.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      (widget.supplier == null
          ? name.text.isNotEmpty || phone.text.isNotEmpty || email.text.isNotEmpty
          : name.text != widget.supplier!.name ||
              phone.text != widget.supplier!.phone ||
              email.text != (widget.supplier!.email ?? ''));

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isDirty || saving,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final discard = await _showDiscardChangesDialog(context);
      if (discard && context.mounted) {
        Navigator.pop(context);
      }
    },
    child: Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.supplier == null
                ? _tr(context, 'Add supplier')
                : _tr(context, 'Edit supplier'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          TextField(
            controller: name,
            decoration: InputDecoration(labelText: _tr(context, 'Supplier name *')),
          ),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: _tr(context, 'Phone *')),
          ),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: _tr(context, 'Email')),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    try {
                      if (widget.supplier == null) {
                        await ref
                            .read(supplierRepositoryProvider)
                            .add(
                              businessId: widget.businessId,
                              name: name.text,
                              phone: phone.text,
                              email: email.text,
                            );
                      } else {
                        await ref
                            .read(supplierRepositoryProvider)
                            .update(
                              businessId: widget.businessId,
                              id: widget.supplier!.id,
                              name: name.text,
                              phone: phone.text,
                              email: email.text,
                            );
                      }
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(_cleanErrorMessage(error, 'Could not save supplier'))));
                      }
                    } finally {
                      if (mounted) setState(() => saving = false);
                    }
                  },
            child: Text(
              saving
                  ? _tr(context, 'Saving...')
                  : (widget.supplier == null
                      ? _tr(context, 'Save supplier')
                      : _tr(context, 'Update supplier')),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecycleRecord {
  const _RecycleRecord(this.id, this.title, this.subtitle, this.restore);
  final String id;
  final String title;
  final String subtitle;
  final Future<void> Function() restore;
}

class _RecycleBinTab extends ConsumerStatefulWidget {
  const _RecycleBinTab({required this.businessId});
  final String businessId;
  @override
  ConsumerState<_RecycleBinTab> createState() => _RecycleBinTabState();
}

class _RecycleBinTabState extends ConsumerState<_RecycleBinTab> {
  late Future<List<_RecycleRecord>> _records;

  @override
  void initState() {
    super.initState();
    _records = _load();
  }

  Future<List<_RecycleRecord>> _load() async {
    final db = ref.read(databaseProvider);
    final expenses =
        await (db.select(db.expenses)..where(
              (e) =>
                  e.businessId.equals(widget.businessId) &
                  e.deletedAt.isNotNull(),
            ))
            .get();
    final products =
        await (db.select(db.inventoryProducts)..where(
              (e) =>
                  e.businessId.equals(widget.businessId) &
                  e.deletedAt.isNotNull(),
            ))
            .get();
    final suppliers =
        await (db.select(db.suppliers)..where(
              (e) =>
                  e.businessId.equals(widget.businessId) &
                  e.deletedAt.isNotNull(),
            ))
            .get();
    final customers =
        await (db.select(db.customers)..where(
              (e) =>
                  e.businessId.equals(widget.businessId) &
                  e.deletedAt.isNotNull(),
            ))
            .get();
    return [
      ...customers.map(
        (c) => _RecycleRecord(
          c.id,
          'Customer: ${c.name}',
          c.phone,
          () => ref
              .read(customerRepositoryProvider)
              .restore(businessId: widget.businessId, customerId: c.id),
        ),
      ),
      ...expenses.map(
        (e) => _RecycleRecord(
          e.id,
          'Expense: ₹${(e.amountPaise / 100).toStringAsFixed(2)}',
          e.category,
          () => ref
              .read(expenseRepositoryProvider)
              .restore(businessId: widget.businessId, id: e.id),
        ),
      ),
      ...products.map(
        (p) => _RecycleRecord(
          p.id,
          'Product: ${p.name}',
          'Deleted inventory item',
          () => ref
              .read(inventoryRepositoryProvider)
              .restoreProduct(businessId: widget.businessId, id: p.id),
        ),
      ),
      ...suppliers.map(
        (s) => _RecycleRecord(
          s.id,
          'Supplier: ${s.name}',
          s.phone,
          () => ref
              .read(supplierRepositoryProvider)
              .restore(businessId: widget.businessId, id: s.id),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<_RecycleRecord>>(
    future: _records,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const _SkeletonListLoader();
      }
      final records = snapshot.data!;
      if (records.isEmpty) {
        return const _EmptyState(
          icon: Icons.delete_sweep_outlined,
          title: 'Recycle bin is empty',
          message:
              'Deleted expenses, products, and suppliers will appear here.',
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: records.length,
        itemBuilder: (context, index) {
          final record = records[index];
          return Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(record.title),
              subtitle: Text(record.subtitle),
              trailing: TextButton(
                onPressed: () async {
                  await record.restore();
                  if (!context.mounted) return;
                  setState(() => _records = _load());
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(_tr(context, 'Record restored'))),
                  );
                },
                child: Text(_tr(context, 'Restore')),
              ),
            ),
          );
        },
      );
    },
  );
}

class _ReportsTab extends StatelessWidget {
  const _ReportsTab({
    required this.businessId,
    required this.summary,
    required this.customers,
  });
  final String businessId;
  final AsyncValue<BillingSummary> summary;
  final AsyncValue<List<Customer>> customers;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        _tr(context, 'Reports'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text(_tr(context, 'A quick view of your business performance.')),
      const SizedBox(height: 20),
      summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Text('Unable to load report: $error'),
        data: (data) => Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _tr(context, 'Collections'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: data.totalBilledPaise == 0
                          ? 0
                          : (data.totalReceivedPaise / data.totalBilledPaise)
                                .clamp(0.0, 1.0),
                      minHeight: 10,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _tr(context, '{collected} collected of {billed} billed')
                          .replaceAll('{collected}', _rupees(data.totalReceivedPaise))
                          .replaceAll('{billed}', _rupees(data.totalBilledPaise)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(_tr(context, 'Invoices issued')),
                    trailing: Text('${data.invoiceCount}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text(_tr(context, 'Overdue invoices')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${data.overdueInvoiceCount}'),
                        if (data.overdueInvoiceCount > 0) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ],
                    ),
                    onTap: data.overdueInvoiceCount > 0
                        ? () => showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => _OverdueInvoicesSheet(
                                businessId: businessId,
                              ),
                            )
                        : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(_tr(context, 'Outstanding')),
                    trailing: Text(_rupees(data.totalOutstandingPaise)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      customers.when(
        data: (items) => Card(
          child: ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(_tr(context, 'Active customers')),
            trailing: Text('${items.length}'),
          ),
        ),
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
      ),
    ],
  );
}

class _SyncQueueSheet extends ConsumerWidget {
  const _SyncQueueSheet({required this.businessId});
  final String businessId;

  Future<void> _retry(BuildContext context, WidgetRef ref, String id) async {
    await (ref
            .read(databaseProvider)
            .update(ref.read(databaseProvider).syncOperations)
          ..where((operation) => operation.id.equals(id)))
        .write(const SyncOperationsCompanion(
          status: Value('pending'),
          attemptCount: Value(0),
        ));
    // Requeueing and starting the worker are one user action. This avoids
    // making the user wait for the next periodic sync tick.
    await ref.read(syncWorkerProvider).syncBusiness(businessId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync operation queued for retry')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(syncOperationsProvider(businessId));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: operations.when(
          loading: () => const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Text('Unable to load sync queue: $error'),
          data: (items) => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Sync queue',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Local changes are safe. Failed operations can be retried when connectivity is available.',
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('No queued operations.'))
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final operation = items[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                operation.status.startsWith('failed')
                                    ? Icons.error_outline
                                    : Icons.schedule_outlined,
                              ),
                              title: Text(operation.operationType),
                              subtitle: Text(
                                operation.status.startsWith('failed:')
                                    ? operation.status.substring(8)
                                    : operation.status,
                              ),
                              trailing: operation.status.startsWith('failed')
                                  ? TextButton(
                                      onPressed: () =>
                                          _retry(context, ref, operation.id),
                                      child: const Text('Retry'),
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
  });
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                if (onTap != null)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _tr(context, label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CustomersTab extends ConsumerStatefulWidget {
  const _CustomersTab({required this.businessId, required this.customers});
  final String businessId;
  final AsyncValue<List<Customer>> customers;

  @override
  ConsumerState<_CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends ConsumerState<_CustomersTab> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.customers.when(
    loading: () => const _LoadingScreen(),
    error: (error, _) => _ErrorScreen(
      message:
          'Unable to load customers. Your local data is still safe.\n$error',
    ),
    data: (items) {
      if (items.isEmpty) return const _EmptyCustomers();
      final query = _search.text.trim().toLowerCase();
      final filtered = query.isEmpty
          ? items
          : items
                .where(
                  (customer) =>
                      customer.name.toLowerCase().contains(query) ||
                      customer.phone.contains(query) ||
                      (customer.email?.toLowerCase().contains(query) ?? false),
                )
                .toList();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: _tr(context, 'Search customers'),
              hintText: _tr(context, 'Name, mobile, or email'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            query.isEmpty
                ? '${items.length} ${_tr(context, items.length == 1 ? 'customer' : 'customers')}'
                : '${filtered.length} ${_tr(context, filtered.length == 1 ? 'result' : 'results')}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          if (filtered.isEmpty)
            const _NoCustomerSearchResults()
          else
            ...List.generate(
              filtered.length,
              (index) => Padding(
                padding: EdgeInsets.only(
                  bottom: index == filtered.length - 1 ? 0 : 8,
                ),
                child: _CustomerListItem(
                  businessId: widget.businessId,
                  customer: filtered[index],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _CustomerListItem extends ConsumerWidget {
  const _CustomerListItem({required this.businessId, required this.customer});
  final String businessId;
  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outstandingAsync = ref.watch(
      customerOutstandingProvider((
        businessId: businessId,
        customerId: customer.id,
      )),
    );
    final theme = Theme.of(context);
    final initial = customer.name.trim().isNotEmpty
        ? customer.name.trim().substring(0, 1).toUpperCase()
        : '?';

    return Card(
      child: ListTile(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) =>
              _CustomerDetailsSheet(businessId: businessId, customer: customer),
        ),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.primary,
          child: Text(
            initial,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          customer.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          customer.phone,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
        trailing: outstandingAsync.maybeWhen(
          data: (outstanding) {
            final isClear = outstanding == 0;
            final color =
                isClear ? const Color(0xFF10B981) : const Color(0xFFEF4444);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withOpacity(0.25)),
              ),
              child: Text(
                isClear ? _tr(context, 'Clear') : '${_tr(context, 'Due')} ${_rupees(outstanding)}',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _NoCustomerSearchResults extends StatelessWidget {
  const _NoCustomerSearchResults();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(
          Icons.person_search_outlined,
          size: 44,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          _tr(context, 'No matching customers'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(_tr(context, 'Try a different name, mobile number, or email.')),
      ],
    ),
  );
}

class _BusinessSettingsSheet extends ConsumerStatefulWidget {
  const _BusinessSettingsSheet({required this.business});
  final BusinessesData business;
  @override
  ConsumerState<_BusinessSettingsSheet> createState() =>
      _BusinessSettingsSheetState();
}

class _BusinessSettingsSheetState
    extends ConsumerState<_BusinessSettingsSheet> {
  late String _language;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _language = widget.business.preferredLanguage;
  }

  Future<void> _saveLanguage(String newLanguage) async {
    if (newLanguage == widget.business.preferredLanguage) return;
    setState(() {
      _language = newLanguage;
      _saving = true;
    });
    try {
      await ref.read(businessRepositoryProvider).updateBusiness(
            businessId: widget.business.id,
            ownerName: widget.business.ownerName,
            name: widget.business.name,
            languageCode: newLanguage,
            phone: widget.business.phone ?? '',
            email: widget.business.email ?? '',
            address: widget.business.address ?? '',
            upiId: widget.business.upiId ?? '',
            paymentQrImage: widget.business.paymentQrImage,
          );
      await ref.read(appLanguageProvider.notifier).setLanguage(newLanguage);
      await ref.read(notificationServiceProvider).reconcileSummaries();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr(context, 'Language preference updated.'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(error, 'Could not update language'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_tr(context, 'Settings'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // Section 1: Business Profile
            Text(
              _tr(context, 'Business Profile'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),

            // Business Profile Header Card
            Card(
              elevation: 0.5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.storefront_rounded, color: theme.colorScheme.primary),
                ),
                title: Text(
                  widget.business.name,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '${_tr(context, 'Owner')}: ${widget.business.ownerName}\n${_tr(context, 'Tap to view and edit shop name, owner, logo, GSTIN, UPI & address')}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BusinessProfileScreen(
                        businessId: widget.business.id,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),

            // Section 2: App Settings
            Text(
              _tr(context, 'App Settings'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),

            // Notifications Settings Card
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
              ),
              child: ListTile(
                leading: Icon(Icons.notifications_outlined, color: theme.colorScheme.onSurfaceVariant),
                title: Text(_tr(context, 'Notifications')),
                subtitle: Text(_tr(context, 'Manage payment alerts, invoice reminders & quiet hours')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NotificationSettingsScreen(),
                    ),
                  );
                },
              ),
            ),

            // App Lock & PIN
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
              ),
              child: ListTile(
                leading: Icon(Icons.lock_outline_rounded, color: theme.colorScheme.onSurfaceVariant),
                title: Text(_tr(context, 'App Security & PIN Lock')),
                subtitle: Text(_tr(context, 'Configure PIN code protection for app startup')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _configurePin(context, ref),
              ),
            ),

            // Language Selector
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: DropdownButtonFormField<String>(
                  value: ['en', 'hi', 'te'].contains(_language) ? _language : 'en',
                  decoration: InputDecoration(
                    labelText: _tr(context, 'App Language'),
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.language_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'hi', child: Text('हिन्दी (Hindi)')),
                    DropdownMenuItem(value: 'te', child: Text('తెలుగు (Telugu)')),
                  ],
                  onChanged: _saving ? null : (val) {
                    if (val != null) _saveLanguage(val);
                  },
                ),
              ),
            ),

            const SizedBox(height: 16),
            // Section 2: Appearance
            Text(
              _tr(context, 'Appearance'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
            Consumer(
              builder: (context, ref, _) {
                final mode = ref.watch(themeModeProvider);
                return SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text(_tr(context, 'System')),
                      icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text(_tr(context, 'Light')),
                      icon: const Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text(_tr(context, 'Dark')),
                      icon: const Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      ref.read(themeModeProvider.notifier).setThemeMode(selection.first);
                    }
                  },
                );
              },
            ),

            const SizedBox(height: 20),
            // Section 3: System & Offline Sync
            Text(
              _tr(context, 'Data & Sync'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
              ),
              child: ListTile(
                leading: Icon(Icons.cloud_sync_outlined, color: theme.colorScheme.onSurfaceVariant),
                title: Text(_tr(context, 'Sync Queue & Status')),
                subtitle: Text(_tr(context, 'Check offline queued operations and retry status')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _SyncQueueSheet(businessId: widget.business.id),
                  );
                },
              ),
            ),

            const SizedBox(height: 24),
            // About OneBill
            Center(
              child: Column(
                children: [
                  Image.asset(
                    'assets/OneBillLogo.png',
                    width: 36,
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'OneBill v1.0.0',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _tr(context, 'Offline-First Smart Billing & Business Management'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _AddBusinessSheet extends ConsumerStatefulWidget {
  const _AddBusinessSheet({required this.accountId});
  final String accountId;
  @override
  ConsumerState<_AddBusinessSheet> createState() => _AddBusinessSheetState();
}

class _AddBusinessSheetState extends ConsumerState<_AddBusinessSheet> {
  final _formKey = GlobalKey<FormState>();
  final _owner = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String _language = 'en';
  bool _saving = false;
  @override
  void dispose() {
    _owner.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(appLanguageProvider.notifier).setLanguage(_language);
      final newBizId = await ref
          .read(businessRepositoryProvider)
          .createBusiness(
            accountId: widget.accountId,
            ownerName: _owner.text,
            businessName: _name.text,
            phone: _phone.text,
            languageCode: _language,
          );
      final session = await ref.read(sessionProvider.future);
      if (session != null) {
        await ref
            .read(businessRepositoryProvider)
            .switchBusiness(sessionId: session.id, businessId: newBizId);
      }
      await ref.read(syncWorkerProvider).retryFailedOperations(newBizId);
      if (mounted) {
        Navigator.pop(context);
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => PostCreationGuidanceSheet(businessId: newBizId),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(error, 'Could not add business'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      24 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _tr(context, 'Add new business'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _tr(context, 'This business starts with empty customers, invoices, and payments.'),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _owner,
            decoration: InputDecoration(labelText: _tr(context, 'Owner name')),
            validator: _required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            decoration: InputDecoration(
              labelText: _tr(context, 'Business or shop name'),
            ),
            validator: _required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: _tr(context, 'Business phone (optional)'),
            ),
            validator: _phoneValidator,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _language,
            decoration: InputDecoration(labelText: _tr(context, 'Language')),
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
              DropdownMenuItem(value: 'te', child: Text('తెలుగు')),
            ],
            onChanged: (value) => setState(() => _language = value!),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? _tr(context, 'Creating...') : _tr(context, 'Create empty business')),
          ),
        ],
      ),
    ),
  );
}

class _CustomerDetailsSheet extends ConsumerWidget {
  const _CustomerDetailsSheet({
    required this.businessId,
    required this.customer,
  });
  final String businessId;
  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoices = ref.watch(
      customerInvoicesProvider((
        businessId: businessId,
        customerId: customer.id,
      )),
    );
    final invoiceRepository = ref.read(invoiceRepositoryProvider);
    final outstanding = ref.watch(
      customerOutstandingProvider((
        businessId: businessId,
        customerId: customer.id,
      )),
    );
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.5,
      builder: (context, controller) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            12,
            24,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      customer.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Customer info',
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => _CustomerInfoSheet(
                        businessId: businessId,
                        customer: customer,
                        outstanding: outstanding,
                      ),
                    ),
                    icon: const Icon(Icons.info_outline),
                  ),
                  IconButton(
                    tooltip: 'Remove customer',
                    onPressed: () => _confirmArchive(context, ref),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              Text(_tr(context, 'Invoices'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: _CustomerInvoiceList(
                  businessId: businessId,
                  invoices: invoices,
                  invoiceRepository: invoiceRepository,
                  controller: controller,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _CreateInvoiceSheet(
                      businessId: businessId,
                      customerId: customer.id,
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(_tr(context, 'Create invoice'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmArchive(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove customer?'),
        content: const Text(
          'This safely removes the customer from your active list. Their invoices and payment records remain intact and no data is permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(customerRepositoryProvider)
          .archive(businessId: businessId, customerId: customer.id);
      if (context.mounted) Navigator.pop(context);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(error, 'Could not remove customer'))),
        );
      }
    }
  }
}

class _CustomerInfoSheet extends StatelessWidget {
  const _CustomerInfoSheet({
    required this.businessId,
    required this.customer,
    required this.outstanding,
  });
  final String businessId;
  final Customer customer;
  final AsyncValue<int> outstanding;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Customer information',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _CustomerInfoLine(
                  icon: Icons.phone_outlined,
                  label: 'Mobile',
                  value: customer.phone,
                ),
              ),
              IconButton(
                tooltip: 'Copy mobile number',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: customer.phone));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_tr(context, 'Mobile number copied'))),
                    );
                  }
                },
                icon: const Icon(Icons.copy_outlined),
              ),
            ],
          ),
          outstanding.maybeWhen(
            data: (amount) => _CustomerInfoLine(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Outstanding',
              value: amount == 0 ? 'Clear' : _rupees(amount),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
          if (customer.email != null) ...[
            const SizedBox(height: 12),
            _CustomerInfoLine(
              icon: Icons.email_outlined,
              label: 'Email',
              value: customer.email!,
            ),
          ],
          if (customer.notes != null) ...[
            const SizedBox(height: 12),
            _CustomerInfoLine(
              icon: Icons.notes_outlined,
              label: 'Notes',
              value: customer.notes!,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => _EditCustomerSheet(
                  businessId: businessId,
                  customer: customer,
                ),
              );
            },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit customer'),
          ),
        ],
      ),
    ),
  );
}

class _CustomerInvoiceList extends StatefulWidget {
  const _CustomerInvoiceList({
    required this.businessId,
    required this.invoices,
    required this.invoiceRepository,
    required this.controller,
  });
  final String businessId;
  final AsyncValue<List<Invoice>> invoices;
  final InvoiceRepository invoiceRepository;
  final ScrollController controller;

  @override
  State<_CustomerInvoiceList> createState() => _CustomerInvoiceListState();
}

class _CustomerInvoiceListState extends State<_CustomerInvoiceList> {
  final _search = TextEditingController();
  InvoicePaymentStatus? _statusFilter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.invoices.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => Center(
      child: Text(
        'Unable to load invoices.\n$error',
        textAlign: TextAlign.center,
      ),
    ),
    data: (items) {
      if (items.isEmpty) return Center(child: Text(_tr(context, 'No invoices yet.')));
      final query = _search.text.trim().toLowerCase();
      final filtered = items
          .where(
            (invoice) =>
                (query.isEmpty ||
                    invoice.invoiceNumber.toLowerCase().contains(query)) &&
                (_statusFilter == null ||
                    widget.invoiceRepository.status(invoice) == _statusFilter),
          )
          .toList();
      return Column(
        children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: _tr(context, 'Search invoices'),
              hintText: _tr(context, 'Invoice number'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: _tr(context, 'Clear search'),
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<InvoicePaymentStatus?>(
            initialValue: _statusFilter,
            decoration: InputDecoration(labelText: _tr(context, 'Filter by status')),
            items: [
              DropdownMenuItem<InvoicePaymentStatus?>(
                value: null,
                child: Text(_tr(context, 'All invoices')),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.unpaid,
                child: Text(_tr(context, 'Unpaid')),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.partiallyPaid,
                child: Text(_tr(context, 'Partially paid')),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.overdue,
                child: Text(_tr(context, 'Overdue')),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.paid,
                child: Text(_tr(context, 'Paid')),
              ),
            ],
            onChanged: (value) => setState(() => _statusFilter = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text(_tr(context, 'No matching invoices.')))
                : ListView.separated(
                    controller: widget.controller,
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final invoice = filtered[index];
                      return _InvoiceListItem(
                        businessId: widget.businessId,
                        invoice: invoice,
                        invoiceRepository: widget.invoiceRepository,
                        onTap: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => _InvoiceDetailsSheet(
                            businessId: widget.businessId,
                            invoice: invoice,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

class _InvoiceListItem extends ConsumerWidget {
  const _InvoiceListItem({
    required this.businessId,
    required this.invoice,
    required this.invoiceRepository,
    required this.onTap,
  });
  final String businessId;
  final Invoice invoice;
  final InvoiceRepository invoiceRepository;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(invoiceItemsProvider(invoice.id));
    final total = invoiceRepository.total(invoice);
    final balance = invoiceRepository.balance(invoice);
    final status = invoiceRepository.status(invoice);
    final theme = Theme.of(context);

    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          child: const Icon(Icons.receipt_long_rounded, size: 20),
        ),
        title: items.maybeWhen(
          data: (entries) => Text(
            entries.isEmpty
                ? 'Invoice ${invoice.invoiceNumber}'
                : entries.first.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          orElse: () => Text(
            'Invoice ${invoice.invoiceNumber}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        subtitle: Text(
          '#${invoice.invoiceNumber}  •  ${_tr(context, "Total")} ${_rupees(total)}  •  ${_tr(context, "Due")} ${_rupees(balance)}',
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12.5,
          ),
        ),
        trailing: _InvoiceStatusBadge(status: status),
      ),
    );
  }
}

class _CustomerInfoLine extends StatelessWidget {
  const _CustomerInfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 18),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 2),
            SelectableText(value),
          ],
        ),
      ),
    ],
  );
}

class _InvoiceDetailsSheet extends ConsumerWidget {
  const _InvoiceDetailsSheet({required this.businessId, required this.invoice});
  final String businessId;
  final Invoice invoice;

  Future<void> _preview(BuildContext context, WidgetRef ref) async {
    try {
      final (bytes, business, customer) = await _pdfData(ref);
      final fileName = InvoiceFileNameService.generate(
        businessName: business.name,
        customerName: customer.name,
        invoiceNumber: invoice.invoiceNumber,
      );
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: fileName,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not generate invoice PDF: $error')),
        );
      }
    }
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    try {
      final (bytes, business, customer) = await _pdfData(ref);
      final fileName = InvoiceFileNameService.generate(
        businessName: business.name,
        customerName: customer.name,
        invoiceNumber: invoice.invoiceNumber,
      );

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'application/pdf',
              name: fileName,
            ),
          ],
          title: fileName,
          text: 'Invoice ${invoice.invoiceNumber}',
        ),
      );

      await ref
          .read(notificationServiceProvider)
          .notifyInvoiceSentShared(invoice, customer);
    } catch (error) {
      if (context.mounted) {
        AppToast.showError(context, 'Could not share invoice PDF: $error');
      }
    }
  }

  Future<void> _sharePaperReceipt(BuildContext context, WidgetRef ref) async {
    try {
      final database = ref.read(databaseProvider);
      final business = await (database.select(
        database.businesses,
      )..where((entry) => entry.id.equals(businessId))).getSingle();
      final customer =
          await (database.select(database.customers)..where(
                (entry) => Expression.and([
                  entry.id.equals(invoice.customerId),
                  entry.businessId.equals(businessId),
                ]),
              ))
              .getSingle();

      final bytes = await ref
          .read(pdfInvoiceServiceProvider)
          .generatePaperReceiptPdf(
            business: business,
            customer: customer,
            invoice: invoice,
            paperReceiptImage: invoice.paperReceiptImage!,
          );

      final fileName = 'Receipt_${invoice.invoiceNumber}.pdf';
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'application/pdf',
              name: fileName,
            ),
          ],
          title: fileName,
          text: 'Paper Receipt ${invoice.invoiceNumber}',
        ),
      );
    } catch (error) {
      if (context.mounted) {
        AppToast.showError(context, 'Could not share paper receipt: $error');
      }
    }
  }

  void _openReceiptViewer(BuildContext context, String rawImage) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (context, scrollController) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _tr(context, 'Paper Receipt'),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      color: Colors.black.withOpacity(0.04),
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 4.0,
                        child: _buildReceiptWidget(rawImage),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptWidget(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('data:image/') || trimmed.length > 500) {
      try {
        final base64Data = trimmed.contains(',') ? trimmed.split(',').last : trimmed;
        final bytes = base64Decode(base64Data);
        return Image.memory(bytes, fit: BoxFit.contain);
      } catch (_) {}
    }
    final file = File(trimmed);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.contain);
    }
    return const Center(child: Icon(Icons.broken_image_outlined, size: 48));
  }

  Widget _buildReceiptThumb(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('data:image/') || trimmed.length > 500) {
      try {
        final base64Data = trimmed.contains(',') ? trimmed.split(',').last : trimmed;
        final bytes = base64Decode(base64Data);
        return Image.memory(bytes, fit: BoxFit.cover);
      } catch (_) {}
    }
    final file = File(trimmed);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return const Icon(Icons.document_scanner_outlined, size: 24);
  }

  Future<(Uint8List, BusinessesData, Customer)> _pdfData(WidgetRef ref) async {
    final database = ref.read(databaseProvider);
    final business = await (database.select(
      database.businesses,
    )..where((entry) => entry.id.equals(businessId))).getSingle();
    final customer =
        await (database.select(database.customers)..where(
              (entry) => Expression.and([
                entry.id.equals(invoice.customerId),
                entry.businessId.equals(businessId),
              ]),
            ))
            .getSingle();
    final items = await (database.select(
      database.invoiceItems,
    )..where((entry) => entry.invoiceId.equals(invoice.id))).get();
    final bytes = await ref
        .read(pdfInvoiceServiceProvider)
        .generate(
          business: business,
          customer: customer,
          invoice: invoice,
          items: items,
        );
    return (bytes, business, customer);
  }


  Future<void> _confirmVoid(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr(context, 'Void invoice?')),
        content: Text(
          _tr(
            context,
            'This removes the invoice from active totals and lists. Its items and audit history remain stored. An invoice with payments cannot be voided.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_tr(context, 'Void invoice')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(invoiceRepositoryProvider)
          .voidInvoice(businessId: businessId, invoiceId: invoice.id);
      if (context.mounted) Navigator.pop(context);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not void invoice: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveInvoice = ref
        .watch(
          invoiceProvider((businessId: businessId, invoiceId: this.invoice.id)),
        )
        .maybeWhen(data: (value) => value, orElse: () => null);
    final invoice = liveInvoice ?? this.invoice;
    final repository = ref.read(invoiceRepositoryProvider);
    final items = ref.watch(invoiceItemsProvider(invoice.id));
    final payments = ref.watch(
      invoicePaymentsProvider((businessId: businessId, invoiceId: invoice.id)),
    );
    final customers = ref.watch(customersProvider(businessId)).valueOrNull ?? [];
    final customer = customers.cast<Customer?>().firstWhere(
          (c) => c?.id == invoice.customerId,
          orElse: () => null,
        );

    final total = repository.total(invoice);
    final balance = repository.balance(invoice);
    final status = repository.status(invoice);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.50,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ListView(
          controller: controller,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (customer != null && customer.name.trim().isNotEmpty)
                        Text(
                          customer.name.trim(),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 2),
                      Text(
                        invoice.invoiceNumber,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '${_tr(context, "Issued")} ${_date(invoice.issuedAt)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          if (invoice.dueAt != null) ...[
                            Text(
                              '  •  ',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            Text(
                              '${_tr(context, "Due")} ${_date(invoice.dueAt!)}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _InvoiceStatusBadge(status: status),
              ],
            ),
            if (invoice.notes != null && invoice.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                invoice.notes!.trim(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            TweenAnimationBuilder<double>(
              key: ValueKey(invoice.paidPaise),
              tween: Tween(begin: 0.10, end: 0),
              duration: const Duration(milliseconds: 700),
              builder: (context, highlight, child) => Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(0.4),
                  ),
                ),
                color: Theme.of(
                  context,
                ).colorScheme.primary.withOpacity(highlight),
                child: child,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  children: [
                    _AmountLine(
                      label: 'Subtotal',
                      amount: invoice.subtotalPaise,
                    ),
                    if (invoice.discountPaise > 0)
                      _AmountLine(
                        label: 'Discount',
                        amount: -invoice.discountPaise,
                      ),
                    if (invoice.interestPaise > 0)
                      _AmountLine(
                        label: 'Interest',
                        amount: invoice.interestPaise,
                      ),
                    const Divider(height: 12),
                    _AmountLine(label: 'Total', amount: total, bold: true),
                    _AmountLine(label: 'Paid', amount: invoice.paidPaise),
                    _AmountLine(label: 'Balance', amount: balance, bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (invoice.paperReceiptImage != null && invoice.paperReceiptImage!.trim().isNotEmpty) ...[
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openReceiptViewer(context, invoice.paperReceiptImage!),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          height: 48,
                          color: Colors.black12,
                          child: _buildReceiptThumb(invoice.paperReceiptImage!),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tr(context, 'Paper Receipt'),
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _tr(context, 'View Paper Receipt'),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (balance > 0) ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _RecordPaymentSheet(
                        businessId: businessId,
                        invoice: invoice,
                      ),
                    ),
                    icon: const Icon(Icons.payments_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Record Payment'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _preview(context, ref),
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                  label: Text(
                    _tr(context, 'PDF / Preview'),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _share(context, ref),
                  icon: const Icon(Icons.share_outlined, size: 20),
                  label: Text(
                    _tr(context, 'Share Invoice'),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (invoice.paperReceiptImage != null &&
                    invoice.paperReceiptImage!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _sharePaperReceipt(context, ref),
                    icon: const Icon(Icons.receipt_long_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Share Paper Receipt'),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
                if (invoice.paidPaise == 0) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _EditInvoiceDetailsSheet(
                        businessId: businessId,
                        invoice: invoice,
                      ),
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Edit Invoice'),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _confirmVoid(context, ref),
                    icon: const Icon(Icons.block_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Void Invoice'),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Text(_tr(context, 'Items'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('Unable to load items: $error'),
              data: (entries) => Column(
                children: entries
                    .map(
                      (item) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.description),
                        subtitle: Text(
                          '${_quantity(item.quantityMilliunits)} × ${_rupees(item.unitPricePaise)}',
                        ),
                        trailing: Text(_rupees(item.lineTotalPaise)),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, 'Payment history'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            payments.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('Unable to load payments: $error'),
              data: (entries) => entries.isEmpty
                  ? Text(_tr(context, 'No payments recorded yet.'))
                  : Column(
                      children: entries
                          .map(
                            (payment) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.check_circle_outline),
                              title: Text(_rupees(payment.amountPaise)),
                              subtitle: Text(
                                '${payment.method} • ${_date(payment.receivedAt)}${payment.note == null ? '' : '\n${payment.note}'}',
                              ),
                              trailing: IconButton(
                                tooltip: 'Reverse payment',
                                icon: const Icon(Icons.undo_outlined),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (dialog) => AlertDialog(
                                      title: const Text('Reverse payment?'),
                                      content: Text(
                                        'This restores ${_rupees(payment.amountPaise)} to the invoice balance. The original payment remains in the audit history.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dialog, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(dialog, true),
                                          child: const Text('Reverse'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok != true) return;
                                  try {
                                    await ref
                                        .read(invoiceRepositoryProvider)
                                        .reversePayment(
                                          businessId: businessId,
                                          paymentId: payment.id,
                                        );
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Could not reverse payment: $error',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditInvoiceDetailsSheet extends ConsumerStatefulWidget {
  const _EditInvoiceDetailsSheet({
    required this.businessId,
    required this.invoice,
  });
  final String businessId;
  final Invoice invoice;
  @override
  ConsumerState<_EditInvoiceDetailsSheet> createState() =>
      _EditInvoiceDetailsSheetState();
}

class _EditInvoiceDetailsSheetState
    extends ConsumerState<_EditInvoiceDetailsSheet> {
  late final TextEditingController discount;
  late final TextEditingController interest;
  late final TextEditingController notes;
  DateTime? dueAt;
  final items = <_InvoiceItemDraft>[];
  bool saving = false;
  String? _paperReceiptImage;
  File? _paperReceiptFile;

  @override
  void initState() {
    super.initState();
    discount = TextEditingController(
      text: (widget.invoice.discountPaise / 100).toStringAsFixed(2),
    );
    interest = TextEditingController(
      text: (widget.invoice.interestPaise / 100).toStringAsFixed(2),
    );
    notes = TextEditingController(text: widget.invoice.notes ?? '');
    dueAt = widget.invoice.dueAt;
    _paperReceiptImage = widget.invoice.paperReceiptImage;
    _initReceiptFile();
    _loadItems();
  }

  Future<void> _initReceiptFile() async {
    if (_paperReceiptImage == null || _paperReceiptImage!.trim().isEmpty) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final receiptsDir = Directory('${appDir.path}/receipts');
      final localFile = File('${receiptsDir.path}/receipt_${widget.invoice.id}.jpg');
      if (localFile.existsSync()) {
        if (mounted) setState(() => _paperReceiptFile = localFile);
      } else {
        final base64Data = _paperReceiptImage!.contains(',')
            ? _paperReceiptImage!.split(',').last
            : _paperReceiptImage!;
        final bytes = base64Decode(base64Data);
        if (!receiptsDir.existsSync()) receiptsDir.createSync(recursive: true);
        await localFile.writeAsBytes(bytes);
        if (mounted) setState(() => _paperReceiptFile = localFile);
      }
    } catch (_) {}
  }

  Future<void> _pickReceipt(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 65,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        final base64String = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final receiptsDir = Directory('${appDir.path}/receipts');
          if (!receiptsDir.existsSync()) receiptsDir.createSync(recursive: true);
          final localFile = File('${receiptsDir.path}/receipt_${widget.invoice.id}_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await localFile.writeAsBytes(bytes);
          setState(() {
            _paperReceiptFile = localFile;
            _paperReceiptImage = base64String;
          });
        } catch (_) {
          setState(() {
            _paperReceiptFile = File(picked.path);
            _paperReceiptImage = base64String;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(e, _tr(context, 'Unable to select image')))),
        );
      }
    }
  }

  void _showPickOptionsSheet(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _tr(context, 'Attach Paper Receipt'),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.camera_alt_rounded, color: theme.colorScheme.primary),
                ),
                title: Text(_tr(context, 'Take Photo')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceipt(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.photo_library_rounded, color: theme.colorScheme.secondary),
                ),
                title: Text(_tr(context, 'Choose from Gallery')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceipt(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptThumbnail(String raw) {
    try {
      final base64Data = raw.contains(',') ? raw.split(',').last : raw;
      return Image.memory(base64Decode(base64Data), fit: BoxFit.cover);
    } catch (_) {
      return const Icon(Icons.receipt_long, size: 28);
    }
  }

  Future<void> _loadItems() async {
    final db = ref.read(databaseProvider);
    final rows =
        await (db.select(db.invoiceItems)
              ..where((i) => i.invoiceId.equals(widget.invoice.id))
              ..orderBy([(i) => OrderingTerm.asc(i.sortOrder)]))
            .get();
    if (!mounted) return;
    setState(() {
      for (final row in rows) {
        final d = _InvoiceItemDraft();
        d.description.text = row.description;
        d.quantity.text = (row.quantityMilliunits / 1000).toString();
        d.unitPrice.text = (row.unitPricePaise / 100).toStringAsFixed(2);
        items.add(d);
      }
    });
  }

  @override
  void dispose() {
    discount.dispose();
    interest.dispose();
    notes.dispose();
    for (final item in items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await ref
          .read(invoiceRepositoryProvider)
          .updateInvoiceDetails(
            businessId: widget.businessId,
            invoiceId: widget.invoice.id,
            discountPaise: _parseOptionalRupees(discount.text),
            interestPaise: _parseOptionalRupees(interest.text),
            dueAt: dueAt,
            notes: notes.text,
            items: items.map((item) => item.toInput()).toList(),
            paperReceiptImage: Value(_paperReceiptImage),
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update invoice: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool get _isDirty =>
      discount.text.isNotEmpty ||
      interest.text.isNotEmpty ||
      notes.text.isNotEmpty ||
      _paperReceiptImage != widget.invoice.paperReceiptImage ||
      items.any((i) => i.description.text.isNotEmpty || i.unitPrice.text.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_isDirty || saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Text(_tr(context, 'Edit invoice'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ...List.generate(
              items.length,
              (index) => _InvoiceItemEditor(
                key: ObjectKey(items[index]),
                draft: items[index],
                itemNumber: index + 1,
                canRemove: items.length > 1,
                onChanged: () => setState(() {}),
                onRemove: () => setState(() {
                  final removed = items.removeAt(index);
                  removed.dispose();
                }),
              ),
            ),
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () => setState(() => items.add(_InvoiceItemDraft())),
              icon: const Icon(Icons.add),
              label: Text(_tr(context, 'Add item')),
            ),
            TextField(
              controller: discount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _tr(context, 'Discount (₹)')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: interest,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _tr(context, 'Interest / extra charge (₹)'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notes,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: _tr(context, 'Notes')),
            ),
            const SizedBox(height: 16),
            _DatePickerField(
              label: _tr(context, 'Payment Due Date'),
              selectedDate: dueAt,
              onTap: saving
                  ? () {}
                  : () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: dueAt ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (d != null && mounted) setState(() => dueAt = d);
                    },
              onClear: () => setState(() => dueAt = null),
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, 'Paper Receipt (Optional)'),
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_paperReceiptImage != null && _paperReceiptImage!.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: _paperReceiptFile != null && _paperReceiptFile!.existsSync()
                            ? Image.file(_paperReceiptFile!, fit: BoxFit.cover)
                            : _buildReceiptThumbnail(_paperReceiptImage!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tr(context, 'Receipt Attached'),
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _tr(context, 'Tap to change or remove'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: _tr(context, 'Change Photo'),
                      onPressed: saving ? null : () => _showPickOptionsSheet(context),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                      tooltip: _tr(context, 'Remove Receipt'),
                      onPressed: saving
                          ? null
                          : () {
                              setState(() {
                                _paperReceiptImage = null;
                                _paperReceiptFile = null;
                              });
                            },
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(_tr(context, 'Take Photo')),
                      onPressed: saving ? null : () => _pickReceipt(ImageSource.camera),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(_tr(context, 'Choose from Gallery')),
                      onPressed: saving ? null : () => _pickReceipt(ImageSource.gallery),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? _tr(context, 'Saving...') : _tr(context, 'Save changes')),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditCustomerSheet extends ConsumerStatefulWidget {
  const _EditCustomerSheet({required this.businessId, required this.customer});
  final String businessId;
  final Customer customer;

  @override
  ConsumerState<_EditCustomerSheet> createState() => _EditCustomerSheetState();
}

class _EditCustomerSheetState extends ConsumerState<_EditCustomerSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _notes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final customer = widget.customer;
    _name = TextEditingController(text: customer.name);
    _phone = TextEditingController(text: customer.phone);
    _email = TextEditingController(text: customer.email);
    _notes = TextEditingController(text: customer.notes);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(customerRepositoryProvider)
          .update(
            businessId: widget.businessId,
            customerId: widget.customer.id,
            name: _name.text,
            phone: _phone.text,
            email: _email.text,
            notes: _notes.text,
          );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update customer: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _isDirty =>
      _name.text != widget.customer.name ||
      _phone.text != widget.customer.phone ||
      _email.text != (widget.customer.email ?? '') ||
      _notes.text != (widget.customer.notes ?? '');

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty || _saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              Text(
                'Edit customer',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Customer name'),
                validator: _required,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Mobile number'),
                validator: _phoneValidator,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                validator: _optionalEmailValidator,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save customer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.label,
    required this.selectedDate,
    required this.onTap,
    this.onClear,
  });
  final String label;
  final DateTime? selectedDate;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDate = selectedDate != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasDate ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
            width: hasDate ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_month_rounded,
              color: hasDate ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: hasDate ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasDate ? _date(selectedDate!) : 'Select Date (Tap to open calendar)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: hasDate ? FontWeight.bold : FontWeight.normal,
                      color: hasDate ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (hasDate && onClear != null)
              IconButton(
                icon: const Icon(Icons.clear, size: 20),
                onPressed: onClear,
                tooltip: 'Clear date',
              )
            else
              Icon(
                Icons.arrow_drop_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _AmountLine extends StatelessWidget {
  const _AmountLine({
    required this.label,
    required this.amount,
    this.bold = false,
  });
  final String label;
  final int amount;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          _tr(context, label),
          style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.94, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            _rupees(amount),
            key: ValueKey(amount),
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
        ),
      ],
    ),
  );
}

class _InvoiceStatusBadge extends StatelessWidget {
  const _InvoiceStatusBadge({required this.status});
  final InvoicePaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      InvoicePaymentStatus.unpaid => ('Unpaid', const Color(0xFFF59E0B)),
      InvoicePaymentStatus.partiallyPaid => ('Partially paid', const Color(0xFF3B82F6)),
      InvoicePaymentStatus.paid => ('Paid', const Color(0xFF10B981)),
      InvoicePaymentStatus.overdue => ('Overdue', const Color(0xFFEF4444)),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Container(
        key: ValueKey(status),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
        ),
        child: Text(
          _tr(context, label),
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _RecordPaymentSheet extends ConsumerStatefulWidget {
  const _RecordPaymentSheet({required this.businessId, required this.invoice});
  final String businessId;
  final Invoice invoice;
  @override
  ConsumerState<_RecordPaymentSheet> createState() =>
      _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends ConsumerState<_RecordPaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _method = 'Cash';
  bool _saving = false;

  int get _remaining =>
      ref.read(invoiceRepositoryProvider).balance(widget.invoice);
  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final amountPaise = _parseRupees(_amount.text);
      await ref
          .read(invoiceRepositoryProvider)
          .recordPayment(
            businessId: widget.businessId,
            invoiceId: widget.invoice.id,
            amountPaise: amountPaise,
            method: _method,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );

      try {
        final db = ref.read(databaseProvider);
        final updatedInvoice = await (db.select(db.invoices)
              ..where((i) => i.id.equals(widget.invoice.id)))
            .getSingleOrNull();
        final customer = updatedInvoice == null
            ? null
            : await (db.select(db.customers)
                  ..where((c) => c.id.equals(updatedInvoice.customerId)))
                .getSingleOrNull();
        final latestPayment = await (db.select(db.payments)
              ..where((p) => p.invoiceId.equals(widget.invoice.id))
              ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
            .get()
            .then((list) => list.firstOrNull);

        if (updatedInvoice != null && latestPayment != null) {
          final totalPaise = updatedInvoice.subtotalPaise +
              updatedInvoice.interestPaise -
              updatedInvoice.discountPaise;
          final remainingPaise = totalPaise - updatedInvoice.paidPaise;
          final isFullyPaid = remainingPaise <= 0;

          await ref.read(notificationServiceProvider).notifyPaymentRecorded(
                payment: latestPayment,
                invoice: updatedInvoice,
                customer: customer,
                isFullyPaid: isFullyPaid,
              );
        }
      } catch (_) {}

      ref.read(syncWorkerProvider).syncBusiness(widget.businessId);

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record payment: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _isDirty => _amount.text.isNotEmpty || _note.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty || _saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              20 +
                  MediaQuery.viewInsetsOf(context).bottom +
                  MediaQuery.paddingOf(context).bottom,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_tr(context, 'Record payment'), style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text('${_tr(context, "Outstanding")}: ${_rupees(_remaining)}'),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: _tr(context, 'Amount received (₹)')),
                    validator: (value) {
                      final error = _amountValidator(value);
                      if (error != null) return error;
                      return _parseRupees(value!) > _remaining
                          ? 'Payment cannot exceed ${_rupees(_remaining)}.'
                          : null;
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _saving
                          ? null
                          : () {
                              _amount.text = (_remaining / 100).toStringAsFixed(2);
                            },
                      child: Text(_tr(context, 'Use full balance')),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _method,
                    decoration: InputDecoration(labelText: _tr(context, 'Payment method')),
                    items: [
                      DropdownMenuItem(value: 'Cash', child: Text(_tr(context, 'Cash'))),
                      DropdownMenuItem(value: 'UPI', child: Text(_tr(context, 'UPI'))),
                      DropdownMenuItem(
                        value: 'Bank transfer',
                        child: Text(_tr(context, 'Bank transfer')),
                      ),
                      DropdownMenuItem(value: 'Other', child: Text(_tr(context, 'Other'))),
                    ],
                    onChanged: (value) => setState(() => _method = value!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _note,
                    decoration: InputDecoration(labelText: _tr(context, 'Note (optional)')),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? _tr(context, 'Recording...') : _tr(context, 'Confirm payment')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateInvoiceSheet extends ConsumerStatefulWidget {
  const _CreateInvoiceSheet({
    required this.businessId,
    required this.customerId,
  });
  final String businessId;
  final String customerId;
  @override
  ConsumerState<_CreateInvoiceSheet> createState() =>
      _CreateInvoiceSheetState();
}

class _CreateInvoiceSheetState extends ConsumerState<_CreateInvoiceSheet> {
  final _formKey = GlobalKey<FormState>();
  final List<_InvoiceItemDraft> _items = [_InvoiceItemDraft()];
  final _discount = TextEditingController();
  final _interest = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _dueAt;
  bool _saving = false;
  String? _paperReceiptImage;
  File? _paperReceiptFile;

  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    _discount.dispose();
    _interest.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 65,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        final base64String = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final receiptsDir = Directory('${appDir.path}/receipts');
          if (!receiptsDir.existsSync()) receiptsDir.createSync(recursive: true);
          final localFile = File('${receiptsDir.path}/receipt_new_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await localFile.writeAsBytes(bytes);
          setState(() {
            _paperReceiptFile = localFile;
            _paperReceiptImage = base64String;
          });
        } catch (_) {
          setState(() {
            _paperReceiptFile = File(picked.path);
            _paperReceiptImage = base64String;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanErrorMessage(e, _tr(context, 'Unable to select image')))),
        );
      }
    }
  }

  void _showPickOptionsSheet(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _tr(context, 'Attach Paper Receipt'),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.camera_alt_rounded, color: theme.colorScheme.primary),
                ),
                title: Text(_tr(context, 'Take Photo')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceipt(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.photo_library_rounded, color: theme.colorScheme.secondary),
                ),
                title: Text(_tr(context, 'Choose from Gallery')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceipt(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptThumbnail(String raw) {
    try {
      final base64Data = raw.contains(',') ? raw.split(',').last : raw;
      return Image.memory(base64Decode(base64Data), fit: BoxFit.cover);
    } catch (_) {
      return const Icon(Icons.receipt_long, size: 28);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final invoiceId = await ref
          .read(invoiceRepositoryProvider)
          .createInvoice(
            businessId: widget.businessId,
            customerId: widget.customerId,
            items: _items.map((item) => item.toInput()).toList(),
            discountPaise: _parseOptionalRupees(_discount.text),
            interestPaise: _parseOptionalRupees(_interest.text),
            dueAt: _dueAt,
            notes: _notes.text,
            paperReceiptImage: _paperReceiptImage,
          );

      try {
        final db = ref.read(databaseProvider);
        final createdInvoice = await (db.select(db.invoices)
              ..where((i) => i.id.equals(invoiceId)))
            .getSingleOrNull();
        final customer = await (db.select(db.customers)
              ..where((c) => c.id.equals(widget.customerId)))
            .getSingleOrNull();

        if (createdInvoice != null) {
          await ref
              .read(notificationServiceProvider)
              .notifyInvoiceCreated(createdInvoice, customer);
        }
      } catch (_) {}

      ref.read(syncWorkerProvider).syncBusiness(widget.businessId);

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create invoice: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectDueDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) setState(() => _dueAt = selected);
  }

  int get _subtotal =>
      _items.fold<int>(0, (sum, item) => sum + item.lineTotalPaise);
  int get _total =>
      _subtotal -
      _parseOptionalRupees(_discount.text) +
      _parseOptionalRupees(_interest.text);

  bool get _isDirty =>
      _items.any((i) => i.description.text.isNotEmpty || i.unitPrice.text.isNotEmpty) ||
      _discount.text.isNotEmpty ||
      _interest.text.isNotEmpty ||
      _notes.text.isNotEmpty ||
      _paperReceiptImage != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_isDirty || _saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.6,
        builder: (context, scrollController) => SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              12,
              24,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Form(
              key: _formKey,
              child: ListView(
                controller: scrollController,
                children: <Widget>[
                  Text(
                    'Create Invoice',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Fill in line items, payment terms, and adjustments below.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Section 1: Line Items
                  Row(
                    children: [
                      Icon(Icons.shopping_bag_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Items & Services',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  ...List.generate(
                    _items.length,
                    (index) => _InvoiceItemEditor(
                      key: ObjectKey(_items[index]),
                      draft: _items[index],
                      itemNumber: index + 1,
                      canRemove: _items.length > 1,
                      onChanged: () => setState(() {}),
                      onRemove: () => setState(() {
                        final removed = _items.removeAt(index);
                        removed.dispose();
                      }),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => setState(() => _items.add(_InvoiceItemDraft())),
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                      label: const Text('Add Another Item'),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Paper Receipt (Optional)
                  Row(
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        _tr(context, 'Paper Receipt (Optional)'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _tr(context, 'Attach photo of handwritten bill'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_paperReceiptImage != null && _paperReceiptImage!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.colorScheme.outlineVariant),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: _paperReceiptFile != null && _paperReceiptFile!.existsSync()
                                  ? Image.file(_paperReceiptFile!, fit: BoxFit.cover)
                                  : _buildReceiptThumbnail(_paperReceiptImage!),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _tr(context, 'Receipt Attached'),
                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  _tr(context, 'Tap to change or remove'),
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: _tr(context, 'Change Photo'),
                            onPressed: _saving ? null : () => _showPickOptionsSheet(context),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                            tooltip: _tr(context, 'Remove Receipt'),
                            onPressed: _saving
                                ? null
                                : () {
                                    setState(() {
                                      _paperReceiptImage = null;
                                      _paperReceiptFile = null;
                                    });
                                  },
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: Text(_tr(context, 'Take Photo')),
                            onPressed: _saving ? null : () => _pickReceipt(ImageSource.camera),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(_tr(context, 'Choose from Gallery')),
                            onPressed: _saving ? null : () => _pickReceipt(ImageSource.gallery),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 24),

                  // Section 2: Terms & Notes
                  Row(
                    children: [
                      Icon(Icons.event_note_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Due Date & Notes',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  _DatePickerField(
                    label: 'Payment Due Date',
                    selectedDate: _dueAt,
                    onTap: _saving ? () {} : _selectDueDate,
                    onClear: () => setState(() => _dueAt = null),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _notes,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Invoice Notes (Optional)',
                      hintText: 'e.g. Thank you for your business!',
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Section 3: Summary
                  Row(
                    children: [
                      Icon(Icons.calculate_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Bill Summary & Adjustments',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _discount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Discount (₹, optional)',
                      prefixIcon: Icon(Icons.discount_outlined),
                    ),
                    validator: _optionalAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _interest,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Extra Charge / Interest (₹, optional)',
                      prefixIcon: Icon(Icons.add_card_outlined),
                    ),
                    validator: _optionalAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),

                  Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _AmountLine(label: 'Subtotal', amount: _subtotal),
                          if (_parseOptionalRupees(_discount.text) > 0)
                            _AmountLine(
                              label: 'Discount',
                              amount: -_parseOptionalRupees(_discount.text),
                            ),
                          if (_parseOptionalRupees(_interest.text) > 0)
                            _AmountLine(
                              label: 'Extra Charge',
                              amount: _parseOptionalRupees(_interest.text),
                            ),
                          const Divider(height: 16),
                          _AmountLine(label: 'Grand Total', amount: _total, bold: true),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(
                        _saving ? 'Creating Invoice...' : 'Create Invoice',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InvoiceItemDraft {
  final description = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final unitPrice = TextEditingController();

  int get quantityMilliunits => _parseQuantityMilliunits(quantity.text);
  int get lineTotalPaise =>
      quantityMilliunits * _tryParseRupees(unitPrice.text) ~/ 1000;
  InvoiceLineInput toInput() => InvoiceLineInput(
    description: description.text,
    quantityMilliunits: quantityMilliunits,
    unitPricePaise: _parseOptionalRupees(unitPrice.text),
  );
  void dispose() {
    description.dispose();
    quantity.dispose();
    unitPrice.dispose();
  }
}

class _InvoiceItemEditor extends StatelessWidget {
  const _InvoiceItemEditor({
    super.key,
    required this.draft,
    required this.itemNumber,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });
  final _InvoiceItemDraft draft;
  final int itemNumber;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Item #$itemNumber',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                if (canRemove)
                  IconButton(
                    tooltip: 'Remove item',
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: draft.description,
              decoration: const InputDecoration(
                labelText: 'Item / Service Description *',
                hintText: 'e.g. Rice Bag 25kg or Plumbing Service',
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: draft.quantity,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Qty *'),
                    validator: _quantityValidator,
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: draft.unitPrice,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Unit Price (₹) *',
                    ),
                    validator: _amountValidator,
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Line Total: ${_rupees(draft.lineTotalPaise)}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddCustomerSheet extends ConsumerStatefulWidget {
  const _AddCustomerSheet({required this.businessId});
  final String businessId;
  @override
  ConsumerState<_AddCustomerSheet> createState() => _AddCustomerSheetState();
}

class _AddCustomerSheetState extends ConsumerState<_AddCustomerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;
  bool _verifyingPhone = false;
  bool _phoneValid = false;
  String? _phoneError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _verifyingPhone = true;
      _phoneError = null;
      _phoneValid = false;
    });

    // Smooth 1.2s verification animation inside input field
    await Future.delayed(const Duration(milliseconds: 1200));

    final normalized = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (!RegExp(r'^[6-9][0-9]{9}$').hasMatch(normalized)) {
      if (mounted) {
        setState(() {
          _verifyingPhone = false;
          _phoneError = 'Enter a valid 10-digit Indian mobile number (6-9xxxx)';
        });
      }
      return;
    }

    try {
      final db = ref.read(databaseProvider);
      final existing = await (db.select(db.customers)
            ..where((c) =>
                c.businessId.equals(widget.businessId) &
                c.phone.equals(normalized) &
                c.deletedAt.isNull()))
          .getSingleOrNull();

      if (existing != null) {
        if (mounted) {
          setState(() {
            _verifyingPhone = false;
            _phoneError = 'Customer with this number already exists';
          });
        }
        return;
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _verifyingPhone = false;
      _phoneValid = true;
      _saving = true;
    });

    try {
      await ref.read(customerRepositoryProvider).create(
            businessId: widget.businessId,
            name: _name.text,
            phone: _phone.text,
          );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        final msg = error
            .toString()
            .replaceAll('ArgumentError: ', '')
            .replaceAll('StateError: ', '');
        setState(() {
          _phoneError = msg;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _isDirty =>
      _name.text.trim().isNotEmpty || _phone.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isDirty || _saving || _verifyingPhone,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _tr(context, 'Add customer'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Customer name',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: _required,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                onChanged: (_) {
                  if (_phoneError != null) {
                    setState(() => _phoneError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Mobile number',
                  prefixIcon: const Icon(Icons.phone_outlined),
                  errorText: _phoneError,
                  suffixIcon: _verifyingPhone
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _phoneValid
                          ? const Icon(
                              Icons.check_circle_rounded,
                              color: Color(0xFF10B981),
                            )
                          : _phoneError != null
                              ? const Icon(
                                  Icons.error_outline_rounded,
                                  color: Color(0xFFEF4444),
                                )
                              : null,
                ),
                validator: _required,
              ),
              if (_phoneError != null) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.error.withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _phoneError!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: (_saving || _verifyingPhone) ? null : _save,
                child: Text(
                  _verifyingPhone
                      ? 'Verifying number...'
                      : _saving
                          ? 'Saving...'
                          : 'Save customer',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCustomers extends StatelessWidget {
  const _EmptyCustomers();
  @override
  Widget build(BuildContext context) => const _EmptyState(
    icon: Icons.people_outline_rounded,
    title: 'No customers yet',
    message: 'Add your first customer to begin creating invoices.',
  );
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();
  @override
  Widget build(BuildContext context) => const _SkeletonListLoader(itemCount: 6);
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

String? _required(String? value) =>
    value == null || value.trim().isEmpty ? 'This field is required.' : null;

String? _emailValidator(String? value) =>
    value == null ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim())
    ? 'Enter a valid email address.'
    : null;

String? _optionalEmailValidator(String? value) =>
    value == null || value.trim().isEmpty ? null : _emailValidator(value);

String? _passwordValidator(String? value) =>
    value == null || value.length < 8 ? 'Use at least 8 characters.' : null;

String? _phoneValidator(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  return RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits)
      ? null
      : 'Enter a valid 10-digit Indian mobile number.';
}

String? _amountValidator(String? value) {
  if (value == null || !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value.trim())) {
    return 'Enter a valid amount, such as 125 or 125.50.';
  }
  return _parseRupees(value) > 0 ? null : 'Amount must be greater than zero.';
}

String? _optionalAmountValidator(String? value) =>
    value == null || value.trim().isEmpty ? null : _amountValidator(value);

String? _quantityValidator(String? value) {
  if (value == null ||
      !RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(value.trim()) ||
      _parseQuantityMilliunits(value) <= 0) {
    return 'Enter a quantity greater than zero.';
  }
  return null;
}

int _parseRupees(String value) {
  final parts = value.trim().split('.');
  final rupees = int.parse(parts.first);
  final paise = parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0'));
  return rupees * 100 + paise;
}

int _parseOptionalRupees(String value) =>
    value.trim().isEmpty ? 0 : _parseRupees(value);

int _tryParseRupees(String value) {
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value.trim())) return 0;
  return _parseRupees(value);
}

int _parseQuantityMilliunits(String value) {
  if (value.trim().isEmpty) return 0;
  final parts = value.trim().split('.');
  final whole = int.tryParse(parts.first) ?? 0;
  final fraction = parts.length == 1
      ? 0
      : int.tryParse(parts[1].padRight(3, '0')) ?? 0;
  return whole * 1000 + fraction;
}

String _rupees(int paise) {
  final sign = paise < 0 ? '-' : '';
  final absolute = paise.abs();
  return '$sign₹${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
}

String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _monthLabel(DateTime value) {
  const names = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${names[value.month - 1]} ${value.year}';
}

String _quantity(int milliunits) =>
    (milliunits / 1000).toStringAsFixed(milliunits % 1000 == 0 ? 0 : 3);

class _OverdueInvoicesSheet extends ConsumerWidget {
  const _OverdueInvoicesSheet({required this.businessId});
  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final database = ref.watch(databaseProvider);
    final invoiceRepo = ref.watch(invoiceRepositoryProvider);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return StreamBuilder<List<Invoice>>(
          stream: (database.select(database.invoices)
                ..where(
                  (i) =>
                      i.businessId.equals(businessId) & i.deletedAt.isNull(),
                )
                ..orderBy([(i) => OrderingTerm.desc(i.issuedAt)]))
              .watch(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final allInvoices = snapshot.data ?? [];
            final overdueInvoices = allInvoices
                .where(
                  (inv) =>
                      invoiceRepo.status(inv) == InvoicePaymentStatus.overdue,
                )
                .toList();

            final totalOutstandingPaise = overdueInvoices.fold<int>(
              0,
              (sum, inv) => sum + invoiceRepo.balance(inv),
            );

            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tr(context, 'Overdue Payments'),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${overdueInvoices.length} ${overdueInvoices.length == 1 ? 'invoice' : 'invoices'}  •  ${_tr(context, "Total outstanding")} ${_rupees(totalOutstandingPaise)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (overdueInvoices.isEmpty)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_outline_rounded,
                              size: 48,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _tr(context, 'No overdue invoices'),
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _tr(context, 'All customer payments are up to date.'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        itemCount: overdueInvoices.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final invoice = overdueInvoices[index];
                          return _OverdueInvoiceCard(
                            invoice: invoice,
                            invoiceRepo: invoiceRepo,
                            database: database,
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _tr(context, 'Total outstanding'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _rupees(totalOutstandingPaise),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _OverdueInvoiceCard extends ConsumerWidget {
  const _OverdueInvoiceCard({
    required this.invoice,
    required this.invoiceRepo,
    required this.database,
  });

  final Invoice invoice;
  final InvoiceRepository invoiceRepo;
  final AppDatabase database;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final balancePaise = invoiceRepo.balance(invoice);
    final dueAt = invoice.dueAt?.toLocal();
    final today = DateTime.now().toLocal();

    int daysOverdue = 0;
    if (dueAt != null) {
      final dueDateStart = DateTime(dueAt.year, dueAt.month, dueAt.day);
      final todayStart = DateTime(today.year, today.month, today.day);
      daysOverdue = todayStart.difference(dueDateStart).inDays;
    }

    return StreamBuilder<Customer?>(
      stream: (database.select(database.customers)
            ..where((c) => c.id.equals(invoice.customerId)))
          .watchSingleOrNull(),
      builder: (context, customerSnapshot) {
        final customerName = customerSnapshot.data?.name ?? 'Customer';

        return StreamBuilder<BusinessesData?>(
          stream: (database.select(database.businesses)
                ..where((b) => b.id.equals(invoice.businessId)))
              .watchSingleOrNull(),
          builder: (context, bizSnapshot) {
            final bizName = bizSnapshot.data?.name;

            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                onTap: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _InvoiceDetailsSheet(
                      businessId: invoice.businessId,
                      invoice: invoice,
                    ),
                  );
                },
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        customerName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _rupees(balancePaise),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      '${invoice.invoiceNumber}${bizName != null ? ' • $bizName' : ''}',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dueAt == null
                          ? _tr(context, 'Overdue')
                          : '${_tr(context, "Due")} ${_date(dueAt)} • $daysOverdue ${daysOverdue == 1 ? "day" : "days"} ${_tr(context, "overdue")}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
              ),
            );
          },
        );
      },
    );
  }
}

