import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../../../core/receipt_engine/styles.dart';
import '../../presentation/providers/receipt_design_models.dart';

class BankReportPdfGenerator {
  BankReportPdfGenerator._();

  static PdfColor _c(Color c) => pdfColor(c.toARGB32());

  static const _chartColors = [
    0xFFA01530, 0xFFB82040, 0xFF7A1020,
    0xFFD4A373, 0xFF6C9BCF, 0xFF77DD77,
    0xFFFFB347, 0xFFCB99C9,
  ];

  static pw.Font? _fontRegular;
  static pw.Font? _fontBold;
  static Future<pw.Font> _getRegular() async {
    _fontRegular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    return _fontRegular!;
  }
  static Future<pw.Font> _getBold() async {
    _fontBold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
    return _fontBold!;
  }

  static Future<Uint8List> generateAllBanksReport({
    required String period,
    required double totalBalance,
    required double totalIncome,
    required double totalExpense,
    required List<Map<String, dynamic>> banks,
    required ReceiptDesignPreset preset,
    Uint8List? logoBytes,
    Map<String, String>? translations,
  }) async {
    final reg = await _getRegular();
    final bold = await _getBold();
    final doc = pw.Document();
    final nf = NumberFormat('#,##0.00');
    final bgColor = _c(preset.backgroundColor);
    final pColor = _c(preset.primaryColor);
    final txtColor = _c(preset.textColor);
    final subColor = _c(preset.secondaryTextColor);
    final divColor = _c(preset.dividerColor);
    final pageW = PdfPageFormat.a4.width - 56;

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          textDirection: pw.TextDirection.rtl,
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: bgColor),
          ),
        ),
        build: (pw.Context context) {
          final children = <pw.Widget>[];

          if (preset.showBrandLogo) {
            if (logoBytes != null) {
              children.add(pw.Center(child: pw.Image(pw.MemoryImage(logoBytes), height: 36)));
              children.add(pw.SizedBox(height: 14));
            } else if (preset.logoBytes != null) {
              children.add(pw.Center(child: pw.Image(pw.MemoryImage(preset.logoBytes!), height: 36)));
              children.add(pw.SizedBox(height: 14));
            }
          }

          children.add(pw.Center(child: pw.Text(translations?['allBanksReport'] ?? 'التقرير الشامل للبنوك', style: pw.TextStyle(font: bold, fontSize: 24, color: pColor))));
          children.add(pw.SizedBox(height: 8));
          children.add(pw.Center(child: pw.Text(period, style: pw.TextStyle(font: reg, fontSize: 11, color: subColor))));
          children.add(pw.SizedBox(height: 14));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: 16));

          children.add(_buildKpiRow(preset, totalBalance, totalIncome, totalExpense, nf, reg, bold, pColor, txtColor, subColor, translations));
          children.add(pw.SizedBox(height: 18));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 16));

          // Banks table
          children.add(_sectionTitle(translations?['banksSection'] ?? 'البنوك', pColor, bold));
          children.add(pw.SizedBox(height: 10));
          final hdrs = [translations?['bankLabel'] ?? 'البنك', translations?['accountsCountLabel'] ?? 'عدد الحسابات', translations?['balanceLabel'] ?? 'الرصيد', translations?['incomeLabel'] ?? 'الإيرادات', translations?['expensesLabel'] ?? 'المصروفات', translations?['transactionsTab'] ?? 'المعاملات'];
          final rows = banks.map((b) => [
            '${b['name'] ?? ''}',
            '${b['accounts'] ?? 0}',
            nf.format((b['balance'] as num?)?.toDouble() ?? 0),
            nf.format((b['income'] as num?)?.toDouble() ?? 0),
            nf.format((b['expense'] as num?)?.toDouble() ?? 0),
            '${b['transactions'] ?? 0}',
          ]).toList();
          final flexes = [1.2, 0.8, 1.0, 1.0, 1.0, 0.8];
          children.add(pw.Column(children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              decoration: pw.BoxDecoration(color: pColor),
              child: pw.Row(children: hdrs.asMap().entries.map((e) => pw.Expanded(flex: (flexes[e.key] * 10).toInt(), child: pw.Text(e.value, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white), textAlign: pw.TextAlign.center))).toList()),
            ),
            ...rows.asMap().entries.map((e) => pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF333333), width: 0.3))),
              child: pw.Row(children: e.value.asMap().entries.map((c) => pw.Expanded(flex: (flexes[c.key] * 10).toInt(), child: pw.Text(c.value, style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor), textAlign: pw.TextAlign.center))).toList()),
            )),
          ]));

          children.add(pw.SizedBox(height: 6));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 14));
          children.add(_buildFooter(preset, reg, subColor, translations));

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  static Future<Uint8List> generate({
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
    required ReceiptDesignPreset preset,
    Uint8List? logoBytes,
    bool includeCharts = true,
    bool includeAccounts = true,
    bool includeTransactions = true,
    Map<String, String>? translations,
  }) async {
    final reg = await _getRegular();
    final bold = await _getBold();
    final doc = pw.Document();
    final nf = NumberFormat('#,##0.00');
    final bgColor = _c(preset.backgroundColor);
    final pColor = _c(preset.primaryColor);
    final txtColor = _c(preset.textColor);
    final subColor = _c(preset.secondaryTextColor);
    final divColor = _c(preset.dividerColor);
    final pageW = PdfPageFormat.a4.width - 56;

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          textDirection: pw.TextDirection.rtl,
          buildBackground: (ctx) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: bgColor),
          ),
        ),
        build: (pw.Context context) {
          final children = <pw.Widget>[];

          if (preset.showBrandLogo) {
            if (logoBytes != null) {
              children.add(pw.Center(
                child: pw.Image(pw.MemoryImage(logoBytes), height: 36),
              ));
              children.add(pw.SizedBox(height: 14));
            } else if (preset.logoBytes != null) {
              children.add(pw.Center(
                child: pw.Image(pw.MemoryImage(preset.logoBytes!), height: 36),
              ));
              children.add(pw.SizedBox(height: 14));
            }
          }

          children.add(pw.Center(
            child: pw.Text(translations?['bankStatement'] ?? 'كشف حساب', style: pw.TextStyle(font: bold, fontSize: 24, color: pColor)),
          ));
          children.add(pw.SizedBox(height: 8));
          children.add(pw.Center(
            child: pw.Text(bankName, style: pw.TextStyle(font: reg, fontSize: 14, color: txtColor)),
          ));
          children.add(pw.SizedBox(height: 2));
          children.add(pw.Center(
            child: pw.Text(period, style: pw.TextStyle(font: reg, fontSize: 11, color: subColor)),
          ));
          children.add(pw.SizedBox(height: 14));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: 16));

          children.add(_buildKpiRow(preset, totalBalance, totalIncome, totalExpense, nf, reg, bold, pColor, txtColor, subColor, translations));
          children.add(pw.SizedBox(height: 18));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 16));

          if (includeCharts) {
            if (incomeExpenseData != null && incomeExpenseData.isNotEmpty) {
              children.add(_sectionTitle(translations?['incomeVsExpenseComparison'] ?? 'مقارنة الإيرادات والمصروفات', pColor, bold));
              children.add(pw.SizedBox(height: 10));
              children.add(_buildComparisonBars(preset, incomeExpenseData, nf, reg, bold, pageW, txtColor, subColor, pColor));
              children.add(pw.SizedBox(height: 6));
              children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
              children.add(pw.SizedBox(height: 14));
            }

            if (categoryData.isNotEmpty) {
              children.add(_sectionTitle(translations?['topSpendingCategories'] ?? 'أعلى الفئات إنفاقاً', pColor, bold));
              children.add(pw.SizedBox(height: 10));
              children.add(_buildCategoryPieBars(preset, categoryData, nf, reg, bold, pageW, txtColor, subColor, pColor));
              children.add(pw.SizedBox(height: 6));
              children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
              children.add(pw.SizedBox(height: 14));
            }

            if (dailyData != null && dailyData.isNotEmpty) {
              children.add(_sectionTitle(translations?['dailyExpenses'] ?? 'المصروفات اليومية', pColor, bold));
              children.add(pw.SizedBox(height: 10));
              children.add(_buildDailyBars(preset, dailyData, nf, reg, bold, pageW, txtColor, subColor, pColor));
              children.add(pw.SizedBox(height: 6));
              children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
              children.add(pw.SizedBox(height: 14));
            }
          }

          if (includeAccounts && accountSummary.isNotEmpty) {
            children.add(_sectionTitle(translations?['accountsSection'] ?? 'الحسابات', pColor, bold));
            children.add(pw.SizedBox(height: 10));
            children.add(_buildAccountsTable(accountSummary, reg, bold, pColor, txtColor, translations));
            children.add(pw.SizedBox(height: 6));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: 14));
          }

          if (includeTransactions && transactions.isNotEmpty) {
            children.add(_sectionTitle(translations?['transactionsTab'] ?? 'المعاملات', pColor, bold));
            children.add(pw.SizedBox(height: 10));
            children.add(_buildTxTable(transactions, reg, bold, pColor, txtColor, translations));
            children.add(pw.SizedBox(height: 6));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: 14));
          }

          children.add(_buildFooter(preset, reg, subColor, translations));
          children.add(pw.SizedBox(height: 8));

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  static pw.Widget _sectionTitle(String text, PdfColor pColor, pw.Font bold) {
    return pw.Row(
      children: [
        pw.Container(width: 3, height: 18, decoration: pw.BoxDecoration(color: pColor, borderRadius: pw.BorderRadius.circular(1.5))),
        pw.SizedBox(width: 8),
        pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white)),
      ],
    );
  }

  // ── KPI row ──
  static pw.Widget _buildKpiRow(ReceiptDesignPreset preset, double balance, double income, double expense, NumberFormat nf, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, PdfColor subColor, [Map<String, String>? translations]) {
    final net = income - expense;
    final netColor = _c(net >= 0 ? preset.successColor : preset.dangerColor);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _c(preset.dividerColor), width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
        children: [
          _kpiItem(translations?['balanceLabel'] ?? 'الرصيد', nf.format(balance), txtColor, reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['incomeLabel'] ?? 'الإيرادات', nf.format(income), _c(preset.successColor), reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['expensesLabel'] ?? 'المصروفات', nf.format(expense), _c(preset.dangerColor), reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['net'] ?? 'الصافي', nf.format(net), netColor, reg, bold),
        ],
      ),
    );
  }

  static pw.Widget _kpiItem(String label, String value, PdfColor valueColor, pw.Font reg, pw.Font bold) {
    return pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 10, color: PdfColor.fromInt(0xFF999999))),
          pw.SizedBox(height: 4),
          pw.Text(value, style: pw.TextStyle(font: bold, fontSize: 15, color: valueColor)),
        ],
      ),
    );
  }

  static pw.Widget _kpiVertDivider(PdfColor subColor) {
    return pw.Container(width: 0.5, height: 32, color: PdfColor.fromInt(0xFF444444));
  }

  // ── Comparison bars ──
  static pw.Widget _buildComparisonBars(ReceiptDesignPreset preset, List<Map<String, dynamic>> data, NumberFormat nf, pw.Font reg, pw.Font bold, double pageW, PdfColor txtColor, PdfColor subColor, PdfColor pColor) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    final barWidth = pageW - 130;
    return pw.Column(
      children: data.asMap().entries.map((entry) {
        final val = (entry.value['value'] as num?)?.toDouble() ?? 0;
        final pct = val / maxVal;
        final label = entry.value['label'] ?? '';
        final color = entry.key == 0 ? _c(preset.successColor) : _c(preset.dangerColor);
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Row(
            children: [
              pw.SizedBox(width: 70, child: pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 11, color: txtColor))),
              pw.Expanded(
                child: pw.Container(
                  height: 26,
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFF2A2A2A),
                    borderRadius: pw.BorderRadius.circular(4),
                  ),
                  child: pw.Align(
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Container(
                      width: barWidth * pct,
                      height: 26,
                      decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(4)),
                    ),
                  ),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.SizedBox(width: 60, child: pw.Text(nf.format(val), style: pw.TextStyle(font: bold, fontSize: 11, color: color), textAlign: pw.TextAlign.right)),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Category pie bars ──
  static pw.Widget _buildCategoryPieBars(ReceiptDesignPreset preset, List<Map<String, dynamic>> data, NumberFormat nf, pw.Font reg, pw.Font bold, double pageW, PdfColor txtColor, PdfColor subColor, PdfColor pColor) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final total = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).fold(0.0, (a, b) => a + b);
    if (total == 0) return pw.SizedBox.shrink();

    final barWidth = pageW - 180;
    return pw.Column(
      children: data.take(8).toList().asMap().entries.map((entry) {
        final val = (entry.value['value'] as num?)?.toDouble() ?? 0;
        final pct = val / total;
        final label = entry.value['label'] ?? '';
        final color = pdfColor(_chartColors[entry.key % _chartColors.length]);
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Column(
            children: [
              pw.Row(
                children: [
                  pw.Container(width: 10, height: 10, decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle)),
                  pw.SizedBox(width: 8),
                  pw.Expanded(child: pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 11, color: txtColor))),
                  pw.Text('${(pct * 100).toStringAsFixed(1)}%', style: pw.TextStyle(font: reg, fontSize: 10, color: PdfColor.fromInt(0xFFAAAAAA))),
                  pw.SizedBox(width: 8),
                  pw.Text(nf.format(val), style: pw.TextStyle(font: bold, fontSize: 11, color: pColor)),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Container(
                height: 6,
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFF2A2A2A),
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Container(
                    width: barWidth * pct,
                    height: 6,
                    decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(3)),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Daily bars ──
  static pw.Widget _buildDailyBars(ReceiptDesignPreset preset, List<Map<String, dynamic>> data, NumberFormat nf, pw.Font reg, pw.Font bold, double pageW, PdfColor txtColor, PdfColor subColor, PdfColor pColor) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['value'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    final maxBars = data.length > 15 ? 15 : data.length;
    final sorted = List<Map<String, dynamic>>.from(data)
      ..sort((a, b) => (int.tryParse(a['label'] ?? '0') ?? 0).compareTo(int.tryParse(b['label'] ?? '0') ?? 0));
    final top = sorted.take(maxBars).toList();
    final barH = 100.0;

    return pw.Container(
      height: barH + 36,
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF2A2A2A), width: 0.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: top.map((d) {
          final val = (d['value'] as num?)?.toDouble() ?? 0;
          final h = maxVal > 0 ? (val / maxVal) * barH : 0.0;
          final day = d['label'] ?? '';
          return pw.Expanded(
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text(nf.format(val), style: pw.TextStyle(font: reg, fontSize: 8, color: PdfColors.white), textAlign: pw.TextAlign.center),
                pw.SizedBox(height: 3),
                pw.Container(
                  height: h < 3 && h > 0 ? 3 : h,
                  decoration: pw.BoxDecoration(
                    color: pColor,
                    borderRadius: const pw.BorderRadius.vertical(top: pw.Radius.circular(3)),
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(day, style: pw.TextStyle(font: reg, fontSize: 8, color: PdfColors.white), textAlign: pw.TextAlign.center),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Accounts table ──
  static pw.Widget _buildAccountsTable(List<Map<String, String>> accounts, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, [Map<String, String>? translations]) {
    if (accounts.isEmpty) return pw.SizedBox.shrink();
    final hdrs = [translations?['currencyLabel'] ?? 'العملة', translations?['treeTypeLabel'] ?? 'النوع', translations?['balanceLabel'] ?? 'الرصيد', translations?['notesLabel'] ?? 'الملاحظات'];
    final rows = accounts.map((r) => [r['currency'] ?? '', r['type'] ?? '', r['balance'] ?? '', r['notes'] ?? '']).toList();
    return pw.Column(children: [
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: pw.BoxDecoration(color: pColor),
        child: pw.Row(children: hdrs.map((h) => pw.Expanded(child: pw.Text(h, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white), textAlign: pw.TextAlign.center))).toList()),
      ),
      ...rows.asMap().entries.map((e) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF333333), width: 0.3))),
        child: pw.Row(children: e.value.map((c) => pw.Expanded(child: pw.Text(c, style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor), textAlign: pw.TextAlign.center))).toList()),
      )),
    ]);
  }

  // ── Transactions table ──
  static pw.Widget _buildTxTable(List<Map<String, dynamic>> txs, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, [Map<String, String>? translations]) {
    if (txs.isEmpty) return pw.SizedBox.shrink();
    final hdrs = [translations?['date'] ?? 'التاريخ', translations?['treeTypeLabel'] ?? 'النوع', translations?['categoryLabel'] ?? 'التصنيف', translations?['description'] ?? 'الوصف', translations?['amount'] ?? 'المبلغ'];
    final rows = txs.map((r) => [
      '${r['date'] ?? ''}', '${r['type'] ?? ''}', '${r['category'] ?? ''}',
      '${r['description'] ?? ''}', '${r['amount'] ?? ''}',
    ]).toList();
    final flexes = [1.0, 0.8, 1.2, 2.0, 1.0];
    return pw.Column(children: [
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: pw.BoxDecoration(color: pColor),
        child: pw.Row(children: hdrs.asMap().entries.map((e) => pw.Expanded(flex: (flexes[e.key] * 10).toInt(), child: pw.Text(e.value, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white), textAlign: pw.TextAlign.center))).toList()),
      ),
      ...rows.asMap().entries.map((e) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF333333), width: 0.3))),
        child: pw.Row(children: e.value.asMap().entries.map((c) => pw.Expanded(flex: (flexes[c.key] * 10).toInt(), child: pw.Text(c.value, style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor), textAlign: pw.TextAlign.center))).toList()),
      )),
    ]);
  }

  // ── Footer ──
  static pw.Widget _buildFooter(ReceiptDesignPreset preset, pw.Font reg, PdfColor subColor, [Map<String, String>? translations]) {
    final now = DateTime.now();
    final dateStr = '${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}';
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(preset.footerText.isNotEmpty ? preset.footerText : 'FYONA', style: pw.TextStyle(font: reg, fontSize: 10, color: PdfColor.fromInt(0xFF666666))),
        pw.Text('${translations?['exportedOn'] ?? 'تم التصدير:'} $dateStr', style: pw.TextStyle(font: reg, fontSize: 10, color: PdfColor.fromInt(0xFF666666))),
      ],
    );
  }
}
