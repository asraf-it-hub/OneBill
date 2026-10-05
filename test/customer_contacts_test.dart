import 'package:flutter_test/flutter_test.dart';
import 'package:onebill/features/customers/services/contact_service.dart';
import 'package:onebill/core/localization/app_localizations.dart';

void main() {
  group('Customer Contacts Integration Tests', () {
    test('ContactService.normalizePhone normalizes various phone number formats', () {
      // 10 digits directly
      expect(ContactService.normalizePhone('9876543210'), '9876543210');

      // Formatted with spaces and hyphens
      expect(ContactService.normalizePhone('98765 43210'), '9876543210');
      expect(ContactService.normalizePhone('98765-43210'), '9876543210');

      // With Indian country code +91
      expect(ContactService.normalizePhone('+91 98765 43210'), '9876543210');
      expect(ContactService.normalizePhone('+919876543210'), '9876543210');
      expect(ContactService.normalizePhone('919876543210'), '9876543210');

      // With leading 0
      expect(ContactService.normalizePhone('09876543210'), '9876543210');
      expect(ContactService.normalizePhone('0 98765 43210'), '9876543210');

      // Empty or non-digits
      expect(ContactService.normalizePhone(''), '');
      expect(ContactService.normalizePhone('   '), '');
    });

    test('Customer contacts localization keys exist for en, hi, and te', () {
      final requiredKeys = [
        'Add from Contacts',
        'Save to phone contacts',
        'Select a phone number',
        'No phone number found',
        'This customer already exists',
        'Contact permission is required',
        'Allow contact access',
        'Unable to access contacts',
        'Open Settings',
        'OR',
        'Contact permission is needed to import customer from phonebook.',
        'Contact permission is permanently denied. Please allow it from App Settings.',
        'Customer saved to phone contacts',
      ];

      for (final key in requiredKeys) {
        expect(appTranslations.containsKey(key), isTrue,
            reason: 'Missing key "$key" in appTranslations');
        final trans = appTranslations[key]!;
        expect(trans.containsKey('hi'), isTrue,
            reason: 'Missing Hindi translation for "$key"');
        expect(trans['hi']!.isNotEmpty, isTrue,
            reason: 'Empty Hindi translation for "$key"');
        expect(trans.containsKey('te'), isTrue,
            reason: 'Missing Telugu translation for "$key"');
        expect(trans['te']!.isNotEmpty, isTrue,
            reason: 'Empty Telugu translation for "$key"');
      }
    });
  });
}
