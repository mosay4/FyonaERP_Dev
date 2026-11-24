import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../../core/utils/currency_formatter.dart' as cf;

/// Condensed 80mm thermal receipt for a sale invoice: number, date,
/// customer, compact lines (name × qty … total), totals, paid/remaining.
/// Narrow fonts, minimal chrome — tailored for receipt printers.
Future<Uint8List> buildSaleThermalPdf(Map<String, dynamic> inv) async {
  final reg =
      pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
  final bold =
      pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
  double n(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  final doc = pw.Document();
  final items = ((inv['items'] as List?) ?? const []).whereType<Map>().toList();
  final cur = (inv['currency'] ?? 'SAR').toString();
  final format = PdfPageFormat.roll80;

  doc.addPage(
    pw.Page(
      pageFormat: format,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: reg, bold: bold),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.Text('فاتورة بيع',
                style: pw.TextStyle(font: bold, fontSize: 13)),
          ),
          pw.Center(
            child: pw.Text(shortDocumentNumber(inv['invoice_number']),
                style: pw.TextStyle(font: bold, fontSize: 11)),
          ),
          pw.Center(
            child: pw.Text((inv['invoice_date'] ?? '').toString(),
                style: pw.TextStyle(font: reg, fontSize: 8)),
          ),
          pw.Divider(thickness: 0.5),
          pw.Text(
            '${(inv['customer_name'] ?? 'عميل نقدي').toString()}',
            style: pw.TextStyle(font: reg, fontSize: 9),
          ),
          pw.Divider(thickness: 0.5),
          for (final it in items)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
              child: pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      '${(it['description'] ?? '').toString()} ×${it['quantity'] ?? ''}',
                      style: pw.TextStyle(font: reg, fontSize: 9),
                    ),
                  ),
                  pw.Text(cf.fmtNum(n(it['total'])),
                      style: pw.TextStyle(font: reg, fontSize: 9)),
                ],
              ),
            ),
          pw.Divider(thickness: 0.5),
          _t('الإجمالي', '${cf.fmtNum(n(inv['total']))} $cur', bold, reg),
          _t('المدفوع', '${cf.fmtNum(n(inv['paid_amount']))} $cur',
              bold, reg),
          _t('المتبقي', '${cf.fmtNum(n(inv['balance']))} $cur', bold, reg),
          pw.SizedBox(height: 10),
          pw.Center(
            child: pw.Text('شكراً لتعاملكم معنا',
                style: pw.TextStyle(font: reg, fontSize: 8)),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

pw.Widget _t(String label, String value, pw.Font bold, pw.Font reg) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 9)),
          pw.Text(value, style: pw.TextStyle(font: bold, fontSize: 10)),
        ],
      ),
    );
