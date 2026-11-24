import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/utils/currency_formatter.dart' as cf;
import '../../../inventory/presentation/widgets/business_product_image.dart';

/// Whether the merchant enabled product images on the normal (A4) invoice.
Future<bool> invoiceImagesEnabled() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getBool('invoice_show_product_images') ?? true;
  } catch (_) {
    return true;
  }
}

/// Fetch the frozen product-image bytes for an issued invoice (best-effort).
Future<Map<String, Uint8List>> collectInvoiceImages(
    Map<String, dynamic> inv, Dio dio, {bool localOnly = false}) async {
  final out = <String, Uint8List>{};
  for (final it in ((inv['items'] as List?) ?? const []).whereType<Map>()) {
    final pid = it['product_id']?.toString();
    final url = it['image']?.toString();
    if (pid == null || pid.isEmpty || url == null || url.isEmpty) continue;
    final local = decodeBusinessProductImage(url);
    if (local != null) {
      out[pid] = local;
      continue;
    }
    if (localOnly) continue;
    try {
      final full =
          url.startsWith('/uploads/') ? '${AppConfig.apiHostUrl}$url' : url;
      final r = await dio.get<List<int>>(full,
          options: Options(responseType: ResponseType.bytes));
      final d = r.data;
      if (d != null) out[pid] = Uint8List.fromList(d);
    } catch (_) {}
  }
  return out;
}

/// Simple RTL sale-invoice PDF (Cairo fonts, A4). Data comes straight from
/// the issue/get response maps (numbers may be num or numeric strings).
Future<Uint8List> buildSaleInvoicePdf(Map<String, dynamic> inv,
    {Map<String, Uint8List>? images}) async {
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
  final payments =
      ((inv['payments'] as List?) ?? const []).whereType<Map>().toList();
  final cur = (inv['currency'] ?? 'SAR').toString();

  pw.Widget cell(String s, pw.Font f) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(s,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: f, fontSize: 10)),
      );

  pw.Widget row(String label, String value, {bool strong = false}) =>
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 11)),
          pw.Text(value,
              style: pw.TextStyle(font: strong ? bold : reg, fontSize: 11)),
        ],
      );

  // Amount in the account's own currency; the converted value is shown too
  // when the payment currency differs from the invoice currency.
  String paymentValue(Map p) {
    final payCur = (p['payment_currency'] ?? cur).toString();
    final original = n(p['original_amount'] ?? p['amount']);
    final equivalent = n(p['equivalent_amount'] ?? p['amount']);
    if (payCur == cur) return '${cf.fmtNum(original)} $payCur';
    return '${cf.fmtNum(original)} $payCur (${cf.fmtNum(equivalent)} $cur)';
  }

  doc.addPage(
    pw.MultiPage(
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: reg, bold: bold),
      pageFormat: PdfPageFormat.a4,
      build: (context) => [
        pw.Header(
          level: 0,
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('فاتورة بيع',
                  style: pw.TextStyle(font: bold, fontSize: 20)),
              pw.Text(shortDocumentNumber(inv['invoice_number']),
                  style: pw.TextStyle(font: bold, fontSize: 14)),
            ],
          ),
        ),
        pw.SizedBox(height: 8),
        row('العميل', (inv['customer_name'] ?? 'عميل نقدي').toString()),
        row('التاريخ', (inv['invoice_date'] ?? '').toString()),
        if ((inv['branch_name']?.toString().isNotEmpty ?? false))
          row('الفرع', inv['branch_name'].toString()),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(width: 0.4, color: PdfColors.grey500),
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (final h in const [
                  'الإجمالي',
                  'الخصم',
                  'السعر',
                  'الكمية',
                  'الوحدة',
                  'الصنف'
                ])
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(h,
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(font: bold, fontSize: 10)),
                  ),
              ],
            ),
            for (final it in items)
              pw.TableRow(children: [
                cell(cf.fmtNum(n(it['total'])), reg),
                cell(cf.fmtNum(n(it['discount'])), reg),
                cell(cf.fmtNum(n(it['unit_price'])), reg),
                cell((it['quantity'] ?? '').toString(), reg),
                cell((it['unit_name'] ?? '').toString(), reg),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Row(children: [
                    if (images != null &&
                        (it['product_id']?.toString() ?? '').isNotEmpty &&
                        images[it['product_id'].toString()] != null) ...[
                      pw.Image(
                        pw.MemoryImage(images[it['product_id'].toString()]!),
                        width: 20,
                        height: 20,
                        fit: pw.BoxFit.cover,
                      ),
                      pw.SizedBox(width: 5),
                    ],
                    pw.Expanded(
                      child: pw.Text(
                        (it['description'] ?? '').toString(),
                        style: pw.TextStyle(font: reg, fontSize: 10),
                      ),
                    ),
                  ]),
                ),
              ]),
          ],
        ),
        pw.SizedBox(height: 12),
        row('الإجمالي', '${cf.fmtNum(n(inv['subtotal']))} $cur'),
        if (n(inv['discount_amount']) > 0)
          row('الخصم', '${cf.fmtNum(n(inv['discount_amount']))} $cur'),
        if (n(inv['tax_amount']) > 0)
          row('الضريبة', '${cf.fmtNum(n(inv['tax_amount']))} $cur'),
        row('الإجمالي النهائي',
            '${cf.fmtNum(n(inv['total']))} $cur'),
        row('المدفوع', '${cf.fmtNum(n(inv['paid_amount']))} $cur'),
        row('المتبقي', '${cf.fmtNum(n(inv['balance']))} $cur'),
        if (payments.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Text('المدفوعات',
              style: pw.TextStyle(font: bold, fontSize: 12)),
          for (final p in payments)
            row(
                (p['bank_account_name'] ?? p['payment_method'] ?? '')
                    .toString(),
                paymentValue(p)),
        ],
        if ((inv['notes']?.toString().isNotEmpty ?? false)) ...[
          pw.SizedBox(height: 8),
          pw.Text('ملاحظات: ${inv['notes']}',
              style: pw.TextStyle(font: reg, fontSize: 10)),
        ],
      ],
    ),
  );
  return doc.save();
}
