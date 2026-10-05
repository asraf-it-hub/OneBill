import 'package:flutter_contacts/flutter_contacts.dart';

class ContactService {
  const ContactService();

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

  /// Request read/write contacts permissions when user explicitly taps 'Add from Contacts'.
  Future<PermissionStatus> requestContactsPermission() async {
    try {
      final status = await FlutterContacts.permissions.request(PermissionType.readWrite);
      if (status == PermissionStatus.granted || status == PermissionStatus.limited) {
        return status;
      }
      // If readWrite was not granted, check if read was granted (Case B: Read granted, Write denied)
      final readStatus = await FlutterContacts.permissions.check(PermissionType.read);
      if (readStatus == PermissionStatus.granted || readStatus == PermissionStatus.limited) {
        return readStatus;
      }
      return status;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  /// Check whether read contacts permission is currently granted
  Future<bool> hasReadPermission() async {
    try {
      return await FlutterContacts.permissions.has(PermissionType.read);
    } catch (_) {
      return false;
    }
  }

  /// Open native Android contact picker and retrieve contact with name and phone details
  Future<Contact?> pickSingleContact() async {
    try {
      return await FlutterContacts.native.showPicker(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
    } catch (_) {
      return null;
    }
  }

  /// Open app settings if permission is permanently denied
  Future<void> openAppSettings() async {
    try {
      await FlutterContacts.permissions.openSettings();
    } catch (_) {}
  }

  /// Optionally save a OneBill customer into Android Phone Contacts.
  /// Checks for obvious duplicate phone numbers before insertion to prevent clutter.
  Future<bool> saveContactToPhone({
    required String name,
    required String phone,
  }) async {
    try {
      // 1. Check or request write permission
      var canWrite = await FlutterContacts.permissions.has(PermissionType.readWrite);
      if (!canWrite) {
        final req = await FlutterContacts.permissions.request(PermissionType.readWrite);
        canWrite = req == PermissionStatus.granted || req == PermissionStatus.limited;
      }
      if (!canWrite) return false;

      final normalizedNew = normalizePhone(phone);
      if (normalizedNew.isEmpty) return false;

      // 2. Check for duplicate phone number in existing phone contacts
      try {
        final existingContacts = await FlutterContacts.getAll(
          properties: {ContactProperty.phone},
        );
        final alreadyExists = existingContacts.any(
          (c) => c.phones.any((p) => normalizePhone(p.number) == normalizedNew),
        );
        if (alreadyExists) {
          // Contact with this number is already in phonebook; avoid duplicate
          return true;
        }
      } catch (_) {
        // If checking existing contacts fails, proceed with safe insert
      }

      // 3. Create new phone contact
      final newContact = Contact(
        name: Name(first: name.trim()),
        phones: [
          Phone(number: phone.trim()),
        ],
      );
      await FlutterContacts.create(newContact);
      return true;
    } catch (_) {
      return false;
    }
  }
}
