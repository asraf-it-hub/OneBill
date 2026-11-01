import 'package:flutter/services.dart';

class PickedContact {
  final String name;
  final String phone;

  const PickedContact({
    required this.name,
    required this.phone,
  });
}

class ContactService {
  const ContactService();

  static const MethodChannel _contactChannel =
      MethodChannel('com.onebill.app/contact_picker');

  /// Normalizes an Indian/international phone number by stripping formatting characters
  /// and standardizing 10-digit Indian mobile numbers (removing leading +91 or 0).
  static String normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    } else if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return digits;
  }

  /// Open native Android contact picker and retrieve contact with name and phone details
  /// without requiring any broad READ_CONTACTS or WRITE_CONTACTS permissions.
  Future<PickedContact?> pickSingleContact() async {
    try {
      final res =
          await _contactChannel.invokeMapMethod<String, dynamic>('pickContact');
      if (res != null) {
        final name = (res['name'] as String? ?? '').trim();
        final phone = (res['phone'] as String? ?? '').trim();
        if (name.isNotEmpty || phone.isNotEmpty) {
          return PickedContact(name: name, phone: phone);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
