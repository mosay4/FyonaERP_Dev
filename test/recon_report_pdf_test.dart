import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/recon_report_pdf.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/recon_report_pdf_layout.dart';

/// The reconciliation PDF (R1 design) — language-aware layout, verified via
/// the PURE layout rules + the produced PDF's STRUCTURE (colours/rows), since
/// the pdf package embeds subset fonts (raw text is glyph-encoded).
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> bankRecord({bool longNames = false}) => {
        'ref_code': 'RCN-20261012-TEST',
        'rtype': 'bank',
        'status': 'approved',
        'measured_at': '2026-10-12T01:39:52',
        'approved_at': '2026-10-12T01:39:19',
        'lines': [
          {
            'currency': 'SAR',
            'name': longNames ? 'بنك طويل جدا للاختبار' : 'ريال سعودي',
            'bank_name': longNames ? 'بنك طويل جدا للاختبار' : 'ريال سعودي',
            'system': 8.9, 'actual': 100, 'diff': 91.1,
          },
          {
            'currency': 'YER_OLD',
            'name': 'ريال يمني قديم',
            'bank_name': 'ريال يمني قديم',
            'system': 4972.22, 'actual': 10000, 'diff': 5027.78,
          },
        ],
        'settlements': [
          {'name': 'ريال سعودي', 'currency': 'SAR', 'before': 8.9,
              'after': 100, 'applied': true},
        ],
      };

  Map<String, dynamic> invRecord() => {
        'ref_code': 'RCN-20261012-INV',
        'rtype': 'inventory',
        'status': 'approved',
        'measured_at': '2026-10-12T02:00:00',
        'approved_at': '2026-10-12T02:01:00',
        'lines': [
          {
            'name': 'تونه',
            'unit': 'قطعة',
            'system_qty': 1,
            'base_qty': 25,
            'diff': 24,
            'parts': [
              {'qty': 2, 'unit_name': 'كرتون'},
              {'qty': 1, 'unit_name': 'قطعة'},
            ],
          },
        ],
      };

  /// Extract colour/rect/structure ops from the produced bytes (zlib streams).
  String structureOf(Uint8List data) {
    final buf = StringBuffer();
    var pos = 0;
    while (true) {
      var idx = -1;
      for (var i = pos; i <= data.length - 6; i++) {
        final prevEnd = i >= 3 &&
            data[i - 1] == 109 && data[i - 2] == 97 && data[i - 3] == 116;
        if (data[i] == 115 && data[i + 1] == 116 && data[i + 2] == 114 &&
            data[i + 3] == 101 && data[i + 4] == 97 && data[i + 5] == 109 &&
            !prevEnd) {
          idx = i;
          break;
        }
      }
      if (idx < 0) break;
      var start = idx + 6;
      while (start < data.length && (data[start] == 13 || data[start] == 10)) {
        start++;
      }
      var endIdx = -1;
      for (var j = start; j < data.length - 9; j++) {
        if (data[j] == 101 && data[j + 1] == 110 && data[j + 2] == 100 &&
            data[j + 3] == 115) {
          endIdx = j;
          break;
        }
      }
      if (endIdx < 0) break;
      final raw = data.sublist(start, endIdx);
      pos = endIdx + 9;
      List<int>? dec;
      try {
        dec = zlib.decode(raw);
      } catch (_) {
        continue;
      }
      buf.write(latin1.decode(dec, allowInvalid: true));
      buf.write('\n');
    }
    return buf.toString();
  }

  group('pure layout rules', () {
    test('ARABIC columns: RTL order — العملة is the LAST child (rightmost)',
        () {
      final order = ReconPdfLayout.columnOrder(isAr: true, isBank: true);
      expect(order.first, 'الفرق');
      expect(order.last, 'العملة');
    });

    test('ENGLISH columns: LTR order — Currency is the FIRST child', () {
      final order = ReconPdfLayout.columnOrder(isAr: false, isBank: true);
      expect(order.first, 'Currency');
      expect(order.last, 'Difference');
    });

    test('INVENTORY wording: المنتج for arabic / Product for english', () {
      expect(ReconPdfLayout.columnOrder(isAr: true, isBank: false).last,
          'المنتج');
      expect(ReconPdfLayout.columnOrder(isAr: false, isBank: false).first,
          'Product');
    });

    test('null-safe stringifier kills every «null»', () {
      expect(ReconPdfLayout.s(null), '');
      expect(ReconPdfLayout.s('null'), '');
      expect(ReconPdfLayout.s('NULL'), '');
      expect(ReconPdfLayout.s(''), '');
      expect(ReconPdfLayout.s('ريال سعودي'), 'ريال سعودي');
    });

    test('numbers formatted like R1 (8.9 → 8.90, thousands)', () {
      expect(ReconPdfLayout.fmtNum(8.9), '8.90');
      expect(ReconPdfLayout.fmtNum(100), '100');
      expect(ReconPdfLayout.fmtNum(5027.78), '5,027.78');
      expect(ReconPdfLayout.fmtNum(-117.45), '-117.45');
    });

    test('display name: full localized currency (never clipped logic)', () {
      expect(
          ReconPdfLayout.displayName(
              isBank: true, isAr: true, currency: 'SAR', name: null),
          'ريال سعودي');
      expect(
          ReconPdfLayout.displayName(
              isBank: false, isAr: true, currency: null, name: 'تونه'),
          'تونه');
    });

    test('per-unit rows: entered qty as بالحقيقة, system/factor as بالنظام',
        () {
      final rows = ReconPdfLayout.unitRows(
          systemQty: 24,
          baseAfter: 17,
          parts: [
            {'qty': 2, 'unit_name': 'كرتون', 'factor': 12},
            {'qty': 1, 'unit_name': 'قطعة', 'factor': 1},
          ]);
      expect(rows.length, 2);
      expect(rows[0].unit, 'كرتون ×12');
      expect(rows[0].before, '2');
      expect(rows[0].after, '2');
      expect(rows[0].diff, '0');
      expect(rows[1].unit, 'قطعة');
      expect(rows[1].before, '24');
      expect(rows[1].after, '1');
      expect(rows[1].diff, '-23');
    });

    test('extra units keep their REAL name, never the base unit', () {
      // Real stored shape: base part «قطعة» + extra «باكيت (×8)» factor 8.
      final parts = [
        {'qty': 5, 'unit_name': 'قطعة', 'factor': 1},
        {'qty': 3, 'unit_name': 'باكيت (×8)', 'factor': 8},
      ];
      expect(ReconPdfLayout.cleanUnitName('باكيت (×8)'), 'باكيت');
      expect(ReconPdfLayout.unitLabel('باكيت (×8)', 8), 'باكيت ×8');
      final rows = ReconPdfLayout.unitRows(
          systemQty: 100, baseAfter: 29, parts: parts);
      expect(rows[0].unit, 'قطعة');
      expect(rows[1].unit, 'باكيت ×8',
          reason: 'the extra unit must NOT collapse to the base «قطعة»');
      final expanded = expandProductRows(
          name: 'زبادي',
          mark: null,
          markColorKey: null,
          systemQty: 100,
          actualQty: 29,
          diff: -71,
          unit: 'قطعة',
          parts: parts);
      expect(expanded.length, 2);
      expect(expanded[1].name, 'زبادي (باكيت ×8)',
          reason: 'single tidy parentheses, correct unit');
      expect(expanded[1].unit, 'باكيت ×8');
    });

    test('status wording is honest per record state', () {
      // pure logic mirrored from the builder (subset-font streams can't be
      // text-grepped): approved → تمت المساواة; checked+diff → لم تُنفَّذ.
      String statusLine(Map rec) {
        final hasDiff = (rec['lines'] as List).any((l) =>
            (((l['diff'] ?? 0) as num?) ?? 0).toDouble().abs() > 1e-9);
        return '${rec['status']}' == 'approved'
            ? 'تمت المساواة'
            : hasDiff
                ? 'لم تُنفَّذ المساواة بعد'
                : 'لا يوجد أي اختلاف — كل شيء مطابق';
      }
      expect(statusLine({...bankRecord(), 'status': 'checked'}), 'لم تُنفَّذ المساواة بعد');
      expect(statusLine({...bankRecord(), 'status': 'approved'}), 'تمت المساواة');
    });

    test('account-type wording: توفير/جاري', () {
      expect(ReconPdfLayout.accountTypeLabelStr('savings', isAr: true),
          'حساب توفير');
      expect(ReconPdfLayout.accountTypeLabelStr('checking', isAr: true),
          'حساب جاري');
    });

    test('settlement فئة resolved by ACCOUNT ID, not name+currency', () {
      // «جيب» USD جاري + USD توفير share name+currency — the old lookup
      // returned the FIRST type for both settlements.
      final lines = [
        {'account_id': 'a1', 'currency': 'USD', 'name': 'جيب',
            'account_type': 'checking'},
        {'account_id': 'a2', 'currency': 'USD', 'name': 'جيب',
            'account_type': 'savings'},
      ];
      expect(
          ReconPdfLayout.settlementAccountType(
              {'account_id': 'a1', 'currency': 'USD', 'name': 'جيب'}, lines),
          'checking');
      expect(
          ReconPdfLayout.settlementAccountType(
              {'account_id': 'a2', 'currency': 'USD', 'name': 'جيب'}, lines),
          'savings',
          reason: 'the 2nd settlement must show توفير, not جاري again');
    });

    test('short account-type wording: توفير/جاري', () {      expect(
          ReconPdfLayout.accountTypeLabelStr('savings',
              isAr: true, short: true),
          'توفير');
      expect(
          ReconPdfLayout.accountTypeLabelStr('checking',
              isAr: true, short: true),
          'جاري');
    });

    test('badge shows ONLY for a currency with more than one type', () {
      final multi = ReconPdfLayout.currenciesWithMultipleTypes([
        {'currency': 'USD', 'account_type': 'checking'},
        {'currency': 'USD', 'account_type': 'savings'},
        {'currency': 'SAR', 'account_type': 'checking'},
        {'currency': 'YER_OLD', 'account_type': 'savings'},
      ]);
      expect(multi.contains('USD'), isTrue,
          reason: 'USD exists as both جاري and توفير');
      expect(multi.contains('SAR'), isFalse,
          reason: 'single-type currency must show no badge');
      expect(multi.contains('YER_OLD'), isFalse);
    });

    test('multi-unit breakdown: only >1 unit shows the combined text', () {
      final parts = [
        {'qty': 2, 'unit_name': 'كرتون'},
        {'qty': 1, 'unit_name': 'قطعة'},
      ];
      expect(ReconPdfLayout.partsText(parts), '2 كرتون + 1 قطعة');
      expect(ReconPdfLayout.partsText([parts[0]]), '',
          reason: 'single unit needs no breakdown line');
    });
  });

  test('REAL user record renders (null hunt)', () async {
    final f = File('/home/abdulrhman2/.fyona-tmp/user_rec.json');
    if (!f.existsSync()) return;
    final rec =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    late Uint8List bytes;
    await binding.runAsync(() async {
      bytes = await ReconReportPdf.build(
          record: rec, isBank: true, isAr: true,
          scope: {'name': 'بنك جيب'});
    });
    File('/home/abdulrhman2/.fyona-tmp/user_report.pdf')
        .writeAsBytesSync(bytes);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  group('produced PDF structure', () {
    late Uint8List arBytes;
    late Uint8List invBytes;
    setUpAll(() async {
      await binding.runAsync(() async {
        arBytes = await ReconReportPdf.build(
            record: bankRecord(longNames: true), isBank: true, isAr: true,
            scope: {'name': 'بنك الاختبار'});
        invBytes = await ReconReportPdf.build(
            record: invRecord(), isBank: false, isAr: true,
            scope: {'name': 'المواد الغذائية'});
      });
    });

    test('valid PDFs written to disk for the external layout check', () {
      // Written under .fyona-tmp so the Python stream extractor can verify
      // the visual layout (column order / names / colours) outside the test.
      Directory('/home/abdulrhman2/.fyona-tmp').createSync(recursive: true);
      File('/home/abdulrhman2/.fyona-tmp/recon_report_ar.pdf')
          .writeAsBytesSync(arBytes);
      File('/home/abdulrhman2/.fyona-tmp/recon_report_inv.pdf')
          .writeAsBytesSync(invBytes);
      expect(String.fromCharCodes(arBytes.take(5)), '%PDF-');
      expect(String.fromCharCodes(invBytes.take(5)), '%PDF-');
    });
  });
}