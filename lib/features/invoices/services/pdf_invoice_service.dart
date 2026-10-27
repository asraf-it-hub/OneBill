import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart'
    show
        Color,
        FontStyle,
        FontWeight,
        Offset,
        TextAlign,
        TextDirection,
        TextPainter,
        TextSpan,
        TextStyle;
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

  /// Renders text with HarfBuzz complex-script shaping via Flutter's native TextPainter
  /// when Indic (Telugu / Hindi) characters are present. For Latin/numbers, returns
  /// standard vector pw.Text for optimal performance and crisp vector fidelity.
  Future<pw.Widget> _indicText(
    String text, {
    required double fontSize,
    bool bold = false,
    bool italic = false,
    PdfColor? color,
    pw.TextAlign textAlign = pw.TextAlign.left,
    double? maxWidth,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return pw.SizedBox();
    }
    // Matches Devanagari (0x0900-0x097F) and Telugu (0x0C00-0x0C7F)
    final hasIndic = RegExp(r'[\u0900-\u097F\u0C00-\u0C7F]').hasMatch(trimmed);
    if (!hasIndic) {
      return pw.Text(
        trimmed,
        textAlign: textAlign,
        style: pw.TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
          color: color,
        ),
      );
    }

    // 3.5x rasterization (~252 DPI) gives flawless print and zoom sharpness
    const scale = 3.5;
    final flutterColor = color != null
        ? Color.fromRGBO(
            (color.red * 255).round(),
            (color.green * 255).round(),
            (color.blue * 255).round(),
            color.alpha,
          )
        : const Color(0xFF1E293B);

    final textPainter = TextPainter(
      text: TextSpan(
        text: trimmed,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          color: flutterColor,
          fontFamilyFallback: const ['NotoSansTelugu', 'NotoSansDevanagari', 'NotoSans'],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign == pw.TextAlign.right
          ? TextAlign.right
          : textAlign == pw.TextAlign.center
          ? TextAlign.center
          : TextAlign.left,
    );

    textPainter.layout(
      maxWidth: maxWidth ?? double.infinity,
    );

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale);
    textPainter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();

    final width = (textPainter.width * scale).ceil().clamp(1, 4096);
    final height = (textPainter.height * scale).ceil().clamp(1, 4096);

    final img = await picture.toImage(width, height);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    return pw.Image(
      pw.MemoryImage(bytes),
      width: textPainter.width,
      height: textPainter.height,
    );
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
    final hindiFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf'),
    );
    final hindiBoldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansDevanagari-Bold.ttf'),
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
        fontFallback: [
          teluguFont,
          teluguBoldFont,
          hindiFont,
          hindiBoldFont,
        ],
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

    // Pre-render dynamic text with Indic (Telugu/Hindi) complex-script shaping
    final businessNameWidget = await _indicText(
      business.name,
      fontSize: 20,
      bold: true,
      color: darkSlate,
      maxWidth: 300,
    );
    final businessTaglineWidget = (business.tagline != null && business.tagline!.trim().isNotEmpty)
        ? await _indicText(
            business.tagline!.trim(),
            fontSize: 10,
            italic: true,
            color: subtleText,
            maxWidth: 300,
          )
        : null;
    final businessAddressWidget = (business.address != null && business.address!.trim().isNotEmpty)
        ? await _indicText(
            business.address!.trim(),
            fontSize: 9,
            color: subtleText,
            maxWidth: 300,
          )
        : null;
    final invoiceNotesWidget = (invoice.notes != null && invoice.notes!.trim().isNotEmpty)
        ? await _indicText(
            invoice.notes!.trim(),
            fontSize: 8.5,
            color: darkSlate,
            maxWidth: 480,
          )
        : null;
    final customerNameWidget = await _indicText(
      customer.name,
      fontSize: 14,
      bold: true,
      color: darkSlate,
      maxWidth: 500,
    );
    final customerNotesWidget = (customer.notes != null && customer.notes!.trim().isNotEmpty)
        ? await _indicText(
            customer.notes!.trim(),
            fontSize: 9,
            color: subtleText,
            maxWidth: 500,
          )
        : null;
    final upiAccountNameWidget = (business.upiName != null && business.upiName!.trim().isNotEmpty)
        ? await _indicText(
            'Account Holder Name: ${business.upiName!.trim()}',
            fontSize: 9,
            color: darkSlate,
            maxWidth: 360,
          )
        : null;
    final businessInvoiceNotesWidget = (business.invoiceNotes != null && business.invoiceNotes!.trim().isNotEmpty)
        ? await _indicText(
            business.invoiceNotes!.trim(),
            fontSize: 9,
            color: darkSlate,
            maxWidth: 520,
          )
        : null;
    final businessTermsWidget = (business.termsAndConditions != null && business.termsAndConditions!.trim().isNotEmpty)
        ? await _indicText(
            business.termsAndConditions!.trim(),
            fontSize: 9,
            color: darkSlate,
            maxWidth: 520,
          )
        : null;

    final itemDescWidgets = await Future.wait(
      items.map(
        (item) => _indicText(
          item.description,
          fontSize: 9,
          color: darkSlate,
          maxWidth: 240,
        ),
      ),
    );

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
                    businessNameWidget,
                    if (businessTaglineWidget != null) ...[
                      pw.SizedBox(height: 2),
                      businessTaglineWidget,
                    ],
                    if (contactDetails.isNotEmpty) ...[
                      pw.SizedBox(height: 4),
                      pw.Text(
                        contactDetails.join('  •  '),
                        style: pw.TextStyle(fontSize: 9, color: subtleText),
                      ),
                    ],
                    if (businessAddressWidget != null) ...[
                      pw.SizedBox(height: 2),
                      businessAddressWidget,
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

          if (invoice.notes != null && invoice.notes!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F8FAFC'),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                border: pw.Border.all(color: borderGrey, width: 0.75),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'NOTE: ',
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold,
                      color: primaryColor,
                    ),
                  ),
                  if (invoiceNotesWidget != null)
                    pw.Expanded(
                      child: invoiceNotesWidget,
                    ),
                ],
              ),
            ),
          ],

          pw.SizedBox(height: 16),
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
                    customerNameWidget,
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
                    if (customerNotesWidget != null) ...[
                      pw.SizedBox(height: 2),
                      customerNotesWidget,
                    ],
                  ],
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 20),

          // 3. ITEMS TABLE
          pw.Table(
            border: pw.TableBorder.all(color: borderGrey, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(3.8),
              1: pw.FlexColumnWidth(1.2),
              2: pw.FlexColumnWidth(1.5),
              3: pw.FlexColumnWidth(1.5),
            },
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: lightGrey),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: pw.Text(
                      'Item',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: darkSlate,
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: pw.Align(
                      alignment: pw.Alignment.centerRight,
                      child: pw.Text(
                        'Qty',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: pw.Align(
                      alignment: pw.Alignment.centerRight,
                      child: pw.Text(
                        'Unit Price',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: pw.Align(
                      alignment: pw.Alignment.centerRight,
                      child: pw.Text(
                        'Amount',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              for (var i = 0; i < items.length; i++)
                pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: itemDescWidgets[i],
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text(
                          _quantity(items[i].quantityMilliunits),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text(
                          _money(items[i].unitPricePaise),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text(
                          _money(items[i].lineTotalPaise),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
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
                    _summaryRow('Extra charge', invoice.interestPaise),
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
                        if (upiAccountNameWidget != null) ...[
                          pw.SizedBox(height: 2),
                          upiAccountNameWidget,
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
          ],

          // 6. NOTES & TERMS & CONDITIONS (From Business Profile)
          if (businessInvoiceNotesWidget != null) ...[
            pw.Text(
              'NOTES',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
              ),
            ),
            pw.SizedBox(height: 4),
            businessInvoiceNotesWidget,
            pw.SizedBox(height: 12),
          ],

          if (businessTermsWidget != null) ...[
            pw.Text(
              'TERMS & CONDITIONS',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
              ),
            ),
            pw.SizedBox(height: 4),
            businessTermsWidget,
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
    final hindiFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf'),
    );
    final hindiBoldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansDevanagari-Bold.ttf'),
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
        fontFallback: [
          teluguFont,
          teluguBoldFont,
          hindiFont,
          hindiBoldFont,
        ],
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

    final upiUrl = (business.upiId != null && business.upiId!.trim().isNotEmpty)
        ? 'upi://pay?pa=${business.upiId!.trim()}&pn=${Uri.encodeComponent(business.upiName?.trim().isNotEmpty == true ? business.upiName!.trim() : business.name)}&cu=INR${balance > 0 ? '&am=${(balance / 100).toStringAsFixed(2)}' : ''}'
        : null;

    final accountHolderName = (business.upiName != null && business.upiName!.trim().isNotEmpty)
        ? business.upiName!.trim()
        : business.ownerName.trim();

    final notes = <String>[];
    if (invoice.notes != null && invoice.notes!.trim().isNotEmpty) {
      notes.add(invoice.notes!.trim());
    }
    if (business.invoiceNotes != null &&
        business.invoiceNotes!.trim().isNotEmpty &&
        !notes.contains(business.invoiceNotes!.trim())) {
      notes.add(business.invoiceNotes!.trim());
    }
    if (notes.isEmpty) {
      notes.add('Thank you for your business! Please reach out if you have any questions.');
    }

    final terms = (business.termsAndConditions != null &&
            business.termsAndConditions!.trim().isNotEmpty)
        ? business.termsAndConditions!.trim()
        : '1. Goods once sold will not be taken back or exchanged.\n2. Payment is due as per agreed payment terms.\n3. E.&O.E.';

    // Pre-render dynamic text with Indic (Telugu/Hindi) complex-script shaping
    final businessNameWidget = await _indicText(
      business.name,
      fontSize: 18,
      bold: true,
      color: darkSlate,
      maxWidth: 300,
    );
    final businessTaglineWidget = (business.tagline != null && business.tagline!.trim().isNotEmpty)
        ? await _indicText(
            business.tagline!.trim(),
            fontSize: 9,
            italic: true,
            color: subtleText,
            maxWidth: 300,
          )
        : null;
    final businessAddressWidget = (business.address != null && business.address!.trim().isNotEmpty)
        ? await _indicText(
            business.address!.trim(),
            fontSize: 8.5,
            color: subtleText,
            maxWidth: 300,
          )
        : null;
    final customerNameWidget = await _indicText(
      customer.name,
      fontSize: 13,
      bold: true,
      color: darkSlate,
      maxWidth: 500,
    );
    final customerNotesWidget = (customer.notes != null && customer.notes!.trim().isNotEmpty)
        ? await _indicText(
            customer.notes!.trim(),
            fontSize: 8.5,
            color: subtleText,
            maxWidth: 500,
          )
        : null;
    final accountHolderWidget = accountHolderName.isNotEmpty
        ? await _indicText(
            'Account Holder Name: $accountHolderName',
            fontSize: 8.5,
            color: darkSlate,
            maxWidth: 360,
          )
        : null;
    final notesWidget = await _indicText(
      notes.join('\n'),
      fontSize: 8.5,
      color: darkSlate,
      maxWidth: 520,
    );
    final termsWidget = await _indicText(
      terms,
      fontSize: 9.5,
      color: darkSlate,
      maxWidth: 520,
    );

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
                        width: 50,
                        height: 50,
                        padding: const pw.EdgeInsets.all(3),
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
                    businessNameWidget,
                    if (businessTaglineWidget != null) ...[
                      pw.SizedBox(height: 2),
                      businessTaglineWidget,
                    ],
                    if (contactDetails.isNotEmpty) ...[
                      pw.SizedBox(height: 3),
                      pw.Text(
                        contactDetails.join('  •  '),
                        style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                      ),
                    ],
                    if (businessAddressWidget != null) ...[
                      pw.SizedBox(height: 2),
                      businessAddressWidget,
                    ],
                    if (business.gstin != null &&
                        business.gstin!.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'GSTIN: ${business.gstin!.trim()}',
                        style: pw.TextStyle(
                          fontSize: 8.5,
                          fontWeight: pw.FontWeight.bold,
                          color: darkSlate,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              pw.SizedBox(width: 16),

              // Right: Invoice Metadata & Status
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Row(
                    mainAxisSize: pw.MainAxisSize.min,
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text(
                        'Powered by OneBill',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                          color: subtleText,
                        ),
                      ),
                      if (oneBillLogo != null) ...[
                        pw.SizedBox(width: 4),
                        pw.Container(
                          width: 16,
                          height: 16,
                          child: pw.Image(oneBillLogo, fit: pw.BoxFit.contain),
                        ),
                      ],
                    ],
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(
                    'INVOICE',
                    style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                      color: primaryColor,
                      letterSpacing: 1.2,
                    ),
                  ),
                  pw.SizedBox(height: 5),
                  pw.Text(
                    invoice.invoiceNumber,
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: darkSlate,
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Date: ${_date(invoice.issuedAt)}',
                    style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                  ),
                  if (invoice.dueAt != null) ...[
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Due Date: ${_date(invoice.dueAt!)}',
                      style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                    ),
                  ],
                  pw.SizedBox(height: 6),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
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
                        fontSize: 8.5,
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

          pw.SizedBox(height: 18),

          // 2. BILL TO SECTION
          pw.Column(
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
              customerNameWidget,
              if (customer.phone.isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  'Phone: ${customer.phone}',
                  style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                ),
              ],
              if (customer.email != null && customer.email!.trim().isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  'Email: ${customer.email!.trim()}',
                  style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                ),
              ],
              if (customerNotesWidget != null) ...[
                pw.SizedBox(height: 2),
                customerNotesWidget,
              ],
            ],
          ),

          pw.SizedBox(height: 14),

          // 3. PAPER RECEIPT PHOTO
          if (receiptImage != null)
            pw.Center(
              child: pw.Container(
                alignment: pw.Alignment.center,
                constraints: const pw.BoxConstraints(maxHeight: 280, maxWidth: 360),
                decoration: pw.BoxDecoration(
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: borderGrey, width: 0.75),
                ),
                child: pw.ClipRRect(
                  horizontalRadius: 6,
                  verticalRadius: 6,
                  child: pw.Image(receiptImage, fit: pw.BoxFit.contain),
                ),
              ),
            )
          else
            pw.Container(
              height: 120,
              alignment: pw.Alignment.center,
              child: pw.Text(
                'Receipt photo unavailable',
                style: pw.TextStyle(fontSize: 9, color: subtleText),
              ),
            ),

          // 4. UPI PAYMENT SECTION
          if (qrImage != null || upiUrl != null || (business.upiId != null && business.upiId!.trim().isNotEmpty)) ...[
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: lightGrey,
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(color: borderGrey, width: 0.75),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (qrImage != null || upiUrl != null) ...[
                    pw.Container(
                      width: 75,
                      height: 75,
                      padding: const pw.EdgeInsets.all(5),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.white,
                        borderRadius: pw.BorderRadius.circular(6),
                        border: pw.Border.all(color: borderGrey, width: 0.75),
                      ),
                      child: pw.Center(
                        child: qrImage != null
                            ? pw.Image(qrImage, fit: pw.BoxFit.contain)
                            : pw.BarcodeWidget(
                                barcode: pw.Barcode.qrCode(),
                                data: upiUrl!,
                              ),
                      ),
                    ),
                    pw.SizedBox(width: 14),
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
                            fontSize: 9.5,
                            fontWeight: pw.FontWeight.bold,
                            color: primaryColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          'Scan QR code with any UPI app to pay',
                          style: pw.TextStyle(fontSize: 8.5, color: subtleText),
                        ),
                        if (business.upiId != null && business.upiId!.trim().isNotEmpty) ...[
                          pw.SizedBox(height: 3),
                          pw.Text(
                            'UPI ID: ${business.upiId!.trim()}',
                            style: pw.TextStyle(
                              fontSize: 9.5,
                              fontWeight: pw.FontWeight.bold,
                              color: darkSlate,
                            ),
                          ),
                        ],
                        if (accountHolderWidget != null) ...[
                          pw.SizedBox(height: 2),
                          accountHolderWidget,
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          // 5. NOTES SECTION
          pw.SizedBox(height: 14),
          pw.Text(
            'NOTES',
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: primaryColor,
              letterSpacing: 0.5,
            ),
          ),
          pw.SizedBox(height: 4),
          notesWidget,

          // 6. PAGE 2: TERMS & CONDITIONS
          pw.NewPage(),
          pw.Text(
            'TERMS & CONDITIONS',
            style: pw.TextStyle(
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
              color: primaryColor,
              letterSpacing: 0.5,
            ),
          ),
          pw.SizedBox(height: 8),
          termsWidget,
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
