import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../../../core/receipt_engine/styles.dart';
import '../../data/models/personal_models.dart';
import '../../presentation/providers/receipt_design_models.dart';

class GoalReportPdfGenerator {
  GoalReportPdfGenerator._();

  static PdfColor _c(Color c) => pdfColor(c.toARGB32());

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

  static Future<Uint8List> generateGoalReport({
    required String goalName,
    required String goalIcon,
    required String currency,
    required double targetAmount,
    required double currentAmount,
    required double totalContributed,
    required double averageMonthly,
    required double suggestedMonthly,
    required int progressPercent,
    required int transactionCount,
    required int monthsCount,
    String? deadline,
    String? deadlineText,
    required List<Map<String, dynamic>> monthlyData,
    required List<Map<String, dynamic>> transactions,
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
    final completed = currentAmount >= targetAmount;
    final remaining = (targetAmount - currentAmount).clamp(0, targetAmount.toInt()).toDouble();

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

          children.add(pw.Center(child: pw.Text(translations?['savingsReportTitle'] ?? 'تقرير الادخار', style: pw.TextStyle(font: bold, fontSize: 24, color: pColor))));
          children.add(pw.SizedBox(height: 8));
          children.add(pw.Center(child: pw.Text(goalName, style: pw.TextStyle(font: reg, fontSize: 14, color: txtColor))));
          children.add(pw.SizedBox(height: 2));
          if (deadlineText != null) {
            children.add(pw.Center(child: pw.Text(deadlineText, style: pw.TextStyle(font: reg, fontSize: 11, color: subColor))));
          }
          children.add(pw.SizedBox(height: 14));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: 16));

