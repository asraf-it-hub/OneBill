abstract final class InvoiceFileNameService {
  static const String prefix = 'OneBill';

  /// Generates a standardized, professional invoice PDF filename.
  /// Format: OneBill_[BusinessName]_[CustomerName]_[InvoiceNumber].pdf
  /// Fallback: OneBill_[BusinessName]_Invoice_[InvoiceNumber].pdf (if customer name is missing)
  static String generate({
    required String businessName,
    required String? customerName,
    required String invoiceNumber,
  }) {
    final cleanBiz = sanitize(businessName);
    final safeBiz = cleanBiz.isEmpty ? 'Business' : cleanBiz;

    final cleanCust = (customerName != null && customerName.trim().isNotEmpty)
        ? sanitize(customerName)
        : 'Invoice';
    final safeCust = cleanCust.isEmpty ? 'Invoice' : cleanCust;

    final cleanNumber = sanitize(invoiceNumber);
    final safeNumber = cleanNumber.isEmpty ? 'OB-000000' : cleanNumber;

    return '${prefix}_${safeBiz}_${safeCust}_$safeNumber.pdf';
  }

  /// Sanitizes string inputs to create safe OS file names.
  /// Replaces filesystem illegal characters (/ \ : * ? " < > |) and spaces with hyphens.
  static String sanitize(String input) {
    var clean = input.trim();
    if (clean.isEmpty) return '';

    // Replace invalid characters on Windows, macOS, Android, Linux with dash
    clean = clean.replaceAll(RegExp(r'[/\:\*\?"<>\|]'), '-');
    // Replace whitespace and multiple consecutive hyphens with a single hyphen
    clean = clean.replaceAll(RegExp(r'\s+'), '-');
    clean = clean.replaceAll(RegExp(r'-+'), '-');

    // Remove leading and trailing hyphens
    while (clean.startsWith('-')) {
      clean = clean.substring(1);
    }
    while (clean.endsWith('-')) {
      clean = clean.substring(0, clean.length - 1);
    }

    return clean;
  }
}
