import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/recon_report_pdf.dart';

/// Issue #3 — the recon PDF engine must handle LONG tables (many products,
/// multi-unit rows, long names) without throwing or dropping content: it
/// paginates cleanly.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> longInventory() => {
        'ref_code': 'RCN-PAGE-TEST',
        'rtype': 'inventory',
        'status': 'approved',
        'measured_at': '2026-10-12T02:00:00',
        'lines': [
          for (var i = 0; i < 80; i++)
            {
              'name': 'منتج طويل الاسم رقم $i للاختبار والتحقق',
              'unit': 'قطعة',
              'system_qty': 100 + i,
              'base_qty': 90 + i,
              'diff': -10,
              'parts': [
                {'qty': 2, 'unit_name': 'كرتون', 'factor': 24},
                {'qty': 3, 'unit_name': 'باكيت (×8)', 'factor': 8},
                {'qty': 5, 'unit_name': 'قطعة', 'factor': 1},
              ],
            }
        ],
      };

  test('long multi-unit inventory table paginates without throwing', () async {
    final bytes = await binding.runAsync(() => ReconReportPdf.build(
        record: longInventory(), isBank: false, isAr: true,
        scope: {'name': 'المواد الغذائية'}));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
    final s = String.fromCharCodes(bytes);
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(s).length;
    expect(pages, greaterThan(1),
        reason: 'a long table must span multiple pages');
  });

  test('mixed-currency bank report with long names builds', () async {
    final bytes = await binding.runAsync(() => ReconReportPdf.build(
        record: {
          'ref_code': 'RCN-BANK-LONG',
          'rtype': 'bank',
          'status': 'checked',
          'measured_at': '2026-10-12T02:00:00',
          'lines': [
            for (var i = 0; i < 40; i++)
              {
                'currency': i.isEven ? 'YER_OLD' : 'USD',
                'name': 'حساب كاش طويل جدا رقم $i للاختبار',
                'bank_name': 'كاش',
                'account_type': i % 3 == 0 ? 'savings' : 'checking',
                'system': 1000 + i,
                'actual': 900 + i,
                'diff': -100,
              }
          ],
        },
        isBank: true, isAr: true, scope: {'name': 'كاش'}));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
  });
}
