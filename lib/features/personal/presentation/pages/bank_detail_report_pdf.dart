import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart' as intl;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/bank_detail/bank_detail_data.dart';
import '../../../../core/utils/time_format.dart';

/// Translation callback: `tr('key', {'param': 'value'})`.
typedef BankPdfTr = String Function(String key, [Map<String, String>? params]);

/// The bank-detail PDF (Personal + Business banks): FYONA-branded header,
/// report meta strip, KPI boxes, per-currency sections, in/out analysis,
/// clean movements table and a footer with issue date + page numbers.
///
/// Content follows [BankReportRequest]: full / summary / movements / flow,
/// for one currency or the whole bank.
class BankDetailReportPdf {
  BankDetailReportPdf._();

  static const _brand = PdfColor.fromInt(0xFFB00020);
  static const _brandDeep = PdfColor.fromInt(0xFF8C0A1C);
  static const _brandSoft = PdfColor.fromInt(0xFFFBEFF1);
  static const _ink = PdfColor.fromInt(0xFF1A1A1A);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _line = PdfColor.fromInt(0xFFE5E7EB);
  static const _card = PdfColor.fromInt(0xFFF7F7F9);
  static const _in = PdfColor.fromInt(0xFF2E7D32);
  static const _inSoft = PdfColor.fromInt(0xFFE8F3E9);
  static const _out = PdfColor.fromInt(0xFFC62828);
  static const _outSoft = PdfColor.fromInt(0xFFFBEAEA);
  static const _count = PdfColor.fromInt(0xFF1565C0);
  static const _white = PdfColor.fromInt(0xFFFFFFFF);

  static pw.Font? _regular;
  static pw.Font? _bold;
  static Uint8List? _logo;

  static Future<void> _loadAssets() async {
    _regular ??=
        pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
    if (_logo == null) {
      try {
        _logo = (await rootBundle.load('assets/images/fyona_report_logo.png'))
            .buffer
            .asUint8List();
      } catch (_) {
        _logo = Uint8List(0);
      }
    }
  }

