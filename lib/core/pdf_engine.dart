import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'receipt_engine/models.dart';
import 'receipt_engine/renderer.dart';
import 'receipt_engine/styles.dart';
import 'utils/currency_formatter.dart';
import 'utils/time_format.dart';

/// One grouped table of a report PDF (title + headers + rows). The template
/// repeats the title + header row on every page chunk, wraps long text, and
/// flips column order for Arabic.
class ReportPdfSection {
  final String title;
  final List<String> headers;
  final List<List<String>> rows;
  const ReportPdfSection(
      {required this.title, required this.headers, required this.rows});
}

/// One bar of a report visual: label, numeric value (for the bar length)
/// and the already formatted amount shown next to it.
class ReportPdfBar {
  final String label;
  final double value;
  final String display;
  /// brand · in · out · info · amber · slate · plum (calm accents).
  final String? tone;
  const ReportPdfBar(this.label, this.value, this.display, {this.tone});
}

/// A simple visual in a report PDF: horizontal bars, or one stacked ratio
/// bar (shares of a whole) with a legend.
class ReportPdfChart {
  final String title;
  final List<ReportPdfBar> bars;
  final bool ratio;
  /// Bars all in the first tone (a ranked list) instead of one per bar.
  final bool singleTone;
  const ReportPdfChart({
    required this.title,
    required this.bars,
    this.ratio = false,
    this.singleTone = false,
  });
}

class PdfEngine {
  PdfEngine._();

  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;

  static Future<pw.Font> _getFontRegular() async {
    _fontRegular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    return _fontRegular!;
  }
  static Future<pw.Font> _getFontBold() async {
    _fontBold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
    return _fontBold!;
  }

  static const _chartColors = [
    0xFFA01530, 0xFFB82040, 0xFF7A1020,
    0xFFD4A373, 0xFF6C9BCF, 0xFF77DD77,
    0xFFFFB347, 0xFFCB99C9,
  ];

  // ════════════════════════════════════════════════════════════
  //  UNIFIED REPORT TEMPLATE — «Report1pdf/Report Design.pdf»
  //  FYONA identity: crimson #B00020 / #A00020, white, a touch of black.
  //  One template for ALL five reports: the content (title, KPIs, tables)
  //  adapts automatically. Arabic → full RTL + Cairo; English → LTR.
  // ════════════════════════════════════════════════════════════

  static Uint8List? _logoBytes;
  static Future<Uint8List?> _getLogo() async {
    if (_logoBytes == null) {
      try {
        final data = await rootBundle.load('assets/images/fyona_report_logo.png');
        _logoBytes = data.buffer.asUint8List();
      } catch (_) {
        _logoBytes = Uint8List(0);
      }
    }
    return _logoBytes!.isEmpty ? null : _logoBytes;
  }

  static bool _hasArabic(String s) => RegExp(r'[\u0600-\u06FF]').hasMatch(s);

  // ── Report template building blocks ────────────────────────────────

  static const _rBrand = PdfColor.fromInt(0xFFB00020);
  static const _rBrandDeep = PdfColor.fromInt(0xFF8C0A1C);
  static const _rBrandSoft = PdfColor.fromInt(0xFFFBEFF1);
  static const _rInk = PdfColor.fromInt(0xFF1F2328);
  static const _rMuted = PdfColor.fromInt(0xFF6B7280);
  static const _rLine = PdfColor.fromInt(0xFFE5E7EB);
  static const _rCard = PdfColor.fromInt(0xFFF7F7F9);
  static const _rWhite = PdfColor.fromInt(0xFFFFFFFF);

  /// Calm accent cycle for KPI cards / bars when no tone is given.
  static const _rTones = <String, PdfColor>{
    'brand': _rBrand,
    'in': PdfColor.fromInt(0xFF2E7D5B),
    'out': PdfColor.fromInt(0xFFC0392B),
    'info': PdfColor.fromInt(0xFF2F5D9E),
    'amber': PdfColor.fromInt(0xFFB7791F),
    'slate': PdfColor.fromInt(0xFF4B5563),
    'plum': PdfColor.fromInt(0xFF7A3E6C),
  };
  static const _rCycle = ['brand', 'info', 'in', 'amber', 'slate', 'plum'];

  static PdfColor _tone(String? tone, int index) =>
      _rTones[tone] ?? _rTones[_rCycle[index % _rCycle.length]]!;

  /// Same writer quirk as «ر»/«ز»: a space between an Arabic word and a
  /// number collapses («صفحة 1 من 5» → «صفحة1 من5»).
  static final _spaceDigit = RegExp(
      r'(?:(?<=[؀-ۿ])(?<![رزژ]) (?=[0-9])|(?<=[0-9]) (?=[؀-ۿ]))');

  /// Text in the report template: the [_pdfText] spacing fix, Arabic always
  /// shaped in an RTL run, and LTR only for runs without Arabic letters
  /// (forcing LTR on Arabic corrupts the bold glyph subset).
  static pw.Widget _rt(
    String text, {
    double size = 9,
    bool bold = false,
    PdfColor color = _rInk,
    pw.TextAlign? align,
    int? maxLines,
    bool ltr = false,
  }) =>
      _pdfText(
        text.replaceAll(_spaceDigit, '  '),
        style: pw.TextStyle(
          font: bold ? _fontBold! : _fontRegular!,
          fontBold: _fontBold,
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : null,
          color: color,
        ),
        textAlign: align,
        maxLines: maxLines,
        textDirection: _hasArabic(text)
            ? pw.TextDirection.rtl
            : (ltr ? pw.TextDirection.ltr : null),
      );

