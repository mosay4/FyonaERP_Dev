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

  static const int _kBrand = 0xFFB00020; // logo crimson
  static const int _kBrandDeep = 0xFFA00020;
  static const int _kBrandDark = 0xFF8C0A1C;
  static const int _kCard = 0xFFF7F7F9;
  static const int _kLine = 0xFFE5E7EB;
  static const int _kInk = 0xFF1A1A1A;
  static const int _kMuted = 0xFF6B7280;

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

  /// A grouped table inside the report (title repeats on every page chunk).
  static pw.Widget? _pdfLogoChip;

  /// Section of a report: its own title + table (headers/rows adapt freely).
  static List<pw.Widget> _sectionBlocks({
    required String title,
    required List<String> tableHeaders,
    required List<List<String>> tableRows,
    required bool rtl,
    required pw.Font regular,
    required pw.Font bold,
    int chunkSize = 18,
  }) {
    final blocks = <pw.Widget>[];
    if (tableRows.isEmpty) return blocks;
    for (var i = 0; i < tableRows.length; i += chunkSize) {
      final chunk = tableRows.sublist(
          i, (i + chunkSize) > tableRows.length ? tableRows.length : i + chunkSize);
      blocks.add(_sectionTitle(title, bold));
      blocks.add(pw.SizedBox(height: 6));
      blocks.add(_brandTable(
          headers: tableHeaders,
          rows: chunk,
          rtl: rtl,
          regular: regular,
          bold: bold,
          zebraBase: i));
      blocks.add(pw.SizedBox(height: 14));
    }
    return blocks;
  }

  static pw.Widget _sectionTitle(String title, pw.Font bold) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(children: [
        pw.Container(width: 4, height: 14, color: pdfColor(_kBrand)),
        pw.SizedBox(width: 6),
        pw.Expanded(
          child: _pdfText(title,
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: pdfColor(_kBrand))),
        ),
      ]),
    );
  }

  static pw.Table _brandTable({
    required List<String> headers,
    required List<List<String>> rows,
    required bool rtl,
    required pw.Font regular,
    required pw.Font bold,
    int zebraBase = 0,
  }) {
    List<String> fix(List<String> r) => rtl ? r.reversed.toList() : r;
    return pw.TableHelper.fromTextArray(
      tableDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      headerDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      headers: fix(headers),
      data: [for (final r in rows) fix(r)],
      headerStyle: pw.TextStyle(
          font: bold,
          fontSize: 8.5,
          fontWeight: pw.FontWeight.bold,
          color: pdfColor(0xFFFFFFFF)),
      headerDecoration: pw.BoxDecoration(color: pdfColor(_kBrandDeep)),
      headerAlignment: rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      cellStyle: pw.TextStyle(font: regular, fontSize: 8.5, color: pdfColor(_kInk)),
      cellAlignment: rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      cellPadding: const pw.EdgeInsets.symmetric(
          horizontal: 6, vertical: 4.5),
      oddRowDecoration:
          pw.BoxDecoration(color: pdfColor(zebraBase.isOdd ? 0xFFFFFFFF : _kCard)),
      border: pw.TableBorder.all(color: pdfColor(_kLine), width: 0.6),
      tableWidth: pw.TableWidth.max,
    );
  }

  /// Directionally-isolated segment Texts: each script stays in its own
  /// paragraph so mixed Arabic + Latin/dates never scramble each other.
  static List<pw.Widget> segments(List<String> parts, pw.Font f, double size,
      PdfColor color, bool boldIt) {
    final out = <pw.Widget>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        out.add(_pdfText('•',
            style: pw.TextStyle(font: f, fontSize: size, color: color)));
        out.add(pw.SizedBox(width: 5));
      }
      out.add(_pdfText(parts[i],
          maxLines: 1,
          style: pw.TextStyle(
              font: f,
              fontSize: size,
              fontWeight: boldIt ? pw.FontWeight.bold : null,
              color: color)));

      out.add(pw.SizedBox(width: 5));
    }
    if (out.isNotEmpty) out.removeLast();
    return out;
  }

  static pw.Widget _brandHeader({
    required String title,
    required String? subtitle,
    List<String>? subtitleParts,
    required Uint8List? logo,
    required bool rtl,
    required pw.Font bold,
    required pw.Font regular,
  }) {
    final textCol = pw.Column(
      crossAxisAlignment:
          rtl ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start,
      children: [
        _pdfText(title,
            style: pw.TextStyle(
                font: bold,
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
                color: pdfColor(0xFFFFFFFF))),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          pw.SizedBox(height: 3),
          _pdfText(subtitle,
              style: pw.TextStyle(
                  font: regular, fontSize: 9.5, color: pdfColor(0xE6FFFFFF))),
        ],
      ],
    );
    final chip = logo == null
        ? pw.SizedBox.shrink()
        : pw.Container(
            width: 46,
            height: 46,
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(
              color: pdfColor(0xFFFFFFFF),
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
          );
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(
          begin: pw.Alignment.topCenter,
          end: pw.Alignment.bottomCenter,
          colors: [
            pdfColor(_kBrand),
            pdfColor(_kBrandDeep),
            pdfColor(_kBrandDark),
          ],
        ),
        borderRadius: pw.BorderRadius.circular(10),
      ),
      child: rtl
          ? pw.Row(children: [chip, pw.SizedBox(width: 12), pw.Expanded(child: textCol)])
          : pw.Row(children: [pw.Expanded(child: textCol), pw.SizedBox(width: 12), chip]),
    );
  }

  static List<pw.Widget> _brandKpis(
      List<Map<String, String>> kpis, pw.Font regular, pw.Font bold) {
    final out = <pw.Widget>[];
    for (var i = 0; i < kpis.length; i += 3) {
      final chunk = kpis.sublist(i, (i + 3) > kpis.length ? kpis.length : i + 3);
      out.add(pw.Row(
        children: [
          for (final k in chunk)
            pw.Expanded(
              child: pw.Container(
                margin: const pw.EdgeInsets.symmetric(horizontal: 3),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                decoration: pw.BoxDecoration(
                  color: pdfColor(_kCard),
                  border: pw.Border.all(color: pdfColor(_kLine), width: 0.6),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _pdfText(k['label'] ?? '',
                        maxLines: 1,
                        style: pw.TextStyle(
                            font: regular,
                            fontSize: 7.5,
                            color: pdfColor(_kMuted))),
                    pw.SizedBox(height: 2),
                    _pdfText(k['value'] ?? '',
                        maxLines: 1,
                        style: pw.TextStyle(
                            font: bold,
                            fontSize: 12.5,
                            fontWeight: pw.FontWeight.bold,
                            color: pdfColor(_kBrand))),
                  ],
                ),
              ),
            ),
        ],
      ));
      out.add(pw.SizedBox(height: 8));
    }
    if (out.isNotEmpty) out.removeLast();
    return out;
  }

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
  }) async {
    final regular = await _getFontRegular();
    final bold = await _getFontBold();
    final logo = await _getLogo();
    final rtl = isAr ??
        _hasArabic(title) ||
            ((sections?.isNotEmpty ?? false) &&
                _hasArabic(sections!.first.title)) ||
            headers.any((h) => _hasArabic(h['label'] ?? ''));
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat ?? PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(24, 20, 24, 30),
        maxPages: 500,
        footer: (pw.Context context) {
          // Each footer part is its own paragraph — mixed Arabic/date/currency
          // segments can never scramble each other.
          final parts = (footerParts != null && footerParts.isNotEmpty)
              ? footerParts
              : ((footer ?? '').isEmpty ? const <String>[] : [footer!]);
          // The footer renders OUTSIDE the page content, so the page-level
          // Directionality never reaches it — without its own wrapper the
          // Arabic footer segments fall back to LTR and letters disconnect.
          return pw.Directionality(
            textDirection:
                rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
            child: pw.Container(
              padding: pw.EdgeInsets.only(top: 6),
              decoration: pw.BoxDecoration(
                border: pw.Border(
                    top: pw.BorderSide(color: pdfColor(_kLine), width: 0.6)),
              ),
              child: pw.Row(children: [
              _pdfText('FYONA ERP',
                  style: pw.TextStyle(
                      font: bold,
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                      color: pdfColor(_kBrand))),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: pw.Row(
                    children: segments(parts, regular, 7.5,
                        pdfColor(_kMuted), false)),
              ),
              _pdfText('${context.pageNumber} / ${context.pagesCount}',
                  style: pw.TextStyle(
                      font: regular, fontSize: 7.5, color: pdfColor(_kMuted))),
            ]),
          )
          );
        },
        build: (pw.Context context) {
          // ROOT FIX for scrambled Arabic («ت اي رت ش مل اوت اعي بم لا»):
          // every pw.Text — including the ones INSIDE TableHelper — resolves
          // its direction from the closest pw.Directionality. Without this
          // wrapper, table cells default to LTR and Arabic renders as
          // disconnected, reversed letters. One wrapper fixes the whole page.
          final children = <pw.Widget>[];
          children.add(_brandHeader(
              title: title,
              subtitle: subtitle,
              subtitleParts: subtitleParts,
              logo: logo,
              rtl: rtl,
              bold: bold,
              regular: regular));
          children.add(pw.SizedBox(height: 12));
          if (kpis != null && kpis.isNotEmpty) {
            children.addAll(_brandKpis(kpis, regular, bold));
            children.add(pw.SizedBox(height: 10));
          }
          if (sections != null && sections.isNotEmpty) {
            for (final sec in sections) {
              children.addAll(_sectionBlocks(
                  title: sec.title,
                  tableHeaders: sec.headers,
                  tableRows: sec.rows,
                  rtl: rtl,
                  regular: regular,
                  bold: bold));
            }
          } else if (rows.isNotEmpty) {
            children.addAll(_sectionBlocks(
                title: '',
                tableHeaders: headers.map((h) => h['label'] ?? '').toList(),
                tableRows: rows,
                rtl: rtl,
                regular: regular,
                bold: bold));
          }
          return [
            pw.Directionality(
              textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: children),
            ),
          ];
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
}) => pw.Text(
  text.replaceAllMapped(_tailSpace, (m) => '${m[1]}  '),
  style: style,
  textAlign: textAlign,
  maxLines: maxLines,
);
