import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../core/utils/currency_formatter.dart';
import 'recon_report_pdf_layout.dart';

/// FYONA reconciliation report — faithful reproduction of the approved «R1»
/// design (A4 portrait), LANGUAGE-AWARE:
///   Arabic  → the table reads RTL:  العملة | بالنظام | بالحقيقة | الفرق
///             (العملة at the RIGHT edge), labels on the right, values left.
///   English → LTR: currency | system | actual | difference.
/// Both flavours: bank/cash (currencies) and inventory (products, multi-unit
/// aware with a clear «2 كرتون + 1 قطعة» breakdown).
/// NOTHING is ever clipped (name column wraps) and «null» can never appear
/// (every dynamic value passes through [_s]).
class ReconReportPdf {
  static const _burgundy = PdfColor.fromInt(0xFF7B1E28);
  static const _dark = PdfColor.fromInt(0xFF24252A);
  static const _grey = PdfColor.fromInt(0xFF8A8A8F);
  static const _gold = PdfColor.fromInt(0xFFB7791F);
  static const _green = PdfColor.fromInt(0xFF1B7A43);
  static const _red = PdfColor.fromInt(0xFFC0392B);
  static const _rowAlt = PdfColor.fromInt(0xFFF7F7F8);
  static const _rose = PdfColor.fromInt(0xFFF8E9EC);
  static const _chipGreenBg = PdfColor.fromInt(0xFFE7F4EC);
  static const _chipRedBg = PdfColor.fromInt(0xFFFBE9E7);
  static const _chipGreenTx = PdfColor.fromInt(0xFF1B7A43);
  static const _chipRedTx = PdfColor.fromInt(0xFFC0392B);

  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<void> _fonts() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
  }

  static String _s(dynamic v) => ReconPdfLayout.s(v);

  static String _num(num? v) {
    if (v == null) return '0';
    final d = v.toDouble();
    final s = d == d.roundToDouble()
        ? d.toInt().toString()
        : d.toStringAsFixed(2);
    final neg = s.startsWith('-');
    final body = neg ? s.substring(1) : s;
    final parts = body.split('.');
    final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    final out = parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
    return neg ? '-$out' : out;
  }

  static String _dt(String? iso) {
    final s = _s(iso);
    if (s.isEmpty) return '—';
    return s.split('.').first.replaceAll('T', ' ');
  }

  /// [isAr] drives the language AND the column direction.
  static Future<Uint8List> build({
    required Map<String, dynamic> record,
    required bool isBank,
    bool isAr = true,
    Map<String, dynamic>? scope,
  }) async {
    await _fonts();
    final regular = _regular!;
    final bold = _bold!;
    final dir = isAr ? pw.TextDirection.rtl : pw.TextDirection.ltr;

    // ── strings ──
    final title = isAr
        ? (isBank
            ? 'تقرير فحص البنوك والكاش'
            : 'تقرير جرد المخزون')
        : (isBank
            ? 'Bank & Cash Check Report'
            : 'Inventory Count Report');
    final cols = ReconPdfLayout.columnOrder(isAr: isAr, isBank: isBank);
    final firstCol = cols.last; // AR: rightmost; EN: leftmost
    final colSystem = isAr ? 'بالنظام' : 'In system';
    final colActual = isAr ? 'بالحقيقة' : 'In reality';
    final colDiff = isAr ? 'الفرق' : 'Difference';
    final subjectLabel = isAr ? (isBank ? 'الحساب' : 'النطاق') : 'Account';
    final dateLabel = isAr ? 'تاريخ الفحص' : 'Checked at';
    final approvedLabel = isAr ? 'تاريخ الاعتماد' : 'Approved at';
    final resultTitle = isAr ? 'نتيجة الفحص' : 'Check result';
    final summaryTitle = isAr ? 'الخلاصة' : 'Summary';
    final settleTitle = isAr ? 'التصحيحات' : 'Corrections';
    final countWord = isAr ? (isBank ? 'عملات' : 'منتجات')
        : (isBank ? 'currencies' : 'products');
    final reviewed = isAr ? 'تمت مراجعتها' : 'reviewed';
    final surplusWord = isAr
        ? (isBank ? 'عملات فيها زيادة' : 'منتجات فيها زيادة')
        : 'with surplus';
    final shortWord = isAr
        ? (isBank ? 'عملات فيها نقص' : 'منتجات فيها نقص')
        : 'with shortage';
    final noneWord =
        isAr ? 'لا يوجد أي اختلاف — كل شيء مطابق' : 'No differences — everything matches';

    final lines = [
      for (final l in (record['lines'] as List? ?? []).whereType<Map>())
        Map<String, dynamic>.from(l)
    ];
    final settlements = [
      for (final s in (record['settlements'] as List? ?? []).whereType<Map>())
        Map<String, dynamic>.from(s)
    ];
    num sNum(dynamic v) => (v is num) ? v : (num.tryParse('$v') ?? 0);
    String amt(num v) => isBank ? fmtNum(v) : _num(v);
    final diffs = [for (final l in lines) sNum(l['diff']).toDouble()];
    final hasDiff = diffs.any((d) => d.abs() > 1e-9);
    final surplus = diffs.where((d) => d > 1e-9).length;
    final short = diffs.where((d) => d < -1e-9).length;
    final ref = _s(record['ref_code']);
    final subjectName = _s(scope?['name']) ;
    final chipText = hasDiff
        ? (isAr ? 'اختلاف' : 'Difference')
        : (isAr ? 'سليم' : 'Clear');

    final summaryLine = [
      if (surplus > 0)
        isAr ? '$surplus $surplusWord' : '$surplus $countWord $surplusWord',
      if (short > 0)
        isAr ? '$short $shortWord' : '$short $countWord $shortWord',
    ].join(isAr ? '، و' : ' and ');

    pw.Widget label(String t,
        {bool b = false,
        double size = 10,
        PdfColor? color,
        pw.TextAlign align = pw.TextAlign.right}) =>
        pw.Text(isAr ? '$t ' : t,
            textAlign: align,
            textDirection: dir,
            softWrap: true,
            style: pw.TextStyle(
                font: b ? bold : regular,
                fontSize: size,
                color: color ?? _dark,
                lineSpacing: 1.6));

    // Column order flips per language; each cell builder is language-neutral.
    pw.Widget resultHeader() {
      final name = pw.Expanded(
          flex: 5,
          child: label(firstCol, b: true, size: 11, color: PdfColors.white,
              align: isAr ? pw.TextAlign.right : pw.TextAlign.left));
      final sys = pw.Expanded(
          flex: 3,
          child: label(colSystem, b: true, size: 11, color: PdfColors.white,
              align: pw.TextAlign.center));
      final act = pw.Expanded(
          flex: 3,
          child: label(colActual, b: true, size: 11, color: PdfColors.white,
              align: pw.TextAlign.center));
      final dif = pw.Expanded(
          flex: 3,
          child: label(colDiff, b: true, size: 11, color: PdfColors.white,
              align: pw.TextAlign.center));
      return pw.Container(
        decoration: pw.BoxDecoration(
          color: _burgundy,
          borderRadius: pw.BorderRadius.circular(8),
        ),
        padding:
            const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: pw.Row(
            children: isAr ? [dif, act, sys, name] : [name, sys, act, dif]),
      );
    }

    // Only currencies that appear with MORE THAN ONE account type get a
    // «جاري/توفير» badge — a single-type currency shows none.
    final multiTypes = ReconPdfLayout.currenciesWithMultipleTypes(lines);

    // One aligned data row: [name | system | actual | difference].
    pw.Widget dataRow({
      required String name,
      required String sys,
      required String act,
      required String dif,
      bool difNeg = false,
      PdfColor? bg,
      bool nameBold = true,
      double nameSize = 10.5,
      PdfColor? nameColor,
      double indent = 0,
    }) {
      final nameCell = pw.Expanded(
        flex: 5,
        child: pw.Padding(
          padding: pw.EdgeInsets.only(right: indent),
          child: label('$name ', b: nameBold, size: nameSize,
              color: nameColor,
              align: isAr ? pw.TextAlign.right : pw.TextAlign.left),
        ),
      );
      final sysCell = pw.Expanded(
          flex: 3,
          child: label(sys, b: true, size: 11.5,
              color: _gold, align: pw.TextAlign.center));
      final actCell = pw.Expanded(
          flex: 3,
          child: label(act, b: true, size: 11.5,
              color: _green, align: pw.TextAlign.center));
      final difCell = pw.Expanded(
          flex: 3,
          child: label(dif, b: true, size: 11.5,
              color: difNeg ? _red : _green, align: pw.TextAlign.center));
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: pw.BoxDecoration(color: bg ?? PdfColors.white),
        child: pw.Row(
            children: isAr ? [difCell, actCell, sysCell, nameCell]
                : [nameCell, sysCell, actCell, difCell]),
      );
    }

    pw.Widget resultRow(Map<String, dynamic> l, int i) {
      final system = sNum(l['system'] ?? l['system_qty']).toDouble();
      final actual =
          sNum(l['actual'] ?? l['base_qty'] ?? l['counted_qty']).toDouble();
      final diff = sNum(l['diff']).toDouble();
      final name = ReconPdfLayout.displayName(
          isBank: isBank, isAr: isAr,
          currency: _s(l['currency']), name: _s(l['name']));
      final acctType = _s(l['account_type']);
      final showType =
          isBank && multiTypes.contains(_s(l['currency']).toUpperCase());
      final typeWord = showType
          ? ReconPdfLayout.accountTypeLabelStr(acctType, isAr: isAr)
          : '';
      final typeColor = acctType == 'savings' ? _green : PdfColor.fromInt(0xFF1E6FD9);
      final sub = isBank ? _s(l['currency']) : _s(l['unit']);
      final diffTxt = '${diff > 0 ? '+' : ''}${amt(diff)}';
      final urs = ReconPdfLayout.unitRows(
          systemQty: system,
          baseAfter: actual,
          parts: l['parts'] ?? const [],
          serverRows: l['unit_rows']);

      // ── Multi-unit product: ONE group with a header band + a row per unit ──
      if (!isBank && urs.length > 1) {
        final headerName = pw.Expanded(
            flex: 5,
            child: label('$name ', b: true, size: 11.5, color: _burgundy,
                align: isAr ? pw.TextAlign.right : pw.TextAlign.left));
        final headerSys = pw.Expanded(
            flex: 3,
            child: label(amt(system), b: true, size: 11.5, color: _gold,
                align: pw.TextAlign.center));
        final headerAct = pw.Expanded(
            flex: 3,
            child: label(amt(actual), b: true, size: 11.5, color: _green,
                align: pw.TextAlign.center));
        final headerDif = pw.Expanded(
            flex: 3,
            child: label(diffTxt, b: true, size: 11.5,
                color: diff < -1e-9 ? _red : _green,
                align: pw.TextAlign.center));
        return pw.Container(
          decoration: pw.BoxDecoration(
              border: pw.Border(
                  top: pw.BorderSide(color: _rowAlt, width: 1))),
          child: pw.Column(children: [
            pw.Container(
              color: _rose,
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: pw.Row(children: isAr
                  ? [headerDif, headerAct, headerSys, headerName]
                  : [headerName, headerSys, headerAct, headerDif]),
            ),
            for (var u = 0; u < urs.length; u++)
              dataRow(
                name: '$name (${urs[u].unit})',
                sys: urs[u].before,
                act: urs[u].after,
                dif: urs[u].diff,
                difNeg: urs[u].diff.startsWith('-'),
                bg: u.isOdd ? _rowAlt : PdfColors.white,
                nameBold: false,
                nameSize: 9.5,
                indent: 12,
              ),
          ]),
        );
      }

      // ── Single row (bank/cash currency, or a single-unit product) ──
      final nameCell = pw.Expanded(
        flex: 5,
        child: pw.Column(
          crossAxisAlignment: isAr
              ? pw.CrossAxisAlignment.end
              : pw.CrossAxisAlignment.start,
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: label('$name ', b: true, size: 10.5)),
            if (sub.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2),
                child: label('$sub ', size: 8, color: _grey)),
            if (typeWord.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2),
                child:
                    label(typeWord, b: true, size: 8.5, color: typeColor)),
          ],
        ),
      );
      final sysCell = pw.Expanded(
          flex: 3,
          child: label(amt(system), b: true, size: 11.5,
              color: _gold, align: pw.TextAlign.center));
      final actCell = pw.Expanded(
          flex: 3,
          child: label(amt(actual), b: true, size: 11.5,
              color: _green, align: pw.TextAlign.center));
      final difCell = pw.Expanded(
          flex: 3,
          child: label(diffTxt, b: true, size: 11.5,
              color: diff < -1e-9 ? _red : _green,
              align: pw.TextAlign.center));
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration:
            pw.BoxDecoration(color: i.isOdd ? _rowAlt : PdfColors.white),
        child: pw.Row(
            children: isAr ? [difCell, actCell, sysCell, nameCell]
                : [nameCell, sysCell, actCell, difCell]),
      );
    }

    // «التسويات الظاهرة» — every unit of a multi-unit product gets its own
    // before ← after row inside the product's block.
    pw.Widget settlementBlock(Map<String, dynamic> s) {
      final parts = (s['parts'] as List?) ?? const [];
      final urs = ReconPdfLayout.unitRows(
          systemQty: sNum(s['before']),
          baseAfter: sNum(s['after']),
          parts: parts,
          serverRows: s['unit_rows']);
      final multi = urs.length > 1;
      final title = '${_s(s['name'])}'
          '${_s(s['currency']).isNotEmpty ? ' (${_s(s['currency'])})' : (!multi && _s(s['unit']).isNotEmpty ? ' (${_s(s['unit'])})' : '')}';

      // The row is laid out left-to-right; Arabic reads right-to-left, so
      // «before» sits on the right and the left-pointing arrow leads to
      // «after»: 0 ← 60,000 reads «from 0 to 60,000».
      pw.Widget arrowPair(String before, String after, {double size = 12}) {
        final first = label(before, b: true, size: size, color: _burgundy,
            align: pw.TextAlign.center);
        final second = label(after, b: true, size: size, color: _burgundy,
            align: pw.TextAlign.center);
        return pw.Directionality(
          textDirection: pw.TextDirection.ltr,
          child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            isAr ? second : first,
            pw.SizedBox(width: 6),
            _arrow(isAr),
            pw.SizedBox(width: 6),
            isAr ? first : second,
          ],
        ));
      }

      if (multi) {
        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: pw.BoxDecoration(
            color: _rose,
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Column(
            crossAxisAlignment: isAr
                ? pw.CrossAxisAlignment.end
                : pw.CrossAxisAlignment.start,
            children: [
              label(title, b: true, size: 11, color: _burgundy,
                  align: isAr ? pw.TextAlign.right : pw.TextAlign.left),
              pw.SizedBox(height: 4),
              for (final ur in urs)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 3),
                  child: pw.Row(children: [
                    pw.Expanded(
                        flex: 5,
                        child: label('$title (${ur.unit})', size: 9.5,
                            color: _dark,
                            align: isAr
                                ? pw.TextAlign.right
                                : pw.TextAlign.left)),
                    pw.Expanded(
                        flex: 4,
                        child: arrowPair(ur.before, ur.after, size: 10.5)),
                  ]),
                ),
            ],
          ),
        );
      }

      return pw.Container(
        padding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
              bottom: pw.BorderSide(color: _rowAlt, width: 1)),
        ),
        child: pw.Row(children: [
          pw.Expanded(
              flex: 5,
              child: label(title, b: true, size: 11,
                  align: isAr ? pw.TextAlign.right : pw.TextAlign.left)),
          pw.Expanded(
            flex: 4,
            child: arrowPair(amt(sNum(s['before'])), amt(sNum(s['after']))),
          ),
        ]),
      );
    }

    pw.Widget sectionTitle(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 18, bottom: 8),
          child: label(t, b: true, size: 14,
              align: isAr ? pw.TextAlign.right : pw.TextAlign.left),
        );

    // Meta row: AR → value left of the right-aligned label; EN → label left.
    pw.Widget metaRow(String labelText, String value) {
      final l = label(labelText, size: 10, color: _grey);
      final v = label(value, b: true, size: 10.5);
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Row(children: isAr
            ? [pw.Expanded(child: pw.Align(
                alignment: pw.Alignment.centerLeft, child: v)),
               pw.SizedBox(width: 10),
               pw.Expanded(child: pw.Align(
                alignment: pw.Alignment.centerRight, child: l))]
            : [pw.Expanded(child: pw.Align(
                alignment: pw.Alignment.centerRight, child: l)),
               pw.SizedBox(width: 10),
               pw.Expanded(child: pw.Align(
                alignment: pw.Alignment.centerLeft, child: v))]),
      );
    }

    final doc = pw.Document(
        theme: pw.ThemeData.withFont(base: regular, bold: bold));
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      // Long reports (hundreds of products/currencies) legitimately span many
      // pages — the default 20-page cap threw `PdfTooBigPageException` and
      // truncated real inventories. Keep a generous, bounded ceiling.
      maxPages: 500,
      build: (context) => [
        pw.Container(height: 6, color: _burgundy),
        pw.Padding(
          padding: const pw.EdgeInsets.fromLTRB(36, 18, 36, 0),
          child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Align(
                    alignment: pw.Alignment.topRight,
                    child: label('FYONA ERP', b: true, size: 15,
                        color: _burgundy)),
                pw.SizedBox(height: 4),
                label(title,
                    b: true, size: 20,
                    align: isAr ? pw.TextAlign.right : pw.TextAlign.left),
                pw.SizedBox(height: 10),
                pw.Row(children: [
                  pw.Expanded(
                    child: pw.Align(
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Container(
                        padding: const pw.EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        decoration: pw.BoxDecoration(
                          color: hasDiff ? _chipRedBg : _chipGreenBg,
                          borderRadius: pw.BorderRadius.circular(6),
                        ),
                        child: label(chipText, b: true, size: 11,
                            color: hasDiff ? _chipRedTx : _chipGreenTx,
                            align: pw.TextAlign.center),
                      ),
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Align(
                      alignment: pw.Alignment.centerRight,
                      child: label(ref, size: 10, color: _grey),
                    ),
                  ),
                ]),
                pw.SizedBox(height: 8),
                pw.Divider(color: _rowAlt, thickness: 1),
                pw.SizedBox(height: 8),
                if (subjectName.isNotEmpty) metaRow(subjectLabel, subjectName),
                metaRow(dateLabel, _dt(record['measured_at'])),
                metaRow(approvedLabel, _dt(record['approved_at'])),
                sectionTitle(resultTitle),
                resultHeader(),
                for (var i = 0; i < lines.length; i++) resultRow(lines[i], i),
                sectionTitle(summaryTitle),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(14),
                  decoration: pw.BoxDecoration(
                    color: _rose,
                    borderRadius: pw.BorderRadius.circular(10),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: isAr
                        ? pw.CrossAxisAlignment.end
                        : pw.CrossAxisAlignment.start,
                    children: [
                      label('${lines.length} $countWord $reviewed',
                          b: true, size: 12),
                      if (summaryLine.isNotEmpty)
                        pw.Padding(
                          padding: const pw.EdgeInsets.only(top: 3),
                          child: label(summaryLine, size: 10, color: _grey),
                        ),
                      if (!hasDiff)
                        pw.Padding(
                          padding: const pw.EdgeInsets.only(top: 3),
                          child: label(noneWord, size: 10, color: _green),
                        ),
                    ],
                  ),
                ),
                if (settlements
                    .where((s) => s['applied'] == true)
                    .isNotEmpty) ...[
                  sectionTitle(settleTitle),
                  for (final s
                      in settlements.where((s) => s['applied'] == true))
                    settlementBlock(s),
                ],
                pw.SizedBox(height: 24),
              ]),
        ),
      ],
      footer: (context) => pw.Column(children: [
        pw.Divider(color: _rowAlt, thickness: 1),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 36, vertical: 8),
          child: pw.Row(children: [
            pw.Expanded(child: label(ref, size: 9, color: _grey,
                align: pw.TextAlign.left)),
            pw.Expanded(
                child: label('FYONA ERP', b: true, size: 10,
                    color: _burgundy, align: pw.TextAlign.right)),
          ]),
        ),
      ]),
    ));
    return doc.save();
  }

  /// A small vector arrow drawn as shapes (the Cairo font has no arrow glyph):
  /// points LEFT in RTL (before ← after) and RIGHT in LTR (before → after).
  static pw.Widget _arrow(bool isAr) => pw.CustomPaint(
        size: const PdfPoint(16, 8),
        painter: (canvas, size) {
          final y = size.y / 2;
          if (isAr) {
            canvas
              ..setStrokeColor(_burgundy)
              ..setLineWidth(1.4)
              ..moveTo(size.x, y)
              ..lineTo(2, y)
              ..strokePath()
              ..setFillColor(_burgundy)
              ..moveTo(0, y)
              ..lineTo(5, y - 3)
              ..lineTo(5, y + 3)
              ..closePath()
              ..fillPath();
          } else {
            canvas
              ..setStrokeColor(_burgundy)
              ..setLineWidth(1.4)
              ..moveTo(0, y)
              ..lineTo(size.x - 2, y)
              ..strokePath()
              ..setFillColor(_burgundy)
              ..moveTo(size.x, y)
              ..lineTo(size.x - 5, y - 3)
              ..lineTo(size.x - 5, y + 3)
              ..closePath()
              ..fillPath();
          }
        },
      );
}