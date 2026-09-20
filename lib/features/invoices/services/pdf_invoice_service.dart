import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/app_database.dart';

class PdfInvoiceService {
  pw.MemoryImage? _loadMemoryImage(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final trimmed = raw.trim();
    if (trimmed.startsWith('data:image/') || trimmed.length > 500) {
      try {
        final base64Data = trimmed.contains(',') ? trimmed.split(',').last : trimmed;
        final bytes = base64Decode(base64Data);
        return pw.MemoryImage(bytes);
      } catch (_) {}
    }
    try {
      final file = File(trimmed);
      if (file.existsSync()) {
        return pw.MemoryImage(file.readAsBytesSync());
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List> generate({
    required BusinessesData business,
    required Customer customer,
    required Invoice invoice,
    required List<InvoiceItem> items,
  }) async {
    final teluguFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansTelugu-Regular.ttf'),
    );
    final teluguBoldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansTelugu-Bold.ttf'),
    );
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );

    final document = pw.Document(
      title: invoice.invoiceNumber,
      author: business.name,
      theme: pw.ThemeData.withFont(
        base: regularFont,
        bold: boldFont,
        fontFallback: [teluguFont, teluguBoldFont],
      ),
    );

    // Financial computations using exact source-of-truth logic
    final total =
        invoice.subtotalPaise - invoice.discountPaise + invoice.interestPaise;
    final balance = total - invoice.paidPaise;
    final isFullyPaid = balance <= 0;
    final isPartiallyPaid = invoice.paidPaise > 0 && balance > 0;

    // Load logo image if present locally or as Base64 data URI
    final logoImage = _loadMemoryImage(business.logoImage);

    // Load UPI QR image if present locally or as Base64 data URI
    final qrImage = _loadMemoryImage(business.paymentQrImage);

    // Load OneBill official logo for branding footer
    pw.MemoryImage? oneBillLogo;
    try {
      final logoBytes = await rootBundle.load('assets/OneBillLogo.png');
      oneBillLogo = pw.MemoryImage(logoBytes.buffer.asUint8List());
    } catch (_) {}

    final primaryColor = PdfColor.fromHex('#20B298'); // OneBill Teal
    final darkSlate = PdfColor.fromHex('#1E293B');
    final lightGrey = PdfColor.fromHex('#F8FAFC');
    final borderGrey = PdfColor.fromHex('#E2E8F0');
    final subtleText = PdfColor.fromHex('#64748B');

    // Build contact info items
    final contactDetails = <String>[];
    if (business.phone != null && business.phone!.trim().isNotEmpty) {
      contactDetails.add(business.phone!.trim());
    }
    if (business.email != null && business.email!.trim().isNotEmpty) {
      contactDetails.add(business.email!.trim());
    }
    if (business.website != null && business.website!.trim().isNotEmpty) {
      contactDetails.add(business.website!.trim());
    }

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => [
          // 1. HEADER SECTION
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Left: Logo & Business Info
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    if (logoImage != null) ...[
                      pw.Container(
                        width: 60,
                        height: 60,
                        padding: const pw.EdgeInsets.all(4),
                        decoration: pw.BoxDecoration(
                          color: PdfColors.white,
                          borderRadius: pw.BorderRadius.circular(6),
                          border: pw.Border.all(color: borderGrey, width: 0.75),
                        ),
                        child: pw.Center(
                          child: pw.Image(logoImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                      pw.SizedBox(height: 8),
                    ],
                    pw.Text(
                      business.name,
                      style: pw.TextStyle(
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                        color: darkSlate,
                      ),
                    ),
                    if (business.tagline != null &&
                        business.tagline!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        business.tagline!.trim(),
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontStyle: pw.FontStyle.italic,
                          color: subtleText,
                        ),
                      ),
                    ],
                    if (contactDetails.isNotEmpty) ...[
                      pw.SizedBox(height: 4),
                      pw.Text(
                        contactDetails.join('  •  '),
                        style: pw.TextStyle(fontSize: 9, color: subtleText),
                      ),
                    ],
                    if (business.address != null &&
                        business.address!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        business.address!.trim(),
                        style: pw.TextStyle(fontSize: 9, color: subtleText),
                      ),
                    ],
                    if (business.gstin != null &&
                        business.gstin!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'GSTIN: ${business.gstin!.trim()}',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              pw.SizedBox(width: 20),

              // Right: Invoice Metadata & Status
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  // Top right branding
                  pw.Row(
                    mainAxisSize: pw.MainAxisSize.min,
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text(
                        'Powered by OneBill',
                        style: pw.TextStyle(
                          fontSize: 9.5,
                          fontWeight: pw.FontWeight.bold,
                          color: subtleText,
                        ),
                      ),
                      if (oneBillLogo != null) ...[
                        pw.SizedBox(width: 5),
                        pw.Container(
                          width: 18,
                          height: 18,
                          child: pw.Image(oneBillLogo, fit: pw.BoxFit.contain),
                        ),
                      ],
                    ],
                  ),
                  pw.SizedBox(height: 10),
                  pw.Text(
                    'INVOICE',
                    style: pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                      color: primaryColor,
                      letterSpacing: 1.2,
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    invoice.invoiceNumber,
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                      color: darkSlate,
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Date: ${_date(invoice.issuedAt)}',
                    style: pw.TextStyle(fontSize: 9, color: subtleText),
                  ),
                  if (invoice.dueAt != null) ...[
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Due Date: ${_date(invoice.dueAt!)}',
                      style: pw.TextStyle(fontSize: 9, color: subtleText),
                    ),
                  ],
                  pw.SizedBox(height: 8),
                  // Payment Status Badge
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: pw.BoxDecoration(
                      color: isFullyPaid
                          ? PdfColor.fromHex('#DCFCE7')
                          : isPartiallyPaid
                          ? PdfColor.fromHex('#FEF3C7')
                          : PdfColor.fromHex('#FEE2E2'),
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                    child: pw.Text(
                      isFullyPaid
                          ? 'PAID IN FULL'
                          : isPartiallyPaid
                          ? 'PARTIALLY PAID'
                          : 'UNPAID',
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: isFullyPaid
                            ? PdfColor.fromHex('#166534')
                            : isPartiallyPaid
                            ? PdfColor.fromHex('#92400E')
                            : PdfColor.fromHex('#991B1B'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          pw.SizedBox(height: 20),
          pw.Divider(color: borderGrey, thickness: 1),
          pw.SizedBox(height: 16),

          // 2. BILL TO SECTION
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'BILL TO',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: primaryColor,
                        letterSpacing: 1.0,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      customer.name,
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: darkSlate,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Phone: ${customer.phone}',
                      style: pw.TextStyle(fontSize: 9, color: subtleText),
                    ),
                    if (customer.email != null &&
                        customer.email!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'Email: ${customer.email!.trim()}',
                        style: pw.TextStyle(fontSize: 9, color: subtleText),
                      ),
                    ],
                    if (customer.notes != null &&
                        customer.notes!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        customer.notes!.trim(),
                        style: pw.TextStyle(fontSize: 9, color: subtleText),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 20),

          // 3. ITEMS TABLE
          pw.TableHelper.fromTextArray(
            headers: const ['Item', 'Qty', 'Unit Price', 'Amount'],
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: darkSlate,
            ),
            headerDecoration: pw.BoxDecoration(color: lightGrey),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            cellAlignment: pw.Alignment.centerRight,
            cellAlignments: {0: pw.Alignment.centerLeft},
            border: pw.TableBorder.all(color: borderGrey, width: 0.5),
            data: items
                .map(
                  (item) => [
                    item.description,
                    _quantity(item.quantityMilliunits),
                    _money(item.unitPricePaise),
                    _money(item.lineTotalPaise),
                  ],
                )
                .toList(),
          ),

          pw.SizedBox(height: 16),

          // 4. FINANCIAL SUMMARY BLOCK
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.SizedBox(
              width: 240,
              child: pw.Column(
                children: [
                  _summaryRow('Subtotal', invoice.subtotalPaise),
                  if (invoice.discountPaise > 0)
                    _summaryRow('Discount', -invoice.discountPaise),
                  if (invoice.interestPaise > 0)
                    _summaryRow('Interest', invoice.interestPaise),
                  pw.Divider(color: borderGrey, thickness: 1),
                  _summaryRow('Total', total, bold: true, fontSize: 11),
                  if (invoice.paidPaise > 0)
                    _summaryRow('Paid', invoice.paidPaise),
                  pw.SizedBox(height: 4),
                  if (isFullyPaid)
                    pw.Container(
                      width: double.infinity,
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#DCFCE7'),
                        borderRadius: pw.BorderRadius.circular(4),
                      ),
                      child: pw.Center(
                        child: pw.Text(
                          'PAID IN FULL',
                          style: pw.TextStyle(
                            fontSize: 11,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromHex('#166534'),
                          ),
                        ),
                      ),
                    )
                  else
                    pw.Container(
                      width: double.infinity,
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#FEF2F2'),
                        borderRadius: pw.BorderRadius.circular(4),
                        border: pw.Border.all(
                          color: PdfColor.fromHex('#FECACA'),
                        ),
                      ),
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(
                            'BALANCE DUE',
                            style: pw.TextStyle(
                              fontSize: 10,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColor.fromHex('#991B1B'),
                            ),
                          ),
                          pw.Text(
                            _money(balance),
                            style: pw.TextStyle(
                              fontSize: 11,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColor.fromHex('#991B1B'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          pw.SizedBox(height: 24),

          // 5. PAYMENT SECTION (UPI QR & DETAILS)
          // Displays whenever QR image, UPI ID, or Account Name is provided by owner
          if (qrImage != null ||
              (business.upiId != null &&
                  business.upiId!.trim().isNotEmpty) ||
              (business.upiName != null &&
                  business.upiName!.trim().isNotEmpty)) ...[
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: lightGrey,
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(color: borderGrey, width: 0.5),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (qrImage != null) ...[
                    pw.Container(
                      width: 90,
                      height: 90,
                      padding: const pw.EdgeInsets.all(6),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.white,
                        borderRadius: pw.BorderRadius.circular(6),
                        border: pw.Border.all(color: borderGrey, width: 0.75),
                      ),
                      child: pw.Center(
                        child: pw.Image(qrImage, fit: pw.BoxFit.contain),
                      ),
                    ),
                    pw.SizedBox(width: 16),
                  ],
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          isFullyPaid
                              ? 'PAYMENT DETAILS (PAID)'
                              : isPartiallyPaid
                              ? 'PAY BALANCE VIA UPI'
                              : 'PAY VIA UPI',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: primaryColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        if (qrImage != null)
                          pw.Text(
                            'Scan QR code with any UPI app to pay',
                            style: pw.TextStyle(
                              fontSize: 9,
                              color: subtleText,
                            ),
                          ),
                        if (business.upiId != null &&
                            business.upiId!.trim().isNotEmpty) ...[
                          pw.SizedBox(height: 4),
                          pw.Text(
                            'UPI ID: ${business.upiId!.trim()}',
                            style: pw.TextStyle(
                              fontSize: 10,
                              fontWeight: pw.FontWeight.bold,
                              color: darkSlate,
                            ),
                          ),
                        ],
                        if (business.upiName != null &&
                            business.upiName!.trim().isNotEmpty) ...[
                          pw.SizedBox(height: 2),
                          pw.Text(
                            'Account Holder Name: ${business.upiName!.trim()}',
                            style: pw.TextStyle(
                              fontSize: 9,
                              color: darkSlate,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
          ],

          // 6. NOTES & TERMS & CONDITIONS
          if ((business.invoiceNotes != null &&
                  business.invoiceNotes!.trim().isNotEmpty) ||
              (invoice.notes != null &&
                  invoice.notes!.trim().isNotEmpty)) ...[
            pw.Text(
              'NOTES',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              (business.invoiceNotes ?? invoice.notes!).trim(),
              style: pw.TextStyle(fontSize: 9, color: darkSlate),
            ),
            pw.SizedBox(height: 12),
          ],

          if (business.termsAndConditions != null &&
              business.termsAndConditions!.trim().isNotEmpty) ...[
            pw.Text(
              'TERMS & CONDITIONS',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              business.termsAndConditions!.trim(),
              style: pw.TextStyle(fontSize: 9, color: darkSlate),
            ),
            pw.SizedBox(height: 16),
          ],

          // 7. FOOTER
          pw.Spacer(),
          pw.Divider(color: borderGrey, thickness: 0.75),
          pw.SizedBox(height: 10),
          pw.Center(
            child: pw.Text(
              'Thank you for your business.',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: darkSlate,
              ),
            ),
          ),
        ],
      ),
    );

    return document.save();
  }

  pw.Widget _summaryRow(
    String label,
    int paise, {
    bool bold = false,
    double fontSize = 9,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
        pw.Text(
          _money(paise),
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ],
    ),
  );

  Future<Uint8List> generatePaperReceiptPdf({
    required BusinessesData business,
    required Customer customer,
    required Invoice invoice,
    required String paperReceiptImage,
  }) async {
    final teluguFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansTelugu-Regular.ttf'),
    );
    final teluguBoldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansTelugu-Bold.ttf'),
    );
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );

    final document = pw.Document(
      title: 'Receipt_${invoice.invoiceNumber}',
      author: business.name,
      theme: pw.ThemeData.withFont(
        base: regularFont,
        bold: boldFont,
        fontFallback: [teluguFont, teluguBoldFont],
      ),
    );

    final total =
        invoice.subtotalPaise - invoice.discountPaise + invoice.interestPaise;
    final balance = total - invoice.paidPaise;
    final isFullyPaid = balance <= 0;
    final isPartiallyPaid = invoice.paidPaise > 0 && balance > 0;

    final logoImage = _loadMemoryImage(business.logoImage);
    final qrImage = _loadMemoryImage(business.paymentQrImage);
    final receiptImage = _loadMemoryImage(paperReceiptImage);

    pw.MemoryImage? oneBillLogo;
    try {
      final logoBytes = await rootBundle.load('assets/OneBillLogo.png');
      oneBillLogo = pw.MemoryImage(logoBytes.buffer.asUint8List());
    } catch (_) {}

    final primaryColor = PdfColor.fromHex('#20B298');
    final darkSlate = PdfColor.fromHex('#1E293B');
    final lightGrey = PdfColor.fromHex('#F8FAFC');
    final borderGrey = PdfColor.fromHex('#E2E8F0');
    final subtleText = PdfColor.fromHex('#64748B');

    // 80mm thermal receipt format with clean proportions
    const receiptPageFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      260 * PdfPageFormat.mm,
      marginLeft: 5 * PdfPageFormat.mm,
      marginRight: 5 * PdfPageFormat.mm,
      marginTop: 6 * PdfPageFormat.mm,
      marginBottom: 6 * PdfPageFormat.mm,
    );

