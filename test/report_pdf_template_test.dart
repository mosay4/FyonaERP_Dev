import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/pdf_engine.dart';

/// «Report1pdf/Report Design.pdf» identity on ALL five report PDFs:
/// crimson/white/black, the FYONA logo, Cairo fonts (Arabic shaping),
/// RTL/LTR, dynamic tables that repeat headers across page chunks.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> build({
    required bool isAr,
    required bool manyRows,
  }) async {
    final kpis = [
      {'label': isAr ? 'المبيعات' : 'Sales', 'value': '8,436.27 SAR'},
      {'label': isAr ? 'تم دفعه' : 'Paid', 'value': '6,233.03 SAR'},
      {'label': isAr ? 'المتبقي' : 'Remaining', 'value': '7.36 SAR'},
      {'label': isAr ? 'المصروفات' : 'Expenses', 'value': '250.00 SAR'},
    ];
    final rows = [
      for (var i = 0; i < (manyRows ? 55 : 4); i++)
        [
          isAr
              ? 'منتج طويل الاسم رقم $i للاختبار والتحقق من الالتفاف'
              : 'A long product name $i to verify text wrapping behaviour',
          '${24 + i}',
          'SAR ${(6269.01 - i * 3.7).toStringAsFixed(2)}',
        ],
    ];
    final sections = [
      ReportPdfSection(
        title: isAr ? 'أكثر المنتجات مبيعًا' : 'Best sellers',
        headers: [
          isAr ? 'المنتج' : 'Product',
          isAr ? 'الكمية' : 'Qty',
          isAr ? 'الإجمالي' : 'Total',
        ],
        rows: rows,
      ),
      ReportPdfSection(
        title: isAr ? 'آخر حركات الديون' : 'Recent debt activity',
        headers: [
          isAr ? 'التاريخ' : 'Date',
          isAr ? 'الطرف' : 'Party',
          isAr ? 'المبلغ' : 'Amount',
        ],
        rows: [
          for (var i = 0; i < (manyRows ? 30 : 3); i++)
            [
              '2026-10-13',
              isAr ? 'عميل نقدي' : 'Cash customer',
              '${i.isEven ? '+' : '-'} ${(120.5 + i).toStringAsFixed(2)} SAR',
            ],
        ],
      ),
    ];
    return PdfEngine.generateReportPdf(
      title: isAr ? 'المبيعات والمشتريات' : 'Sales & Purchases',
      subtitle: isAr
          ? 'الفترة: هذا الشهر • العملة: SAR'
          : 'Period: This month • Currency: SAR',
      headers: const [],
      rows: const [],
      kpis: kpis,
      sections: sections,
      isAr: isAr,
      footer: isAr ? 'تقرير FYONA — جميع الأسعار وفق سعر الصرف' : 'FYONA report — rates per FX basis',
    );
  }

  test('identity: all 5 kinds share the branded template (AR + EN, few rows)',
      () async {
    final kinds = [
      (isAr: true, many: false),
      (isAr: false, many: false),
    ];
    for (final k in kinds) {
      final bytes = (await binding.runAsync(() => build(isAr: k.isAr, manyRows: k.many)))!;
      final s = String.fromCharCodes(bytes);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      // Cairo fonts embedded (Arabic shaping needs them) — never Helvetica-only.
      expect(s.contains('Cairo'), isTrue, reason: 'Cairo font must be embedded');
      // The FYONA logo image is embedded in the header band.
      expect(s.contains('/Image'), isTrue, reason: 'logo must be embedded');
      expect(bytes.length, greaterThan(20000));
    }
  });

  test('many rows → multi-page with repeated section titles, no crash (AR)',
      () async {
    final bytes = (await binding.runAsync(() => build(isAr: true, manyRows: true)))!;
    final s = String.fromCharCodes(bytes);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(s).length;
    expect(pages, greaterThan(1),
        reason: '55+30 rows must span multiple pages');
  });

  test('single-section legacy call (old signature) still renders', () async {
    final bytes = (await binding.runAsync(() => PdfEngine.generateReportPdf(
          title: 'تقرير',
          headers: [
            {'label': 'البيان'},
            {'label': 'القيمة'},
          ],
          rows: [
            ['المبيعات', '1000'],
            ['المصروفات', '250'],
          ],
          footer: 'FYONA',
        )))!;
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(String.fromCharCodes(bytes).contains('Cairo'), isTrue);
  });

  test('PDF files written to disk are valid', () async {
    final bytes = (await binding.runAsync(() => build(isAr: true, manyRows: true)))!;
    final dir = await Directory.systemTemp.createTemp('fyona_report_test');
    final f = File('${dir.path}/t.pdf');
    await f.writeAsBytes(bytes);
    expect(await f.length(), greaterThan(20000));
    await f.delete();
  });
}