  static final _nf = intl.NumberFormat('#,##0.00', 'en');
  static String _n(double v) => _nf.format(v);
  static String _date(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  /// The PDF writer drops the space after a final «ر»/«ز» («آخر الحركات»
  /// printed as «آخرالحركات»); one extra space keeps the words apart.
  static final _tailSpace = RegExp('([رزژ]) ');
  static final _arabic = RegExp(r'[\u0600-\u06FF]');

  /// Same writer quirk between an Arabic word and a number on either side
  /// («صفحة 1 من 5» printed as «صفحة1 من5»).
  static final _spaceDigit = RegExp(
      r'(?:(?<=[\u0600-\u06FF]) (?=[0-9])|(?<=[0-9]) (?=[\u0600-\u06FF]))');

  static pw.Widget _t(
    String text, {
    double size = 9,
    bool bold = false,
    PdfColor color = _ink,
    pw.TextAlign? align,
    int? maxLines,
    bool ltr = false,
  }) =>
      pw.Text(
        text
            .replaceAllMapped(_tailSpace, (m) => '${m[1]}  ')
            .replaceAll(_spaceDigit, '  '),
        textAlign: align,
        maxLines: maxLines,
        // Arabic is only shaped in RTL runs: forcing LTR on Arabic would
        // embed unshaped letters that share glyphs with the shaped forms and
        // corrupt the font subset, so LTR is applied to Latin/digits only.
        textDirection: _arabic.hasMatch(text)
            ? pw.TextDirection.rtl
            : (ltr ? pw.TextDirection.ltr : null),
        style: pw.TextStyle(
          font: bold ? _bold : _regular,
          fontBold: _bold,
          fontSize: size,
          color: color,
        ),
      );

  static Future<Uint8List> generate({
    required BankReportBundle bundle,
    required BankPdfTr tr,
    required bool isAr,
    String? footerText,
  }) async {
    await _loadAssets();
    final logo = (_logo?.isEmpty ?? true) ? null : _logo;
    final req = bundle.request;
    final lang = isAr ? 'ar' : 'en';
    final rtl = isAr;
    final now = DateTime.now();
    final issued =
        '${_date(now)}  ${formatClock(now, locale: lang)}';
    final title = tr(switch (req.content) {
      BankReportContent.full => 'bdvPdfTitleFull',
      BankReportContent.summary => 'bdvPdfTitleSummary',
      BankReportContent.movements => 'bdvPdfTitleMovements',
      BankReportContent.flow => 'bdvPdfTitleFlow',
    });
    String curName(String c) => currencyName(c, locale: lang);
    final scope = req.allCurrencies
        ? tr('allCurrencies')
        : (bundle.sections.isEmpty
            ? ''
            : curName(bundle.sections.first.currency));

    final doc = pw.Document(title: '$title — ${bundle.bankName}');
    final textDir = rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 26, 28, 22),
        textDirection: textDir,
        theme: pw.ThemeData.withFont(base: _regular, bold: _bold),
        buildBackground: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Column(children: [
            pw.Container(height: 5, color: _brand),
            pw.Spacer(),
            pw.Container(height: 3, color: _brand),
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
                      bottom: pw.BorderSide(color: _line, width: 0.8))),
              child: pw.Row(children: [
                _t(title, size: 9, bold: true, color: _brand),
                pw.SizedBox(width: 8),
                _t('•', size: 9, color: _muted),
                pw.SizedBox(width: 8),
                pw.Expanded(
                    child: _t(bundle.bankName,
                        size: 9, color: _muted, maxLines: 1)),
                _t(bundle.period, size: 9, color: _muted),
              ]),
            ),
      footer: (ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 10),
        padding: const pw.EdgeInsets.only(top: 6),
        decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _line, width: 0.8))),
        child: pw.Row(children: [
          _t(
              (footerText ?? '').trim().isNotEmpty
                  ? footerText!.trim()
                  : tr('bdvPdfFooter'),
              size: 8,
              color: _muted),
          pw.Spacer(),
          _t(issued, size: 8, color: _muted, ltr: true),
          pw.SizedBox(width: 14),
          _t(
              tr('bdvPdfPage', {
                'page': '${ctx.pageNumber}',
                'pages': '${ctx.pagesCount}',
              }),
              size: 8,
              bold: true,
              color: _brand),
        ]),
      ),
      build: (ctx) {
        final out = <pw.Widget>[
          _header(title: title, bank: bundle.bankName, period: bundle.period,
              logo: logo),
          pw.SizedBox(height: 10),
          _metaStrip([
            (tr('bdvPdfBank'), bundle.bankName),
            (tr('bdvPdfPeriod'), bundle.period),
            (tr('bdvPdfScope'), scope),
            (tr('bdvPdfIssued'), issued),
          ]),
          pw.SizedBox(height: 16),
        ];

        final combined = bundle.combined;
        if (combined != null && (req.withSummary || req.withFlow)) {
          // Band + KPIs stay together (never a lonely title at a page end).
          out.add(pw.Inseparable(child: pw.Column(children: [
            _sectionBand(tr('bdvPdfOverview'),
                tr('bdvPdfConverted', {'currency': currencyShort(combined.displayCurrency)})),
            pw.SizedBox(height: 10),
            _kpis(combined, tr),
          ])));
          out.add(pw.SizedBox(height: 10));
          out.addAll(_table(
            rtl: rtl,
            headers: [
              tr('bdvPdfColCurrency'),
              tr('bdvAccounts'),
              tr('bdvPdfColBalance'),
              tr('bdvIn'),
              tr('bdvOut'),
              tr('net'),
              tr('bdvMovementsCount'),
            ],
            flex: const [2.2, 1, 1.6, 1.5, 1.5, 1.5, 1],
            numeric: const [false, true, true, true, true, true, true],
            colors: const [null, null, null, _in, _out, null, null],
            rows: [
              for (final s in bundle.sections)
                [
                  '${curName(s.currency)} (${currencyShort(s.currency)})',
                  '${s.accounts.length}',
                  _n(s.balance),
                  _n(s.totalIn),
                  _n(s.totalOut),
                  _n(s.net),
                  '${s.count}',
                ],
            ],
          ));
          out.add(pw.SizedBox(height: 18));
        }

        for (var i = 0; i < bundle.sections.length; i++) {
          final s = bundle.sections[i];
          final code = currencyShort(s.currency);
          if (i > 0 || combined != null) out.add(pw.SizedBox(height: 6));
          out.add(pw.Inseparable(child: pw.Column(children: [
            _sectionBand(
                tr('bdvPdfCurrencySection', {'currency': curName(s.currency)}),
                code),
            pw.SizedBox(height: 10),
            _kpis(s, tr),
          ])));
          out.add(pw.SizedBox(height: 10));
          if (req.withSummary || req.withFlow) {
            out.add(_ratio(s, tr));
            out.add(pw.SizedBox(height: 12));
          }
          if (req.withSummary && s.accounts.isNotEmpty) {
            out.add(_subTitle(tr('bankAccountsTitle')));
            out.add(pw.SizedBox(height: 6));
            out.addAll(_table(
              rtl: rtl,
              headers: [
                tr('bdvPdfColType'),
                tr('bdvPdfColCurrency'),
                tr('bdvPdfColNote'),
                tr('bdvPdfColBalance'),
              ],
              flex: const [1.6, 1, 2.4, 1.6],
              numeric: const [false, false, false, true],
              rows: [
                for (final a in s.accounts)
                  [
                    a.typeLabel,
                    currencyShort(a.currency),
                    (a.note ?? '').trim().isEmpty ? '—' : a.note!.trim(),
                    _n(a.balance),
                  ],
              ],
              totals: s.isAll ? null : [tr('bdvPdfTotal'), code, '', _n(s.balance)],
            ));
            out.add(pw.SizedBox(height: 14));
          }
          if (req.withFlow && s.count > 0) {
            out.add(_breakdown(s, tr));
            out.add(pw.SizedBox(height: 12));
            out.add(_subTitle(tr('bdvDailyFlow')));
            out.add(pw.SizedBox(height: 6));
            out.add(_daily(s, tr));
            out.add(pw.SizedBox(height: 14));
          }

          if (req.withMovements) {
            out.add(_subTitle(tr('bdvMovements')));
            out.add(pw.SizedBox(height: 6));
            if (s.movements.isEmpty) {
              out.add(_empty(tr('bdvNoMovements')));
            } else {
              out.addAll(_table(
                rtl: rtl,
                headers: [
                  '#',
                  tr('bdvPdfColDate'),
                  tr('bdvPdfColKind'),
                  tr('bdvPdfColDetails'),
                  tr('bdvIn'),
                  tr('bdvOut'),
                ],
                flex: const [0.5, 1.25, 1.5, 3, 1.35, 1.35],
                numeric: const [true, true, false, false, true, true],
                colors: const [_muted, null, null, null, _in, _out],
                rows: [
                  for (var k = 0; k < s.movements.length; k++)
                    () {
                      final m = s.movements[k];
                      final details = [
                        if ((m.category ?? '').trim().isNotEmpty)
                          m.category!.trim(),
                        if ((m.note ?? '').trim().isNotEmpty) m.note!.trim(),
                      ].join(' — ');
                      final amount = _n(m.amount.abs());
                      final foreign = s.isAll && m.currency != s.displayCurrency
                          ? ' ${currencyShort(m.currency)}'
                          : '';
                      return [
                        '${k + 1}',
                        m.date == null ? '—' : _date(m.date!),
                        m.title,
                        details.isEmpty ? '—' : details,
                        m.isIn ? '$amount$foreign' : '',
                        m.isIn ? '' : '$amount$foreign',
                      ];
                    }(),
                ],
                totals: [
                  '',
                  '',
                  tr('bdvPdfTotal'),
                  '${s.count}  ·  ${tr('net')}: ${_n(s.net)} $code',
                  _n(s.totalIn),
                  _n(s.totalOut),
                ],
              ));
              out.add(pw.SizedBox(height: 14));
            }
          }
        }
        return out;
      },
    ));
    return Uint8List.fromList(await doc.save());
  }

  // ── Header ──────────────────────────────────────────────
  static pw.Widget _header({
    required String title,
    required String bank,
    required String period,
    required Uint8List? logo,
  }) {
    final chip = logo == null
        ? pw.SizedBox()
        : pw.Container(
            width: 52,
            height: 52,
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(
                color: _white, borderRadius: pw.BorderRadius.circular(12)),
            child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
          );
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: pw.BoxDecoration(
        gradient: const pw.LinearGradient(
          begin: pw.Alignment.topLeft,
          end: pw.Alignment.bottomRight,
          colors: [PdfColor.fromInt(0xFFC81E3A), _brand, _brandDeep],
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
              _t(title, size: 19, bold: true, color: _white),
              pw.SizedBox(height: 2),
              _t(bank, size: 11.5, bold: true,
                  color: const PdfColor.fromInt(0xF2FFFFFF), maxLines: 1),
            ],
          ),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: pw.BoxDecoration(
            color: _brandDeep,
            borderRadius: pw.BorderRadius.circular(9),
          ),
          child: _t(period, size: 9.5, bold: true, color: _white),
        ),
      ]),
    );
  }

  static pw.Widget _metaStrip(List<(String, String)> cells) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _card,
        border: pw.Border.all(color: _line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(10),
      ),
      padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: pw.Row(children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) pw.Container(width: 0.7, height: 26, color: _line),
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _t(cells[i].$1, size: 7.5, color: _muted),
                  pw.SizedBox(height: 1),
                  _t(cells[i].$2,
                      size: 9.5, bold: true, maxLines: 1, ltr: i == 3),
                ],
              ),
            ),
          ),
        ],
      ]),
    );
  }

  static pw.Widget _sectionBand(String title, String trailing) {
    return pw.Container(
      decoration: pw.BoxDecoration(
          color: _brandSoft, borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Row(children: [
        pw.Container(
          width: 4,
          height: 30,
          decoration: pw.BoxDecoration(
              color: _brand, borderRadius: pw.BorderRadius.circular(2)),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(child: _t(title, size: 12, bold: true, color: _brand)),
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(horizontal: 10),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: pw.BoxDecoration(
              color: _brand, borderRadius: pw.BorderRadius.circular(10)),
          child: _t(trailing, size: 8.5, bold: true, color: _white, ltr: true),
        ),
      ]),
    );
  }

  static pw.Widget _subTitle(String text) => pw.Row(children: [
        pw.Container(
          width: 7,
          height: 7,
          decoration:
              const pw.BoxDecoration(color: _brand, shape: pw.BoxShape.circle),
        ),
        pw.SizedBox(width: 6),
        _t(text, size: 10.5, bold: true),
      ]);

  static pw.Widget _empty(String text) => pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 14),
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(
            color: _card, borderRadius: pw.BorderRadius.circular(8)),
        child: _t(text, size: 9.5, color: _muted),
      );

  // ── KPI boxes ───────────────────────────────────────────
  static pw.Widget _kpis(BankCurrencyFigures f, BankPdfTr tr) {
    const balance = true;
    final code = currencyShort(f.displayCurrency);
    final items = <(String, String, String, PdfColor)>[
      if (balance)
        (f.isAll ? tr('totalBalances') : tr('bdvPdfColBalance'),
            _n(f.balance), code, _brand),
      (tr('bdvTotalIn'), _n(f.totalIn), code, _in),
      (tr('bdvTotalOut'), _n(f.totalOut), code, _out),
      (tr('net'), _n(f.net), code, f.net >= 0 ? _ink : _out),
      (tr('bdvMovementsCount'), '${f.count}', '', _count),
    ];
    return pw.Row(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) pw.SizedBox(width: 6),
        pw.Expanded(
          flex: i == 0 && balance ? 13 : (i == items.length - 1 ? 8 : 11),
          child: pw.Container(
            decoration: pw.BoxDecoration(
              color: _white,
              border: pw.Border.all(color: _line, width: 0.8),
              borderRadius: pw.BorderRadius.circular(9),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Container(
                  height: 3,
                  decoration: pw.BoxDecoration(
                    color: items[i].$4,
                    borderRadius: const pw.BorderRadius.only(
                        topLeft: pw.Radius.circular(9),
                        topRight: pw.Radius.circular(9)),
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      _t(items[i].$1, size: 7.5, color: _muted, maxLines: 1),
                      pw.SizedBox(height: 3),
                      _t(items[i].$2,
                          size: 12, bold: true, color: items[i].$4, ltr: true,
                          maxLines: 1),
                      if (items[i].$3.isNotEmpty)
                        _t(items[i].$3, size: 7, color: _muted, ltr: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ]);
  }

  static pw.Widget _ratio(BankCurrencyFigures f, BankPdfTr tr) {
    final total = f.totalIn + f.totalOut;
    final inShare = total <= 0 ? 0.5 : f.totalIn / total;
    final inPct = total <= 0 ? 0 : (inShare * 100).round();
    final outPct = total <= 0 ? 0 : 100 - inPct;
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
          color: _card, borderRadius: pw.BorderRadius.circular(9)),
      child: pw.Column(children: [
        pw.Row(children: [
          _dot(_in),
          pw.SizedBox(width: 5),
          _t('${tr('bdvIn')}  ', size: 8.5, color: _muted),
          _t('$inPct%', size: 9, bold: true, color: _in, ltr: true),
          pw.Spacer(),
          _t(tr('bdvInOutFlow'), size: 8.5, bold: true),
          pw.Spacer(),
          _t('$outPct%', size: 9, bold: true, color: _out, ltr: true),
          _t('  ${tr('bdvOut')}', size: 8.5, color: _muted),
          pw.SizedBox(width: 5),
          _dot(_out),
        ]),
        pw.SizedBox(height: 6),
        pw.ClipRRect(
          horizontalRadius: 4,
          verticalRadius: 4,
          child: pw.SizedBox(
            height: 9,
            child: total <= 0
                ? pw.Container(color: _line)
                : pw.Row(children: [
                    if (inShare > 0)
                      pw.Expanded(
                          flex: math.max(1, (inShare * 1000).round()),
                          child: pw.Container(color: _in)),
                    if (inShare < 1)
                      pw.Expanded(
                          flex: math.max(1, ((1 - inShare) * 1000).round()),
                          child: pw.Container(color: _out)),
                  ]),
          ),
        ),
      ]),
    );
  }

  static pw.Widget _dot(PdfColor c) => pw.Container(
      width: 7,
      height: 7,
      decoration: pw.BoxDecoration(color: c, shape: pw.BoxShape.circle));

  // ── In / out breakdown ──────────────────────────────────
  static pw.Widget _breakdown(BankCurrencyFigures f, BankPdfTr tr) {
    pw.Widget panel(String title, Map<String, double> data, double total,
        PdfColor color, PdfColor soft) {
      final rows = data.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: _white,
          border: pw.Border.all(color: _line, width: 0.8),
          borderRadius: pw.BorderRadius.circular(9),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Row(children: [
              pw.Expanded(
                  child: _t(title, size: 10, bold: true, color: color)),
              _t(_n(total), size: 10, bold: true, color: color, ltr: true),
            ]),
            pw.SizedBox(height: 8),
            if (rows.isEmpty) _t('—', size: 9, color: _muted),
            for (final e in rows.take(7)) ...[
              pw.Row(children: [
                pw.Expanded(child: _t(e.key, size: 8.5, maxLines: 1)),
                _t(_n(e.value), size: 8.5, bold: true, ltr: true),
                pw.SizedBox(width: 6),
                pw.SizedBox(
                  width: 28,
                  child: _t(
                      '${total > 0 ? (e.value / total * 100).round() : 0}%',
                      size: 7.5,
                      color: _muted,
                      ltr: true,
                      align: pw.TextAlign.right),
                ),
              ]),
              pw.SizedBox(height: 2),
              pw.ClipRRect(
                horizontalRadius: 2,
                verticalRadius: 2,
                child: pw.SizedBox(
                  height: 4,
                  child: pw.Row(children: [
                    pw.Expanded(
                        flex: math.max(
                            1, total > 0 ? (e.value / total * 1000).round() : 0),
                        child: pw.Container(color: color)),
                    pw.Expanded(
                        flex: math.max(
                            1,
                            total > 0
                                ? 1000 - (e.value / total * 1000).round()
                                : 1000),
                        child: pw.Container(color: soft)),
                  ]),
                ),
              ),
              pw.SizedBox(height: 6),
            ],
          ],
        ),
      );
    }

    return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Expanded(
          child: panel(tr('bdvTopIn'), f.inByKey, f.totalIn, _in, _inSoft)),
      pw.SizedBox(width: 8),
      pw.Expanded(
          child:
              panel(tr('bdvTopOut'), f.outByKey, f.totalOut, _out, _outSoft)),
    ]);
  }

  // ── Daily flow chart ────────────────────────────────────
  static pw.Widget _daily(BankCurrencyFigures f, BankPdfTr tr) {
    final d0 = f.movements
        .map((m) => m.date)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a ?? b);
    final days = d0 == null ? 31 : DateTime(d0.year, d0.month + 1, 0).day;
    var maxV = 0.0;
    for (var d = 1; d <= days; d++) {
      maxV = math.max(maxV, math.max(f.dailyIn[d] ?? 0, f.dailyOut[d] ?? 0));
    }
    const chartH = 90.0;
    double h(double v) => maxV <= 0 ? 0 : math.max(v > 0 ? 1.5 : 0, v / maxV * chartH);
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(10, 10, 10, 6),
      decoration: pw.BoxDecoration(
        color: _white,
        border: pw.Border.all(color: _line, width: 0.8),
        borderRadius: pw.BorderRadius.circular(9),
      ),
      child: pw.Directionality(
        textDirection: pw.TextDirection.ltr,
        child: pw.Column(children: [
          pw.Row(children: [
            _t(_n(maxV), size: 7, color: _muted, ltr: true),
            pw.Spacer(),
            _dot(_in),
            pw.SizedBox(width: 3),
            _t(tr('bdvIn'), size: 7.5, color: _muted),
            pw.SizedBox(width: 10),
            _dot(_out),
            pw.SizedBox(width: 3),
            _t(tr('bdvOut'), size: 7.5, color: _muted),
          ]),
          pw.SizedBox(height: 4),
          pw.Container(
            height: chartH,
            decoration: const pw.BoxDecoration(
                border:
                    pw.Border(bottom: pw.BorderSide(color: _line, width: 0.8))),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                for (var d = 1; d <= days; d++)
                  pw.Expanded(
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Container(
                            width: 3.6,
                            height: h(f.dailyIn[d] ?? 0),
                            color: _in),
                        pw.SizedBox(width: 0.8),
                        pw.Container(
                            width: 3.6,
                            height: h(f.dailyOut[d] ?? 0),
                            color: _out),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Row(children: [
            for (var d = 1; d <= days; d++)
              pw.Expanded(
                child: _t(d == 1 || d % 5 == 0 ? '$d' : '',
                    size: 6.5, color: _muted, align: pw.TextAlign.center),
              ),
          ]),
        ]),
      ),
    );
  }

  // ── Tables ──────────────────────────────────────────────
  /// Header row repeats on every page; RTL flips the column order (the pdf
  /// Table always lays columns left → right).
  static List<pw.Widget> _table({
    required bool rtl,
    required List<String> headers,
    required List<List<String>> rows,
    required List<double> flex,
    required List<bool> numeric,
    List<PdfColor?>? colors,
    List<String>? totals,
  }) {
    List<T> dir<T>(List<T> l) => rtl ? l.reversed.toList() : l;
    final n = headers.length;
    final order = dir(List<int>.generate(n, (i) => i));
    pw.Alignment align(int i) => numeric[i]
        ? pw.Alignment.center
        : (rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft);
    pw.TextAlign talign(int i) => numeric[i]
        ? pw.TextAlign.center
        : (rtl ? pw.TextAlign.right : pw.TextAlign.left);

    pw.Widget cell(int i, String text,
            {bool head = false, bool bold = false, PdfColor? color}) =>
        pw.Container(
          alignment: align(i),
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4.5),
          child: _t(text,
              size: head ? 8.2 : 8.4,
              bold: head || bold,
              color: head ? _white : (color ?? _ink),
              align: talign(i),
              ltr: numeric[i] && !head),
        );

    final table = pw.Table(
      columnWidths: {
        for (var c = 0; c < n; c++) c: pw.FlexColumnWidth(flex[order[c]]),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _line, width: 0.6),
        bottom: pw.BorderSide(color: _line, width: 0.6),
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _brand),
          children: [for (final i in order) cell(i, headers[i], head: true)],
        ),
        for (var r = 0; r < rows.length; r++)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: r.isOdd ? _card : _white),
            children: [
              for (final i in order)
                cell(i, rows[r][i], color: colors?[i]),
            ],
          ),
        if (totals != null)
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _brandSoft),
            children: [
              for (final i in order)
                cell(i, totals[i],
                    bold: true,
                    color: colors?[i] == _muted ? null : (colors?[i] ?? _brandDeep)),
            ],
          ),
      ],
    );
    return [table];
  }
}