  /// A value that may hold several «amount currency» parts joined by «•»:
  /// each part is its own paragraph (one line each) so mixed Arabic/Latin
  /// currencies never reorder each other.
  static pw.Widget _rValue(
    String text, {
    required double size,
    bool bold = false,
    PdfColor color = _rInk,
    bool end = false,
    pw.TextAlign? align,
  }) {
    final parts = text
        .split('•')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2) {
      return _rt(text, size: size, bold: bold, color: color, align: align,
          ltr: true, maxLines: 2);
    }
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment:
          end ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start,
      children: [
        for (final p in parts)
          _rt(p, size: size, bold: bold, color: color, align: align,
              ltr: true, maxLines: 1),
      ],
    );
  }

  static final _numericCell =
      RegExp(r'^[+\-−]?\s*[0-9٠-٩][0-9٠-٩,.\s/:%\-]*');

  /// A column reads as numeric (amount, quantity, date) when most of its
  /// filled cells start with a digit — those align right.
  static List<bool> _numericColumns(List<List<String>> rows, int n) => [
        for (var c = 0; c < n; c++)
          () {
            var filled = 0, numeric = 0;
            for (final r in rows) {
              final v = c < r.length ? r[c].trim() : '';
              if (v.isEmpty || v == '—') continue;
              filled++;
              if (_numericCell.hasMatch(v)) numeric++;
            }
            return filled > 0 && numeric * 10 >= filled * 6;
          }(),
      ];

  static pw.Widget _reportHeader({
    required String title,
    required String? subtitle,
    required String? badge,
    required Uint8List? logo,
  }) {
    final chip = logo == null
        ? pw.SizedBox()
        : pw.Container(
            width: 50,
            height: 50,
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(
                color: _rWhite, borderRadius: pw.BorderRadius.circular(12)),
            child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
          );
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: pw.BoxDecoration(
        gradient: const pw.LinearGradient(
          begin: pw.Alignment.topLeft,
          end: pw.Alignment.bottomRight,
          colors: [PdfColor.fromInt(0xFFC81E3A), _rBrand, _rBrandDeep],
        ),
        borderRadius: pw.BorderRadius.circular(14),
      ),
      child: pw.Row(children: [
        chip,
        pw.SizedBox(width: 14),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _rt(title, size: 18.5, bold: true, color: _rWhite, maxLines: 2),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                pw.SizedBox(height: 2),
                _rt(subtitle, size: 10,
                    color: const PdfColor.fromInt(0xE6FFFFFF), maxLines: 1),
              ],
            ],
          ),
        ),
        if (badge != null && badge.trim().isNotEmpty)
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: pw.BoxDecoration(
              color: _rBrandDeep,
              borderRadius: pw.BorderRadius.circular(9),
            ),
            child: _rt(badge, size: 9.5, bold: true, color: _rWhite),
          ),
      ]),
    );
  }

  static pw.Widget _reportMeta(List<(String, String)> cells) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _rCard,
        border: pw.Border.all(color: _rLine, width: 0.7),
        borderRadius: pw.BorderRadius.circular(10),
      ),
      padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: pw.Row(children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) pw.Container(width: 0.7, height: 26, color: _rLine),
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _rt(cells[i].$1, size: 7.5, color: _rMuted, maxLines: 1),
                  pw.SizedBox(height: 1),
                  _rt(cells[i].$2,
                      size: 9.5, bold: true, maxLines: 1, ltr: true),
                ],
              ),
            ),
          ),
        ],
      ]),
    );
  }

  static pw.Widget _reportBand(String title, {String? trailing}) {
    return pw.Container(
      decoration: pw.BoxDecoration(
          color: _rBrandSoft, borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Row(children: [
        pw.Container(
          width: 4,
          height: 28,
          decoration: pw.BoxDecoration(
              color: _rBrand, borderRadius: pw.BorderRadius.circular(2)),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
            child: _rt(title, size: 11.5, bold: true, color: _rBrand,
                maxLines: 1)),
        if (trailing != null && trailing.isNotEmpty)
          pw.Container(
            margin: const pw.EdgeInsets.symmetric(horizontal: 10),
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: pw.BoxDecoration(
                color: _rBrand, borderRadius: pw.BorderRadius.circular(10)),
            child: _rt(trailing, size: 8.5, bold: true, color: _rWhite,
                ltr: true),
          ),
      ]),
    );
  }

  static List<pw.Widget> _reportKpis(List<Map<String, String>> kpis) {
    final perRow = kpis.length <= 4
        ? kpis.length
        : (kpis.length % 3 == 0 && kpis.length % 4 != 0 ? 3 : 4);
    final out = <pw.Widget>[];
    for (var i = 0; i < kpis.length; i += perRow) {
      final chunk = kpis.sublist(i, min(i + perRow, kpis.length));
      // Every card in a row shares one height, sized for its longest value.
      var lines = 1;
      for (final k in chunk) {
        final v = k['value'] ?? '';
        final n = v.split('•').length;
        lines = max(lines, n > 1 ? n : (v.length > 20 ? 2 : 1));
      }
      final cardHeight = 38.0 + (lines == 1 ? 22.5 : lines * 17.0);
      out.add(pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (var j = 0; j < perRow; j++) ...[
            if (j > 0) pw.SizedBox(width: 7),
            pw.Expanded(
              child: j >= chunk.length
                  ? pw.SizedBox()
                  : () {
                      final k = chunk[j];
                      final color = _tone(k['tone'], i + j);
                      final value = k['value'] ?? '—';
                      final long =
                          value.contains('•') || value.length > 20;
                      return pw.Container(
                        height: cardHeight,
                        decoration: pw.BoxDecoration(
                          color: _rWhite,
                          border: pw.Border.all(color: _rLine, width: 0.8),
                          borderRadius: pw.BorderRadius.circular(9),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                          children: [
                            pw.Container(
                              height: 3,
                              decoration: pw.BoxDecoration(
                                color: color,
                                borderRadius: const pw.BorderRadius.only(
                                    topLeft: pw.Radius.circular(9),
                                    topRight: pw.Radius.circular(9)),
                              ),
                            ),
                            pw.Padding(
                              padding: const pw.EdgeInsets.fromLTRB(9, 6, 9, 8),
                              child: pw.Column(
                                crossAxisAlignment: pw.CrossAxisAlignment.start,
                                children: [
                                  _rt(k['label'] ?? '',
                                      size: 7.8, color: _rMuted, maxLines: 1),
                                  pw.SizedBox(height: 3),
                                  _rValue(value,
                                      size: long ? 9 : 12,
                                      bold: true,
                                      color: color),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }(),
            ),
          ],
        ],
      ));
      out.add(pw.SizedBox(height: 7));
    }
    if (out.isNotEmpty) out.removeLast();
    return out;
  }

  static pw.Widget _reportChart(ReportPdfChart chart, bool rtl) {
    final bars = chart.bars.where((b) => b.value.isFinite).toList();
    final peak = bars.fold<double>(0, (m, b) => max(m, b.value.abs()));
    final sum = bars.fold<double>(0, (m, b) => m + max(0, b.value));
    pw.Widget track(double share, PdfColor color, {double height = 7}) =>
        pw.ClipRRect(
          horizontalRadius: height / 2,
          verticalRadius: height / 2,
          child: pw.SizedBox(
            height: height,
            child: pw.Row(children: [
              if (share > 0)
                pw.Expanded(
                    flex: max(1, (share * 1000).round()),
                    child: pw.Container(color: color)),
              if (share < 1)
                pw.Expanded(
                    flex: max(1, ((1 - share) * 1000).round()),
                    child: pw.Container(color: _rCard)),
            ]),
          ),
        );
    final body = <pw.Widget>[];
    if (chart.ratio) {
      body.add(pw.ClipRRect(
        horizontalRadius: 5,
        verticalRadius: 5,
        child: pw.SizedBox(
          height: 11,
          child: sum <= 0
              ? pw.Container(color: _rLine)
              : pw.Row(children: [
                  for (var i = 0; i < bars.length; i++)
                    if (bars[i].value > 0)
                      pw.Expanded(
                          flex: max(1, (bars[i].value / sum * 1000).round()),
                          child: pw.Container(
                              color: _tone(bars[i].tone, i))),
                ]),
        ),
      ));
      body.add(pw.SizedBox(height: 7));
      for (var i = 0; i < bars.length; i++) {
        final b = bars[i];
        final pct = sum <= 0 ? 0 : (max(0, b.value) / sum * 100).round();
        body.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(children: [
            pw.Container(
                width: 7,
                height: 7,
                decoration: pw.BoxDecoration(
                    color: _tone(b.tone, i), shape: pw.BoxShape.circle)),
            pw.SizedBox(width: 5),
            pw.Expanded(child: _rt(b.label, size: 8.5, maxLines: 1)),
            _rt(b.display, size: 8.5, bold: true, ltr: true, maxLines: 1),
            pw.SizedBox(width: 6),
            pw.SizedBox(
              width: 30,
              child: _rt('$pct%',
                  size: 8, color: _rMuted, ltr: true,
                  align: rtl ? pw.TextAlign.left : pw.TextAlign.right),
            ),
          ]),
        ));
      }
    } else {
      for (var i = 0; i < bars.length; i++) {
        final b = bars[i];
        final color = _tone(b.tone, chart.singleTone ? 0 : i);
        body.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Row(children: [
                pw.Expanded(child: _rt(b.label, size: 8.5, maxLines: 1)),
                _rt(b.display, size: 8.5, bold: true, color: color,
                    ltr: true, maxLines: 1),
              ]),
              pw.SizedBox(height: 2),
              track(peak <= 0 ? 0 : b.value.abs() / peak, color),
            ],
          ),
        ));
      }
    }
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(11, 9, 11, 7),
      decoration: pw.BoxDecoration(
        color: _rWhite,
        border: pw.Border.all(color: _rLine, width: 0.8),
        borderRadius: pw.BorderRadius.circular(9),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _rt(chart.title, size: 10, bold: true, maxLines: 1),
          pw.SizedBox(height: 7),
          ...body,
        ],
      ),
    );
  }

  static pw.Widget _reportTable({
    required bool rtl,
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    final n = headers.length;
    final numeric = _numericColumns(rows, n);
    List<T> dir<T>(List<T> l) => rtl ? l.reversed.toList() : l;
    final order = dir(List<int>.generate(n, (i) => i));
    // Wider text columns, compact numbers.
    double flex(int i) => numeric[i] ? 1.3 : (i == 0 ? 2.4 : 1.8);
    pw.Widget cell(int i, String text, {bool head = false}) => pw.Container(
          alignment: numeric[i] || rtl
              ? pw.Alignment.centerRight
              : pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4.6),
          child: !head && text.contains('•')
              ? _rValue(text,
                  size: 8.4,
                  end: (numeric[i] || rtl) != rtl,
                  align: numeric[i] || rtl
                      ? pw.TextAlign.right
                      : pw.TextAlign.left)
              : _rt(text.isEmpty ? '—' : text,
                  size: head ? 8.2 : 8.4,
                  bold: head,
                  color: head ? _rWhite : _rInk,
                  align: numeric[i] || rtl
                      ? pw.TextAlign.right
                      : pw.TextAlign.left,
                  ltr: numeric[i] && !head),
        );
    return pw.Table(
      columnWidths: {
        for (var c = 0; c < n; c++) c: pw.FlexColumnWidth(flex(order[c])),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _rLine, width: 0.6),
        bottom: pw.BorderSide(color: _rLine, width: 0.6),
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _rBrand),
          children: [for (final i in order) cell(i, headers[i], head: true)],
        ),
        for (var r = 0; r < rows.length; r++)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: r.isOdd ? _rCard : _rWhite),
            children: [
              for (final i in order)
                cell(i, i < rows[r].length ? rows[r][i] : ''),
            ],
          ),
      ],
    );
  }

  /// The five Reports-section PDFs (overview, sales & purchases, money,
  /// inventory, debts) share this template: branded header with the logo,
  /// a meta strip (period · currency · branch · issued), KPI cards, simple
  /// bar/ratio visuals, then one band + zebra table per section. The footer
  /// carries the issue date and «page X of Y» on every page.
  static Future<Uint8List> generateReportPdf({
    required String title,
    required List<Map<String, String>> headers,
    required List<List<String>> rows,
    List<Map<String, String>>? kpis,
    String? footer,
    PdfPageFormat? pageFormat,
    String? subtitle,
    List<String>? subtitleParts,
    List<String>? footerParts,
    List<ReportPdfSection>? sections,
    bool? isAr,
    List<(String, String)>? meta,
    List<ReportPdfChart>? charts,
    String? kpiTitle,
    String? chartsTitle,
    String? notes,
  }) async {
    await _getFontRegular();
    await _getFontBold();
    final logo = await _getLogo();
    final rtl = isAr ??
        _hasArabic(title) ||
            ((sections?.isNotEmpty ?? false) &&
                _hasArabic(sections!.first.title)) ||
            headers.any((h) => _hasArabic(h['label'] ?? ''));
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final issued =
        '${now.year}-${two(now.month)}-${two(now.day)}  ${formatClock(now)}';
    final parts = (subtitleParts != null && subtitleParts.isNotEmpty)
        ? subtitleParts
        : (subtitle ?? '')
            .split('•')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
    final badge = parts.isEmpty ? null : parts.first;
    final metaCells = meta ??
        [
          for (final p in parts)
            p.contains(':')
                ? (p.substring(0, p.indexOf(':')).trim(),
                    p.substring(p.indexOf(':') + 1).trim())
                : ('', p),
          (rtl ? 'تاريخ الإصدار' : 'Issued', issued),
        ];
    final footerText = (footerParts != null && footerParts.isNotEmpty)
        ? footerParts.where((p) => p.trim().isNotEmpty).join('  ·  ')
        : (footer ?? '');
    final allSections = [
      ...?sections,
      if ((sections == null || sections.isEmpty) && rows.isNotEmpty)
        ReportPdfSection(
          title: '',
          headers: headers.map((h) => h['label'] ?? '').toList(),
          rows: rows,
        ),
    ];
    final doc = pw.Document(title: title);
    final textDir = rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;
    doc.addPage(
      pw.MultiPage(
        maxPages: 500,
        pageTheme: pw.PageTheme(
          pageFormat: pageFormat ?? PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 26, 28, 22),
          textDirection: textDir,
          theme: pw.ThemeData.withFont(base: _fontRegular!, bold: _fontBold!),
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Column(children: [
              pw.Container(height: 5, color: _rBrand),
              pw.Spacer(),
              pw.Container(height: 3, color: _rBrand),
            ]),
          ),
        ),
        header: (ctx) => ctx.pageNumber == 1
            ? pw.SizedBox()
            : pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 10),
                padding: const pw.EdgeInsets.only(bottom: 6),
                decoration: const pw.BoxDecoration(
                    border: pw.Border(
                        bottom: pw.BorderSide(color: _rLine, width: 0.8))),
                child: pw.Row(children: [
                  pw.Expanded(
                      child: _rt(title, size: 9, bold: true, color: _rBrand,
                          maxLines: 1)),
                  if (badge != null) _rt(badge, size: 9, color: _rMuted),
                ]),
              ),
        footer: (ctx) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _rLine, width: 0.8))),
          child: pw.Row(children: [
            _rt('FYONA ERP', size: 8, bold: true, color: _rBrand),
            pw.SizedBox(width: 10),
            pw.Expanded(
                child: _rt(footerText, size: 7.5, color: _rMuted, maxLines: 1)),
            pw.SizedBox(width: 10),
            _rt(issued, size: 8, color: _rMuted, ltr: true),
            pw.SizedBox(width: 12),
            _rt(
                rtl
                    ? 'صفحة ${ctx.pageNumber} من ${ctx.pagesCount}'
                    : 'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                size: 8,
                bold: true,
                color: _rBrand),
          ]),
        ),
        build: (ctx) {
          final out = <pw.Widget>[
            _reportHeader(
              title: title,
              subtitle: rtl ? 'تقرير من FYONA ERP' : 'FYONA ERP report',
              badge: badge,
              logo: logo,
            ),
            pw.SizedBox(height: 10),
            if (metaCells.isNotEmpty) ...[
              _reportMeta(metaCells),
              pw.SizedBox(height: 14),
            ],
          ];
          if (kpis != null && kpis.isNotEmpty) {
            out.add(pw.Inseparable(
              child: pw.Column(children: [
                _reportBand(kpiTitle ?? (rtl ? 'ملخص المؤشرات' : 'Key figures')),
                pw.SizedBox(height: 8),
                ..._reportKpis(kpis),
              ]),
            ));
            out.add(pw.SizedBox(height: 14));
          }
          final visuals = [
            for (final c in charts ?? const <ReportPdfChart>[])
              if (c.bars.length > 1 || (!c.ratio && c.bars.isNotEmpty)) c,
          ];
          if (visuals.isNotEmpty) {
            out.add(_reportBand(
                chartsTitle ?? (rtl ? 'نظرة بصرية' : 'At a glance')));
            out.add(pw.SizedBox(height: 8));
            for (var i = 0; i < visuals.length; i += 2) {
              if (visuals.length == 1) {
                out.add(_reportChart(visuals[i], rtl));
                out.add(pw.SizedBox(height: 8));
                continue;
              }
              out.add(pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(child: _reportChart(visuals[i], rtl)),
                  pw.SizedBox(width: 8),
                  pw.Expanded(
                      child: i + 1 < visuals.length
                          ? _reportChart(visuals[i + 1], rtl)
                          : pw.SizedBox()),
                ],
              ));
              out.add(pw.SizedBox(height: 8));
            }
            out.add(pw.SizedBox(height: 6));
          }
          for (final sec in allSections) {
            if (sec.rows.isEmpty) continue;
            final n = sec.headers.length;
            if (sec.title.trim().isNotEmpty) {
              // The band never stays alone at the bottom of a page.
              out.add(pw.Inseparable(
                child: pw.Column(children: [
                  _reportBand(sec.title, trailing: '${sec.rows.length}'),
                  pw.SizedBox(height: 6),
                ]),
              ));
            }
            out.add(_reportTable(
              rtl: rtl,
              headers: n == 0 ? const [''] : sec.headers,
              rows: sec.rows,
            ));
            out.add(pw.SizedBox(height: 16));
          }
          if (notes != null && notes.trim().isNotEmpty) {
            out.add(pw.Container(
              padding: const pw.EdgeInsets.all(9),
              decoration: pw.BoxDecoration(
                  color: _rCard, borderRadius: pw.BorderRadius.circular(8)),
              child: _rt(notes, size: 8, color: _rMuted),
            ));
          }
          return out;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  // ════════════════════════════════════════════════════════════
  //  BANK DETAIL PDF — يطابق ترتيب وتسميات التطبيق تماماً
  // ════════════════════════════════════════════════════════════
  static Future<Uint8List> generateBankReportPdf({
    required String bankName,
    required String period,
    required double totalBalance,
    required double totalIncome,
    required double totalExpense,
    required List<Map<String, dynamic>> categoryData,
    required List<Map<String, dynamic>> transactions,
    required List<Map<String, String>> accountSummary,
    List<Map<String, dynamic>>? dailyData,
    List<Map<String, dynamic>>? incomeExpenseData,
    bool includeCover = true,
    bool includeCharts = true,
    bool includeAccounts = true,
    bool includeTransactions = true,
    String? footer,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          final children = <pw.Widget>[];

          // 1. الهيدر كاملاً — اسم البنك + عدد الحسابات + إجمالي الأرصدة
          if (includeCover) {
            children.add(_buildReportCover(bankName, period, totalBalance, totalIncome, totalExpense));
            children.add(pw.SizedBox(height: 20));
            children.add(_buildKpiCards(totalIncome, totalExpense));
            children.add(pw.SizedBox(height: 24));
          }

          if (includeCharts) {
            // 2. مقارنة الإيرادات والمصروفات
            if (incomeExpenseData != null && incomeExpenseData.isNotEmpty) {
              children.add(_buildSectionTitle(AppLocalizations.t('pdfIncomeVsExpense')));
              children.add(pw.SizedBox(height: 8));
              children.add(_buildIncomeExpenseBarPdf(incomeExpenseData));
              children.add(pw.SizedBox(height: 20));
            }

            // 3. أعلى الفئات إنفاقاً
            if (categoryData.isNotEmpty) {
              children.add(_buildSectionTitle(AppLocalizations.t('pdfTopCategories')));
              children.add(pw.SizedBox(height: 8));
              children.add(_buildPieChartPdf(categoryData));
              children.add(pw.SizedBox(height: 20));
            }

            // 4. المصروفات اليومية
            if (dailyData != null && dailyData.isNotEmpty) {
              children.add(_buildSectionTitle(AppLocalizations.t('pdfDailyExpenses')));
              children.add(pw.SizedBox(height: 8));
              children.add(_buildDailyBarChartPdf(dailyData, height: 120));
              children.add(pw.SizedBox(height: 20));
            }

            // 5. تفاصيل الفئات
            if (categoryData.isNotEmpty) {
              children.add(_buildSectionTitle(AppLocalizations.t('pdfCategoryDetails')));
              children.add(pw.SizedBox(height: 8));
              children.add(_buildCategoryDetailsPdf(categoryData));
              children.add(pw.SizedBox(height: 20));
            }
          }

          if (includeAccounts && accountSummary.isNotEmpty) {
            // 6. توزيع العملات
            final currencyGroups = <String, double>{};
            for (final a in accountSummary) {
              final cur = a['currency'] ?? '';
              final bal = double.tryParse(a['balance']?.replaceAll(',', '') ?? '0') ?? 0;
              currencyGroups[cur] = (currencyGroups[cur] ?? 0) + bal;
            }
            if (currencyGroups.length > 1) {
              children.add(_buildSectionTitle(AppLocalizations.t('currencyDistribution')));
              children.add(pw.SizedBox(height: 8));
              final curData = currencyGroups.entries.map((e) => {'label': e.key, 'value': e.value}).toList();
              children.add(_buildPieChartPdf(curData));
              children.add(pw.SizedBox(height: 20));
            }

            // 7. الحسابات
            children.add(_buildSectionTitle(AppLocalizations.t('pdfAccounts')));
            children.add(pw.SizedBox(height: 8));
            children.add(
              pw.TableHelper.fromTextArray(
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF), fontSize: 9),
                headerDecoration: pw.BoxDecoration(color: pdfColor(0xFFA01530)),
                cellStyle: const pw.TextStyle(fontSize: 9),
                cellAlignment: pw.Alignment.centerLeft,
                headers: [AppLocalizations.t('currencyLabel'), AppLocalizations.t('treeTypeLabel'), AppLocalizations.t('balanceLabel'), AppLocalizations.t('pdfNotes')],
                data: accountSummary.map((r) => [r['currency'] ?? '', r['type'] ?? '', r['balance'] ?? '', r['notes'] ?? '']).toList(),
              ),
            );
            children.add(pw.SizedBox(height: 20));
          }

          if (includeTransactions && transactions.isNotEmpty) {
            // 8. المعاملات
            children.add(_buildSectionTitle(AppLocalizations.t('homeServiceTransactions')));
            children.add(pw.SizedBox(height: 8));
            children.add(
              pw.TableHelper.fromTextArray(
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF), fontSize: 8),
                headerDecoration: pw.BoxDecoration(color: pdfColor(0xFFA01530)),
                cellStyle: const pw.TextStyle(fontSize: 8),
                cellAlignment: pw.Alignment.centerLeft,
                headers: [AppLocalizations.t('date'), AppLocalizations.t('treeTypeLabel'), AppLocalizations.t('categoryLabel'), AppLocalizations.t('description'), AppLocalizations.t('amountLabel')],
                data: transactions.map((r) => [
                  r['date'] ?? '', r['type'] ?? '', r['category'] ?? '',
                  r['description'] ?? '', r['amount'] ?? '',
                ]).toList(),
              ),
            );
          }

          if (footer != null) {
            children.add(pw.SizedBox(height: 24));
            children.add(pw.Center(child: _pdfText(footer, style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFF999999)))));
          }

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  // ════════════════════════════════════════════════════════════
  //  ALL BANKS REPORT PDF WITH COMPARISON CHART
  // ════════════════════════════════════════════════════════════
  static Future<Uint8List> generateAllBanksReportPdf({
    required String period,
    required double totalBalance,
    required double totalIncome,
    required double totalExpense,
    required List<Map<String, dynamic>> banks,
    String? footer,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          final children = <pw.Widget>[];

          children.add(_buildReportCover(AppLocalizations.t('pdfBanksReport'), period, totalBalance, totalIncome, totalExpense));
          children.add(pw.SizedBox(height: 20));

          children.add(_buildKpiRow([
            {'label': AppLocalizations.t('totalBalances'), 'value': _fmtNumPdf(totalBalance)},
            {'label': AppLocalizations.t('revenue'), 'value': _fmtNumPdf(totalIncome)},
            {'label': AppLocalizations.t('pdfExpenses'), 'value': _fmtNumPdf(totalExpense)},
            {'label': AppLocalizations.t('pdfBanksCount'), 'value': '${banks.length}'},
          ]));
          children.add(pw.SizedBox(height: 24));

          if (banks.length > 1) {
            children.add(_buildSectionTitle(AppLocalizations.t('pdfBanksCompare')));
            children.add(pw.SizedBox(height: 8));
            final bankChartData = banks.map((b) => {'label': b['name'] ?? '', 'value': (b['balance'] as num?)?.toDouble() ?? 0}).toList();
            children.add(_buildBarChartPdf(bankChartData, height: 100));
            children.add(pw.SizedBox(height: 16));
            children.add(_buildPieChartPdf(bankChartData));
            children.add(pw.SizedBox(height: 20));
          }

          children.add(_buildSectionTitle(AppLocalizations.t('pdfBanksDetails')));
          children.add(pw.SizedBox(height: 8));
          children.add(
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF), fontSize: 9),
              headerDecoration: pw.BoxDecoration(color: pdfColor(0xFFA01530)),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              headers: [AppLocalizations.t('pdfBank'), AppLocalizations.t('pdfAccounts'), AppLocalizations.t('balanceLabel'), AppLocalizations.t('revenue'), AppLocalizations.t('pdfExpenses'), AppLocalizations.t('homeServiceTransactions')],
              data: banks.map((b) => [
                b['name'] ?? '', '${b['accounts'] ?? 0}', _fmtNumPdf((b['balance'] as num?)?.toDouble() ?? 0),
                _fmtNumPdf((b['income'] as num?)?.toDouble() ?? 0), _fmtNumPdf((b['expense'] as num?)?.toDouble() ?? 0),
                '${b['transactions'] ?? 0}',
              ]).toList(),
            ),
          );

          if (footer != null) {
            children.add(pw.SizedBox(height: 24));
            children.add(pw.Center(child: _pdfText(footer, style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFF999999)))));
          }

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  // ════════════════════════════════════════════════════════════
  //  CHART DRAWING HELPERS (safe pdf widgets)
  // ════════════════════════════════════════════════════════════
  static pw.Widget _buildBarChartPdf(List<Map<String, dynamic>> data, {double height = 120, double width = 480}) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: data.asMap().entries.map((entry) {
        final i = entry.key;
        final d = entry.value;
        final val = (d['value'] as num?)?.toDouble() ?? 0;
        final pct = val / maxVal;
        final label = d['label'] ?? '';
        final color = pdfColor(_chartColors[i % _chartColors.length]);

        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Row(
            children: [
              pw.SizedBox(
                width: 80,
                child: _pdfText(label, style: const pw.TextStyle(fontSize: 8)),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.Container(
                  height: 18,
                  child: pw.Stack(
                    children: [
                      pw.Container(
                        decoration: pw.BoxDecoration(
                          color: pdfColor(0xFFF0F0F0),
                          borderRadius: pw.BorderRadius.circular(3),
                        ),
                      ),
                      pw.Container(
                        width: (width - 120) * pct,
                        height: 18,
                        decoration: pw.BoxDecoration(
                          color: color,
                          borderRadius: pw.BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.SizedBox(
                width: 50,
                child: _pdfText(_fmtNumPdf(val), style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.right),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  static pw.Widget _buildPieChartPdf(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final total = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).fold(0.0, (a, b) => a + b);
    if (total == 0) return pw.SizedBox.shrink();

    final slices = <pw.Widget>[];
    for (int i = 0; i < data.length; i++) {
      final val = (data[i]['value'] as num?)?.toDouble() ?? 0;
      final pct = val / total;
      final color = pdfColor(_chartColors[i % _chartColors.length]);
      final label = data[i]['label'] ?? '';

      slices.add(
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          margin: const pw.EdgeInsets.only(bottom: 3),
          decoration: pw.BoxDecoration(
            color: color,
            borderRadius: pw.BorderRadius.circular(3),
          ),
          child: pw.Row(
            children: [
              _pdfText(label, style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFFFFFFFF))),
              pw.SizedBox(width: 8),
              _pdfText('${(pct * 100).toStringAsFixed(1)}%', style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFFFFFFFF))),
              pw.SizedBox(width: 4),
              _pdfText(_fmtNumPdf(val), style: pw.TextStyle(fontSize: 8, color: pdfColor(0xEEFFFFFF))),
            ],
          ),
        ),
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: slices,
    );
  }

  // ════════════════════════════════════════════════════════════
  //  INCOME/EXPENSE COMPARISON BAR CHART
  // ════════════════════════════════════════════════════════════
  static pw.Widget _buildIncomeExpenseBarPdf(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    final incomeColor = pdfColor(0xFF2E7D32);
    final expenseColor = pdfColor(0xFFC62828);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: data.asMap().entries.map((entry) {
        final i = entry.key;
        final d = entry.value;
        final val = (d['value'] as num?)?.toDouble() ?? 0;
        final pct = val / maxVal;
        final label = d['label'] ?? '';
        final color = i == 0 ? incomeColor : expenseColor;

        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Row(
            children: [
              pw.SizedBox(width: 80, child: _pdfText(label, style: const pw.TextStyle(fontSize: 10))),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.Container(
                  height: 24,
                  child: pw.Stack(
                    children: [
                      pw.Container(
                        decoration: pw.BoxDecoration(color: pdfColor(0xFFF0F0F0), borderRadius: pw.BorderRadius.circular(4)),
                      ),
                      pw.Container(
                        width: (460 - 160) * pct,
                        height: 24,
                        decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.SizedBox(width: 60, child: _pdfText(_fmtNumPdf(val), style: const pw.TextStyle(fontSize: 10), textAlign: pw.TextAlign.right)),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  DAILY EXPENSE BAR CHART
  // ════════════════════════════════════════════════════════════
  static pw.Widget _buildDailyBarChartPdf(List<Map<String, dynamic>> data, {double height = 120, double width = 460}) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    final maxBars = data.length > 15 ? 15 : data.length;
    final sorted = List<Map<String, dynamic>>.from(data)..sort((a, b) => ((a['label'] ?? '0') as String).compareTo(b['label'] ?? '0'));
    final top = sorted.take(maxBars).toList();

    double barWidth = (width - 40) / top.length;
    if (barWidth > 28) barWidth = 28;
    if (barWidth < 8) barWidth = 8;

    return pw.Container(
      height: height,
      padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: top.map((d) {
          final val = (d['value'] as num?)?.toDouble() ?? 0;
          final barH = maxVal > 0 ? (val / maxVal) * (height - 40) : 0.0;
          final day = d['label'] ?? '';
          return pw.Expanded(
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                _pdfText(_fmtNumPdf(val), style: const pw.TextStyle(fontSize: 6)),
                pw.SizedBox(height: 2),
                pw.Container(
                  width: barWidth,
                  height: barH,
                  decoration: pw.BoxDecoration(
                    color: pdfColor(_chartColors[2]),
                    borderRadius: const pw.BorderRadius.vertical(top: pw.Radius.circular(3)),
                  ),
                ),
                pw.SizedBox(height: 2),
                _pdfText(day, style: const pw.TextStyle(fontSize: 6)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  CATEGORY DETAILS (تفاصيل الفئات)
  // ════════════════════════════════════════════════════════════
  static pw.Widget _buildCategoryDetailsPdf(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final total = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).fold(0.0, (a, b) => a + b);
    if (total == 0) return pw.SizedBox.shrink();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: data.take(8).map((d) {
        final val = (d['value'] as num?)?.toDouble() ?? 0;
        final pct = total > 0 ? val / total : 0.0;
        final label = d['label'] ?? '';
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  _pdfText(label, style: const pw.TextStyle(fontSize: 9)),
                  pw.SizedBox(width: 8),
                  _pdfText(_fmtNumPdf(val), style: const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(width: 4),
                  _pdfText('(${(pct * 100).toStringAsFixed(1)}%)', style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFF999999))),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Container(
                height: 8,
                decoration: pw.BoxDecoration(
                  color: pdfColor(0xFFF0F0F0),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Stack(
                  children: [
                    pw.Container(
                      width: 400 * pct,
                      height: 8,
                      decoration: pw.BoxDecoration(
                        color: pdfColor(0xFFA01530),
                        borderRadius: pw.BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  LAYOUT HELPERS
  // ════════════════════════════════════════════════════════════
  static pw.Widget _buildHeader(String title) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
            color: pdfColor(0xFFA01530),
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: _pdfText(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF))),
        ),
      ],
    );
  }

  static pw.Widget _buildReportCover(String title, String period, double balance, double income, double expense) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(20),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(
          colors: [pdfColor(0xFFC01838), pdfColor(0xFFA01530), pdfColor(0xFF7A1020)],
        ),
        borderRadius: pw.BorderRadius.circular(12),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _pdfText(title, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF))),
          pw.SizedBox(height: 4),
          _pdfText(period, style: pw.TextStyle(fontSize: 10, color: pdfColor(0xCCFFFFFF))),
          pw.SizedBox(height: 16),
          _pdfText(AppLocalizations.t('totalBalances'), style: pw.TextStyle(fontSize: 10, color: pdfColor(0x99FFFFFF))),
          _pdfText(_fmtNumPdf(balance), style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF))),
        ],
      ),
    );
  }

  static pw.Widget _buildKpiCards(double income, double expense) {
    final net = income - expense;
    return pw.Row(
      children: [
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(12),
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            decoration: pw.BoxDecoration(color: pdfColor(0xFFF5F5F5), borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pdfText(AppLocalizations.t('revenue'), style: pw.TextStyle(fontSize: 9, color: pdfColor(0xFF888888))),
                pw.SizedBox(height: 4),
                _pdfText(_fmtNumPdf(income), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFF2E7D32))),
              ],
            ),
          ),
        ),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(12),
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            decoration: pw.BoxDecoration(color: pdfColor(0xFFF5F5F5), borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pdfText(AppLocalizations.t('pdfExpenses'), style: pw.TextStyle(fontSize: 9, color: pdfColor(0xFF888888))),
                pw.SizedBox(height: 4),
                _pdfText(_fmtNumPdf(expense), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFC62828))),
              ],
            ),
          ),
        ),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(12),
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            decoration: pw.BoxDecoration(color: pdfColor(0xFFF5F5F5), borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pdfText(AppLocalizations.t('pdfNet'), style: pw.TextStyle(fontSize: 9, color: pdfColor(0xFF888888))),
                pw.SizedBox(height: 4),
                _pdfText(_fmtNumPdf(net), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: pdfColor(net >= 0 ? 0xFFA01530 : 0xFFC62828))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildSectionTitle(String title) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 4),
      decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: pdfColor(0xFFA01530), width: 1.5))),
      child: _pdfText(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFA01530))),
    );
  }

  static pw.Widget _buildKpiRow(List<Map<String, String>> kpis) {
    return pw.Row(
      children: kpis.map((kpi) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(12),
          margin: const pw.EdgeInsets.symmetric(horizontal: 3),
          decoration: pw.BoxDecoration(
            color: pdfColor(0xFFF5F5F5),
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _pdfText(kpi['label'] ?? '', style: pw.TextStyle(fontSize: 8, color: pdfColor(0xFF888888))),
              pw.SizedBox(height: 3),
              _pdfText(kpi['value'] ?? '', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFA01530))),
            ],
          ),
        ),
      )).toList(),
    );
  }

  static String _fmtNumPdf(double value) => fmtNum(value);

  // ════════════════════════════════════════════════════════════
  //  INVOICE PDF (existing)
  // ════════════════════════════════════════════════════════════
  static Future<Uint8List> generateInvoicePdf({
    required ReceiptData data,
    required DocumentConfig config,
  }) async {
    final renderer = PdfReceiptRenderer(data: data, config: config);
    return Uint8List.fromList(await renderer.save());
  }

  static Future<Uint8List> generateExecutivePdf({
    required String title,
    required String period,
    required List<Map<String, String>> summaryKpis,
    required List<Map<String, String>> tableHeaders,
    required List<List<String>> tableRows,
    List<pw.Widget>? charts,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          final children = <pw.Widget>[];
          children.add(_buildHeader(title));
          children.add(pw.SizedBox(height: 8));
          children.add(_pdfText(AppLocalizations.t('pdfPeriod', {'period': period}), style: pw.TextStyle(fontSize: 10, color: pdfColor(0xFF666666))));
          children.add(pw.SizedBox(height: 20));

          children.add(_buildKpiRow(summaryKpis));
          children.add(pw.SizedBox(height: 24));

          if (charts != null && charts.isNotEmpty) {
            children.addAll(charts);
            children.add(pw.SizedBox(height: 24));
          }

          children.add(
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF), fontSize: 9),
              headerDecoration: pw.BoxDecoration(color: pdfColor(0xFFA01530)),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.centerLeft,
              headers: tableHeaders.map((h) => h['label'] ?? '').toList(),
              data: tableRows.map((r) => r).toList(),
            ),
          );

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }
}






/// The PDF writer does not apply the font's spacing after a final «ر»/«ز»
/// (their tail covers the space: «آخر الحركات» printed as «آخرالحركات»).
/// One extra space there keeps the words apart, exactly as on screen.
final _tailSpace = RegExp('([\u0631\u0632\u0698]) ');

pw.Text _pdfText(
  String text, {
  pw.TextStyle? style,
  pw.TextAlign? textAlign,
  int? maxLines,
  pw.TextDirection? textDirection,
}) => pw.Text(
  text.replaceAllMapped(_tailSpace, (m) => '${m[1]}  '),
  style: style,
  textAlign: textAlign,
  maxLines: maxLines,
  textDirection: textDirection,
);