    final upiUrl = (business.upiId != null && business.upiId!.trim().isNotEmpty)
        ? 'upi://pay?pa=${business.upiId!.trim()}&pn=${Uri.encodeComponent(business.name)}&cu=INR${balance > 0 ? '&am=${(balance / 100).toStringAsFixed(2)}' : ''}'
        : null;

    document.addPage(
      pw.MultiPage(
        pageFormat: receiptPageFormat,
        build: (context) => [
          // 1. SHOP INFORMATION — TOP OF RECEIPT
          if (logoImage != null) ...[
            pw.Center(
              child: pw.Container(
                width: 44,
                height: 44,
                margin: const pw.EdgeInsets.only(bottom: 6),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: borderGrey, width: 0.5),
                ),
                child: pw.Center(child: pw.Image(logoImage, fit: pw.BoxFit.contain)),
              ),
            ),
          ],
          pw.Center(
            child: pw.Text(
              business.name,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: darkSlate,
              ),
            ),
          ),
          if (business.businessType != null &&
              business.businessType!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(
                business.businessType!.trim(),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 8.5,
                  fontStyle: pw.FontStyle.italic,
                  color: subtleText,
                ),
              ),
            ),
          ],
          pw.SizedBox(height: 4),
          if (business.phone != null && business.phone!.trim().isNotEmpty)
            pw.Center(
              child: pw.Text(
                'Phone: ${business.phone!.trim()}',
                style: pw.TextStyle(fontSize: 8, color: subtleText),
              ),
            ),
          if (business.email != null && business.email!.trim().isNotEmpty)
            pw.Center(
              child: pw.Text(
                'Email: ${business.email!.trim()}',
                style: pw.TextStyle(fontSize: 8, color: subtleText),
              ),
            ),
          if (business.address != null && business.address!.trim().isNotEmpty)
            pw.Center(
              child: pw.Text(
                'Address: ${business.address!.trim()}',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 8, color: subtleText),
              ),
            ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  'Powered by OneBill',
                  style: pw.TextStyle(
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                    color: subtleText,
                  ),
                ),
                if (oneBillLogo != null) ...[
                  pw.SizedBox(width: 3),
                  pw.Container(
                    width: 10,
                    height: 10,
                    child: pw.Image(oneBillLogo, fit: pw.BoxFit.contain),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Divider(color: borderGrey, thickness: 0.5),
          pw.SizedBox(height: 4),

          // 2. KEEP EXISTING RECEIPT INFORMATION
          pw.Center(
            child: pw.Text(
              'PAPER RECEIPT',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
                letterSpacing: 0.8,
              ),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Receipt No: ${invoice.invoiceNumber}',
                style: pw.TextStyle(
                  fontSize: 8.5,
                  fontWeight: pw.FontWeight.bold,
                  color: darkSlate,
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: pw.BoxDecoration(
                  color: isFullyPaid
                      ? PdfColor.fromHex('#DCFCE7')
                      : isPartiallyPaid
                      ? PdfColor.fromHex('#FEF3C7')
                      : PdfColor.fromHex('#FEE2E2'),
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Text(
                  isFullyPaid
                      ? 'PAID IN FULL'
                      : isPartiallyPaid
                      ? 'PARTIALLY PAID'
                      : 'UNPAID',
                  style: pw.TextStyle(
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                    color: isFullyPaid
                        ? PdfColor.fromHex('#166534')
                        : isPartiallyPaid
                        ? PdfColor.fromHex('#92400E')
                        : PdfColor.fromHex('#991B1B'),
                  ),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Date: ${_date(invoice.issuedAt)}',
            style: pw.TextStyle(fontSize: 8, color: subtleText),
          ),
          if (invoice.dueAt != null) ...[
            pw.SizedBox(height: 1),
            pw.Text(
              'Due Date: ${_date(invoice.dueAt!)}',
              style: pw.TextStyle(fontSize: 8, color: subtleText),
            ),
          ],
          pw.SizedBox(height: 6),
          pw.Divider(color: borderGrey, thickness: 0.5),
          pw.SizedBox(height: 4),

          // Customer Info
          pw.Text(
            'BILL TO',
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: primaryColor,
              letterSpacing: 0.6,
            ),
          ),
          pw.SizedBox(height: 1),
          pw.Text(
            customer.name,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: darkSlate,
            ),
          ),
          if (customer.phone.isNotEmpty) ...[
            pw.SizedBox(height: 1),
            pw.Text(
              'Phone: ${customer.phone}',
              style: pw.TextStyle(fontSize: 8, color: subtleText),
            ),
          ],
          pw.SizedBox(height: 6),
          pw.Divider(color: borderGrey, thickness: 0.5),
          pw.SizedBox(height: 6),

          // Handwritten Receipt Photo
          if (receiptImage != null)
            pw.Container(
              alignment: pw.Alignment.center,
              constraints: const pw.BoxConstraints(maxHeight: 280),
              decoration: pw.BoxDecoration(
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(color: borderGrey, width: 0.5),
              ),
              child: pw.ClipRRect(
                horizontalRadius: 6,
                verticalRadius: 6,
                child: pw.Image(receiptImage, fit: pw.BoxFit.contain),
              ),
            )
          else
            pw.Container(
              height: 100,
              alignment: pw.Alignment.center,
              child: pw.Text(
                'Receipt photo unavailable',
                style: pw.TextStyle(fontSize: 9, color: subtleText),
              ),
            ),

          if (invoice.notes != null && invoice.notes!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 6),
            pw.Text(
              'Notes: ${invoice.notes!.trim()}',
              style: pw.TextStyle(
                fontSize: 8,
                fontStyle: pw.FontStyle.italic,
                color: subtleText,
              ),
            ),
          ],

          // Transaction Totals
          if (total > 0) ...[
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: pw.BoxDecoration(
                color: lightGrey,
                borderRadius: pw.BorderRadius.circular(4),
                border: pw.Border.all(color: borderGrey, width: 0.5),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'TOTAL AMOUNT',
                        style: pw.TextStyle(
                          fontSize: 7.5,
                          fontWeight: pw.FontWeight.bold,
                          color: subtleText,
                        ),
                      ),
                      pw.Text(
                        _money(total),
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ],
                  ),
                  if (invoice.paidPaise > 0)
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text(
                          'PAID',
                          style: pw.TextStyle(
                            fontSize: 7.5,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromHex('#166534'),
                          ),
                        ),
                        pw.Text(
                          _money(invoice.paidPaise),
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromHex('#166534'),
                          ),
                        ),
                      ],
                    ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'BALANCE DUE',
                        style: pw.TextStyle(
                          fontSize: 7.5,
                          fontWeight: pw.FontWeight.bold,
                          color: balance > 0
                              ? PdfColor.fromHex('#991B1B')
                              : PdfColor.fromHex('#166534'),
                        ),
                      ),
                      pw.Text(
                        _money(balance > 0 ? balance : 0),
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: balance > 0
                              ? PdfColor.fromHex('#991B1B')
                              : PdfColor.fromHex('#166534'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // 3. ADD UPI PAYMENT SECTION
          if (qrImage != null || upiUrl != null) ...[
            pw.SizedBox(height: 8),
            pw.Divider(color: borderGrey, thickness: 0.5),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Text(
                'PAY VIA UPI',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: primaryColor,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: borderGrey, width: 0.5),
                ),
                child: qrImage != null
                    ? pw.Image(qrImage, width: 85, height: 85, fit: pw.BoxFit.contain)
                    : pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: upiUrl!,
                        width: 85,
                        height: 85,
                      ),
              ),
            ),
            pw.SizedBox(height: 5),
            pw.Center(
              child: pw.Text(
                'Scan QR code with any UPI app to pay',
                style: pw.TextStyle(fontSize: 8, color: subtleText),
              ),
            ),
            if (business.upiId != null && business.upiId!.trim().isNotEmpty) ...[
              pw.SizedBox(height: 2),
              pw.Center(
                child: pw.Text(
                  'UPI ID: ${business.upiId!.trim()}',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                    color: darkSlate,
                  ),
                ),
              ),
            ],
            if (business.upiName != null && business.upiName!.trim().isNotEmpty) ...[
              pw.SizedBox(height: 1),
              pw.Center(
                child: pw.Text(
                  'Account: ${business.upiName!.trim()}',
                  style: pw.TextStyle(fontSize: 7.5, color: subtleText),
                ),
              ),
            ],
          ],

          // 4. FOOTER & ONEBILL BRANDING
          pw.SizedBox(height: 10),
          pw.Divider(color: borderGrey, thickness: 0.5),
          pw.SizedBox(height: 6),
          pw.Center(
            child: pw.Text(
              'Thank you for your business!',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: darkSlate,
              ),
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Center(
            child: pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  'Powered by OneBill',
                  style: pw.TextStyle(fontSize: 7.5, color: subtleText),
                ),
                if (oneBillLogo != null) ...[
                  pw.SizedBox(width: 3),
                  pw.Container(
                    width: 10,
                    height: 10,
                    child: pw.Image(oneBillLogo, fit: pw.BoxFit.contain),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(height: 6),
        ],
      ),
    );

    return document.save();
  }

}


String _money(int paise) {
  final sign = paise < 0 ? '-' : '';
  final absolute = paise.abs();
  return '$sign Rs. ${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
}

String _quantity(int milliunits) =>
    (milliunits / 1000).toStringAsFixed(milliunits % 1000 == 0 ? 0 : 3);

String _date(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
