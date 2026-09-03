import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Expression, OrderingTerm, Value;
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/config/app_environment.dart';
import '../core/database/app_database.dart';
import '../core/providers.dart';
import '../features/invoices/data/invoice_repository.dart';
import 'theme/app_theme.dart';

class OneBillApp extends StatelessWidget {
  const OneBillApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OneBill',
    debugShowCheckedModeBanner: false,
    theme: OneBillTheme.light,
    home: const _StartupGate(),
  );
}

class _StartupGate extends ConsumerWidget {
  const _StartupGate();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

class _AuthScreenState extends ConsumerState<_AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _submitting = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final auth = ref.read(authServiceProvider);
      if (_registering) {
        await auth.register(email: _email.text, password: _password.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Account created. Verify your email, then sign in.',
              ),
            ),
          );
        }
      } else {
        await auth.signIn(email: _email.text, password: _password.text);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_authErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _authErrorMessage(Object error) {
    if (error is AuthApiException &&
        error.code == 'over_email_send_rate_limit') {
      return 'Supabase has temporarily limited email sending. Wait before requesting another email, or sign in with your existing account.';
    }
    return 'Could not continue: $error';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.receipt_long_rounded,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _registering
                        ? 'Create your OneBill account'
                        : 'Sign in to OneBill',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your business data stays available offline after setup.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                    ),
                    validator: _emailValidator,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    validator: _passwordValidator,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: Text(
                      _submitting
                          ? 'Please wait...'
                          : (_registering ? 'Create account' : 'Sign in'),
                    ),
                  ),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _registering = !_registering),
                    child: Text(
                      _registering
                          ? 'Already have an account? Sign in'
                          : 'New to OneBill? Create an account',
                    ),
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
    if (AppEnvironment.cloudConfigured) {
      _restoring = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await ref.read(syncWorkerProvider).restoreAccount();
        } catch (error) {
          if (mounted) {
            setState(() {
              _restoreError = 'Could not restore cloud data: $error';
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
      await ref
          .read(businessRepositoryProvider)
          .createLocalWorkspace(
            accountId: ref.read(authSessionProvider).valueOrNull?.user.id,
            ownerName: _owner.text,
            businessName: _business.text,
            phone: _phone.text,
            languageCode: _language,
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create workspace: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Restoring your business data...'),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.receipt_long_rounded,
                      size: 56,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Welcome to OneBill',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Create your first business. Your information is saved on this device and works offline.',
                      textAlign: TextAlign.center,
                    ),
                    if (_restoreError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          _restoreError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _owner,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Owner name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _business,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Business or shop name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Business phone (optional)',
                      ),
                      validator: _phoneValidator,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _language,
                      decoration: const InputDecoration(labelText: 'Language'),
                      items: const [
                        DropdownMenuItem(value: 'en', child: Text('English')),
                        DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                        DropdownMenuItem(value: 'te', child: Text('తెలుగు')),
                        DropdownMenuItem(value: 'ta', child: Text('தமிழ்')),
                        DropdownMenuItem(value: 'kn', child: Text('ಕನ್ನಡ')),
                        DropdownMenuItem(value: 'ml', child: Text('മലയാളം')),
                        DropdownMenuItem(value: 'mr', child: Text('मराठी')),
                        DropdownMenuItem(value: 'gu', child: Text('ગુજરાતી')),
                        DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
                        DropdownMenuItem(value: 'ur', child: Text('اردو')),
                        DropdownMenuItem(value: 'pa', child: Text('ਪੰਜਾਬੀ')),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _language = value!),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _create,
                      child: Text(_saving ? 'Creating...' : 'Create business'),
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
  var _lockChecking = true;
  var _locked = false;
  var _biometricEnabled = false;
  String? _unlockError;
  final _lockPin = TextEditingController();
  bool _checkingPin = false;
  Timer? _syncTimer;
  Timer? _syncPulseTimer;
  ProviderSubscription<AsyncValue<SyncQueueStatus>>? _syncQueueSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAppLock();
    if (AppEnvironment.cloudConfigured) {
      _syncQueueSubscription = ref.listenManual<AsyncValue<SyncQueueStatus>>(
        syncQueueStatusProvider(widget.session.activeBusinessId!),
        (previous, next) {
          final before = previous?.value?.pending ?? 0;
          final now = next.value?.pending ?? 0;
          if (now > 0 && now > before) _syncNow();
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNow());
      _syncTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _syncNow(),
      );
      // Drift streams normally notify the listener immediately. This small
      // pulse is a safety net for writes made while a sheet is transitioning
      // or while the app is returning from the background.
      _syncPulseTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _syncNow(),
      );
    }
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
    _syncPulseTimer?.cancel();
    _lockPin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncNow();
      _checkAppLock(lockIfEnabled: true);
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
                    if (await ref
                            .read(securityServiceProvider)
                            .authenticateBiometrics() &&
                        mounted) {
                      setState(() => _locked = false);
                    }
                  },
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Use biometrics'),
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
    return Scaffold(
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
              tooltip: 'Switch business',
              icon: const Icon(Icons.storefront_outlined),
              onSelected: (value) {
                if (value == '__add_business__') {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        _AddBusinessSheet(accountId: session.accountId!),
                  );
                } else {
                  ref
                      .read(businessRepositoryProvider)
                      .switchBusiness(sessionId: session.id, businessId: value);
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
                const PopupMenuItem(
                  value: '__add_business__',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.add_business_outlined),
                    title: Text('Add new business'),
                  ),
                ),
              ],
            ),
            orElse: () => const SizedBox.shrink(),
          ),
          businesses.maybeWhen(
            data: (items) {
              final active = items
                  .where((business) => business.id == session.activeBusinessId)
                  .firstOrNull;
              return active == null
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Business settings',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) =>
                            _BusinessSettingsSheet(business: active),
                      ),
                    );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: 'App lock',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => _configurePin(context, ref),
          ),
          if (AppEnvironment.cloudConfigured)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () => _confirmSignOut(context, ref),
            ),
        ],
      ),
      body: _tab == 0
          ? _DashboardTab(
              customers: customers,
              summary: summary,
              inventory: inventory,
              onShowCustomers: () => setState(() => _tab = 1),
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
          ? _InventoryTab(businessId: session.activeBusinessId!)
          : _tab == 5
          ? _SuppliersTab(businessId: session.activeBusinessId!)
          : _tab == 6
          ? _RecycleBinTab(businessId: session.activeBusinessId!)
          : _tab == 7
          ? _ActivityTab(businessId: session.activeBusinessId!)
          : _ReportsTab(summary: summary, customers: customers),
      floatingActionButton: (_tab == 2 || _tab >= 6)
          ? null
          : _tab == 3
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    _ExpenseEditor(businessId: session.activeBusinessId!),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add expense'),
            )
          : _tab == 4
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    _InventoryEditor(businessId: session.activeBusinessId!),
              ),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Add product'),
            )
          : _tab == 5
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    _SupplierEditor(businessId: session.activeBusinessId!),
              ),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add supplier'),
            )
          : FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    _AddCustomerSheet(businessId: session.activeBusinessId!),
              ),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add customer'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Customers',
          ),
          NavigationDestination(
            icon: Icon(Icons.attach_money_outlined),
            selectedIcon: Icon(Icons.attach_money),
            label: 'Income',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Expenses',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Inventory',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping),
            label: 'Suppliers',
          ),
          NavigationDestination(
            icon: Icon(Icons.delete_sweep_outlined),
            selectedIcon: Icon(Icons.delete_sweep),
            label: 'Recycle bin',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Reports',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will need internet to sign in again. Local business data remains protected on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authServiceProvider).signOut();
    }
  }

  Future<void> _configurePin(BuildContext context, WidgetRef ref) async {
    final pin = TextEditingController();
    bool enabled;
    try {
      enabled = await ref.read(securityServiceProvider).isPinEnabled();
    } catch (_) {
      pin.dispose();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'App lock storage is unavailable. Please restart the app and try again.',
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) {
      pin.dispose();
      return;
    }
    final value = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(enabled ? 'Change app PIN' : 'Enable app PIN'),
        content: TextField(
          controller: pin,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '4–6 digit PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (enabled)
            TextButton(
              onPressed: () => Navigator.pop(context, '__disable__'),
              child: const Text('Disable'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, pin.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    pin.dispose();
    if (value == null || !context.mounted) return;
    try {
      if (value == '__disable__') {
        await ref.read(securityServiceProvider).clearPin();
        await ref.read(securityServiceProvider).setBiometricEnabled(false);
      } else {
        await ref.read(securityServiceProvider).setPin(value);
        if (context.mounted) {
          final useBiometric =
              await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Enable fingerprint unlock?'),
                  content: const Text(
                    'Use fingerprint or another device biometric to unlock OneBill faster.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Not now'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Enable'),
                    ),
                  ],
                ),
              ) ??
              false;
          await ref
              .read(securityServiceProvider)
              .setBiometricEnabled(useBiometric);
        }
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value == '__disable__'
                  ? 'App lock disabled'
                  : 'App lock PIN saved',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({
    required this.customers,
    required this.summary,
    required this.onShowCustomers,
    required this.inventory,
  });
  final AsyncValue<List<Customer>> customers;
  final AsyncValue<BillingSummary> summary;
  final VoidCallback onShowCustomers;
  final AsyncValue<List<InventoryProduct>> inventory;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'Business overview',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      const Text('All figures are calculated from data saved on this device.'),
      const SizedBox(height: 20),
      if (summary.valueOrNull?.overduePaise case final overdue?
          when overdue > 0)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.warning_amber),
            title: const Text('Overdue invoices'),
            subtitle: Text(
              '${_rupees(overdue)} remains overdue. Review payment status from Customers.',
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
                  title: const Text('Low-stock alert'),
                  subtitle: Text(
                    '$low product${low == 1 ? '' : 's'} need restocking.',
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
                child: Text(
                  '${data.overdueInvoiceCount} invoice${data.overdueInvoiceCount == 1 ? '' : 's'} overdue',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
            title: const Text('Customers'),
            subtitle: Text(
              '${items.length} active customer${items.length == 1 ? '' : 's'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onShowCustomers,
          ),
        ),
      ),
    ],
  );
}

