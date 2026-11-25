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
          _kpiItem(translations?['net'] ?? 'الفرق', nf.format(net), netColor, reg, bold),
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
