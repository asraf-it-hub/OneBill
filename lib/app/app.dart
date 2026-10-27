import '../core/ui/app_toast.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../features/customers/services/contact_service.dart';
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
import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
import '../features/business/ui/confirm_delete_business_dialog.dart';
import '../features/business/ui/post_creation_guidance_sheet.dart';
import '../features/auth/domain/auth_error_details.dart';
import '../features/auth/services/app_credential_manager.dart';
import '../features/auth/ui/confirm_delete_account_dialog.dart';
import '../core/localization/app_localizations.dart';
import '../core/localization/app_language_provider.dart';

class OneBillApp extends ConsumerWidget {
  const OneBillApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final savedLang = ref.watch(appLanguageProvider);
    final isSigningOut = ref.watch(isSigningOutProvider);
    final authSession = ref.watch(authSessionProvider).valueOrNull;
    final useSessionLanguage =
        !isSigningOut &&
        session != null &&
        session.activeBusinessId != null &&
        session.localeCode.isNotEmpty &&
        (!AppEnvironment.cloudConfigured || authSession != null);
    final effectiveLang = useSessionLanguage
        ? session.localeCode
        : (savedLang.isNotEmpty ? savedLang : 'en');
    final locale = {'en', 'hi', 'te'}.contains(effectiveLang)
        ? effectiveLang
        : 'en';
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
      title: Text(_tr(context, 'Discard changes?')),
      content: Text(_tr(context, "Your changes haven't been saved.")),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(_tr(context, 'Keep Editing')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(_tr(context, 'Discard')),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _StartupGate extends ConsumerStatefulWidget {
  const _StartupGate();
  @override
  ConsumerState<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<_StartupGate> {
  StreamSubscription<Uri>? _appLinksSub;
  StreamSubscription<AuthState>? _authSub;
  bool _hadAuthenticatedSession = false;
  bool _checkingUnexpectedSignOut = false;

  @override
  void initState() {
    super.initState();
    _checkDanglingRecoverySession();
    _setupDeepLinks();
  }

  Future<void> _checkDanglingRecoverySession() async {
    try {
      final storage = FlutterSecureStorage();
      final inRecovery = await storage.read(
        key: 'onebill.auth.in_password_recovery',
      );
      if (inRecovery == 'true') {
        // App was closed or killed while in password recovery. Force the
        // session back to the auth screen, but preserve offline financial data.
        await storage.delete(key: 'onebill.auth.in_password_recovery');
        try {
          await ref.read(notificationServiceProvider).cancelAll();
        } catch (_) {}
        try {
          await ref.read(authServiceProvider).signOut();
        } catch (_) {}
        ref.read(isSigningOutProvider.notifier).state = true;
        ref.read(isPasswordRecoveryProvider.notifier).state = false;
        ref.read(passwordRecoveryErrorProvider.notifier).state = null;
        ref.read(passwordRecoveryUriProvider.notifier).state = null;
        ref.invalidate(authSessionProvider);
        ref.invalidate(sessionProvider);
      }
    } catch (_) {}
  }

  void _setupDeepLinks() {
    final appLinks = AppLinks();

    // Check initial launch link (cold start)
    appLinks
        .getInitialLink()
        .then((uri) {
          if (uri != null) _handleUri(uri);
        })
        .catchError((_) {});

    // Listen to deep links while app is open / foregrounded / backgrounded
    _appLinksSub = appLinks.uriLinkStream.listen((uri) {
      _handleUri(uri);
    }, onError: (_) {});

    // Listen to Supabase auth state changes for recovery events
    if (AppEnvironment.cloudConfigured) {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.signedIn ||
            data.event == AuthChangeEvent.initialSession) {
          if (data.session != null) _hadAuthenticatedSession = true;
          // Auth callbacks can arrive just after the sign-in form continues.
          // Restore again once Supabase has committed the session so an old
          // local business row cannot hide the current cloud profile.
          unawaited(ref.read(syncWorkerProvider).restoreAccount());
        }
        // A remote account deletion invalidates the cached refresh token. The
        // SDK emits signedOut while the app may still have the old local
        // workspace. Keep the selected language and explain what happened
        // before presenting the sign-in screen.
        if (data.event == AuthChangeEvent.signedOut &&
            _hadAuthenticatedSession &&
            !ref.read(isSigningOutProvider)) {
          _checkingUnexpectedSignOut = true;
          unawaited(_showUnexpectedAccountDeletion());
        }
        if (data.event == AuthChangeEvent.passwordRecovery) {
          if (mounted) {
            ref.read(passwordRecoveryErrorProvider.notifier).state = null;
            ref.read(isPasswordRecoveryProvider.notifier).state = true;
            try {
              FlutterSecureStorage().write(
                key: 'onebill.auth.in_password_recovery',
                value: 'true',
              );
            } catch (_) {}
          }
        }
      });
    }
  }

  Future<void> _showUnexpectedAccountDeletion() async {
    if (ref.read(accountDeletedProvider)) return;
    final localSession = await ref.read(sessionProvider.future);
    if (!mounted || localSession?.accountId == null) {
      if (mounted) setState(() => _checkingUnexpectedSignOut = false);
      return;
    }
    ref.read(accountDeletedProvider.notifier).state = true;
    // The cloud account is already gone. Remove only its local records so a
    // later sign-in cannot expose stale data, while retaining language choice.
    try {
      await ref
          .read(databaseProvider)
          .deleteAccountData(localSession!.accountId!);
    } catch (_) {}
    try {
      await ref.read(notificationServiceProvider).cancelAll();
    } catch (_) {}
    try {
      await ref.read(securityServiceProvider).clearPin();
    } catch (_) {}
    ref.invalidate(sessionProvider);
    if (mounted) setState(() => _checkingUnexpectedSignOut = false);
  }