class _IncomeTab extends ConsumerStatefulWidget {
  const _IncomeTab({required this.businessId});
  final String businessId;
  @override
  ConsumerState<_IncomeTab> createState() => _IncomeTabState();
}

class _IncomeTabState extends ConsumerState<_IncomeTab> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(businessPaymentsProvider(widget.businessId));
    return entries.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Unable to load income data.\n$e')),
      data: (all) {
        final query = search.text.trim().toLowerCase();
        final filtered = query.isEmpty
            ? all
            : all
                  .where(
                    (e) =>
                        e.method.toLowerCase().contains(query) ||
                        e.amountPaise.toString().contains(query) ||
                        _date(e.receivedAt).toLowerCase().contains(query),
                  )
                  .toList();
        final now = DateTime.now();
        final todayTotal = all
            .where(
              (e) =>
                  e.receivedAt.year == now.year &&
                  e.receivedAt.month == now.month &&
                  e.receivedAt.day == now.day,
            )
            .fold<int>(0, (s, e) => s + e.amountPaise);
        final monthTotal = all
            .where(
              (e) =>
                  e.receivedAt.year == now.year &&
                  e.receivedAt.month == now.month,
            )
            .fold<int>(0, (s, e) => s + e.amountPaise);
        final total = all.fold<int>(0, (s, e) => s + e.amountPaise);
        final months = <DateTime, List<Payment>>{};
        for (final e in filtered) {
          final month = DateTime(e.receivedAt.year, e.receivedAt.month);
          (months[month] ??= []).add(e);
        }
        final sortedMonths = months.entries.toList()
          ..sort((a, b) => b.key.compareTo(a.key));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Income', style: Theme.of(context).textTheme.headlineSmall),
            const Text('Track and manage your business income.'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: 'Today',
                    value: _rupees(todayTotal),
                    icon: Icons.today_outlined,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MetricCard(
                    label: 'This month',
                    value: _rupees(monthTotal),
                    icon: Icons.calendar_month_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _MetricCard(
              label: 'Total income',
              value: _rupees(total),
              icon: Icons.trending_up_outlined,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search income',
                suffixIcon: Icon(Icons.tune_outlined),
              ),
            ),
            const SizedBox(height: 16),
            if (months.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No payments received yet. Payments received from customers will appear here.',
                  ),
                ),
              ),
            ...sortedMonths.map((entry) {
              final monthTotal = entry.value.fold<int>(
                0,
                (s, e) => s + e.amountPaise,
              );
              return Card(
                child: ListTile(
                  title: Text(_monthLabel(entry.key)),
                  subtitle: Text(
                    '${_rupees(monthTotal)} • ${entry.value.length} payments',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _IncomeMonthSheet(
                      month: entry.key,
                      payments: entry.value,
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

class _IncomeMonthSheet extends StatelessWidget {
  const _IncomeMonthSheet({required this.month, required this.payments});
  final DateTime month;
  final List<Payment> payments;
  @override
  Widget build(BuildContext context) {
    final days = <DateTime, List<Payment>>{};
    for (final payment in payments) {
      final day = DateTime(
        payment.receivedAt.year,
        payment.receivedAt.month,
        payment.receivedAt.day,
      );
      (days[day] ??= []).add(payment);
    }
    final total = payments.fold<int>(
      0,
      (sum, payment) => sum + payment.amountPaise,
    );
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .8,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              _monthLabel(month),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('Total payments received: ${_rupees(total)}'),
            const SizedBox(height: 16),
            ...days.entries.map((entry) {
              final dayTotal = entry.value.fold<int>(
                0,
                (sum, payment) => sum + payment.amountPaise,
              );
              return Card(
                child: ExpansionTile(
                  title: Text(_date(entry.key)),
                  subtitle: Text('Total received: ${_rupees(dayTotal)}'),
                  children: entry.value
                      .map(
                        (payment) => ListTile(
                          title: Text(_rupees(payment.amountPaise)),
                          subtitle: Text(
                            '${payment.method} • ${TimeOfDay.fromDateTime(payment.receivedAt).format(context)}',
                          ),
                          trailing: const Icon(
                            Icons.check_circle_outline,
                            color: Colors.green,
                          ),
                        ),
                      )
                      .toList(),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _IncomeEditor extends ConsumerStatefulWidget {
  // Kept for local migration compatibility; the active Income flow is payment-derived.
  // ignore: unused_element_parameter
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
        const SnackBar(content: Text('Enter an amount greater than zero.')),
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
        ).showSnackBar(SnackBar(content: Text('Failed to save income: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
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
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(
            saving
                ? 'Saving...'
                : (widget.income == null ? 'Save income' : 'Update income'),
          ),
        ),
      ],
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
        loading: () => const Center(child: CircularProgressIndicator()),
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
                'Expenses',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Text('Track your business spending.'),
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
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search expenses',
                ),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No expenses recorded yet.'),
                  ),
                )
              else
                ...list.map(
                  (expense) => Card(
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
                                title: const Text('Delete expense?'),
                                content: const Text(
                                  'This action cannot be undone.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(d, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(d, true),
                                    child: const Text('Delete'),
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
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
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
    if (value <= 0 || category.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount and category.')),
      );
      return;
    }
    setState(() => saving = true);
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
        ).showSnackBar(SnackBar(content: Text('Could not save expense: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
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
    child: ListView(
      shrinkWrap: true,
      children: [
        Text(
          widget.expense == null ? 'Add expense' : 'Edit expense',
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
          controller: category,
          decoration: const InputDecoration(labelText: 'Category'),
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
          title: const Text('Expense date'),
          subtitle: Text(_date(date)),
          onTap: saving
              ? null
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
          child: Text(saving ? 'Saving...' : 'Save expense'),
        ),
      ],
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
      loading: () => const Center(child: CircularProgressIndicator()),
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
                      '${product.stockMilliunits / 1000} ${product.unit}${low ? ' • Low stock' : ''}',
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
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text('Edit product'),
                        ),
                        PopupMenuItem(
                          value: 'adjust',
                          child: Text('Adjust stock'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete product'),
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
        title: Text('Adjust ${product.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Change stock',
                hintText: 'Use -10 to remove stock',
              ),
            ),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(amount.text.trim());
              if (value != null && value != 0) {
                Navigator.pop(context, (value * 1000, reason.text));
              }
            },
            child: const Text('Save'),
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
        title: const Text('Delete product?'),
        content: Text(
          'Remove ${product.name} from active inventory? It can be restored from Recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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

  @override
  Widget build(BuildContext context) => Padding(
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
          widget.product == null
              ? 'Add inventory product'
              : 'Edit inventory product',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Product name *'),
        ),
        TextField(
          controller: sku,
          decoration: const InputDecoration(labelText: 'SKU (optional)'),
        ),
        TextField(
          controller: stock,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Opening stock'),
        ),
        TextField(
          controller: threshold,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Low-stock threshold'),
        ),
        TextField(
          controller: cost,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Unit cost (₹)'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
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
                ).showSnackBar(SnackBar(content: Text('$error')));
              }
            }
          },
          child: Text(
            widget.product == null ? 'Save product' : 'Update product',
          ),
        ),
      ],
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
      loading: () => const Center(child: CircularProgressIndicator()),
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
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text('Edit supplier'),
                        ),
                        PopupMenuItem(
                          value: 'payment',
                          child: Text('Record payment'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete supplier'),
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
        title: Text('Payment to ${supplier.name}'),
        content: TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Amount (₹)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(amount.text);
              if (value != null && value > 0) {
                Navigator.pop(context, (value * 100).round());
              }
            },
            child: const Text('Save'),
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
        title: const Text('Delete supplier?'),
        content: Text(
          'Remove ${supplier.name} from active suppliers? It can be restored from Recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
      loading: () => const Center(child: CircularProgressIndicator()),
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
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
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

  @override
  Widget build(BuildContext context) => Padding(
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
          widget.supplier == null ? 'Add supplier' : 'Edit supplier',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Supplier name *'),
        ),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone *'),
        ),
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
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
                ).showSnackBar(SnackBar(content: Text('$error')));
              }
            }
          },
          child: Text(
            widget.supplier == null ? 'Save supplier' : 'Update supplier',
          ),
        ),
      ],
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
        return const Center(child: CircularProgressIndicator());
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
                    const SnackBar(content: Text('Record restored')),
                  );
                },
                child: const Text('Restore'),
              ),
            ),
          );
        },
      );
    },
  );
}

