import 'dart:typed_data';
import 'dart:ui' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../../../core/receipt_engine/styles.dart';
import '../providers/receipt_design_models.dart';
import '../../data/models/personal_models.dart';

class AccountTreeReportPdfGenerator {
  AccountTreeReportPdfGenerator._();

  static PdfColor _c(Color c) => pdfColor(c.toARGB32());

  static String _tr(Map<String, String>? translations, String key, String fallback) =>
      translations?[key] ?? fallback;

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

  static Future<Uint8List> generate({
    required String reportTitle,
    required String clientName,
    required String period,
    required List<PersonalBankAccount> banks,
    required List<SavingsGoal> goals,
    required List<PersonalDebt> debts,
    required String walletCurrency,
    required double totalAssets,
    required double totalPayable,
    required double totalReceivable,
    required double netWorth,
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
    final cur = walletCurrency.isEmpty ? '' : ' $walletCurrency';

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
            final logo = logoBytes ?? preset.logoBytes;
            if (logo != null) {
              children.add(pw.Center(child: pw.Image(pw.MemoryImage(logo), height: 36)));
              children.add(pw.SizedBox(height: 14));
            }
          }

          children.add(pw.Center(child: pw.Text(reportTitle, style: pw.TextStyle(font: bold, fontSize: 24, color: pColor))));
          children.add(pw.SizedBox(height: 8));
          if (clientName.isNotEmpty) {
            children.add(pw.Center(child: pw.Text('${_tr(translations, 'clientName', 'العميل')}: $clientName', style: pw.TextStyle(font: reg, fontSize: 11, color: subColor))));
            children.add(pw.SizedBox(height: 4));
          }
          children.add(pw.Center(child: pw.Text(period, style: pw.TextStyle(font: reg, fontSize: 11, color: subColor))));
          children.add(pw.SizedBox(height: 14));
          children.add(pw.Container(height: 1.5, width: pageW, color: pColor));
          children.add(pw.SizedBox(height: 16));

          // Summary KPIs
          children.add(_buildKpiRow(preset, totalAssets, totalPayable, totalReceivable, netWorth, cur, nf, reg, bold, txtColor, translations));
          children.add(pw.SizedBox(height: 18));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 16));

          // ── Banks tree ──
          children.add(_sectionTitle(_tr(translations, 'banksSection', 'البنوك والحسابات'), pColor, bold));
          children.add(pw.SizedBox(height: 10));
          if (banks.isEmpty) {
            children.add(pw.Text(_tr(translations, 'noBanks', 'لا توجد حسابات بنكية'), style: pw.TextStyle(font: reg, fontSize: 10, color: subColor)));
          } else {
            final grouped = <String, List<PersonalBankAccount>>{};
            for (final a in banks) {
              grouped.putIfAbsent(a.bankName, () => []).add(a);
            }
            final entries = grouped.entries.toList();
            for (var i = 0; i < entries.length; i++) {
              final e = entries[i];
              final bankTotal = e.value.fold<double>(0, (s, a) => s + a.balance);
              children.add(_bankNode(
                bankName: e.key,
                accountCount: e.value.length,
                bankTotal: bankTotal,
                cur: cur,
                isLast: i == entries.length - 1,
                reg: reg,
                bold: bold,
                pColor: pColor,
                txtColor: txtColor,
                subColor: subColor,
                nf: nf,
                translations: translations,
              ));
              for (final acc in e.value) {
                children.add(_accountNode(
                  account: acc,
                  cur: cur,
                  reg: reg,
                  bold: bold,
                  txtColor: txtColor,
                  subColor: subColor,
                  nf: nf,
                  translations: translations,
                ));
              }
            }
          }
          children.add(pw.SizedBox(height: 6));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 14));

          // ── Savings goals ──
          children.add(_sectionTitle(_tr(translations, 'goalsSection', 'أهداف الادخار'), pColor, bold));
          children.add(pw.SizedBox(height: 10));
          if (goals.isEmpty) {
            children.add(pw.Text(_tr(translations, 'noGoals', 'لا توجد أهداف ادخار'), style: pw.TextStyle(font: reg, fontSize: 10, color: subColor)));
          } else {
            children.add(_goalsList(goals, cur, reg, bold, pColor, txtColor, subColor, nf));
          }
          children.add(pw.SizedBox(height: 6));
          children.add(pw.Container(height: 0.5, width: pageW, color: divColor));
          children.add(pw.SizedBox(height: 14));

          // ── Debts ──
          children.add(_sectionTitle(_tr(translations, 'debtsSection', 'الديون'), pColor, bold));
          children.add(pw.SizedBox(height: 10));
          if (debts.isEmpty) {
            children.add(pw.Text(_tr(translations, 'noDebts', 'لا توجد ديون'), style: pw.TextStyle(font: reg, fontSize: 10, color: subColor)));
          } else {
            children.add(_debtsList(debts, cur, reg, bold, pColor, txtColor, subColor, nf, translations));
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

  static pw.Widget _sectionTitle(String text, PdfColor pColor, pw.Font bold) {
    return pw.Row(
      children: [
        pw.Container(width: 3, height: 18, decoration: pw.BoxDecoration(color: pColor, borderRadius: pw.BorderRadius.circular(1.5))),
        pw.SizedBox(width: 8),
        pw.Text(text, style: pw.TextStyle(font: bold, fontSize: 16, color: PdfColors.white)),
      ],
    );
  }

  static pw.Widget _buildKpiRow(ReceiptDesignPreset preset, double assets, double payable, double receivable, double net, String cur, NumberFormat nf, pw.Font reg, pw.Font bold, PdfColor txtColor, [Map<String, String>? translations]) {
    final netColor = _c(net >= 0 ? preset.successColor : preset.dangerColor);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _c(preset.dividerColor), width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
        children: [
          _kpiItem(_tr(translations, 'totalAssets', 'إجمالي الأصول'), '${nf.format(assets)}$cur', txtColor, reg, bold),
          _kpiVertDivider(),
          _kpiItem(_tr(translations, 'totalPayable', 'ديون مستحقة'), '${nf.format(payable)}$cur', _c(preset.dangerColor), reg, bold),
          _kpiVertDivider(),
          _kpiItem(_tr(translations, 'totalReceivable', 'ديون لي'), '${nf.format(receivable)}$cur', _c(preset.successColor), reg, bold),
          _kpiVertDivider(),
          _kpiItem(_tr(translations, 'netWorth', 'صافي الثروة'), '${nf.format(net)}$cur', netColor, reg, bold),
        ],
      ),
    );
  }

  static pw.Widget _kpiItem(String label, String value, PdfColor valueColor, pw.Font reg, pw.Font bold) {
    return pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(label, style: pw.TextStyle(font: reg, fontSize: 9, color: PdfColor.fromInt(0xFF999999))),
          pw.SizedBox(height: 4),
          pw.Text(value, style: pw.TextStyle(font: bold, fontSize: 12, color: valueColor)),
        ],
      ),
    );
  }

  static pw.Widget _kpiVertDivider() {
    return pw.Container(width: 0.5, height: 34, color: PdfColor.fromInt(0xFF444444));
  }

  static pw.Widget _bankNode({
    required String bankName,
    required int accountCount,
    required double bankTotal,
    required String cur,
    required bool isLast,
    required pw.Font reg,
    required pw.Font bold,
    required PdfColor pColor,
    required PdfColor txtColor,
    required PdfColor subColor,
    required NumberFormat nf,
    Map<String, String>? translations,
  }) {
    final accountsWord = _tr(translations, 'accountsCount', 'حساب');
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      margin: const pw.EdgeInsets.only(bottom: 2),
      decoration: pw.BoxDecoration(
        color: _c(const Color(0xFF151515)),
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF2A2A2A), width: 0.4)),
      ),
      child: pw.Row(
        children: [
          pw.Container(width: 10, height: 10, decoration: pw.BoxDecoration(color: pColor, shape: pw.BoxShape.circle)),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Text(bankName, style: pw.TextStyle(font: bold, fontSize: 12, color: PdfColors.white))),
          pw.Text('$accountCount $accountsWord', style: pw.TextStyle(font: reg, fontSize: 9, color: subColor)),
          pw.SizedBox(width: 10),
          pw.Text('${nf.format(bankTotal)}$cur', style: pw.TextStyle(font: bold, fontSize: 11, color: pColor)),
        ],
      ),
    );
  }

  static pw.Widget _accountNode({
    required PersonalBankAccount account,
    required String cur,
    required pw.Font reg,
    required pw.Font bold,
    required PdfColor txtColor,
    required PdfColor subColor,
    required NumberFormat nf,
    Map<String, String>? translations,
  }) {
    final typeLabel = _tr(translations, 'accountType${account.accountType}',
        account.accountType == 'cash'
            ? _tr(translations, 'accountTypeCash', 'نقدي')
            : account.accountType == 'savings'
                ? _tr(translations, 'accountTypeSavings', 'ادخار')
                : account.accountType);
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF222222), width: 0.3))),
      child: pw.Row(
        children: [
          pw.SizedBox(width: 18),
          pw.Container(width: 8, height: 1, color: subColor),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Text(isCashAccount(account.bankName) ? cashDisplayName() : account.bankName, style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor))),
          pw.SizedBox(width: 8),
          pw.Text(typeLabel, style: pw.TextStyle(font: reg, fontSize: 9, color: subColor)),
          pw.SizedBox(width: 10),
          pw.Text('${nf.format(account.balance)}$cur', style: pw.TextStyle(font: bold, fontSize: 10, color: txtColor)),
        ],
      ),
    );
  }

  static pw.Widget _goalsList(List<SavingsGoal> goals, String cur, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, PdfColor subColor, NumberFormat nf) {
    return pw.Column(
      children: goals.map((g) {
        final pct = g.progress;
        return pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          margin: const pw.EdgeInsets.only(bottom: 4),
          decoration: pw.BoxDecoration(
            color: _c(const Color(0xFF151515)),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  pw.Expanded(child: pw.Text(g.name, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white))),
                  pw.Text('${(pct * 100).toStringAsFixed(1)}%', style: pw.TextStyle(font: bold, fontSize: 10, color: pColor)),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                children: [
                  pw.Text('${nf.format(g.currentAmount)}$cur', style: pw.TextStyle(font: reg, fontSize: 10, color: txtColor)),
                  pw.SizedBox(width: 6),
                  pw.Text('/ ${nf.format(g.targetAmount)}$cur', style: pw.TextStyle(font: reg, fontSize: 10, color: subColor)),
                  if (g.deadline != null && g.deadline!.isNotEmpty) ...[
                    pw.SizedBox(width: 10),
                    pw.Text(g.deadline!, style: pw.TextStyle(font: reg, fontSize: 9, color: subColor)),
                  ],
                ],
              ),
              pw.SizedBox(height: 5),
              pw.Container(
                height: 5,
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFF2A2A2A),
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Container(
                    width: 200 * pct,
                    height: 5,
                    decoration: pw.BoxDecoration(color: pColor, borderRadius: pw.BorderRadius.circular(3)),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  static pw.Widget _debtsList(List<PersonalDebt> debts, String cur, pw.Font reg, pw.Font bold, PdfColor pColor, PdfColor txtColor, PdfColor subColor, NumberFormat nf, [Map<String, String>? translations]) {
    return pw.Column(
      children: debts.map((d) {
        final isPayable = d.type == 'payable';
        final color = isPayable ? _c(const Color(0xFFC62828)) : _c(const Color(0xFF2E7D32));
        final status = d.isPaid
            ? _tr(translations, 'paidStatus', 'مسدد')
            : d.isOverdue
                ? _tr(translations, 'overdueStatus', 'متأخر')
                : _tr(translations, 'activeStatus', 'نشط');
        final pct = d.progress;
        return pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          margin: const pw.EdgeInsets.only(bottom: 4),
          decoration: pw.BoxDecoration(
            color: _c(const Color(0xFF151515)),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(child: pw.Text(d.personName.isEmpty ? _tr(translations, 'unknownPerson', 'جهة غير محددة') : d.personName, style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.white))),
                  pw.Text(status, style: pw.TextStyle(font: bold, fontSize: 9, color: color)),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      '${_tr(translations, 'totalAmount', 'المبلغ')}: ${nf.format(d.amount)}$cur  •  ${_tr(translations, 'paidLabel', 'المسدد')}: ${nf.format(d.paid)}$cur  •  ${_tr(translations, 'remainingLabel', 'المتبقي')}: ${nf.format(d.remaining)}$cur',
                      style: pw.TextStyle(font: reg, fontSize: 9, color: subColor),
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 5),
              pw.Container(
                height: 5,
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFF2A2A2A),
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Container(
                    width: 200 * pct,
                    height: 5,
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
