import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/providers.dart';

class BusinessProfileScreen extends ConsumerStatefulWidget {
  const BusinessProfileScreen({super.key, required this.businessId});
  final String businessId;

  @override
  ConsumerState<BusinessProfileScreen> createState() =>
      _BusinessProfileScreenState();
}

class _BusinessProfileScreenState
    extends ConsumerState<BusinessProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _ownerNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _addressController;
  late final TextEditingController _websiteController;
  late final TextEditingController _taglineController;
  late final TextEditingController _gstinController;
  late final TextEditingController _upiIdController;
  late final TextEditingController _upiNameController;
  late final TextEditingController _invoiceNotesController;
  late final TextEditingController _termsController;

  String? _logoImagePath;
  String? _paymentQrImagePath;

  bool _isLoading = true;
  bool _isSaving = false;
  String? _qrResolutionWarning;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _ownerNameController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
    _addressController = TextEditingController();
    _websiteController = TextEditingController();
    _taglineController = TextEditingController();
    _gstinController = TextEditingController();
    _upiIdController = TextEditingController();
    _upiNameController = TextEditingController();
    _invoiceNotesController = TextEditingController();
    _termsController = TextEditingController();

    _loadBusinessData();
  }

  Future<void> _loadBusinessData() async {
    final db = ref.read(databaseProvider);
    final business = await (db.select(
      db.businesses,
    )..where((b) => b.id.equals(widget.businessId))).getSingleOrNull();

    final authEmail =
        ref.read(authSessionProvider).valueOrNull?.user.email ??
        Supabase.instance.client.auth.currentUser?.email;

    if (business != null && mounted) {
      setState(() {
        _nameController.text = business.name;
        _ownerNameController.text = business.ownerName;
        _phoneController.text = business.phone ?? '';
        _emailController.text =
            (business.email != null && business.email!.trim().isNotEmpty)
                ? business.email!
                : (authEmail ?? '');
        _addressController.text = business.address ?? '';
        _websiteController.text = business.website ?? '';
        _taglineController.text = business.tagline ?? '';
        _gstinController.text = business.gstin ?? '';
        _upiIdController.text = business.upiId ?? '';
        _upiNameController.text = business.upiName ?? '';
        _invoiceNotesController.text =
            (business.invoiceNotes != null &&
                    business.invoiceNotes!.trim().isNotEmpty)
                ? business.invoiceNotes!
                : 'Thank you for your business! Please reach out if you have any questions.';
        _termsController.text =
            (business.termsAndConditions != null &&
                    business.termsAndConditions!.trim().isNotEmpty)
                ? business.termsAndConditions!
                : '1. Goods once sold will not be taken back or exchanged.\n2. Payment is due as per agreed payment terms.\n3. E.&O.E.';

        _logoImagePath = business.logoImage;
        _paymentQrImagePath = business.paymentQrImage;

        _isLoading = false;
      });
    } else if (mounted) {
      if (authEmail != null) {
        _emailController.text = authEmail;
      }
      _invoiceNotesController.text =
          'Thank you for your business! Please reach out if you have any questions.';
      _termsController.text =
          '1. Goods once sold will not be taken back or exchanged.\n2. Payment is due as per agreed payment terms.\n3. E.&O.E.';
      setState(() => _isLoading = false);
    }
  }

  int get _completedCount {
    int count = 0;
    if (_nameController.text.trim().isNotEmpty) count++;
    if (_ownerNameController.text.trim().isNotEmpty) count++;
    if (_phoneController.text.trim().isNotEmpty) count++;
    if (_emailController.text.trim().isNotEmpty) count++;
    if (_addressController.text.trim().isNotEmpty) count++;
    if (_logoImagePath != null && _logoImagePath!.trim().isNotEmpty) count++;
    if (_upiIdController.text.trim().isNotEmpty) count++;
    if (_paymentQrImagePath != null && _paymentQrImagePath!.trim().isNotEmpty) count++;
    if (_gstinController.text.trim().isNotEmpty) count++;
    return count;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ownerNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _websiteController.dispose();
    _taglineController.dispose();
    _gstinController.dispose();
    _upiIdController.dispose();
    _upiNameController.dispose();
    _invoiceNotesController.dispose();
    _termsController.dispose();
    super.dispose();
  }

  Future<void> _pickImage({required bool isLogo}) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
      maxHeight: 800,
    );

    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();
    final base64String = 'data:image/png;base64,${base64Encode(bytes)}';

    if (!isLogo) {
      final image = await decodeImageFromList(bytes);
      if (image.width < 300 || image.height < 300) {
        setState(() {
          _qrResolutionWarning =
              'Low QR image resolution (${image.width}x${image.height}). A clearer image is recommended for scanning.';
        });
      } else {
        setState(() => _qrResolutionWarning = null);
      }
    }

    setState(() {
      if (isLogo) {
        _logoImagePath = base64String;
      } else {
        _paymentQrImagePath = base64String;
      }
    });
  }

  Widget _buildImagePreview(String? pathOrBase64, IconData fallbackIcon, double iconSize) {
    if (pathOrBase64 == null || pathOrBase64.trim().isEmpty) {
      return Icon(
        fallbackIcon,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: iconSize,
      );
    }
    final trimmed = pathOrBase64.trim();
    if (trimmed.startsWith('data:image/') || trimmed.length > 500) {
      try {
        final base64Data = trimmed.contains(',') ? trimmed.split(',').last : trimmed;
        final bytes = base64Decode(base64Data);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(bytes, fit: BoxFit.contain),
        );
      } catch (_) {}
    }
    if (File(trimmed).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(File(trimmed), fit: BoxFit.contain),
      );
    }
    return Icon(
      fallbackIcon,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      size: iconSize,
    );
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final repository = ref.read(businessRepositoryProvider);
      final session = ref.read(sessionProvider).valueOrNull;
      final langCode = session?.localeCode ?? 'en';

      await repository.updateBusiness(
        businessId: widget.businessId,
        ownerName: _ownerNameController.text.trim(),
        name: _nameController.text.trim(),
        languageCode: langCode,
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
        address: _addressController.text.trim(),
        website: _websiteController.text.trim(),
        tagline: _taglineController.text.trim(),
        gstin: _gstinController.text.trim(),
        upiId: _upiIdController.text.trim(),
        upiName: _upiNameController.text.trim(),
        invoiceNotes: _invoiceNotesController.text.trim(),
        termsAndConditions: _termsController.text.trim(),
        logoImage: _logoImagePath,
        paymentQrImage: _paymentQrImagePath,
      );

      ref.read(syncWorkerProvider).syncBusiness(widget.businessId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Business profile updated successfully')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save business profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Business Profile')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Business Profile')),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: Text(
              _isSaving ? tr(context, 'Saving...') : tr(context, 'Save'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            _buildProgressCard(theme),
            const SizedBox(height: 16),

            _buildSectionHeader(
              theme,
              'Business Identity',
              Icons.storefront_outlined,
            ),
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'Business Logo'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr(context, 'Appears at the top of your PDF invoices'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: _buildImagePreview(
                            _logoImagePath,
                            Icons.add_photo_alternate_outlined,
                            32,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _pickImage(isLogo: true),
                                icon: const Icon(Icons.upload_outlined, size: 18),
                                label: Text(
                                  _logoImagePath == null
                                      ? tr(context, 'Upload Logo')
                                      : tr(context, 'Change Logo'),
                                ),
                              ),
                              if (_logoImagePath != null) ...[
                                const SizedBox(height: 4),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _logoImagePath = null),
                                  child: Text(
                                    tr(context, 'Remove Logo'),
                                    style: const TextStyle(color: Colors.red, fontSize: 13),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldBlock(
                      title: 'Business Name *',
                      subtitle: 'Primary business name shown on invoices',
                      child: TextFormField(
                        controller: _nameController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Acme Enterprises',
                          prefixIcon: Icon(Icons.store_outlined),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Business name is required'
                                : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Owner Name *',
                      subtitle: 'Your name as business owner',
                      child: TextFormField(
                        controller: _ownerNameController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Ramesh Kumar',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Owner name is required'
                                : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Business Tagline (Optional)',
                      subtitle: 'Appears under your business name',
                      child: TextFormField(
                        controller: _taglineController,
                        decoration: const InputDecoration(
                          hintText: 'e.g. Quality Hardware & Tools',
                          prefixIcon: Icon(Icons.subtitles_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            _buildSectionHeader(
              theme,
              'Contact & Address',
              Icons.contact_mail_outlined,
            ),
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldBlock(
                      title: 'Phone Number',
                      subtitle: 'Primary contact phone number',
                      child: TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. 9876543210',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Email Address (Optional)',
                      subtitle: 'Pre-filled with login email; editable anytime',
                      child: TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. owner@example.com',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Business Address (Optional)',
                      subtitle: 'Physical business location shown on invoices',
                      child: TextFormField(
                        controller: _addressController,
                        maxLines: 2,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Shop #4, Main Road, Hyderabad',
                          prefixIcon: Icon(Icons.location_on_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Website (Optional)',
                      subtitle: 'Your shop or business website',
                      child: TextFormField(
                        controller: _websiteController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          hintText: 'e.g. www.mybusiness.com',
                          prefixIcon: Icon(Icons.language_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            _buildSectionHeader(
              theme,
              'Tax & Registration',
              Icons.badge_outlined,
            ),
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _buildFieldBlock(
                  title: 'GSTIN (Optional)',
                  subtitle: '15-digit GST Identification Number',
                  child: TextFormField(
                    controller: _gstinController,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'e.g. 36AAAAA0000A1Z5',
                      prefixIcon: Icon(Icons.receipt_outlined),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            _buildSectionHeader(
              theme,
              'Payment Details',
              Icons.qr_code_scanner_outlined,
            ),
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'UPI Payment QR Code'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr(context, 'Upload your UPI QR code for customers to scan on invoices.'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: _buildImagePreview(
                            _paymentQrImagePath,
                            Icons.qr_code_2_outlined,
                            38,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _pickImage(isLogo: false),
                                icon: const Icon(
                                  Icons.upload_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _paymentQrImagePath == null
                                      ? tr(context, 'Upload QR')
                                      : tr(context, 'Change QR'),
                                ),
                              ),
                              if (_paymentQrImagePath != null) ...[
                                const SizedBox(height: 4),
                                TextButton(
                                  onPressed: () => setState(() {
                                    _paymentQrImagePath = null;
                                    _qrResolutionWarning = null;
                                  }),
                                  child: Text(
                                    tr(context, 'Remove QR'),
                                    style: const TextStyle(color: Colors.red, fontSize: 13),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_qrResolutionWarning != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade300),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.amber,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _qrResolutionWarning!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black87,
                                ),
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
            const SizedBox(height: 12),

            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldBlock(
                      title: 'UPI ID (Optional)',
                      subtitle: 'Shown on invoices for direct UPI payments',
                      child: TextFormField(
                        controller: _upiIdController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'e.g. 9010094034@ybl or business@upi',
                          prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFieldBlock(
                      title: 'Account Holder Name (as in UPI)',
                      subtitle: 'Verified name registered in UPI for customer verification',
                      child: TextFormField(
                        controller: _upiNameController,
                        decoration: const InputDecoration(
                          hintText: 'e.g. Ramesh Kumar',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            _buildSectionHeader(
              theme,
              'Invoice Terms & Notes',
              Icons.description_outlined,
            ),
            const SizedBox(height: 12),

            // Notes & Terms block styled with distinct theme contrast
            Card(
              elevation: 0,
              color: const Color(0xFFF8FAFC),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStyledPolicyBlock(
                      theme: theme,
                      title: 'Default Invoice Notes',
                      badgeText: 'DEFAULT NOTE PREVIEW',
                      controller: _invoiceNotesController,
                      maxLines: 2,
                      hintText: 'e.g. Thank you for your business!',
                      icon: Icons.note_alt_outlined,
                    ),
                    const SizedBox(height: 20),
                    _buildStyledPolicyBlock(
                      theme: theme,
                      title: 'Terms & Conditions',
                      badgeText: 'POLICY PREVIEW',
                      controller: _termsController,
                      maxLines: 3,
                      hintText: 'e.g. Goods once sold will not be taken back.',
                      icon: Icons.gavel_outlined,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),

            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _saveProfile,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(
                  _isSaving ? tr(context, 'Saving Profile...') : tr(context, 'Save Business Profile'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 36),

            _buildDangerZoneSection(theme),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildDangerZoneSection(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr(context, 'Danger Zone - Business Deletion'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF991B1B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(context, 'Permanently delete this business and remove all invoices, customers, inventory, expenses, and cloud sync records. This action is irreversible.'),
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF7F1D1D),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isSaving ? null : () => _confirmAndDeleteBusiness(theme),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                side: const BorderSide(color: Color(0xFFDC2626), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.delete_forever, size: 20),
              label: Text(
                tr(context, 'Delete Business (Local & Cloud)'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndDeleteBusiness(ThemeData theme) async {
    final businessName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : 'this business';
    final confirmController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isMatch = confirmController.text.trim().toLowerCase() ==
                businessName.toLowerCase();
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFFEF4444), width: 2),
              ),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Delete Business Permanently?',
                      style: TextStyle(
                        color: Color(0xFF991B1B),
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFCA5A5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '⚠️ DANGER: PERMANENT DATA LOSS',
                            style: TextStyle(
                              color: Color(0xFF991B1B),
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'You are about to delete "$businessName" and all associated records on this device and in the cloud:',
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF7F1D1D),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '• Invoices, Line Items & Payments\n'
                            '• Customer & Supplier Accounts\n'
                            '• Inventory Stock & Movements\n'
                            '• Income & Expense Reports\n'
                            '• Cloud Backups & Sync Records',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF991B1B),
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'To confirm deletion, please type "$businessName" below:',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF334155),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: confirmController,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        hintText: businessName,
                        prefixIcon: const Icon(Icons.edit_note, color: Color(0xFFDC2626)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFDC2626), width: 2),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: isMatch ? () => Navigator.pop(context, true) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    disabledBackgroundColor: Colors.red.shade100,
                  ),
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: const Text(
                    'Delete Business',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      setState(() => _isSaving = true);
      try {
        await ref
            .read(businessRepositoryProvider)
            .deleteBusiness(businessId: widget.businessId);
        ref.read(syncWorkerProvider).syncBusiness(widget.businessId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Business deleted successfully from local and cloud.'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isSaving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting business: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }


  Widget _buildFieldBlock({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr(context, title),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1E293B),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          tr(context, subtitle),
          style: const TextStyle(
            fontSize: 11.5,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildStyledPolicyBlock({
    required ThemeData theme,
    required String title,
    required String badgeText,
    required TextEditingController controller,
    required int maxLines,
    required String hintText,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              tr(context, title),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          style: const TextStyle(
            fontSize: 13.5,
            color: Color(0xFF334155),
            height: 1.4,
          ),
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: Icon(icon, color: theme.colorScheme.primary),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressCard(ThemeData theme) {
    final count = _completedCount;
    const total = 9;
    final percent = ((count / total) * 100).toInt();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_outlined,
                color: theme.colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr(context, 'Profile Completion Status'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count of $total added ($percent%)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (count / total).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          tr(context, title),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(
            color: theme.colorScheme.outlineVariant,
            thickness: 1,
          ),
        ),
      ],
    );
  }
}