class _ReportsTab extends StatelessWidget {
  const _ReportsTab({required this.summary, required this.customers});
  final AsyncValue<BillingSummary> summary;
  final AsyncValue<List<Customer>> customers;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Reports', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text('A quick view of your business performance.'),
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
                      'Collections',
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
                      '${_rupees(data.totalReceivedPaise)} collected of ${_rupees(data.totalBilledPaise)} billed',
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
                    title: const Text('Invoices issued'),
                    trailing: Text('${data.invoiceCount}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: const Text('Overdue invoices'),
                    trailing: Text('${data.overdueInvoiceCount}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('Outstanding'),
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
            title: const Text('Active customers'),
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
        .write(const SyncOperationsCompanion(status: Value('pending')));
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
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(label),
        ],
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
              labelText: 'Search customers',
              hintText: 'Name, mobile, or email',
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
                ? '${items.length} customer${items.length == 1 ? '' : 's'}'
                : '${filtered.length} result${filtered.length == 1 ? '' : 's'}',
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
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: ListTile(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) =>
            _CustomerDetailsSheet(businessId: businessId, customer: customer),
      ),
      leading: CircleAvatar(
        child: Text(customer.name.substring(0, 1).toUpperCase()),
      ),
      title: Text(customer.name),
      subtitle: Text(customer.phone),
      trailing: ref
          .watch(
            customerOutstandingProvider((
              businessId: businessId,
              customerId: customer.id,
            )),
          )
          .maybeWhen(
            data: (outstanding) => Text(
              outstanding == 0 ? 'Clear' : 'Due ${_rupees(outstanding)}',
              textAlign: TextAlign.end,
            ),
            orElse: () => const SizedBox.shrink(),
          ),
    ),
  );
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
          'No matching customers',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        const Text('Try a different name, mobile number, or email.'),
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
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _owner;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _upi;
  late String _language;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    final business = widget.business;
    _owner = TextEditingController(text: business.ownerName);
    _name = TextEditingController(text: business.name);
    _phone = TextEditingController(text: business.phone);
    _email = TextEditingController(text: business.email);
    _address = TextEditingController(text: business.address);
    _upi = TextEditingController(text: business.upiId);
    _language = business.preferredLanguage;
  }

  @override
  void dispose() {
    _owner.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _upi.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(businessRepositoryProvider)
          .updateBusiness(
            businessId: widget.business.id,
            ownerName: _owner.text,
            name: _name.text,
            phone: _phone.text,
            email: _email.text,
            address: _address.text,
            upiId: _upi.text,
            languageCode: _language,
          );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save settings: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.88,
    minChildSize: 0.55,
    builder: (context, scrollController) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          controller: scrollController,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Business settings',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _owner,
              decoration: const InputDecoration(labelText: 'Owner name'),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Business or shop name',
              ),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Business phone'),
              validator: _phoneValidator,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Business email'),
              validator: _optionalEmailValidator,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _address,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Business address'),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _upi,
              decoration: const InputDecoration(labelText: 'UPI ID'),
              validator: _upiValidator,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show payment QR'),
              onPressed: () {
                final upi = _upi.text.trim();
                if (upi.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Save a UPI ID before showing the QR.'),
                    ),
                  );
                  return;
                }
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Payment QR'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QrImageView(
                          data:
                              'upi://pay?pa=${Uri.encodeComponent(upi)}&pn=${Uri.encodeComponent(widget.business.name)}',
                          size: 220,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Showing this QR never records a payment. Confirm payment only after money is received.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.backup_outlined),
              label: const Text('Export local backup'),
              onPressed: () async {
                try {
                  final json = await ref
                      .read(backupServiceProvider)
                      .exportBusiness(widget.business.id);
                  await SharePlus.instance.share(
                    ShareParams(
                      text: json,
                      subject: 'OneBill backup ${widget.business.name}',
                    ),
                  );
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Backup failed: $error')),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _language,
              decoration: const InputDecoration(labelText: 'Language'),
              items: const [
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                DropdownMenuItem(value: 'te', child: Text('తెలుగు')),
                DropdownMenuItem(value: 'ta', child: Text('தமிழ்')),
                DropdownMenuItem(value: 'kn', child: Text('ಕನ್ನಡ')),
                DropdownMenuItem(value: 'ml', child: Text('മലയാളം')),
                DropdownMenuItem(value: 'mr', child: Text('मराठी')),
                DropdownMenuItem(value: 'gu', child: Text('ગુજરાતી')),
                DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
                DropdownMenuItem(value: 'ur', child: Text('اردو')),
                DropdownMenuItem(value: 'pa', child: Text('ਪੰਜਾਬੀ')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _language = value!),
            ),
            const SizedBox(height: 8),
            const Text(
              'UPI details are stored for a future QR-payment screen; showing a QR will never create a payment automatically.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Save business settings'),
            ),
          ],
        ),
      ),
    ),
  );
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
      await ref
          .read(businessRepositoryProvider)
          .createBusiness(
            accountId: widget.accountId,
            ownerName: _owner.text,
            businessName: _name.text,
            phone: _phone.text,
            languageCode: _language,
          );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add business: $error')),
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
            'Add new business',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'This business starts with empty customers, invoices, and payments.',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _owner,
            decoration: const InputDecoration(labelText: 'Owner name'),
            validator: _required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Business or shop name',
            ),
            validator: _required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Business phone (optional)',
            ),
            validator: _phoneValidator,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _language,
            decoration: const InputDecoration(labelText: 'Language'),
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
              DropdownMenuItem(value: 'te', child: Text('తెలుగు')),
              DropdownMenuItem(value: 'ta', child: Text('தமிழ்')),
              DropdownMenuItem(value: 'kn', child: Text('ಕನ್ನಡ')),
              DropdownMenuItem(value: 'ml', child: Text('മലയാളം')),
              DropdownMenuItem(value: 'mr', child: Text('मराठी')),
              DropdownMenuItem(value: 'gu', child: Text('ગુજરાતી')),
              DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
              DropdownMenuItem(value: 'ur', child: Text('اردو')),
              DropdownMenuItem(value: 'pa', child: Text('ਪੰਜਾਬੀ')),
            ],
            onChanged: (value) => setState(() => _language = value!),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Creating...' : 'Create empty business'),
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
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 20),
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
            Text('Invoices', style: Theme.of(context).textTheme.titleMedium),
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
                label: const Text('Create invoice'),
              ),
            ),
          ],
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
          SnackBar(content: Text('Could not remove customer: $error')),
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
                      const SnackBar(content: Text('Mobile number copied')),
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
      if (items.isEmpty) return const Center(child: Text('No invoices yet.'));
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
              labelText: 'Search invoices',
              hintText: 'Invoice number',
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
          const SizedBox(height: 8),
          DropdownButtonFormField<InvoicePaymentStatus?>(
            initialValue: _statusFilter,
            decoration: const InputDecoration(labelText: 'Filter by status'),
            items: const [
              DropdownMenuItem<InvoicePaymentStatus?>(
                value: null,
                child: Text('All invoices'),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.unpaid,
                child: Text('Unpaid'),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.partiallyPaid,
                child: Text('Partially paid'),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.overdue,
                child: Text('Overdue'),
              ),
              DropdownMenuItem(
                value: InvoicePaymentStatus.paid,
                child: Text('Paid'),
              ),
            ],
            onChanged: (value) => setState(() => _statusFilter = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No matching invoices.'))
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
    return Card(
      child: ListTile(
        onTap: onTap,
        title: items.maybeWhen(
          data: (entries) => Text(
            entries.isEmpty
                ? 'Invoice ${invoice.invoiceNumber}'
                : entries.first.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          orElse: () => Text('Invoice ${invoice.invoiceNumber}'),
        ),
        subtitle: Text(
          '${invoice.invoiceNumber}  •  Total ${_rupees(total)}  •  Due ${_rupees(balance)}',
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
      final bytes = await _pdfBytes(ref);
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: invoice.invoiceNumber,
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
      final bytes = await _pdfBytes(ref);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'application/pdf',
              name: '${invoice.invoiceNumber}.pdf',
            ),
          ],
          title: 'Invoice ${invoice.invoiceNumber}',
          text: 'Invoice ${invoice.invoiceNumber}',
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share invoice PDF: $error')),
        );
      }
    }
  }

  Future _pdfBytes(WidgetRef ref) async {
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
    return ref
        .read(pdfInvoiceServiceProvider)
        .generate(
          business: business,
          customer: customer,
          invoice: invoice,
          items: items,
        );
  }

  Future<void> _confirmVoid(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Void invoice?'),
        content: const Text(
          'This removes the invoice from active totals and lists. Its items and audit history remain stored. An invoice with payments cannot be voided.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Void invoice'),
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
    final total = repository.total(invoice);
    final balance = repository.balance(invoice);
    final status = repository.status(invoice);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.55,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: ListView(
          controller: controller,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              invoice.invoiceNumber,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('Created ${_date(invoice.issuedAt)}'),
            if (invoice.dueAt != null) Text('Due ${_date(invoice.dueAt!)}'),
            if (invoice.notes != null) ...[
              const SizedBox(height: 8),
              Text(
                invoice.notes!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 4),
            _InvoiceStatusBadge(status: status),
            const SizedBox(height: 16),
            TweenAnimationBuilder<double>(
              key: ValueKey(invoice.paidPaise),
              tween: Tween(begin: 0.10, end: 0),
              duration: const Duration(milliseconds: 700),
              builder: (context, highlight, child) => Card(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: highlight),
                child: child,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    const Divider(),
                    _AmountLine(label: 'Total', amount: total, bold: true),
                    _AmountLine(label: 'Paid', amount: invoice.paidPaise),
                    _AmountLine(label: 'Balance', amount: balance, bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (balance > 0)
              FilledButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _RecordPaymentSheet(
                    businessId: businessId,
                    invoice: invoice,
                  ),
                ),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Record payment'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _preview(context, ref),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Preview / print PDF'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _share(context, ref),
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share / save PDF'),
            ),
            if (invoice.paidPaise == 0) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _EditInvoiceDetailsSheet(
                    businessId: businessId,
                    invoice: invoice,
                  ),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit invoice'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _confirmVoid(context, ref),
                icon: const Icon(Icons.block_outlined),
                label: const Text('Void invoice'),
              ),
            ],
            const SizedBox(height: 20),
            Text('Items', style: Theme.of(context).textTheme.titleMedium),
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
              'Payment history',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            payments.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('Unable to load payments: $error'),
              data: (entries) => entries.isEmpty
                  ? const Text('No payments recorded yet.')
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
    _loadItems();
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

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      24 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: ListView(
      shrinkWrap: true,
      children: [
        Text('Edit invoice', style: Theme.of(context).textTheme.titleLarge),
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
          label: const Text('Add item'),
        ),
        TextField(
          controller: discount,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Discount (₹)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: interest,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Interest / extra charge (₹)',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: notes,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Notes'),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Due date'),
          subtitle: Text(dueAt == null ? 'No due date' : _date(dueAt!)),
          onTap: saving
              ? null
              : () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: dueAt ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null && mounted) setState(() => dueAt = d);
                },
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? 'Saving...' : 'Save changes'),
        ),
      ],
    ),
  );
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
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('Edit customer', style: Theme.of(context).textTheme.titleLarge),
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
  );
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
          label,
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
      InvoicePaymentStatus.unpaid => ('Unpaid', Colors.orange),
      InvoicePaymentStatus.partiallyPaid => ('Partially paid', Colors.blue),
      InvoicePaymentStatus.paid => ('Paid', Colors.green),
      InvoicePaymentStatus.overdue => ('Overdue', Colors.red),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Chip(
        key: ValueKey(status),
        visualDensity: VisualDensity.compact,
        label: Text(label),
        labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        backgroundColor: color.withValues(alpha: 0.08),
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
      await ref
          .read(invoiceRepositoryProvider)
          .recordPayment(
            businessId: widget.businessId,
            invoiceId: widget.invoice.id,
            amountPaise: _parseRupees(_amount.text),
            method: _method,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
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
          Text('Record payment', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('Outstanding: ${_rupees(_remaining)}'),
          const SizedBox(height: 20),
          TextFormField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount received (₹)'),
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
              child: const Text('Use full balance'),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _method,
            decoration: const InputDecoration(labelText: 'Payment method'),
            items: const [
              DropdownMenuItem(value: 'Cash', child: Text('Cash')),
              DropdownMenuItem(value: 'UPI', child: Text('UPI')),
              DropdownMenuItem(
                value: 'Bank transfer',
                child: Text('Bank transfer'),
              ),
              DropdownMenuItem(value: 'Other', child: Text('Other')),
            ],
            onChanged: (value) => setState(() => _method = value!),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Recording...' : 'Confirm payment'),
          ),
        ],
      ),
    ),
  );
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(invoiceRepositoryProvider)
          .createInvoice(
            businessId: widget.businessId,
            customerId: widget.customerId,
            items: _items.map((item) => item.toInput()).toList(),
            discountPaise: _parseOptionalRupees(_discount.text),
            interestPaise: _parseOptionalRupees(_interest.text),
            dueAt: _dueAt,
            notes: _notes.text,
          );
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

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.9,
    minChildSize: 0.55,
    builder: (context, scrollController) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          controller: scrollController,
          children: [
            Text(
              'Create invoice',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('Add each item with its quantity and unit price.'),
            const SizedBox(height: 20),
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
              child: TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() => _items.add(_InvoiceItemDraft())),
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
              ),
            ),
            const Divider(height: 32),
            TextFormField(
              controller: _discount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Discount (₹, optional)',
              ),
              validator: _optionalAmountValidator,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _interest,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Interest / extra charge (₹, optional)',
              ),
              validator: _optionalAmountValidator,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Due date'),
              subtitle: Text(_dueAt == null ? 'No due date' : _date(_dueAt!)),
              trailing: _dueAt == null
                  ? const Icon(Icons.calendar_today_outlined)
                  : IconButton(
                      tooltip: 'Clear due date',
                      onPressed: () => setState(() => _dueAt = null),
                      icon: const Icon(Icons.clear),
                    ),
              onTap: _saving ? null : _selectDueDate,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _AmountLine(label: 'Subtotal', amount: _subtotal),
                    _AmountLine(
                      label: 'Discount',
                      amount: -_parseOptionalRupees(_discount.text),
                    ),
                    _AmountLine(
                      label: 'Extra charge',
                      amount: _parseOptionalRupees(_interest.text),
                    ),
                    const Divider(),
                    _AmountLine(label: 'Total', amount: _total, bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Create invoice'),
            ),
          ],
        ),
      ),
    ),
  );
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
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Item $itemNumber',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              if (canRemove)
                IconButton(
                  tooltip: 'Remove item',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          TextFormField(
            controller: draft.description,
            decoration: const InputDecoration(labelText: 'Item or service'),
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
                  decoration: const InputDecoration(labelText: 'Quantity'),
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
                    labelText: 'Unit price (₹)',
                  ),
                  validator: _amountValidator,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text('Line total: ${_rupees(draft.lineTotalPaise)}'),
          ),
        ],
      ),
    ),
  );
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
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(customerRepositoryProvider)
          .create(
            businessId: widget.businessId,
            name: _name.text,
            phone: _phone.text,
          );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
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
          Text('Add customer', style: Theme.of(context).textTheme.titleLarge),
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
            validator: _required,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save customer'),
          ),
        ],
      ),
    ),
  );
}

class _EmptyCustomers extends StatelessWidget {
  const _EmptyCustomers();
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, size: 56),
          SizedBox(height: 16),
          Text(
            'No customers yet.',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Add your first customer to begin creating invoices.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
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

String? _upiValidator(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return RegExp(r'^[\w.\-]{2,}@[\w.\-]{2,}$').hasMatch(value.trim())
      ? null
      : 'Enter a valid UPI ID, for example name@bank.';
}

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