  Future<void> _handleUri(Uri uri) async {
    final fragment = uri.fragment;
    final query = uri.queryParameters;
    final fragmentParams = fragment.isNotEmpty
        ? Uri.splitQueryString(fragment)
        : <String, String>{};

    final error = query['error'] ?? fragmentParams['error'];
    final errorDesc =
        query['error_description'] ??
        fragmentParams['error_description'] ??
        query['error_code'] ??
        fragmentParams['error_code'];

    final isRecovery =
        uri.host == 'reset-password' ||
        uri.path.contains('reset-password') ||
        uri.fragment.contains('type=recovery') ||
        uri.queryParameters['type'] == 'recovery' ||
        (error != null &&
            (uri.path.contains('reset-password') ||
                uri.host == 'reset-password'));

    final email = query['email'] ?? fragmentParams['email'];
    if (email != null && email.isNotEmpty) {
      ref.read(lastAuthEmailProvider.notifier).state = email;
    }

    if (isRecovery && mounted) {
      if (error != null || errorDesc != null) {
        ref.read(passwordRecoveryErrorProvider.notifier).state =
            errorDesc ?? error ?? 'Auth session missing';
      } else {
        ref.read(passwordRecoveryErrorProvider.notifier).state = null;
      }
      ref.read(passwordRecoveryUriProvider.notifier).state = null;
      ref.read(passwordRecoveryUriProvider.notifier).state = uri;
      ref.read(isPasswordRecoveryProvider.notifier).state = true;
      try {
        FlutterSecureStorage().write(
          key: 'onebill.auth.in_password_recovery',
          value: 'true',
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _appLinksSub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPasswordRecovery = ref.watch(isPasswordRecoveryProvider);
    if (isPasswordRecovery) {
      return const _ResetPasswordScreen();
    }

    if (ref.watch(accountDeletedProvider)) {
      return const _AccountDeletedScreen();
    }

    final isSigningOut = ref.watch(isSigningOutProvider);
    if (isSigningOut) return const _AuthScreen();

    if (_checkingUnexpectedSignOut) return const _LoadingScreen();

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

class _AccountDeletedScreen extends ConsumerWidget {
  const _AccountDeletedScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                elevation: 0,
                color: theme.colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(26, 30, 26, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.person_remove_outlined,
                          size: 31,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _tr(context, 'Your OneBill account was deleted'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tr(
                          context,
                          'The account and its associated cloud data are no longer available. Your device data has been removed from this account.',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            ref.read(accountDeletedProvider.notifier).state =
                                false;
                            ref.read(isSigningOutProvider.notifier).state =
                                true;
                            ref.invalidate(sessionProvider);
                            ref.invalidate(authSessionProvider);
                          },
                          icon: const Icon(Icons.login_rounded),
                          label: Text(_tr(context, 'Continue to sign in')),
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

class _ResetPasswordScreen extends ConsumerStatefulWidget {
  const _ResetPasswordScreen();

  @override
  ConsumerState<_ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<_ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _submitting = false;
  bool _validatingSession = true;
  bool _resetEmailSent = false;
  String? _sentEmailAddress;
  AuthErrorDetails? _authErrorDetails;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _emailController.text =
        ref.read(lastAuthEmailProvider) ??
        Supabase.instance.client.auth.currentUser?.email ??
        '';
    if (AppEnvironment.cloudConfigured) {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.session != null && mounted) {
          setState(() {
            _validatingSession = false;
            _authErrorDetails = null;
            _resetEmailSent = false;
          });
        }
      });
    }
    _checkRecoverySession();
  }

  Future<void> _checkRecoverySession() async {
    // 1. If Supabase already has an active session
    if (Supabase.instance.client.auth.currentSession != null) {
      if (mounted) {
        setState(() {
          _validatingSession = false;
          _authErrorDetails = null;
          _resetEmailSent = false;
        });
      }
      return;
    }

    // 2. Check if deep link brought an explicit error parameter (e.g. otp_expired, access_denied)
    final passedError = ref.read(passwordRecoveryErrorProvider);
    if (passedError != null && passedError.isNotEmpty) {
      if (mounted) {
        setState(() {
          _validatingSession = false;
          _resetEmailSent = false;
          _authErrorDetails = AuthErrorDetails.fromError(passedError);
        });
      }
      return;
    }

    // 3. Hydrate session from recovery URI
    final uri = ref.read(passwordRecoveryUriProvider);
    if (uri != null && AppEnvironment.cloudConfigured) {
      try {
        await Supabase.instance.client.auth.getSessionFromUrl(uri);
      } catch (_) {}

      // Fallback: If session not yet established, parse refreshToken from fragment or query
      if (Supabase.instance.client.auth.currentSession == null) {
        try {
          final fragment = uri.fragment;
          final fragmentParams = fragment.isNotEmpty
              ? Uri.splitQueryString(fragment)
              : <String, String>{};
          final refreshToken =
              fragmentParams['refresh_token'] ??
              uri.queryParameters['refresh_token'];
          if (refreshToken != null && refreshToken.isNotEmpty) {
            await Supabase.instance.client.auth.setSession(refreshToken);
          }
        } catch (_) {}
      }

      if (Supabase.instance.client.auth.currentSession != null) {
        if (mounted) {
          setState(() {
            _validatingSession = false;
            _authErrorDetails = null;
            _resetEmailSent = false;
          });
        }
        return;
      }
    }

    // 4. Poll for up to 3 seconds for background hydration
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentSession != null) {
        setState(() {
          _validatingSession = false;
          _authErrorDetails = null;
          _resetEmailSent = false;
        });
        return;
      }
    }

    // 5. If still no session after polling, only then declare missing/expired session
    if (mounted) {
      setState(() {
        _validatingSession = false;
        _resetEmailSent = false;
        _authErrorDetails = AuthErrorDetails.fromError(
          'AuthException(message: Auth session missing!, statusCode: 400)',
        );
      });
    }
  }

  Future<void> _sendNewResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _authErrorDetails = AuthErrorDetails(
          type: AuthErrorType.somethingWentWrong,
          title: _tr(context, 'Email required'),
          message: _tr(
            context,
            'Please enter a valid email address to request a new link.',
          ),
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
      ref.read(lastAuthEmailProvider.notifier).state = email;
      ref.read(passwordResetSentEmailProvider.notifier).state = email;
      // Clear previous error and previous URI so incoming new link cleanly triggers hydration
      ref.read(passwordRecoveryErrorProvider.notifier).state = null;
      ref.read(passwordRecoveryUriProvider.notifier).state = null;

      if (mounted) {
        setState(() {
          _resetEmailSent = true;
          _sentEmailAddress = email;
          _authErrorDetails = null;
        });
        AppToast.showSuccess(
          context,
          _tr(
            context,
            'Password reset instructions have been sent to your email address.',
          ),
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

  @override
  void dispose() {
    _authSub?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _passwordValidator(String? value) {
    if (value == null || value.isEmpty) {
      return _tr(context, 'This field is required.');
    }
    if (value.length < 8) {
      return _tr(context, 'Use at least 8 characters.');
    }
    return null;
  }

  String? _confirmPasswordValidator(String? value) {
    if (value == null || value.isEmpty) {
      return _tr(context, 'Please confirm your password');
    }
    if (value != _passwordController.text) {
      return _tr(context, 'Passwords do not match');
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _authErrorDetails = null;
    });

    final newPassword = _passwordController.text;
    try {
      await ref
          .read(authServiceProvider)
          .updatePassword(newPassword: newPassword);
      if (!mounted) return;

      AppToast.showSuccess(
        context,
        _tr(context, 'Password updated successfully! Welcome back.'),
      );

      final email = Supabase.instance.client.auth.currentUser?.email;
      if (email != null && email.isNotEmpty) {
        await AppCredentialManager.instance.saveCredential(
          email: email,
          password: newPassword,
        );
      }

      try {
        await FlutterSecureStorage().delete(
          key: 'onebill.auth.in_password_recovery',
        );
      } catch (_) {}

      ref.read(isPasswordRecoveryProvider.notifier).state = false;
      ref.read(passwordRecoveryErrorProvider.notifier).state = null;
      ref.read(passwordRecoveryUriProvider.notifier).state = null;
      ref.read(isSigningOutProvider.notifier).state = false;
      ref.invalidate(sessionProvider);
      ref.invalidate(authSessionProvider);
    } catch (error) {
      if (mounted) {
        setState(() => _authErrorDetails = AuthErrorDetails.fromError(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    // 1. Immediately guard root router by setting isSigningOutProvider to true
    // so it renders _AuthScreen and blocks any auto-entry into HomeScreen or WorkspaceSetupScreen
    ref.read(isSigningOutProvider.notifier).state = true;

    // 2. Clear recovery marker from secure storage
    try {
      await FlutterSecureStorage().delete(
        key: 'onebill.auth.in_password_recovery',
      );
    } catch (_) {}

    // 3. Clear local notifications
    try {
      await ref.read(notificationServiceProvider).cancelAll();
    } catch (_) {}

    // 4. Force full sign out from Supabase while preserving local offline data
    // and its sync queue. A later sign-in under another account is isolated by
    // restoreAccount before the workspace is exposed.
    try {
      await ref.read(authServiceProvider).signOut();
    } catch (_) {}

    // 5. Reset security lock authenticated state
    try {
      await ref.read(securityServiceProvider).markAuthenticated();
    } catch (_) {}

    // 6. Reset password recovery state
    ref.read(isPasswordRecoveryProvider.notifier).state = false;
    ref.read(passwordRecoveryErrorProvider.notifier).state = null;
    ref.read(passwordRecoveryUriProvider.notifier).state = null;
    ref.read(passwordResetSentEmailProvider.notifier).state = null;

    // 8. Invalidate auth and session providers
    ref.invalidate(authSessionProvider);
    ref.invalidate(sessionProvider);

    if (mounted) {
      setState(() => _submitting = false);
    }
  }

  Widget _buildErrorBox(ThemeData theme) {
    if (_authErrorDetails == null) return const SizedBox.shrink();
    final err = _authErrorDetails!;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 22,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _tr(context, err.title),
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
            _tr(context, err.message),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer.withValues(alpha: 0.9),
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessBox(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final boxBg = isDark
        ? const Color(0xFF064E3B).withValues(alpha: 0.45)
        : const Color(0xFFE8F5E9);
    final boxBorder = isDark
        ? const Color(0xFF25D366).withValues(alpha: 0.5)
        : const Color(0xFF86EFAC);
    final titleColor = isDark
        ? const Color(0xFF25D366)
        : const Color(0xFF1B5E20);

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: boxBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: boxBorder, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mark_email_read_rounded, size: 24, color: titleColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _tr(context, 'Password reset email sent!'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _tr(
              context,
              'Password reset instructions have been sent to your email address.',
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (_sentEmailAddress != null && _sentEmailAddress!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF047857).withValues(alpha: 0.3)
                    : const Color(0xFFC8E6C9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _sentEmailAddress!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Uri?>(passwordRecoveryUriProvider, (prev, next) {
      if (next != null) {
        setState(() {
          _validatingSession = true;
          _authErrorDetails = null;
          _resetEmailSent = false;
        });
        _checkRecoverySession();
      }
    });

    final theme = Theme.of(context);
    if (_validatingSession) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_tr(context, 'Checking reset link...')),
            ],
          ),
        ),
      );
    }

    final isExpired =
        _authErrorDetails != null &&
        (_authErrorDetails!.title == 'Reset link expired' ||
            Supabase.instance.client.auth.currentSession == null);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) {
          _cancel();
        }
      },
      child: Scaffold(
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
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.25),
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
                        _tr(context, 'Reset your password'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isExpired
                            ? (_resetEmailSent
                                  ? _tr(
                                      context,
                                      'Check your email inbox to reset your password.',
                                    )
                                  : _tr(
                                      context,
                                      'This password reset link has expired or has already been used.',
                                    ))
                            : _tr(
                                context,
                                'Enter a new password for your OneBill account.',
                              ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Prominent Preferred Language Choice (Design identical to Sign-in & Create Business pages)
                      Builder(
                        builder: (context) {
                          final activeLang = ref.watch(appLanguageProvider);
                          final effectiveLang =
                              {'en', 'hi', 'te'}.contains(activeLang)
                              ? activeLang
                              : 'en';

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _tr(context, 'Choose your preferred language'),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  _LanguageChoiceCard(
                                    code: 'en',
                                    nativeTitle: 'English',
                                    subtitle: 'English',
                                    isSelected: effectiveLang == 'en',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('en'),
                                  ),
                                  const SizedBox(width: 8),
                                  _LanguageChoiceCard(
                                    code: 'te',
                                    nativeTitle: 'తెలుగు',
                                    subtitle: 'Telugu',
                                    isSelected: effectiveLang == 'te',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('te'),
                                  ),
                                  const SizedBox(width: 8),
                                  _LanguageChoiceCard(
                                    code: 'hi',
                                    nativeTitle: 'हिन्दी',
                                    subtitle: 'Hindi',
                                    isSelected: effectiveLang == 'hi',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('hi'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      if (isExpired) ...[
                        if (_resetEmailSent) ...[
                          _buildSuccessBox(theme),
                          FilledButton(
                            onPressed: _submitting ? null : _cancel,
                            child: Text(_tr(context, 'Back to sign in')),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _submitting ? null : _sendNewResetEmail,
                            child: Text(_tr(context, 'Resend email')),
                          ),
                        ] else ...[
                          _buildErrorBox(theme),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: _tr(context, 'Email address'),
                              prefixIcon: const Icon(Icons.email_outlined),
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _submitting ? null : _sendNewResetEmail,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded),
                            label: Text(_tr(context, 'Request new link')),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _submitting ? null : _cancel,
                            child: Text(_tr(context, 'Back to sign in')),
                          ),
                        ],
                      ] else ...[
                        _buildErrorBox(theme),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            labelText: _tr(context, 'New password'),
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),
                          validator: _passwordValidator,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          obscureText: _obscureConfirmPassword,
                          decoration: InputDecoration(
                            labelText: _tr(context, 'Confirm new password'),
                            prefixIcon: const Icon(Icons.lock_reset_rounded),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirmPassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscureConfirmPassword =
                                    !_obscureConfirmPassword,
                              ),
                            ),
                          ),
                          validator: _confirmPasswordValidator,
                        ),
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
                              : Text(_tr(context, 'Update password')),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _submitting ? null : _cancel,
                          child: Text(_tr(context, 'Back to sign in')),
                        ),
                      ],
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

class _AuthScreen extends ConsumerStatefulWidget {
  const _AuthScreen();
  @override
  ConsumerState<_AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<_AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _submitting = false;
  bool _isGoogleAuthPending = false;
  bool _obscurePassword = true;
  AuthErrorDetails? _authErrorDetails;

  bool get _canSubmit =>
      _emailValidator(_email.text) == null &&
      _passwordValidator(_password.text) == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final savedEmail =
            ref.read(passwordResetSentEmailProvider) ??
            ref.read(lastAuthEmailProvider);
        if (savedEmail != null &&
            savedEmail.isNotEmpty &&
            _email.text.isEmpty) {
          _email.text = savedEmail;
        }
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
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
    ref.read(lastAuthEmailProvider.notifier).state = email;
    try {
      await ref.read(authServiceProvider).resetPassword(email: email);
      ref.read(passwordResetSentEmailProvider.notifier).state = email;
      if (mounted) {
        AppToast.showSuccess(
          context,
          _tr(
            context,
            'Password reset instructions have been sent to your email address.',
          ),
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

  Future<void> _resendResetEmail(String email) async {
    setState(() {
      _submitting = true;
      _authErrorDetails = null;
    });
    try {
      await ref.read(authServiceProvider).resetPassword(email: email);
      ref.read(passwordResetSentEmailProvider.notifier).state = email;
      if (mounted) {
        AppToast.showSuccess(
          context,
          _tr(
            context,
            'Password reset instructions have been sent to your email address.',
          ),
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
    ref.read(lastAuthEmailProvider.notifier).state = email;
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
      final success = await ref.read(authServiceProvider).signInWithGoogle();
      if (!success && mounted) {
        // User cancelled or dismissed the Google account chooser
        setState(() {
          _submitting = false;
          _isGoogleAuthPending = false;
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
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.3),
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
                  _tr(context, err.title),
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
            _tr(context, err.message),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer.withValues(alpha: 0.9),
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
                  child: Text(_tr(context, 'Create account')),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _authErrorDetails = null);
                  },
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_tr(context, 'Try again')),
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
                child: Text(_tr(context, 'Forgot password?')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmailSentBox(ThemeData theme, String sentEmail) {
    final isDark = theme.brightness == Brightness.dark;
    final boxBg = isDark
        ? const Color(0xFF064E3B).withValues(alpha: 0.35)
        : const Color(0xFFE8F5E9);
    final boxBorder = isDark
        ? const Color(0xFF25D366).withValues(alpha: 0.5)
        : const Color(0xFF86EFAC);
    final titleColor = isDark
        ? const Color(0xFF25D366)
        : const Color(0xFF1B5E20);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: boxBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: boxBorder, width: 1.5),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: titleColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.mark_email_read_rounded,
              size: 48,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _tr(context, 'Password reset email sent!'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _tr(
              context,
              'A new password reset link has been sent to your email. Please check your inbox and tap the link to set your new password.',
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF047857).withValues(alpha: 0.35)
                  : const Color(0xFFC8E6C9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.email_outlined, size: 16, color: titleColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    sentEmail,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submitting
                  ? null
                  : () => _resendResetEmail(sentEmail),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(_tr(context, 'Resend email')),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                ref.read(passwordResetSentEmailProvider.notifier).state = null;
                setState(() {
                  _authErrorDetails = null;
                });
              },
              child: Text(_tr(context, 'Back to sign in')),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sentEmail = ref.watch(passwordResetSentEmailProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.25),
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
                            ? _tr(context, 'Create your OneBill account')
                            : _tr(context, 'Sign in to OneBill'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _tr(
                          context,
                          'Your business data stays available offline after setup.',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Prominent Preferred Language Choice (Design identical to Create Business page)
                      Builder(
                        builder: (context) {
                          final activeLang = ref.watch(appLanguageProvider);
                          final effectiveLang =
                              {'en', 'hi', 'te'}.contains(activeLang)
                              ? activeLang
                              : 'en';

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _tr(context, 'Choose your preferred language'),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  _LanguageChoiceCard(
                                    code: 'en',
                                    nativeTitle: 'English',
                                    subtitle: 'English',
                                    isSelected: effectiveLang == 'en',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('en'),
                                  ),
                                  const SizedBox(width: 8),
                                  _LanguageChoiceCard(
                                    code: 'te',
                                    nativeTitle: 'తెలుగు',
                                    subtitle: 'Telugu',
                                    isSelected: effectiveLang == 'te',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('te'),
                                  ),
                                  const SizedBox(width: 8),
                                  _LanguageChoiceCard(
                                    code: 'hi',
                                    nativeTitle: 'हिन्दी',
                                    subtitle: 'Hindi',
                                    isSelected: effectiveLang == 'hi',
                                    onTap: () => ref
                                        .read(appLanguageProvider.notifier)
                                        .setLanguage('hi'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      if (sentEmail != null && sentEmail.isNotEmpty)
                        _buildEmailSentBox(theme, sentEmail)
                      else ...[
                        _buildErrorBox(theme),
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [
                            AutofillHints.email,
                            AutofillHints.username,
                          ],
                          decoration: InputDecoration(
                            labelText: _tr(context, 'Email address'),
                            prefixIcon: const Icon(Icons.email_outlined),
                          ),
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          onChanged: (_) => setState(() {}),
                          validator: _emailValidator,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _password,
                          obscureText: _obscurePassword,
                          autofillHints: const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: _tr(context, 'Password'),
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          onChanged: (_) => setState(() {}),
                          validator: _passwordValidator,
                        ),
                        if (!_registering &&
                            _authErrorDetails?.type !=
                                AuthErrorType.incorrectPassword) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _submitting ? null : _resetPassword,
                              child: Text(_tr(context, 'Forgot password?')),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _submitting || !_canSubmit
                              ? null
                              : _submit,
                          style: FilledButton.styleFrom(
                            disabledBackgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            disabledForegroundColor: theme
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.65),
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _registering
                                      ? _tr(context, 'Create account')
                                      : _tr(context, 'Sign in'),
                                ),
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
                                ? _tr(
                                    context,
                                    'Already have an account? Sign in',
                                  )
                                : _tr(
                                    context,
                                    'New to OneBill? Create an account',
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                _tr(context, 'OR'),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
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
                              color: theme.colorScheme.outline.withValues(
                                alpha: 0.5,
                              ),
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
                                      _tr(context, 'Connecting to Google...'),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: theme.colorScheme.primary,
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
                                      _tr(context, 'Sign in with Google'),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ],
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
      child: CustomPaint(painter: _GoogleIconPainter()),
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
                ? primary.withValues(alpha: 0.12)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? primary
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
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
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.w600,
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
                      ? primary.withValues(alpha: 0.85)
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
              _restoreError = _cleanErrorMessage(
                error,
                'Could not restore cloud data',
              );
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

  void _changeLanguage(String lang) {
    setState(() => _language = lang);
    ref.read(appLanguageProvider.notifier).setLanguage(lang);
    final session = ref.read(sessionProvider).valueOrNull;
    if (session != null) {
      ref
          .read(businessRepositoryProvider)
          .updateSessionLanguage(sessionId: session.id, languageCode: lang);
    }
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final activeLang = ref.read(appLanguageProvider);
      final effectiveLang = {'en', 'hi', 'te'}.contains(activeLang)
          ? activeLang
          : _language;
      await ref.read(appLanguageProvider.notifier).setLanguage(effectiveLang);
      await ref
          .read(businessRepositoryProvider)
          .createLocalWorkspace(
            accountId: ref.read(authSessionProvider).valueOrNull?.user.id,
            ownerName: _owner.text,
            businessName: _business.text,
            phone: _phone.text,
            languageCode: effectiveLang,
          );
      final session = await ref.read(sessionProvider.future);
      if (session?.activeBusinessId != null) {
        await ref
            .read(syncWorkerProvider)
            .retryFailedOperations(session!.activeBusinessId!);
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
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.25,
                    ),
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
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.25,
                          ),
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
                      _tr(
                        context,
                        'Create your first business. Your information is saved on this device and works offline.',
                      ),
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
                          color: theme.colorScheme.errorContainer.withValues(
                            alpha: 0.7,
                          ),
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
                    Builder(
                      builder: (context) {
                        final activeLang = ref.watch(appLanguageProvider);
                        final effectiveLang =
                            {'en', 'hi', 'te'}.contains(activeLang)
                            ? activeLang
                            : _language;

                        return Column(
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
                                  isSelected: effectiveLang == 'en',
                                  onTap: () => _changeLanguage('en'),
                                ),
                                const SizedBox(width: 8),
                                _LanguageChoiceCard(
                                  code: 'te',
                                  nativeTitle: 'తెలుగు',
                                  subtitle: 'Telugu',
                                  isSelected: effectiveLang == 'te',
                                  onTap: () => _changeLanguage('te'),
                                ),
                                const SizedBox(width: 8),
                                _LanguageChoiceCard(
                                  code: 'hi',
                                  nativeTitle: 'हिन्दी',
                                  subtitle: 'Hindi',
                                  isSelected: effectiveLang == 'hi',
                                  onTap: () => _changeLanguage('hi'),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _owner,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Owner name'),
                        prefixIcon: const Icon(Icons.person_outline_rounded),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? _tr(context, 'This field is required.')
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _business,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Business or shop name'),
                        prefixIcon: const Icon(Icons.storefront_outlined),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? _tr(context, 'This field is required.')
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Business phone (optional)'),
                        prefixIcon: const Icon(Icons.phone_outlined),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return null;
                        final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
                        return RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits)
                            ? null
                            : _tr(
                                context,
                                'Enter a valid 10-digit Indian mobile number.',
                              );
                      },
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
  late final PageController _pageController = PageController(initialPage: _tab);
  DateTime? _lastBackPress;

  void _setTab(int index, {bool animate = true}) {
    if (_tab == index) return;
    setState(() {
      _tab = index;
      if (index < 4) {
        _bottomTab = index;
      }
    });
    if (_pageController.hasClients) {
      if (animate) {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
        );
      } else {
        _pageController.jumpToPage(index);
      }
    }
  }

  var _lockChecking = true;
  var _locked = false;
  var _biometricEnabled = false;
  String? _unlockError;
  final _lockPin = TextEditingController();
  bool _checkingPin = false;
  bool _isSigningOut = false;
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

  void _openOverdueSheet([String? businessId]) async {
    if (!mounted) return;
    final bId = businessId ?? widget.session.activeBusinessId;
    if (bId == null) return;
    if (businessId != null && businessId != widget.session.activeBusinessId) {
      await ref
          .read(businessRepositoryProvider)
          .switchBusiness(sessionId: widget.session.id, businessId: businessId);
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OverdueInvoicesSheet(businessId: bId),
    );
  }

  void _openReportsTab([String? businessId]) async {
    if (!mounted) return;
    final targetBizId = businessId ?? widget.session.activeBusinessId;
    if (targetBizId == null) return;
    if (businessId != null && businessId != widget.session.activeBusinessId) {
      await ref
          .read(businessRepositoryProvider)
          .switchBusiness(sessionId: widget.session.id, businessId: businessId);
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Consumer(
          builder: (context, ref, _) {
            final summary = ref.watch(
              businessBillingSummaryProvider(targetBizId),
            );
            final customers = ref.watch(customersProvider(targetBizId));
            return Scaffold(
              appBar: AppBar(title: Text(_tr(context, 'Reports'))),
              body: _ReportsTab(
                businessId: targetBizId,
                summary: summary,
                customers: customers,
              ),
            );
          },
        ),
      ),
    );
  }

  void _openInvoiceDetails(String invoiceId, [String? businessId]) async {
    if (!mounted) return;
    final bId = businessId ?? widget.session.activeBusinessId;
    if (bId == null) return;
    if (businessId != null && businessId != widget.session.activeBusinessId) {
      await ref
          .read(businessRepositoryProvider)
          .switchBusiness(sessionId: widget.session.id, businessId: businessId);
    }
    final db = ref.read(databaseProvider);
    final inv = await (db.select(
      db.invoices,
    )..where((i) => i.id.equals(invoiceId))).getSingleOrNull();
    if (inv != null && mounted) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _InvoiceDetailsSheet(businessId: bId, invoice: inv),
      );
    }
  }

  void _openCustomerDetails(String customerId, [String? businessId]) async {
    if (!mounted) return;
    final bId = businessId ?? widget.session.activeBusinessId;
    if (bId == null) return;
    if (businessId != null && businessId != widget.session.activeBusinessId) {
      await ref
          .read(businessRepositoryProvider)
          .switchBusiness(sessionId: widget.session.id, businessId: businessId);
    }
    final db = ref.read(databaseProvider);
    final cust = await (db.select(
      db.customers,
    )..where((c) => c.id.equals(customerId))).getSingleOrNull();
    if (cust != null && mounted) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _CustomerDetailsSheet(businessId: bId, customer: cust),
      );
    }
  }

  void _openSyncSheet() {
    if (!mounted) return;
    final bId = widget.session.activeBusinessId;
    if (bId == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SyncQueueSheet(businessId: bId),
    );
  }

  void _handleNotificationPayload(String payloadStr, [String? actionId]) {
    try {
      final data = jsonDecode(payloadStr) as Map<String, dynamic>;
      final action = actionId ?? (data['action'] as String?);
      final invoiceId = data['invoiceId'] as String?;
      final customerId = data['customerId'] as String?;
      final businessId = data['businessId'] as String?;

      if (action == 'view_overdue' ||
          (action == NotificationActionKeys.viewInvoice && invoiceId == null)) {
        _openOverdueSheet(businessId);
      } else if (invoiceId != null &&
          (action == NotificationActionKeys.viewInvoice ||
              action == NotificationActionKeys.viewPayment ||
              action == NotificationActionKeys.shareInvoice ||
              action == 'view_invoice' ||
              action == 'view_payment' ||
              action == 'share_invoice')) {
        _openInvoiceDetails(invoiceId, businessId);
      } else if (customerId != null &&
          (action == NotificationActionKeys.viewCustomer ||
              action == 'view_customer' ||
              action == 'view_customers')) {
        _openCustomerDetails(customerId, businessId);
      } else if (action == NotificationActionKeys.viewSummary ||
          action == 'view_summary' ||
          action == 'view_reports') {
        _openReportsTab(businessId);
      }
    } catch (_) {}
  }

  void _syncNow() {
    if (!mounted) return;
    ref.read(syncWorkerProvider).syncBusiness(widget.session.activeBusinessId!);
  }

  @override
  void dispose() {
    _isSigningOut = true;
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _syncQueueSubscription?.close();
    _syncTimer?.cancel();
    _lockPin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isSigningOut || ref.read(isSigningOutProvider)) return;
    final security = ref.read(securityServiceProvider);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      security.markBackgrounded();
    }
    if (state == AppLifecycleState.resumed) {
      _syncNow();
      // Rebuild reminder and summary schedules from the latest local invoice
      // and payment state whenever the app returns from the background.
      // This is account-scoped inside NotificationService and does not block
      // the app-lock flow.
      unawaited(_refreshNotificationsOnResume());
      security.shouldLockOnResume().then((shouldLock) {
        if (shouldLock &&
            mounted &&
            !_isSigningOut &&
            !ref.read(isSigningOutProvider)) {
          _checkAppLock(lockIfEnabled: true);
        }
      });
    }
  }

  Future<void> _refreshNotificationsOnResume() async {
    try {
      await ref.read(notificationServiceProvider).reconcileAllReminders();
    } catch (error) {
      // Notification failures must never prevent the app from resuming.
      debugPrint('OneBill notification refresh failed: ${error.runtimeType}');
    }
  }

  Future<void> _checkAppLock({bool lockIfEnabled = false}) async {
    if (_isSigningOut || ref.read(isSigningOutProvider)) return;
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
          SnackBar(
            content: Text(
              _tr(
                context,
                'App lock storage is unavailable. Please disable and enable App Lock again.',
              ),
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
    if (enabled &&
        biometric &&
        mounted &&
        !_isSigningOut &&
        !ref.read(isSigningOutProvider)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryBiometricUnlock(),
      );
    }
  }

  Future<void> _tryBiometricUnlock() async {
    if (_isSigningOut ||
        !_locked ||
        _checkingPin ||
        ref.read(isSigningOutProvider)) {
      return;
    }
    final ok = await ref.read(securityServiceProvider).authenticateBiometrics();
    if (ok && mounted && !_isSigningOut && !ref.read(isSigningOutProvider)) {
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
        final remaining = await ref
            .read(securityServiceProvider)
            .pinLockRemaining();
        if (!mounted) return;
        final err = remaining != null
            ? _tr(context, 'Too many incorrect PIN attempts. Try again later.')
            : _tr(context, 'Incorrect PIN. Please try again.');
        setState(() => _unlockError = err);
        _lockPin.clear();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                context,
                'Could not read the app PIN. Disable and enable App Lock again.',
              ),
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
    final confirmed = await showConfirmDeleteBusinessDialog(
      context,
      businessName: business.name,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(businessRepositoryProvider)
          .deleteBusiness(businessId: business.id);
      ref.read(syncWorkerProvider).syncBusiness(business.id);

      ref.invalidate(sessionProvider);
      ref.invalidate(businessesProvider(business.accountId));
      if (widget.session.accountId != null) {
        ref.invalidate(businessesProvider(widget.session.accountId!));
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_tr(context, "Business deleted:")} ${business.name}',
            ),
          ),
        );
        final nextSession = await ref.read(sessionProvider.future);
        if (context.mounted &&
            (nextSession == null || nextSession.activeBusinessId == null)) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
    } catch (error) {
      if (context.mounted) {
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
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.language_rounded),
                tooltip: _tr(context, 'Language'),
                onSelected: (code) {
                  ref.read(appLanguageProvider.notifier).setLanguage(code);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'en', child: Text('English')),
                  PopupMenuItem(value: 'hi', child: Text('हिन्दी (Hindi)')),
                  PopupMenuItem(value: 'te', child: Text('తెలుగు (Telugu)')),
                ],
              ),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 52),
              const SizedBox(height: 12),
              Text(
                _tr(context, 'Unlock OneBill'),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
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
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Enter PIN'),
                  ),
                  onChanged: _onLockPinChanged,
                  onSubmitted: (_) => _unlock(),
                ),
              ),
              FilledButton.icon(
                onPressed: _checkingPin ? null : _unlock,
                icon: const Icon(Icons.lock_open),
                label: Text(
                  _checkingPin
                      ? _tr(context, 'Checking...')
                      : _tr(context, 'Unlock with PIN'),
                ),
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
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _tr(
                              context,
                              'Biometric authentication was cancelled or unavailable.',
                            ),
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_tr(context, 'Use Biometric')),
                ),
            ],
          ),
        ),
      );
    }
    final currentSession = ref.watch(sessionProvider).valueOrNull;
    if (currentSession != null && currentSession.activeBusinessId == null) {
      return const _WorkspaceSetupScreen();
    }
    final session =
        (currentSession != null && currentSession.activeBusinessId != null)
        ? currentSession
        : widget.session;
    if (session.activeBusinessId == null) {
      return const _WorkspaceSetupScreen();
    }
    final customers = ref.watch(customersProvider(session.activeBusinessId!));
    final syncStatus = ref.watch(
      syncQueueStatusProvider(session.activeBusinessId!),
    );
    final summary = ref.watch(
      businessBillingSummaryProvider(session.activeBusinessId!),
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
                          _tr(context, 'Delete'),
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
              onOpenInvoice: _openInvoiceDetails,
              onOpenCustomer: _openCustomerDetails,
              onOpenSync: _openSyncSheet,
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
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(
                              title: Text(_tr(context, 'Recycle Bin')),
                            ),
                            body: _RecycleBinTab(
                              businessId: session.activeBusinessId!,
                            ),
                          ),
                        ),
                      );
                      break;
                    case 'activity':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(
                              title: Text(_tr(context, 'Activity')),
                            ),
                            body: _ActivityTab(
                              businessId: session.activeBusinessId!,
                            ),
                          ),
                        ),
                      );
                      break;
                    case 'reports':
                      _openReportsTab();
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
        body: PageView(
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          onPageChanged: (value) {
            setState(() {
              _tab = value;
              if (value < 4) {
                _bottomTab = value;
              }
            });
          },
          children: [
            _DashboardTab(
              businessId: session.activeBusinessId!,
              customers: customers,
              summary: summary,
              onShowCustomers: () => _setTab(1),
            ),
            _CustomersTab(
              businessId: session.activeBusinessId!,
              customers: customers,
            ),
            _IncomeTab(businessId: session.activeBusinessId!),
            _ExpensesTab(businessId: session.activeBusinessId!),
          ],
        ),
        floatingActionButton: _tab == 2
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
          onDestinationSelected: (value) => _setTab(value),
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
      _setTab(0);
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
          _tr(
            context,
            'You will need internet to sign in again. Local business data remains protected on this device.',
          ),
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
    if (confirmed != true || !context.mounted) return;

    final security = ref.read(securityServiceProvider);
    final isLockEnabled = await security.isPinEnabled();
    if (!context.mounted) return;
    if (isLockEnabled) {
      final authenticated = await _authenticateForSecurity(context, ref);
      if (!authenticated) {
        if (mounted) setState(() => _isSigningOut = false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_tr(context, 'Sign out cancelled'))),
          );
        }
        return;
      }
    }

    final db = ref.read(databaseProvider);
    final session =
        await (db.select(db.localSessions)
              ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)])
              ..limit(1))
            .getSingleOrNull();
    final ownedBusinessIds = session?.accountId == null
        ? <String>[]
        : (await (db.select(
                db.businesses,
              )..where((b) => b.accountId.equals(session!.accountId!))).get())
              .map((b) => b.id)
              .toList();
    var pendingBusinessIds = <String>[];
    if (ownedBusinessIds.isNotEmpty) {
      final pending =
          await (db.select(db.syncOperations)..where(
                (op) =>
                    op.businessId.isIn(ownedBusinessIds) &
                    (op.status.equals('pending') |
                        (op.status.isNotValue('synced') &
                            op.status.isNotValue('pending'))),
              ))
              .get();
      pendingBusinessIds = pending.map((op) => op.businessId!).toSet().toList();
    }

    if (pendingBusinessIds.isNotEmpty && context.mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_tr(dialogContext, 'Unsynchronized changes')),
          content: Text(
            _tr(
              dialogContext,
              'Some changes are still waiting to sync. Sync them before signing out to keep your data current.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'cancel'),
              child: Text(_tr(dialogContext, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'sync'),
              child: Text(_tr(dialogContext, 'Sync now')),
            ),
          ],
        ),
      );
      if (action == 'cancel' || action == null || !context.mounted) return;
      if (action == 'sync') {
        for (final businessId in pendingBusinessIds) {
          try {
            await ref
                .read(syncWorkerProvider)
                .retryFailedOperations(businessId);
          } catch (_) {}
        }
        final remaining =
            await (db.select(db.syncOperations)..where(
                  (op) =>
                      op.businessId.isIn(ownedBusinessIds) &
                      (op.status.equals('pending') |
                          (op.status.isNotValue('synced') &
                              op.status.isNotValue('pending'))),
                ))
                .get();
        if (remaining.isNotEmpty && context.mounted) {
          final keepLocal = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(_tr(dialogContext, 'Sync unavailable')),
              content: Text(
                _tr(
                  dialogContext,
                  'Your unsynchronized data will be kept safely on this device. You can cancel and try again later.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(_tr(dialogContext, 'Cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(_tr(dialogContext, 'Keep data and sign out')),
                ),
              ],
            ),
          );
          if (keepLocal != true || !context.mounted) return;
        }
      }
    }

    if (mounted) setState(() => _isSigningOut = true);

    final auth = ref.read(authServiceProvider);
    final notifService = ref.read(notificationServiceProvider);

    try {
      await const FlutterSecureStorage().delete(
        key: 'onebill.auth.in_password_recovery',
      );
    } catch (_) {}
    try {
      await notifService.cancelAll();
    } catch (_) {}
    // Keep the local account and its pending queue. On the next sign-in,
    // restoreAccount clears foreign-account data before exposing the workspace.
    // Set the guard before signOut so the auth listener does not interpret an
    // intentional sign-out as an externally deleted account.
    ref.read(isSigningOutProvider.notifier).state = true;
    try {
      await auth.signOut();
    } catch (_) {}
    try {
      await security.markAuthenticated();
    } catch (_) {}

    ref.invalidate(sessionProvider);
    ref.invalidate(authSessionProvider);
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
            _tr(
              context,
              'App lock storage is unavailable. Please restart the app and try again.',
            ),
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
  final signOutReason = _tr(context, 'Confirm identity to sign out of OneBill');
  if (await service.isBiometricEnabled() &&
      await service.authenticateBiometrics(reason: signOutReason)) {
    await service.markAuthenticated();
    return true;
  }
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const _ConfirmPinDialog(),
  );
  if (result == true) {
    await service.markAuthenticated();
    return true;
  }
  return false;
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
      setState(() => _error = _tr(context, 'PIN must contain 4 to 6 digits.'));
      return;
    }
    if (value != confirmation) {
      setState(
        () => _error = _tr(context, "PINs don't match. Please try again."),
      );
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
          _error = '${_tr(context, "Could not save PIN")}: $e';
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
        title: Text(_tr(context, 'Use Biometric?')),
        content: Text(
          _tr(
            context,
            'Biometric will be the primary unlock method. Your PIN remains available as a fallback.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _setBiometric(false),
            child: Text(_tr(context, 'Not now')),
          ),
          FilledButton(
            onPressed: _saving ? null : () => _setBiometric(true),
            child: Text(
              _saving ? _tr(context, 'Saving...') : _tr(context, 'Enable'),
            ),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(
        widget.enabled
            ? _tr(context, 'Change PIN')
            : _tr(context, 'Secure OneBill'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _tr(context, 'Choose a secure 4–6 digit PIN for offline unlock.'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            decoration: InputDecoration(labelText: _tr(context, 'Create PIN')),
          ),
          TextField(
            controller: _confirm,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            decoration: InputDecoration(labelText: _tr(context, 'Confirm PIN')),
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
          child: Text(_tr(context, 'Cancel')),
        ),
        if (widget.enabled)
          TextButton(
            onPressed: _saving ? null : _disableAppLock,
            child: Text(_tr(context, 'Disable')),
          ),
        FilledButton(
          onPressed: _saving ? null : _savePin,
          child: Text(
            _saving ? _tr(context, 'Saving...') : _tr(context, 'Save'),
          ),
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
        final remaining = await ref
            .read(securityServiceProvider)
            .pinLockRemaining();
        setState(() {
          _checking = false;
          _error = remaining != null
              ? _tr(
                  context,
                  'Too many incorrect PIN attempts. Try again later.',
                )
              : _tr(context, 'Incorrect PIN. Please try again.');
          _pin.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = _tr(context, 'Could not verify PIN.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_tr(context, 'Confirm your PIN')),
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
          decoration: InputDecoration(labelText: _tr(context, 'Enter PIN')),
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
        child: Text(_tr(context, 'Cancel')),
      ),
      FilledButton(
        onPressed: _checking ? null : _submit,
        child: Text(
          _checking ? _tr(context, 'Checking...') : _tr(context, 'Continue'),
        ),
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
  });
  final String businessId;
  final AsyncValue<List<Customer>> customers;
  final AsyncValue<BillingSummary> summary;
  final VoidCallback onShowCustomers;

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
              _tr(
                context,
                '{amount} remains overdue. Tap to view and review payment status.',
              ).replaceAll('{amount}', _rupees(overdue)),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => _OverdueInvoicesSheet(businessId: businessId),
            ),
          ),
        ),
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
                    label: 'Due',
                    value: _rupees(data.totalOutstandingPaise),
                    icon: Icons.payments_outlined,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _OverdueInvoicesSheet(
                        businessId: businessId,
                        isOverdueOnly: false,
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
                        isOverdueOnly: true,
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
    final paymentsAsync = ref.watch(
      businessPaymentsProvider(widget.businessId),
    );
    final ownerIncomeAsync = ref.watch(
      incomeEntriesProvider(widget.businessId),
    );

    if (paymentsAsync.isLoading || ownerIncomeAsync.isLoading) {
      return const _SkeletonListLoader();
    }
    if (paymentsAsync.hasError) {
      return Center(
        child: Text(
          'Unable to load customer payments.\n${paymentsAsync.error}',
        ),
      );
    }
    if (ownerIncomeAsync.hasError) {
      return Center(
        child: Text(
          'Unable to load owner income entries.\n${ownerIncomeAsync.error}',
        ),
      );
    }

    final customerPayments = paymentsAsync.valueOrNull ?? [];
    final ownerEntries = ownerIncomeAsync.valueOrNull ?? [];

    final customerTotal = customerPayments.fold<int>(
      0,
      (s, e) => s + e.amountPaise,
    );
    final ownerTotal = ownerEntries.fold<int>(0, (s, e) => s + e.amountPaise);
    final grandTotal = customerTotal + ownerTotal;

    final allCombined = <_CombinedIncomeItem>[
      ...customerPayments.map(_CombinedIncomeItem.fromPayment),
      ...ownerEntries.map(_CombinedIncomeItem.fromOwnerEntry),
    ]..sort((a, b) => b.date.compareTo(a.date));

    final query = search.text.trim().toLowerCase();
    final sourceFiltered = allCombined.where((item) {
      if (_filterSource == 'customer' &&
          item.sourceType != _IncomeSourceType.customer) {
        return false;
      }
      if (_filterSource == 'owner' &&
          item.sourceType != _IncomeSourceType.owner) {
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
                      ? _tr(
                          context,
                          'No manual owner income entries added yet. Tap "+ Add Income" above to add one.',
                        )
                      : _filterSource == 'customer'
                      ? _tr(context, 'No customer payments recorded yet.')
                      : _tr(context, 'No income records found.'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ...sortedMonths.map((entry) {
          final monthTotal = entry.value.fold<int>(
            0,
            (s, e) => s + e.amountPaise,
          );
          final custCount = entry.value
              .where((e) => e.sourceType == _IncomeSourceType.customer)
              .length;
          final ownerCount = entry.value
              .where((e) => e.sourceType == _IncomeSourceType.owner)
              .length;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
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
      avatar: Icon(icon, size: 18, color: isSelected ? onPrimary : primary),
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
        color: isSelected
            ? primary
            : theme.colorScheme.outline.withValues(alpha: 0.3),
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
      final day = DateTime(item.date.year, item.date.month, item.date.day);
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.5,
                        ),
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
                    side: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                  child: Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                      title: Text(
                        _date(entry.key),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      subtitle: Text(
                        '${_tr(context, 'Day Total')}: ${_rupees(dayTotal)} • ${entry.value.length} ${entry.value.length == 1 ? _tr(context, 'entry') : _tr(context, 'entries')}',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                      children: entry.value.map((item) {
                        final isCust =
                            item.sourceType == _IncomeSourceType.customer;
                        final p = item.payment;
                        final o = item.ownerEntry;
                        final method = isCust
                            ? _formatTitleCase(p?.method ?? 'Cash')
                            : _tr(context, 'Owner Entry');
                        final note = isCust ? p?.note : o?.description;
                        final timeStr = TimeOfDay.fromDateTime(
                          item.date,
                        ).format(context);

                        return Container(
                          margin: const EdgeInsets.only(top: 8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _showIncomeDetailSheet(
                                context,
                                businessId: businessId,
                                item: item,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor: isCust
                                          ? Colors.teal.withValues(alpha: 0.15)
                                          : theme.colorScheme.primary
                                                .withValues(alpha: 0.15),
                                      child: Icon(
                                        isCust
                                            ? Icons.receipt_long_outlined
                                            : Icons.person_add_alt_1_outlined,
                                        color: isCust
                                            ? Colors.teal
                                            : theme.colorScheme.primary,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  isCust
                                                      ? _tr(
                                                          context,
                                                          'Customer Payment',
                                                        )
                                                      : _tr(
                                                          context,
                                                          'Owner Entry',
                                                        ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 13.5,
                                                  ),
                                                ),
                                              ),
                                              if (isCust) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.teal
                                                        .withValues(
                                                          alpha: 0.12,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    method,
                                                    style: const TextStyle(
                                                      color: Colors.teal,
                                                      fontSize: 10.5,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            note != null &&
                                                    note.trim().isNotEmpty
                                                ? '$timeStr • ${_formatTitleCase(note.trim())}'
                                                : timeStr,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
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
                                        color: isCust
                                            ? Colors.teal
                                            : theme.colorScheme.primary,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: theme.colorScheme.outline,
                                    ),
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
  return text
      .trim()
      .split(' ')
      .map((word) {
        if (word.isEmpty) return word;
        return word[0].toUpperCase() + word.substring(1).toLowerCase();
      })
      .join(' ');
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

  final formattedDate =
      '${_date(item.date)} at ${TimeOfDay.fromDateTime(item.date).format(context)}';
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
                      isCustomer
                          ? Icons.receipt_long_outlined
                          : Icons.person_add_alt_1_outlined,
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isCustomer
                                ? Colors.teal.withValues(alpha: 0.12)
                                : theme.primaryColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isCustomer
                                ? _tr(context, 'Customer Payment')
                                : _tr(context, 'Owner Entry'),
                            style: TextStyle(
                              color: isCustomer
                                  ? Colors.teal
                                  : theme.primaryColor,
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
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
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
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            '+ ${_rupees(item.amountPaise)}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isCustomer
                                  ? Colors.teal
                                  : theme.primaryColor,
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
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            formattedDate,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      if (isCustomer && p?.method != null) ...[
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _tr(context, 'Payment Method'),
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              _formatTitleCase(p!.method),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
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
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
                child: Text(
                  (note != null && note.trim().isNotEmpty)
                      ? _formatTitleCase(note.trim())
                      : (isCustomer
                            ? _tr(
                                context,
                                'Payment received for customer invoice.',
                              )
                            : _tr(context, 'Manual income recorded by owner.')),
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
        SnackBar(
          content: Text(_tr(context, 'Enter an amount greater than zero.')),
        ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _cleanErrorMessage(e, _tr(context, 'Failed to save income')),
            ),
          ),
        );
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
        content: Text(
          _tr(
            context,
            'Are you sure you want to delete this manual income entry?',
          ),
        ),
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
      await ref
          .read(incomeRepositoryProvider)
          .delete(businessId: widget.businessId, id: widget.income!.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_cleanErrorMessage(e, 'Failed to delete income')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool get _isDirty => amount.text.isNotEmpty || description.text.isNotEmpty;

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
    child: SafeArea(
      top: false,
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
              widget.income == null
                  ? _tr(context, 'Add income')
                  : _tr(context, 'Edit income'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _tr(context, 'Amount (₹)'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              decoration: InputDecoration(
                labelText: _tr(context, 'Description (optional)'),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_tr(context, 'Income date')),
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
                      if (picked != null && mounted) {
                        setState(() => date = picked);
                      }
                    },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.income != null)
                  OutlinedButton.icon(
                    onPressed: saving ? null : delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(_tr(context, 'Delete')),
                  ),
                if (widget.income != null) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: saving ? null : save,
                    child: Text(
                      saving
                          ? _tr(context, 'Saving...')
                          : (widget.income == null
                                ? _tr(context, 'Save income')
                                : _tr(context, 'Update income')),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(_tr(context, 'Edit')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(_tr(context, 'Delete')),
                          ),
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
          content: Text(
            _tr(
              context,
              'Please fill all mandatory fields (Amount and Category).',
            ),
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_cleanErrorMessage(e, 'Could not save expense')),
          ),
        );
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
    child: SafeArea(
      top: false,
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
              _tr(
                context,
                widget.expense == null ? 'Add expense' : 'Edit expense',
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
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
                if (_categoryError != null) {
                  setState(() => _categoryError = null);
                }
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
              child: Text(
                saving
                    ? _tr(context, 'Saving...')
                    : _tr(context, 'Save expense'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
                  margin: const EdgeInsets.only(bottom: 8),
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
    _animation = Tween<double>(
      begin: 0.25,
      end: 0.65,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
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
          color: baseColor.withValues(alpha: _animation.value),
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
    itemBuilder: (_, _) => _SkeletonCard(height: cardHeight),
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
                color: colorScheme.primaryContainer.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, title),
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
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
        return _EmptyState(
          icon: Icons.delete_sweep_outlined,
          title: _tr(context, 'Recycle bin is empty'),
          message: _tr(
            context,
            'Deleted customers and expenses will appear here.',
          ),
        );
      }
      return Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.delete_sweep_outlined,
                  color: Theme.of(context).colorScheme.error,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr(context, 'Recycle Bin'),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _tr(
                          context,
                          'Deleted items can be restored back to your active lists.',
                        ),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
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
                          SnackBar(
                            content: Text(_tr(context, 'Record restored')),
                          ),
                        );
                      },
                      child: Text(_tr(context, 'Restore')),
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
                          .replaceAll(
                            '{collected}',
                            _rupees(data.totalReceivedPaise),
                          )
                          .replaceAll(
                            '{billed}',
                            _rupees(data.totalBilledPaise),
                          ),
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
                            builder: (_) =>
                                _OverdueInvoicesSheet(businessId: businessId),
                          )
                        : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(_tr(context, 'Due')),
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
        .write(
          const SyncOperationsCompanion(
            status: Value('pending'),
            attemptCount: Value(0),
          ),
        );
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
          error: (error, _) => Text(
            '${_tr(context, 'Unable to load sync queue')}: ${_cleanErrorMessage(error, _tr(context, 'Something went wrong'))}',
          ),
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
                Text(
                  _tr(
                    context,
                    'Local changes are safe. Failed operations can be retried when connectivity is available.',
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(_tr(context, 'No queued operations.')),
                        )
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
                                      child: Text(_tr(context, 'Retry')),
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
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
            final color = isClear
                ? const Color(0xFF10B981)
                : const Color(0xFFEF4444);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.25)),
              ),
              child: Text(
                isClear
                    ? _tr(context, 'Clear')
                    : '${_tr(context, 'Due')} ${_rupees(outstanding)}',
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
      await ref
          .read(businessRepositoryProvider)
          .updateLanguage(
            businessId: widget.business.id,
            languageCode: newLanguage,
          );
      await ref.read(appLanguageProvider.notifier).setLanguage(newLanguage);
      await ref.read(notificationServiceProvider).reconcileSummaries();
      try {
        ref.read(syncWorkerProvider).syncBusiness(widget.business.id);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr(context, 'Language preference updated.'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _cleanErrorMessage(error, 'Could not update language'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _handleDeleteAccount(BuildContext context, WidgetRef ref) async {
    // 1. Check network connectivity before starting deletion
    try {
      final lookup = await InternetAddress.lookup(
        'supabase.co',
      ).timeout(const Duration(seconds: 4));
      if (lookup.isEmpty || lookup.first.rawAddress.isEmpty) {
        throw const SocketException('Offline');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(
              _tr(
                context,
                'Internet connection is required to delete your account. Please check your network and try again.',
              ),
            ),
          ),
        );
      }
      return;
    }

    // 2. Check pending unsynced operations
    int pendingSyncCount = 0;
    try {
      final db = ref.read(databaseProvider);
      final pendingOps = await (db.select(
        db.syncOperations,
      )..where((s) => s.businessId.equals(widget.business.id))).get();
      pendingSyncCount = pendingOps.length;
    } catch (_) {}

    // 3. Show professional confirmation dialog
    if (!context.mounted) return;
    final confirmed = await showConfirmDeleteAccountDialog(
      context,
      pendingSyncCount: pendingSyncCount,
    );

    if (confirmed != true) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr(context, 'Account deletion cancelled'))),
        );
      }
      return;
    }

    if (!context.mounted) return;

    // 4. Show modal progress barrier while deletion executes
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(color: Color(0xFFDC2626)),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  _tr(context, 'Deleting account...'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final auth = ref.read(authServiceProvider);
    final db = ref.read(databaseProvider);
    final security = ref.read(securityServiceProvider);
    final notifService = ref.read(notificationServiceProvider);
    final accountId = widget.business.accountId;
    var backendDeleted = false;

    try {
      // 5. Call backend deletion
      await auth.deleteAccount();
      backendDeleted = true;

      // 6. Backend confirmed deletion. Now perform complete local cleanup
      try {
        await notifService.cancelAll();
      } catch (_) {}
      try {
        await security.clearPin();
      } catch (_) {}
      try {
        await const FlutterSecureStorage().deleteAll();
      } catch (_) {}
      // Remove only this account's local rows. Never fall back to clearing
      // every account if a scoped cleanup fails.
      await db.deleteAccountData(accountId);
      // Mark this as an intentional sign-out before Supabase emits signedOut,
      // so the remote-deletion notice is not shown for the in-app flow.
      ref.read(isSigningOutProvider.notifier).state = true;
      try {
        await auth.signOut();
      } catch (_) {}

      // Close progress dialog if open
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      // 7. Reset session and route user to Welcome / Sign In screen
      ref.invalidate(sessionProvider);
      ref.invalidate(authSessionProvider);

      if (context.mounted) {
        Navigator.of(context).pop();
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade800,
            content: Text(_tr(context, 'Account deleted successfully')),
          ),
        );
      }
    } catch (error) {
      if (backendDeleted) {
        // The cloud account is already gone; do not leave a stale authenticated
        // session active if local cleanup encounters a recoverable failure.
        try {
          await auth.signOut();
        } catch (_) {}
        ref.read(isSigningOutProvider.notifier).state = true;
        ref.invalidate(sessionProvider);
        ref.invalidate(authSessionProvider);
      }
      // Close progress dialog
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!context.mounted) return;

      final errorDetails = AuthErrorDetails.fromError(error);
      final errorMsg = errorDetails.type == AuthErrorType.connectionProblem
          ? _tr(
              context,
              'Internet connection is required to delete your account. Please check your network and try again.',
            )
          : _cleanErrorMessage(error, _tr(context, 'Could not delete account'));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(errorMsg),
          ),
        );
      }
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
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.storefront_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ),
                title: Text(
                  widget.business.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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
                      builder: (_) =>
                          BusinessProfileScreen(businessId: widget.business.id),
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
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.notifications_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(_tr(context, 'Notifications')),
                subtitle: Text(
                  _tr(context, 'Manage payment alerts and invoice reminders'),
                ),
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
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.lock_outline_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(_tr(context, 'App Security & PIN Lock')),
                subtitle: Text(
                  _tr(context, 'Configure PIN code protection for app startup'),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _configurePin(context, ref),
              ),
            ),

            // Language Selector
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: DropdownButtonFormField<String>(
                  initialValue: ['en', 'hi', 'te'].contains(_language)
                      ? _language
                      : 'en',
                  decoration: InputDecoration(
                    labelText: _tr(context, 'App Language'),
                    border: InputBorder.none,
                    prefixIcon: const Icon(Icons.language_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(
                      value: 'hi',
                      child: Text('हिन्दी (Hindi)'),
                    ),
                    DropdownMenuItem(
                      value: 'te',
                      child: Text('తెలుగు (Telugu)'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (val) {
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
                      icon: const Icon(
                        Icons.brightness_auto_outlined,
                        size: 18,
                      ),
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
                      ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(selection.first);
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
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.cloud_sync_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(_tr(context, 'Sync Queue & Status')),
                subtitle: Text(
                  _tr(
                    context,
                    'Check offline queued operations and retry status',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        _SyncQueueSheet(businessId: widget.business.id),
                  );
                },
              ),
            ),

            const SizedBox(height: 20),
            // Section 4: Account Deletion (BELOW Data & Sync)
            Text(
              _tr(context, 'Account'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.28),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: theme.colorScheme.error.withValues(alpha: 0.55),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.delete_forever_outlined,
                    color: theme.colorScheme.error,
                  ),
                ),
                title: Text(
                  _tr(context, 'Delete Account'),
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  _tr(
                    context,
                    'Permanently delete your account and associated data.',
                  ),
                ),
                trailing: Icon(
                  Icons.arrow_forward_rounded,
                  color: theme.colorScheme.error,
                ),
                onTap: () => _handleDeleteAccount(context, ref),
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
                    _tr(
                      context,
                      'Offline-First Smart Billing & Business Management',
                    ),
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
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider).valueOrNull;
    final savedLang = ref.read(appLanguageProvider);
    _language =
        (session != null &&
            session.activeBusinessId != null &&
            session.localeCode.isNotEmpty)
        ? session.localeCode
        : (savedLang.isNotEmpty ? savedLang : 'en');
  }

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
          SnackBar(
            content: Text(_cleanErrorMessage(error, 'Could not add business')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _t(String key) => trLang(key, _language);
  String? _req(String? value) => value == null || value.trim().isEmpty
      ? _t('This field is required.')
      : null;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
              _t('Add new business'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _t(
                'This business starts with empty customers, invoices, and payments.',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _LanguageChoiceCard(
                  code: 'en',
                  nativeTitle: 'English',
                  subtitle: 'English',
                  isSelected: _language == 'en',
                  onTap: () {
                    setState(() => _language = 'en');
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
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _owner,
              decoration: InputDecoration(labelText: _t('Owner name')),
              validator: _req,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: _t('Business or shop name'),
              ),
              validator: _req,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: _t('Business phone (optional)'),
              ),
              validator: _phoneValidator,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving ? _t('Creating...') : _t('Create empty business'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _launchCustomerCall(BuildContext context, String rawPhone) async {
  final cleanNumber = rawPhone.trim().replaceAll(RegExp(r'[^\d+]'), '');
  if (cleanNumber.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _tr(context, 'No phone number available for this customer'),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }

  final uri = Uri(scheme: 'tel', path: cleanNumber);
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      await launchUrl(uri);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_tr(context, 'Could not open phone dialer')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

class _CustomerDetailsSheet extends ConsumerWidget {
  const _CustomerDetailsSheet({
    required this.businessId,
    required this.customer,
  });
  final String businessId;
  final Customer customer;

  Widget _buildCallButton(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final callBgColor = isDark
        ? const Color(0xFF064E3B).withValues(alpha: 0.55)
        : const Color(0xFFE8F5E9);
    final callBorderColor = isDark
        ? const Color(0xFF059669).withValues(alpha: 0.65)
        : const Color(0xFFA5D6A7);
    final callFgColor = isDark
        ? const Color(0xFF6EE7B7)
        : const Color(0xFF1B5E20);

    return Tooltip(
      message: _tr(context, 'Call customer'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _launchCustomerCall(context, customer.phone),
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: callBgColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: callBorderColor, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_rounded, size: 15, color: callFgColor),
                const SizedBox(width: 4),
                Text(
                  _tr(context, 'Call'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: callFgColor,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWhatsAppButton(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final waBgColor = isDark
        ? const Color(0xFF064E3B).withValues(alpha: 0.55)
        : const Color(0xFFE8F5E9);
    final waBorderColor = isDark
        ? const Color(0xFF25D366).withValues(alpha: 0.6)
        : const Color(0xFF86EFAC);
    final waFgColor = isDark
        ? const Color(0xFF25D366)
        : const Color(0xFF25D366);

    return Tooltip(
      message: _tr(context, 'WhatsApp reminder'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _sendWhatsAppReminder(context, ref),
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: waBgColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: waBorderColor, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaIcon(FontAwesomeIcons.whatsapp, size: 16, color: waFgColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendWhatsAppReminder(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final rawPhone = customer.phone.trim();
    var cleanPhone = rawPhone.replaceAll(RegExp(r'[^\d]'), '');
    if (cleanPhone.isEmpty || cleanPhone.length < 10) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                context,
                'Please enter a valid phone number for this customer.',
              ),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    if (cleanPhone.length == 10) {
      cleanPhone = '91$cleanPhone';
    }

    final invoiceRepo = ref.read(invoiceRepositoryProvider);
    final db = ref.read(databaseProvider);

    final invoices =
        await (db.select(db.invoices)
              ..where(
                (i) =>
                    i.businessId.equals(businessId) &
                    i.customerId.equals(customer.id) &
                    i.deletedAt.isNull(),
              )
              ..orderBy([(i) => OrderingTerm.asc(i.issuedAt)]))
            .get();

    final eligibleInvoices = <Invoice>[];
    var totalOutstandingPaise = 0;
    var overdueCount = 0;
    var unpaidCount = 0;
    var partiallyPaidCount = 0;

    for (final inv in invoices) {
      final bal = invoiceRepo.balance(inv);
      if (bal > 0) {
        eligibleInvoices.add(inv);
        totalOutstandingPaise += bal;
        final st = invoiceRepo.status(inv);
        if (st == InvoicePaymentStatus.overdue) {
          overdueCount++;
        } else if (st == InvoicePaymentStatus.partiallyPaid) {
          partiallyPaidCount++;
        } else {
          unpaidCount++;
        }
      }
    }

    if (eligibleInvoices.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(context, 'This customer has no outstanding payments.'),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final business = await (db.select(
      db.businesses,
    )..where((b) => b.id.equals(businessId))).getSingleOrNull();
    final businessName = business?.name.trim().isNotEmpty == true
        ? business!.name.trim()
        : 'OneBill';
    if (!context.mounted) return;
    final customerName = customer.name.trim();

    final buffer = StringBuffer();
    buffer.writeln('${_tr(context, 'Hello')} $customerName! 👋\n');

    final lang = Localizations.localeOf(context).languageCode;
    if (lang == 'hi') {
      buffer.writeln('$businessName की ओर से सादर अभिवादन!\n');
    } else if (lang == 'te') {
      buffer.writeln('$businessName నుండి నమస్కారాలు!\n');
    } else {
      buffer.writeln('Greetings from $businessName!\n');
    }

    buffer.writeln('📋 *${_tr(context, 'YOUR PAYMENT SUMMARY')}*\n');
    buffer.writeln(
      '🧾 ${_tr(context, 'Outstanding Invoices')}: ${eligibleInvoices.length}',
    );
    buffer.writeln(
      '💰 ${_tr(context, 'Total Due')}: ${_rupees(totalOutstandingPaise)}\n',
    );
    buffer.writeln('━━━━━━━━━━━━━━━━\n');

    if (eligibleInvoices.length <= 5) {
      for (var idx = 0; idx < eligibleInvoices.length; idx++) {
        final inv = eligibleInvoices[idx];
        final num = idx + 1;
        final invTotal = invoiceRepo.total(inv);
        final invBal = invoiceRepo.balance(inv);
        final invStatus = invoiceRepo.status(inv);

        String statusLabel;
        String statusEmoji;
        if (invStatus == InvoicePaymentStatus.overdue) {
          statusLabel = _tr(context, 'Overdue');
          statusEmoji = '🔴';
        } else if (invStatus == InvoicePaymentStatus.partiallyPaid) {
          statusLabel = _tr(context, 'Partially Paid');
          statusEmoji = '🟡';
        } else {
          statusLabel = _tr(context, 'Unpaid');
          statusEmoji = '🟠';
        }

        buffer.writeln(
          '*$num. ${_tr(context, 'Invoice')} ${inv.invoiceNumber}*\n',
        );
        buffer.writeln('📅 ${_tr(context, 'Date')}: ${_date(inv.issuedAt)}');
        if (inv.dueAt != null) {
          buffer.writeln(
            '📅 ${_tr(context, 'Due Date')}: ${_date(inv.dueAt!)}',
          );
        }
        buffer.writeln(
          '💵 ${_tr(context, 'Invoice Amount')}: ${_rupees(invTotal)}',
        );
        if (inv.paidPaise > 0) {
          buffer.writeln(
            '✅ ${_tr(context, 'Paid')}: ${_rupees(inv.paidPaise)}',
          );
        }
        buffer.writeln('⏳ ${_tr(context, 'Balance Due')}: ${_rupees(invBal)}');
        buffer.writeln(
          '$statusEmoji ${_tr(context, 'Status')}: $statusLabel\n',
        );
      }
      buffer.writeln('━━━━━━━━━━━━━━━━\n');
      buffer.writeln(
        '💰 *${_tr(context, 'TOTAL DUE')}: ${_rupees(totalOutstandingPaise)}*\n',
      );
    } else {
      buffer.writeln('🔴 ${_tr(context, 'Overdue')}: $overdueCount');
      buffer.writeln('🟠 ${_tr(context, 'Unpaid')}: $unpaidCount');
      buffer.writeln(
        '🟡 ${_tr(context, 'Partially Paid')}: $partiallyPaidCount\n',
      );
      buffer.writeln('━━━━━━━━━━━━━━━━\n');
      buffer.writeln(
        '💰 *${_tr(context, 'TOTAL DUE')}: ${_rupees(totalOutstandingPaise)}*\n',
      );
    }

    buffer.writeln(
      '${_tr(context, 'Kindly settle your outstanding payments at your convenience.')}\n',
    );
    buffer.writeln(
      '${_tr(context, 'If you have already made any payments, please let us know.')}\n',
    );
    buffer.writeln(
      '${_tr(context, 'Thank you for your continued support! 🙏')}\n',
    );
    buffer.writeln('*$businessName*\n');
    buffer.writeln('━━━━━━━━━━━━━━━━\n');
    buffer.writeln('_Generated by OneBill_');

    final messageText = buffer.toString();
    final whatsappUrl =
        'https://wa.me/$cleanPhone?text=${Uri.encodeComponent(messageText)}';
    final uri = Uri.parse(whatsappUrl);

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          await SharePlus.instance.share(ShareParams(text: messageText));
        }
      }
    } catch (_) {
      try {
        await SharePlus.instance.share(ShareParams(text: messageText));
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_tr(context, 'Could not open WhatsApp'))),
          );
        }
      }
    }
  }

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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: _tr(context, 'Customer info'),
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
                  const SizedBox(width: 4),
                  _buildCallButton(context),
                  const SizedBox(width: 4),
                  _buildWhatsAppButton(context, ref),
                  IconButton(
                    tooltip: _tr(context, 'Remove customer'),
                    onPressed: () => _confirmArchive(context, ref),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              Text(
                _tr(context, 'Invoices'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
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
                  label: Text(
                    _tr(context, 'Create invoice'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
        title: Text(_tr(context, 'Remove customer?')),
        content: Text(
          _tr(
            context,
            'This safely removes the customer from your active list. Their invoices and payment records remain intact and no data is permanently deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_tr(context, 'Remove')),
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
          SnackBar(
            content: Text(
              _cleanErrorMessage(error, 'Could not remove customer'),
            ),
          ),
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
            _tr(context, 'Customer information'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _CustomerInfoLine(
                  icon: Icons.phone_outlined,
                  label: _tr(context, 'Mobile'),
                  value: customer.phone,
                ),
              ),
              IconButton(
                tooltip: _tr(context, 'Call customer'),
                onPressed: () => _launchCustomerCall(context, customer.phone),
                icon: const Icon(Icons.phone_outlined),
              ),
              IconButton(
                tooltip: _tr(context, 'Copy mobile number'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: customer.phone));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(_tr(context, 'Mobile number copied')),
                      ),
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
              label: _tr(context, 'Due'),
              value: amount == 0 ? _tr(context, 'Clear') : _rupees(amount),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
          if (customer.email != null) ...[
            const SizedBox(height: 12),
            _CustomerInfoLine(
              icon: Icons.email_outlined,
              label: _tr(context, 'Email'),
              value: customer.email!,
            ),
          ],
          if (customer.notes != null) ...[
            const SizedBox(height: 12),
            _CustomerInfoLine(
              icon: Icons.notes_outlined,
              label: _tr(context, 'Notes'),
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
            label: Text(_tr(context, 'Edit customer')),
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
      if (items.isEmpty) {
        return Center(child: Text(_tr(context, 'No invoices yet.')));
      }
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
            decoration: InputDecoration(
              labelText: _tr(context, 'Filter by status'),
            ),
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text(
              '#${invoice.invoiceNumber}  •  ${_date(invoice.issuedAt)}',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Text(
                  '${_tr(context, "Total")}:\u00A0${_rupees(total)}',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_tr(context, "Due")}:\u00A0${_rupees(balance)}',
                  style: TextStyle(
                    color: balance > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
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
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: fileName);
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

      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(file.path, mimeType: 'application/pdf', name: fileName),
            ],
            title: fileName,
            text: 'Invoice ${invoice.invoiceNumber}',
          ),
        );
      } finally {
        await ref
            .read(notificationServiceProvider)
            .notifyInvoiceSentShared(invoice, customer);
      }
    } catch (error) {
      if (context.mounted) {
        AppToast.showError(context, 'Could not share invoice PDF: $error');
      }
    }
  }

  Future<void> _printPaperReceipt(BuildContext context, WidgetRef ref) async {
    try {
      final (_, business, customer) = await _pdfData(ref);
      final bytes = await ref
          .read(pdfInvoiceServiceProvider)
          .generatePaperReceiptPdf(
            business: business,
            customer: customer,
            invoice: invoice,
            paperReceiptImage: invoice.paperReceiptImage!,
          );
      final fileName = 'Receipt_${invoice.invoiceNumber}.pdf';
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: fileName);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not print receipt: $error')),
        );
      }
    }
  }

  Future<void> _sharePaperReceipt(BuildContext context, WidgetRef ref) async {
    try {
      final (_, business, customer) = await _pdfData(ref);
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

      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(file.path, mimeType: 'application/pdf', name: fileName),
            ],
            title: fileName,
            text: 'Paper Receipt ${invoice.invoiceNumber}',
          ),
        );
      } finally {
        await ref
            .read(notificationServiceProvider)
            .notifyPaperReceiptShared(invoice, customer);
      }
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
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
                      color: Colors.black.withValues(alpha: 0.04),
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
        final base64Data = trimmed.contains(',')
            ? trimmed.split(',').last
            : trimmed;
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
        final base64Data = trimmed.contains(',')
            ? trimmed.split(',').last
            : trimmed;
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
    final customers =
        ref.watch(customersProvider(businessId)).valueOrNull ?? [];
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
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 2),
                      Text(
                        invoice.invoiceNumber,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
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
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          if (invoice.dueAt != null) ...[
                            Text(
                              '  •  ',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            Text(
                              '${_tr(context, "Due")} ${_date(invoice.dueAt!)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
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
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.4),
                  ),
                ),
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: highlight),
                child: child,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Column(
                  children: [
                    _AmountLine(
                      label: _tr(context, 'Subtotal'),
                      amount: invoice.subtotalPaise,
                    ),
                    if (invoice.discountPaise > 0)
                      _AmountLine(
                        label: _tr(context, 'Discount'),
                        amount: -invoice.discountPaise,
                      ),
                    if (invoice.interestPaise > 0)
                      _AmountLine(
                        label: _tr(context, 'Extra charge'),
                        amount: invoice.interestPaise,
                      ),
                    const Divider(height: 12),
                    _AmountLine(
                      label: _tr(context, 'Grand Total'),
                      amount: total,
                      bold: true,
                    ),
                    _AmountLine(
                      label: _tr(context, 'Paid'),
                      amount: invoice.paidPaise,
                    ),
                    _AmountLine(
                      label: _tr(context, 'Balance'),
                      amount: balance,
                      bold: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (invoice.paperReceiptImage != null &&
                invoice.paperReceiptImage!.trim().isNotEmpty) ...[
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () =>
                    _openReceiptViewer(context, invoice.paperReceiptImage!),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _tr(context, 'View Paper Receipt'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
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
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
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
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
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
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
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
                    onPressed: () => _printPaperReceipt(context, ref),
                    icon: const Icon(Icons.print_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Print Paper Receipt'),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
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
                    onPressed: () => _sharePaperReceipt(context, ref),
                    icon: const Icon(Icons.receipt_long_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Share Paper Receipt'),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
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
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _confirmVoid(context, ref),
                    icon: const Icon(Icons.block_outlined, size: 20),
                    label: Text(
                      _tr(context, 'Void Invoice'),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, 'Items'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _tr(
                                    context,
                                    'Mistake in payment? Tap "Reverse" to cancel it and restore the balance.',
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ...entries.map(
                          (payment) => Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.4),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.check_rounded,
                                            size: 16,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          _rupees(payment.amountPaise),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ],
                                    ),
                                    OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        minimumSize: const Size(0, 32),
                                        visualDensity: VisualDensity.compact,
                                        foregroundColor: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                        side: BorderSide(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.history_rounded,
                                        size: 16,
                                      ),
                                      label: Text(
                                        _tr(context, 'Reverse'),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      onPressed: () async {
                                        final ok = await showDialog<bool>(
                                          context: context,
                                          builder: (dialog) => AlertDialog(
                                            title: Row(
                                              children: [
                                                Icon(
                                                  Icons.warning_amber_rounded,
                                                  color: Theme.of(
                                                    dialog,
                                                  ).colorScheme.error,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  _tr(
                                                    dialog,
                                                    'Reverse Payment?',
                                                  ),
                                                ),
                                              ],
                                            ),
                                            content: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _tr(
                                                    dialog,
                                                    'Are you sure you want to reverse this payment?',
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                Container(
                                                  padding: const EdgeInsets.all(
                                                    10,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(dialog)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      Text(
                                                        _tr(
                                                          dialog,
                                                          'Amount to restore:',
                                                        ),
                                                      ),
                                                      Text(
                                                        _rupees(
                                                          payment.amountPaise,
                                                        ),
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Theme.of(
                                                            dialog,
                                                          ).colorScheme.error,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  _tr(
                                                    dialog,
                                                    'This amount will be added back to the invoice balance due.',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(dialog)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  dialog,
                                                  false,
                                                ),
                                                child: Text(
                                                  _tr(dialog, 'Cancel'),
                                                ),
                                              ),
                                              FilledButton(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor: Theme.of(
                                                    dialog,
                                                  ).colorScheme.error,
                                                  foregroundColor: Theme.of(
                                                    dialog,
                                                  ).colorScheme.onError,
                                                ),
                                                onPressed: () =>
                                                    Navigator.pop(dialog, true),
                                                child: Text(
                                                  _tr(
                                                    dialog,
                                                    'Confirm Reverse',
                                                  ),
                                                ),
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
                                          await ref
                                              .read(notificationServiceProvider)
                                              .reconcileInvoice(invoice.id);
                                          await ref
                                              .read(notificationServiceProvider)
                                              .reconcileSummaries();
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  _tr(
                                                    context,
                                                    'Payment reversed successfully. Balance updated.',
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
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
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      '${payment.method} • ${_date(payment.receivedAt)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                    if (payment.note != null &&
                                        payment.note!.trim().isNotEmpty) ...[
                                      Text(
                                        ' • ',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          payment.note!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                fontStyle: FontStyle.italic,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildCircularFieldIcon(
  BuildContext context, {
  IconData? icon,
  String? text,
}) {
  final theme = Theme.of(context);
  final primary = theme.colorScheme.primary;
  return Container(
    width: 32,
    height: 32,
    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: primary.withValues(alpha: 0.12),
      shape: BoxShape.circle,
      border: Border.all(color: primary.withValues(alpha: 0.35), width: 1),
    ),
    alignment: Alignment.center,
    child: text != null
        ? Text(
            text,
            style: TextStyle(
              color: primary,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          )
        : Icon(icon, size: 16, color: primary),
  );
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
  final _formKey = GlobalKey<FormState>();
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
      text: widget.invoice.discountPaise == 0
          ? ''
          : (widget.invoice.discountPaise / 100).toStringAsFixed(2),
    );
    interest = TextEditingController(
      text: widget.invoice.interestPaise == 0
          ? ''
          : (widget.invoice.interestPaise / 100).toStringAsFixed(2),
    );
    notes = TextEditingController(text: widget.invoice.notes ?? '');
    dueAt = widget.invoice.dueAt;
    _paperReceiptImage = widget.invoice.paperReceiptImage;
    _initReceiptFile();
    _loadItems();
  }

  Future<void> _initReceiptFile() async {
    if (_paperReceiptImage == null || _paperReceiptImage!.trim().isEmpty) {
      return;
    }
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final receiptsDir = Directory('${appDir.path}/receipts');
      final localFile = File(
        '${receiptsDir.path}/receipt_${widget.invoice.id}.jpg',
      );
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
          if (!receiptsDir.existsSync()) {
            receiptsDir.createSync(recursive: true);
          }
          final localFile = File(
            '${receiptsDir.path}/receipt_${widget.invoice.id}_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
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
          SnackBar(
            content: Text(
              _cleanErrorMessage(e, _tr(context, 'Unable to select image')),
            ),
          ),
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
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
                  child: Icon(
                    Icons.camera_alt_rounded,
                    color: theme.colorScheme.primary,
                  ),
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
                  child: Icon(
                    Icons.photo_library_rounded,
                    color: theme.colorScheme.secondary,
                  ),
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

  Future<void> _selectDueDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: dueAt ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) setState(() => dueAt = selected);
  }

  Future<void> save() async {
    if (!_formKey.currentState!.validate()) return;
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
      await ref.read(notificationServiceProvider).reconcileAllReminders();
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
      items.any(
        (i) => i.description.text.isNotEmpty || i.unitPrice.text.isNotEmpty,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtotalPaise = items.fold<int>(
      0,
      (sum, i) => sum + i.lineTotalPaise,
    );
    final discountPaise = _tryParseRupees(discount.text);
    final interestPaise = _tryParseRupees(interest.text);
    final grandTotalPaise = (subtotalPaise - discountPaise + interestPaise)
        .clamp(0, 1 << 62);
    return PopScope(
      canPop: !_isDirty || saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.95,
        minChildSize: 0.6,
        maxChildSize: 0.96,
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
                    _tr(context, 'Edit invoice'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 14),

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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: 0.08,
                          ),
                          side: BorderSide(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.35,
                            ),
                            width: 1,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        onPressed: saving
                            ? null
                            : () => setState(
                                () => items.add(_InvoiceItemDraft()),
                              ),
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _tr(context, 'Add Another Item'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                  TextFormField(
                    controller: discount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Discount (₹)'),
                      hintText: '0.00',
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.discount_outlined,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _optionalNonNegativeAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: interest,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Extra charge (₹)'),
                      hintText: '0.00',
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.percent_rounded,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _optionalNonNegativeAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: notes,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Notes'),
                      hintText: _tr(context, 'Add any additional notes...'),
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.description_outlined,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  _DatePickerField(
                    label: _tr(context, 'Payment Due Date'),
                    selectedDate: dueAt,
                    onTap: saving ? () {} : _selectDueDate,
                    onClear: () => setState(() => dueAt = null),
                  ),
                  const SizedBox(height: 14),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr(context, 'Paper Receipt (Optional)'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_paperReceiptImage != null &&
                          _paperReceiptImage!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.35,
                              ),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child:
                                      _paperReceiptFile != null &&
                                          _paperReceiptFile!.existsSync()
                                      ? Image.file(
                                          _paperReceiptFile!,
                                          fit: BoxFit.cover,
                                        )
                                      : _buildReceiptThumbnail(
                                          _paperReceiptImage!,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _tr(context, 'Receipt Attached'),
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme.colorScheme.primary,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _tr(context, 'Tap to change or remove'),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                tooltip: _tr(context, 'Change Photo'),
                                onPressed: saving
                                    ? null
                                    : () => _showPickOptionsSheet(context),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: theme.colorScheme.error,
                                  size: 20,
                                ),
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
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: theme.colorScheme.primary,
                                  backgroundColor: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  side: BorderSide(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.4),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.camera_alt_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _tr(context, 'Take Photo'),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onPressed: saving
                                    ? null
                                    : () => _pickReceipt(ImageSource.camera),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: theme.colorScheme.primary,
                                  backgroundColor: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  side: BorderSide(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.4),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.photo_library_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _tr(context, 'Choose from Gallery'),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onPressed: saving
                                    ? null
                                    : () => _pickReceipt(ImageSource.gallery),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.35,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _tr(context, 'Grand Total'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          _rupees(grandTotalPaise),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: saving ? null : save,
                      icon: saving
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.check_circle_rounded, size: 20),
                      label: Text(
                        saving
                            ? _tr(context, 'Saving...')
                            : _tr(context, 'Save changes'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
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
      await ref.read(notificationServiceProvider).reconcileAllReminders();
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
      child: SafeArea(
        top: false,
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
                  _tr(context, 'Edit customer'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Customer name'),
                  ),
                  validator: _required,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Mobile number'),
                  ),
                  validator: _phoneValidator,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Email (optional)'),
                  ),
                  validator: _optionalEmailValidator,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Notes (optional)'),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(
                    _saving
                        ? _tr(context, 'Saving...')
                        : _tr(context, 'Save customer'),
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
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: hasDate
                ? theme.colorScheme.primary.withValues(alpha: 0.8)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1.0,
          ),
        ),
        child: Row(
          children: [
            _buildCircularFieldIcon(
              context,
              icon: Icons.calendar_today_rounded,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasDate
                        ? _date(selectedDate!)
                        : _tr(context, 'Select Date (Tap to open calendar)'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: hasDate ? FontWeight.w600 : FontWeight.normal,
                      color: hasDate
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
            if (hasDate && onClear != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
                tooltip: _tr(context, 'Clear date'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  Icons.arrow_drop_down,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
  Widget build(BuildContext context) {
    final style = TextStyle(fontWeight: bold ? FontWeight.w700 : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              _tr(context, label),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
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
            child: Text(_rupees(amount), key: ValueKey(amount), style: style),
          ),
        ],
      ),
    );
  }
}

class _InvoiceStatusBadge extends StatelessWidget {
  const _InvoiceStatusBadge({required this.status});
  final InvoicePaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      InvoicePaymentStatus.unpaid => ('Unpaid', const Color(0xFFF59E0B)),
      InvoicePaymentStatus.partiallyPaid => (
        'Partially paid',
        const Color(0xFF3B82F6),
      ),
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
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
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
        final updatedInvoice = await (db.select(
          db.invoices,
        )..where((i) => i.id.equals(widget.invoice.id))).getSingleOrNull();
        final customer = updatedInvoice == null
            ? null
            : await (db.select(db.customers)
                    ..where((c) => c.id.equals(updatedInvoice.customerId)))
                  .getSingleOrNull();
        final latestPayment =
            await (db.select(db.payments)
                  ..where((p) => p.invoiceId.equals(widget.invoice.id))
                  ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
                .get()
                .then((list) => list.firstOrNull);

        if (updatedInvoice != null && latestPayment != null) {
          final totalPaise =
              updatedInvoice.subtotalPaise +
              updatedInvoice.interestPaise -
              updatedInvoice.discountPaise;
          final remainingPaise = totalPaise - updatedInvoice.paidPaise;
          final isFullyPaid = remainingPaise <= 0;

          await ref
              .read(notificationServiceProvider)
              .notifyPaymentRecorded(
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
                  Text(
                    _tr(context, 'Record payment'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('${_tr(context, "Due")}: ${_rupees(_remaining)}'),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Amount received (₹)'),
                    ),
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
                              _amount.text = (_remaining / 100).toStringAsFixed(
                                2,
                              );
                            },
                      child: Text(_tr(context, 'Use full balance')),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _method,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Payment method'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'Cash',
                        child: Text(_tr(context, 'Cash')),
                      ),
                      DropdownMenuItem(
                        value: 'UPI',
                        child: Text(_tr(context, 'UPI')),
                      ),
                      DropdownMenuItem(
                        value: 'Bank transfer',
                        child: Text(_tr(context, 'Bank transfer')),
                      ),
                      DropdownMenuItem(
                        value: 'Other',
                        child: Text(_tr(context, 'Other')),
                      ),
                    ],
                    onChanged: (value) => setState(() => _method = value!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _note,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Note (optional)'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving
                          ? _tr(context, 'Recording...')
                          : _tr(context, 'Confirm payment'),
                    ),
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
          if (!receiptsDir.existsSync()) {
            receiptsDir.createSync(recursive: true);
          }
          final localFile = File(
            '${receiptsDir.path}/receipt_new_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
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
          SnackBar(
            content: Text(
              _cleanErrorMessage(e, _tr(context, 'Unable to select image')),
            ),
          ),
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
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
                  child: Icon(
                    Icons.camera_alt_rounded,
                    color: theme.colorScheme.primary,
                  ),
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
                  child: Icon(
                    Icons.photo_library_rounded,
                    color: theme.colorScheme.secondary,
                  ),
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
        final createdInvoice = await (db.select(
          db.invoices,
        )..where((i) => i.id.equals(invoiceId))).getSingleOrNull();
        final customer = await (db.select(
          db.customers,
        )..where((c) => c.id.equals(widget.customerId))).getSingleOrNull();

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

  bool get _isDirty =>
      _items.any(
        (i) => i.description.text.isNotEmpty || i.unitPrice.text.isNotEmpty,
      ) ||
      _discount.text.isNotEmpty ||
      _interest.text.isNotEmpty ||
      _notes.text.isNotEmpty ||
      _paperReceiptImage != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtotalPaise = _items.fold<int>(
      0,
      (sum, i) => sum + i.lineTotalPaise,
    );
    final discountPaise = _tryParseRupees(_discount.text);
    final interestPaise = _tryParseRupees(_interest.text);
    final grandTotalPaise = (subtotalPaise - discountPaise + interestPaise)
        .clamp(0, 1 << 62);
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
        initialChildSize: 0.95,
        minChildSize: 0.6,
        maxChildSize: 0.96,
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
                    _tr(context, 'Create invoice'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 14),

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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: 0.08,
                          ),
                          side: BorderSide(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.35,
                            ),
                            width: 1,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        onPressed: _saving
                            ? null
                            : () => setState(
                                () => _items.add(_InvoiceItemDraft()),
                              ),
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _tr(context, 'Add Another Item'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                  TextFormField(
                    controller: _discount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Discount (₹)'),
                      hintText: '0.00',
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.discount_outlined,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _optionalNonNegativeAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _interest,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Extra charge (₹)'),
                      hintText: '0.00',
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.percent_rounded,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _optionalNonNegativeAmountValidator,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _notes,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Notes'),
                      hintText: _tr(context, 'Add any additional notes...'),
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.description_outlined,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  _DatePickerField(
                    label: _tr(context, 'Payment Due Date'),
                    selectedDate: _dueAt,
                    onTap: _saving ? () {} : _selectDueDate,
                    onClear: () => setState(() => _dueAt = null),
                  ),
                  const SizedBox(height: 14),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr(context, 'Paper Receipt (Optional)'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_paperReceiptImage != null &&
                          _paperReceiptImage!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.35,
                              ),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child:
                                      _paperReceiptFile != null &&
                                          _paperReceiptFile!.existsSync()
                                      ? Image.file(
                                          _paperReceiptFile!,
                                          fit: BoxFit.cover,
                                        )
                                      : _buildReceiptThumbnail(
                                          _paperReceiptImage!,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _tr(context, 'Receipt Attached'),
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme.colorScheme.primary,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _tr(context, 'Tap to change or remove'),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                tooltip: _tr(context, 'Change Photo'),
                                onPressed: _saving
                                    ? null
                                    : () => _showPickOptionsSheet(context),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: theme.colorScheme.error,
                                  size: 20,
                                ),
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
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: theme.colorScheme.primary,
                                  backgroundColor: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  side: BorderSide(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.4),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.camera_alt_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _tr(context, 'Take Photo'),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onPressed: _saving
                                    ? null
                                    : () => _pickReceipt(ImageSource.camera),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: theme.colorScheme.primary,
                                  backgroundColor: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.35),
                                  side: BorderSide(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.4),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.photo_library_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _tr(context, 'Choose from Gallery'),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onPressed: _saving
                                    ? null
                                    : () => _pickReceipt(ImageSource.gallery),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.35,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _tr(context, 'Grand Total'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          _rupees(grandTotalPaise),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: theme.colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.check_circle_rounded, size: 20),
                      label: Text(
                        _saving
                            ? _tr(context, 'Creating Invoice...')
                            : _tr(context, 'Create Invoice'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sell_outlined,
                        size: 13,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${_tr(context, 'Item')} #$itemNumber',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (canRemove)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: _tr(context, 'Remove item'),
                    onPressed: onRemove,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: theme.colorScheme.error.withValues(alpha: 0.85),
                      size: 20,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: draft.description,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _tr(context, 'Item / Service Description *'),
                hintText: _tr(context, 'Enter item or service description'),
                prefixIcon: _buildCircularFieldIcon(
                  context,
                  icon: Icons.edit_note_rounded,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 46,
                  minHeight: 36,
                ),
                filled: true,
                fillColor: theme.colorScheme.surface.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5,
                  ),
                ),
              ),
              validator: _required,
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: draft.quantity,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Qty *'),
                      hintText: '1',
                      prefixIcon: _buildCircularFieldIcon(
                        context,
                        icon: Icons.tag_rounded,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surface.withValues(
                        alpha: 0.5,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _quantityValidator,
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: draft.unitPrice,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Unit Price (₹) *'),
                      hintText: '0.00',
                      prefixIcon: _buildCircularFieldIcon(context, text: '₹'),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 46,
                        minHeight: 36,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surface.withValues(
                        alpha: 0.5,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: _amountValidator,
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _tr(context, 'Line Total'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _rupees(draft.lineTotalPaise),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
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
  bool _pickingContact = false;
  String? _phoneError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pickFromContacts() async {
    setState(() {
      _pickingContact = true;
      _phoneError = null;
    });

    try {
      final contactService = ref.read(contactServiceProvider);
      final contact = await contactService.pickSingleContact();
      if (!mounted || contact == null) {
        // User cancelled or pressed back
        return;
      }

      final displayName = contact.displayName?.trim() ?? '';
      final firstName = contact.name?.first?.trim() ?? '';
      final lastName = contact.name?.last?.trim() ?? '';
      final fullName = '$firstName $lastName'.trim();
      final name = displayName.isNotEmpty ? displayName : fullName;

      final phones = contact.phones;
      String chosenNumber = '';

      if (phones.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_tr(context, 'No phone number found')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (phones.length == 1) {
        chosenNumber = phones.first.number;
      } else {
        final selected = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) =>
              _SelectPhoneNumberSheet(contactName: name, phones: phones),
        );
        if (!mounted || selected == null) return;
        chosenNumber = selected;
      }

      final normalized = ContactService.normalizePhone(chosenNumber);

      // Check if this contact already exists as a OneBill customer
      if (normalized.isNotEmpty) {
        final db = ref.read(databaseProvider);
        final existing =
            await (db.select(db.customers)..where(
                  (c) =>
                      c.businessId.equals(widget.businessId) &
                      c.phone.equals(normalized) &
                      c.deletedAt.isNull(),
                ))
                .getSingleOrNull();

        if (existing != null && mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_tr(context, 'This customer already exists')),
              duration: const Duration(seconds: 2),
            ),
          );
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _CustomerDetailsSheet(
              businessId: widget.businessId,
              customer: existing,
            ),
          );
          return;
        }
      }

      // Populate form for new customer
      if (mounted) {
        setState(() {
          if (name.isNotEmpty) {
            _name.text = name;
          }
          if (normalized.isNotEmpty) {
            _phone.text = normalized;
          } else if (chosenNumber.isNotEmpty) {
            _phone.text = chosenNumber;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_tr(context, 'Unable to access contacts')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pickingContact = false);
      }
    }
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

    final normalized = ContactService.normalizePhone(_phone.text);
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
      final existing =
          await (db.select(db.customers)..where(
                (c) =>
                    c.businessId.equals(widget.businessId) &
                    c.phone.equals(normalized) &
                    c.deletedAt.isNull(),
              ))
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
      await ref
          .read(customerRepositoryProvider)
          .create(
            businessId: widget.businessId,
            name: _name.text,
            phone: normalized,
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
      canPop: !_isDirty || _saving || _verifyingPhone || _pickingContact,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _showDiscardChangesDialog(context);
        if (discard && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            32 + MediaQuery.viewInsetsOf(context).bottom,
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
                OutlinedButton.icon(
                  onPressed: (_saving || _verifyingPhone || _pickingContact)
                      ? null
                      : _pickFromContacts,
                  icon: _pickingContact
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.contacts_outlined),
                  label: Text(_tr(context, 'Add from Contacts')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _tr(context, 'OR'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: _tr(context, 'Customer name'),
                    prefixIcon: const Icon(Icons.person_outline_rounded),
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
                    labelText: _tr(context, 'Mobile number'),
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
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.5),
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
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: (_saving || _verifyingPhone || _pickingContact)
                      ? null
                      : _save,
                  child: Text(
                    _verifyingPhone
                        ? _tr(context, 'Verifying number...')
                        : _saving
                        ? _tr(context, 'Saving...')
                        : _tr(context, 'Save customer'),
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

class _SelectPhoneNumberSheet extends StatelessWidget {
  const _SelectPhoneNumberSheet({
    required this.contactName,
    required this.phones,
  });

  final String contactName;
  final List<Phone> phones;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tr(context, 'Select a phone number'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (contactName.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          contactName,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            ...phones.map((phone) {
              final label = (phone.label.customLabel ?? phone.label.label.name)
                  .toUpperCase();
              return ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(
                  phone.number,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(label),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onTap: () => Navigator.pop(context, phone.number),
              );
            }),
          ],
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

String? _nonNegativeAmountValidator(String? value) {
  if (value == null || !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value.trim())) {
    return 'Enter a valid amount, such as 0 or 125.50.';
  }
  return _parseRupees(value) >= 0 ? null : 'Amount cannot be negative.';
}

String? _optionalNonNegativeAmountValidator(String? value) =>
    value == null || value.trim().isEmpty
    ? null
    : _nonNegativeAmountValidator(value);

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
  const _OverdueInvoicesSheet({
    required this.businessId,
    this.isOverdueOnly = false,
  });
  final String businessId;
  final bool isOverdueOnly;

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
          stream:
              (database.select(database.invoices)
                    ..where(
                      (i) =>
                          i.businessId.equals(businessId) &
                          i.deletedAt.isNull(),
                    )
                    ..orderBy([(i) => OrderingTerm.desc(i.issuedAt)]))
                  .watch(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final allInvoices = snapshot.data ?? [];
            final displayedInvoices = isOverdueOnly
                ? allInvoices
                      .where(
                        (inv) =>
                            invoiceRepo.status(inv) ==
                            InvoicePaymentStatus.overdue,
                      )
                      .toList()
                : allInvoices
                      .where((inv) => invoiceRepo.balance(inv) > 0)
                      .toList();

            final totalAmountPaise = displayedInvoices.fold<int>(
              0,
              (sum, inv) => sum + invoiceRepo.balance(inv),
            );

            final title = isOverdueOnly ? 'Overdue Payments' : 'Due Payments';
            final summaryLabel = isOverdueOnly ? 'Total Overdue' : 'Total Due';
            final emptyTitle = isOverdueOnly
                ? 'No overdue invoices'
                : 'No due invoices';

            return SafeArea(
              top: false,
              child: Padding(
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
                                _tr(context, title),
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${displayedInvoices.length} ${displayedInvoices.length == 1 ? _tr(context, "invoice") : _tr(context, "invoices")}  •  ${_tr(context, summaryLabel)} ${_rupees(totalAmountPaise)}',
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
                    if (displayedInvoices.isEmpty)
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
                                _tr(context, emptyTitle),
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _tr(
                                  context,
                                  'All customer payments are up to date.',
                                ),
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
                          itemCount: displayedInvoices.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final invoice = displayedInvoices[index];
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
                            _tr(context, summaryLabel),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _rupees(totalAmountPaise),
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
      stream: (database.select(
        database.customers,
      )..where((c) => c.id.equals(invoice.customerId))).watchSingleOrNull(),
      builder: (context, customerSnapshot) {
        final customerName = customerSnapshot.data?.name ?? 'Customer';

        return StreamBuilder<BusinessesData?>(
          stream: (database.select(
            database.businesses,
          )..where((b) => b.id.equals(invoice.businessId))).watchSingleOrNull(),
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
                          ? _tr(context, 'Unpaid')
                          : (daysOverdue > 0
                                ? '${_tr(context, "Due")} ${_date(dueAt)} • $daysOverdue ${daysOverdue == 1 ? _tr(context, "day") : _tr(context, "days")} ${_tr(context, "overdue")}'
                                : '${_tr(context, "Due")} ${_date(dueAt)}'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: daysOverdue > 0
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
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