          children.add(_buildKpiRow(preset, targetAmount, currentAmount, remaining, progressPercent, completed, currency, nf, reg, bold, pColor, txtColor, subColor, translations));
          children.add(pw.SizedBox(height: 18));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 16));

          children.add(_sectionTitle(translations?['goalAnalysis'] ?? 'تحليل الهدف', pColor, bold));
          children.add(pw.SizedBox(height: 10));
          children.add(_buildAnalysisTable(totalContributed, averageMonthly, suggestedMonthly, monthsCount, transactionCount, currency, nf, reg, bold, pColor, txtColor, subColor, completed, translations));
          children.add(pw.SizedBox(height: 6));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 14));

          if (monthlyData.isNotEmpty) {
            children.add(_sectionTitle(translations?['monthlyDeposits'] ?? 'الإيداعات الشهرية', pColor, bold));
            children.add(pw.SizedBox(height: 10));
            children.add(_buildMonthlyBarChart(preset, monthlyData, nf, reg, bold, pageW, txtColor, subColor, pColor));
            children.add(pw.SizedBox(height: 6));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: 14));
          }

          if (monthlyData.isNotEmpty) {
            children.add(_sectionTitle(translations?['monthlyDepositsTable'] ?? 'جدول الإيداعات الشهرية', pColor, bold));
            children.add(pw.SizedBox(height: 10));
            children.add(_buildMonthlyTable(monthlyData, nf, reg, bold, pColor, txtColor, translations));
            children.add(pw.SizedBox(height: 6));
            children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
            children.add(pw.SizedBox(height: 14));
          }

          if (transactions.isNotEmpty) {
            children.add(_sectionTitle(translations?['transactionsTab'] ?? 'المعاملات', pColor, bold));
            children.add(pw.SizedBox(height: 10));
            children.add(_buildTransactionTable(transactions, reg, bold, pColor, txtColor, translations));
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
    return pw.Row(children: [
      pw.Container(width: 3, height: 18, decoration: pw.BoxDecoration(color: pColor, borderRadius: pw.BorderRadius.circular(1.5))),
      pw.SizedBox(width: 8),
      pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white)),
    ]);
  }

  // ── KPI row (same style as bank report) ──
  static pw.Widget _buildKpiRow(ReceiptDesignPreset preset, double target, double current, double remaining, int pct, bool completed, String currency, NumberFormat nf, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, PdfColor subColor, [Map<String, String>? translations]) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _c(preset.dividerColor), width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
        children: [
          _kpiItem(translations?['goalLabel'] ?? 'الهدف', '${nf.format(target)} $currency', txtColor, reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['depositedLabel'] ?? 'المودع', '${nf.format(current)} $currency', _c(preset.successColor), reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['remainingLabel'] ?? 'المتبقي', '${nf.format(remaining)} $currency', _c(preset.dangerColor), reg, bold),
          _kpiVertDivider(subColor),
          _kpiItem(translations?['achievementPercentage'] ?? 'نسبة التحقيق', '$pct%', pColor, reg, bold),
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

  
  static pw.Widget _buildMonthlyBarChart(ReceiptDesignPreset preset, List<Map<String, dynamic>> data, NumberFormat nf, pw.Font reg, pw.Font bold, double pageW, PdfColor txtColor, PdfColor subColor, PdfColor pColor) {
    if (data.isEmpty) return pw.SizedBox.shrink();
    final maxVal = data.map((d) => (d['amount'] as num?)?.toDouble() ?? 0).reduce(max);
    if (maxVal == 0) return pw.SizedBox.shrink();

    final maxBars = data.length > 12 ? 12 : data.length;
    final top = data.take(maxBars).toList();
    final barH = 120.0;

    return pw.Container(
      height: barH + 36,
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF2A2A2A), width: 0.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: top.map((d) {
          final val = (d['amount'] as num?)?.toDouble() ?? 0;
          final h = maxVal > 0 ? (val / maxVal) * barH : 0.0;
          final month = d['month'] ?? '';
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
                pw.Text(month.toString().replaceAll(RegExp(r'^....\/'), ''), style: pw.TextStyle(font: reg, fontSize: 8, color: PdfColors.white), textAlign: pw.TextAlign.center),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Analysis table (like bank's accounts table) ──
  static pw.Widget _buildAnalysisTable(double totalContributed, double avgMonthly, double suggestedMonthly, int monthsCount, int txCount, String currency, NumberFormat nf, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, PdfColor subColor, bool completed, [Map<String, String>? translations]) {
    final hdrs = [translations?['itemLabel'] ?? 'البيان', translations?['valueLabel'] ?? 'القيمة'];
    final rows = <List<String>>[
      [translations?['totalDeposited'] ?? 'إجمالي المودع', '${nf.format(totalContributed)} $currency'],
      [translations?['averageMonthlyDeposit'] ?? 'متوسط الإيداع الشهري', '${nf.format(avgMonthly)} $currency'],
      [translations?['transactionCount'] ?? 'عدد المعاملات', '$txCount'],
      [translations?['monthsCountLabel'] ?? 'عدد الشهور', '$monthsCount ${translations?['month'] ?? 'شهر'}'],
    ];
    if (!completed && suggestedMonthly > 0) {
      rows.add([translations?['suggestedMonthly'] ?? 'المقترح شهرياً', '${nf.format(suggestedMonthly)} $currency']);
    }
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

  // ── Monthly deposits table ──
  static pw.Widget _buildMonthlyTable(List<Map<String, dynamic>> data, NumberFormat nf, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, [Map<String, String>? translations]) {
    final hdrs = [translations?['monthLabel'] ?? 'الشهر', translations?['depositLabel'] ?? 'الإيداع'];
    final rows = data.map((r) => ['${r['month'] ?? ''}', nf.format((r['amount'] as num?)?.toDouble() ?? 0)]).toList();
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

  // ── Transactions table (same format as bank) ──
  static pw.Widget _buildTransactionTable(List<Map<String, dynamic>> txs, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, [Map<String, String>? translations]) {
    final hdrs = [translations?['date'] ?? 'التاريخ', translations?['description'] ?? 'الوصف', translations?['amount'] ?? 'المبلغ'];
    final rows = txs.map((r) => [
      '${r['date'] ?? ''}',
      '${r['description'] ?? ''}',
      '${r['amount'] ?? ''}',
    ]).toList();
    final flexes = [1.0, 2.0, 1.0];
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

  // ── All goals report (same style as individual) ──
  static Future<Uint8List> generateAllGoalsReport({
    required List<SavingsGoal> goals,
    required String currency,
    required double totalTarget,
    required double totalSaved,
    required int completedCount,
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
    final pct = totalTarget > 0 ? ((totalSaved / totalTarget) * 100).toStringAsFixed(1) : '0.0';

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

          children.add(pw.Center(child: pw.Text(translations?['financialGoalsReport'] ?? 'تقرير الأهداف المالية', style: pw.TextStyle(font: bold, fontSize: 24, color: pColor))));
          children.add(pw.SizedBox(height: 8));
          children.add(pw.Center(child: pw.Text(translations?['goalsCountLine'] ?? '${goals.length} أهداف \u2022 $completedCount مكتملة', style: pw.TextStyle(font: reg, fontSize: 14, color: txtColor))));
          children.add(pw.SizedBox(height: 14));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: 16));

          children.add(pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
            _kpiItem(translations?['totalGoal'] ?? 'الهدف الإجمالي', '${nf.format(totalTarget)} $currency', txtColor, reg, bold),
            _kpiVertDivider(subColor),
            _kpiItem(translations?['totalSaved'] ?? 'إجمالي المدخر', '${nf.format(totalSaved)} $currency', _c(preset.successColor), reg, bold),
            _kpiVertDivider(subColor),
            _kpiItem(translations?['achievementPercentage'] ?? 'نسبة التحقيق', '$pct%', pColor, reg, bold),
            _kpiVertDivider(subColor),
            _kpiItem(translations?['completed'] ?? 'مكتمل', translations?['completedOfCount'] ?? '$completedCount من ${goals.length}', _c(preset.successColor), reg, bold),
          ]));
          children.add(pw.SizedBox(height: 18));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 16));

          children.add(_sectionTitle(translations?['goalsDetails'] ?? 'تفاصيل الأهداف', pColor, bold));
          children.add(pw.SizedBox(height: 10));
          children.add(pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: pw.BoxDecoration(color: pColor),
            child: pw.Row(children: [translations?['goalLabel'] ?? 'الهدف', translations?['targetLabel'] ?? 'المستهدف', translations?['savedLabel'] ?? 'المدخر', translations?['remainingLabel'] ?? 'المتبقي', translations?['percentage'] ?? 'النسبة'].map((h) => pw.Expanded(child: pw.Text(h, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white), textAlign: pw.TextAlign.center))).toList()),
          ));
          for (final g in goals) {
            final gPct = g.targetAmount > 0 ? ((g.currentAmount / g.targetAmount) * 100).toStringAsFixed(0) : '0';
            final rem = (g.targetAmount - g.currentAmount).clamp(0, g.targetAmount.toInt()).toDouble();
            children.add(pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF333333), width: 0.3))),
              child: pw.Row(children: [
                pw.Expanded(child: pw.Text(g.name, style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor), textAlign: pw.TextAlign.center)),
                pw.Expanded(child: pw.Text('${nf.format(g.targetAmount)} $currency', style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor), textAlign: pw.TextAlign.center)),
                pw.Expanded(child: pw.Text('${nf.format(g.currentAmount)} $currency', style: pw.TextStyle(font: reg, fontSize: 10, color: _c(preset.successColor)), textAlign: pw.TextAlign.center)),
                pw.Expanded(child: pw.Text('${nf.format(rem)} $currency', style: pw.TextStyle(font: reg, fontSize: 10, color: _c(preset.dangerColor)), textAlign: pw.TextAlign.center)),
                pw.Expanded(child: pw.Text('$gPct%', style: pw.TextStyle(font: reg, fontSize: 10, color: pColor), textAlign: pw.TextAlign.center)),
              ]),
            ));
          }
          children.add(pw.SizedBox(height: 6));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 14));

          children.add(_buildFooter(preset, reg, subColor, translations));
          children.add(pw.SizedBox(height: 8));

          return children;
        },
      ),
    );
    return Uint8List.fromList(await doc.save());
  }
}
