import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/app_database.dart';

class PdfInvoiceService {
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
    final total =
        invoice.subtotalPaise - invoice.discountPaise + invoice.interestPaise;
    final balance = total - invoice.paidPaise;
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'ONEBILL',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.teal,
                    ),
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(
                    business.name,
                    style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (business.address != null) pw.Text(business.address!),
                  if (business.phone != null) pw.Text(business.phone!),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'INVOICE',
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(invoice.invoiceNumber),
                  pw.Text('Date: ${_date(invoice.issuedAt)}'),
                  if (invoice.dueAt != null)
                    pw.Text('Due: ${_date(invoice.dueAt!)}'),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 28),
          pw.Text(
            'Bill to',
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.teal,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            customer.name,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(customer.phone),
          pw.SizedBox(height: 24),
          pw.TableHelper.fromTextArray(
            headers: const ['Item', 'Quantity', 'Unit price', 'Amount'],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal50),
            cellAlignment: pw.Alignment.centerRight,
            cellAlignments: {0: pw.Alignment.centerLeft},
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
          pw.SizedBox(height: 18),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.SizedBox(
              width: 220,
              child: pw.Column(
                children: [
                  _totalRow('Subtotal', invoice.subtotalPaise),
                  if (invoice.discountPaise > 0)
                    _totalRow('Discount', -invoice.discountPaise),
                  if (invoice.interestPaise > 0)
                    _totalRow('Interest', invoice.interestPaise),
                  pw.Divider(),
                  _totalRow('Total', total, bold: true),
                  _totalRow('Paid', invoice.paidPaise),
                  _totalRow('Balance due', balance, bold: true),
                ],
              ),
            ),
          ),
          if (invoice.notes != null) ...[
            pw.SizedBox(height: 20),
            pw.Text(
              'Notes',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(invoice.notes!),
          ],
          pw.SizedBox(height: 34),
          pw.Center(
            child: pw.Text(
              'Thank you for your business.',
              style: const pw.TextStyle(color: PdfColors.grey700),
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  pw.Widget _totalRow(String label, int paise, {bool bold = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              label,
              style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null,
            ),
            pw.Text(
              _money(paise),
              style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null,
            ),
          ],
        ),
      );
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
