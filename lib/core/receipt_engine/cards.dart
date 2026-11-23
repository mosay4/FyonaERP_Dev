import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../responsive/r_api.dart';
import '../utils/currency_formatter.dart';
import 'models.dart';
import 'renderer.dart';
import 'styles.dart';

typedef CardBuilder = Widget Function(BuildContext, ReceiptData, DocumentConfig);
typedef PdfCardBuilder = pw.Widget Function(ReceiptData, DocumentConfig);

class CardRegistry {
  CardRegistry._();
  static final Map<String, CardBuilder> _widgetBuilders = {};
  static final Map<String, PdfCardBuilder> _pdfBuilders = {};

  static void register(String name, CardBuilder widget, PdfCardBuilder pdf) {
    _widgetBuilders[name] = widget;
    _pdfBuilders[name] = pdf;
  }

  static CardBuilder? getWidget(String name) => _widgetBuilders[name];
  static PdfCardBuilder? getPdf(String name) => _pdfBuilders[name];

  static void initialize() {
    register('header', _buildHeaderWidget, _buildHeaderPdf);
    register('amount', _buildAmountWidget, _buildAmountPdf);
    register('info', _buildInfoWidget, _buildInfoPdf);
    register('party', _buildPartyWidget, _buildPartyPdf);
    register('items', _buildItemsWidget, _buildItemsPdf);
    register('totals', _buildTotalsWidget, _buildTotalsPdf);
    register('notes', _buildNotesWidget, _buildNotesPdf);
    register('footer', _buildFooterWidget, _buildFooterPdf);
  }
}

TextStyle _ts(BuildContext context, DocumentConfig config, {double? size, Color? color, FontWeight? weight}) {
  return TextStyle(
    fontFamily: config.typography.fontFamily,
    fontSize: size ?? R.font(context),
    color: color ?? config.colors.textPrimary,
    fontWeight: weight ?? FontWeight.w400,
  );
}

pw.TextStyle _pts(DocumentConfig config, {double? size, pw.FontWeight? weight, pw.Font? font}) {
  return pw.TextStyle(
    font: font ?? PdfFonts.regular,
    fontSize: size ?? config.typography.bodySize,
    fontWeight: weight ?? pw.FontWeight.normal,
  );
}

String _docTypeTitle(DocumentType type) {
  switch (type) {
    case DocumentType.salesInvoice: return AppLocalizations.t('receiptSalesInvoice');
    case DocumentType.purchaseInvoice: return AppLocalizations.t('receiptPurchaseInvoice');
    case DocumentType.paymentReceipt: return AppLocalizations.t('receiptPaymentReceipt');
    case DocumentType.paymentVoucher: return AppLocalizations.t('receiptPaymentVoucher');
    case DocumentType.transferNote: return AppLocalizations.t('receiptTransferNote');
    case DocumentType.receiptNote: return AppLocalizations.t('receiptReceiptNote');
    case DocumentType.paymentNote: return AppLocalizations.t('receiptPaymentNote');
  }
}

String _statusText(String? status) {
  switch (status?.toLowerCase()) {
    case 'paid': return AppLocalizations.t('receiptPaid');
    case 'confirmed': return AppLocalizations.t('receiptConfirmed');
    case 'draft': return AppLocalizations.t('status_draft');
    case 'cancelled': return AppLocalizations.t('receiptCancelled');
    case 'overdue': return AppLocalizations.t('receiptOverdue');
    case 'refunded': return AppLocalizations.t('status_refunded');
    default: return status ?? '';
  }
}

Color _statusColor(String? status, ThemeColorsConfig colors) {
  switch (status?.toLowerCase()) {
    case 'paid': case 'active': case 'approved': return colors.success;
    case 'confirmed': case 'refunded': return colors.primary;
    case 'cancelled': case 'overdue': return colors.danger;
    case 'draft': case 'pending': return colors.textSecondary;
    default: return colors.textSecondary;
  }
}

// ── Header Card ──

Widget _buildHeaderWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  final vis = config.visibility;
  return Container(
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    child: Column(
      children: [
        if (vis.showLogo && config.logoBytes != null)
          Padding(
            padding: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingSm)),
            child: Image.memory(config.logoBytes!, height: 60, fit: BoxFit.contain),
          ),
        if (vis.showCompanyName && config.company.name.isNotEmpty)
          Text(config.company.name, style: _ts(context, config, size: config.typography.headerSize, weight: FontWeight.w700)),
        if (vis.showBranch && config.company.branch != null && config.company.branch!.isNotEmpty)
          Text(config.company.branch!, style: _ts(context, config, color: config.colors.textSecondary)),
        if (vis.showDocumentTitle)
          Padding(
            padding: EdgeInsets.only(top: R.spacing(context, DesignTokens.spacingSm)),
            child: Text(_docTypeTitle(data.type), style: _ts(context, config, size: config.typography.titleSize, weight: FontWeight.w600)),
          ),
      ],
    ),
  );
}

pw.Widget _buildHeaderPdf(ReceiptData data, DocumentConfig config) {
  final vis = config.visibility;
  return pw.Container(
    margin: pw.EdgeInsets.only(bottom: config.canvas.padding),
    child: pw.Column(
      children: [
        if (vis.showLogo && config.logoBytes != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: DesignTokens.spacingSm),
            child: pw.Image(pw.MemoryImage(config.logoBytes!), height: 60),
          ),
        if (vis.showCompanyName && config.company.name.isNotEmpty)
          pw.Text(config.company.name, style: _pts(config, size: config.typography.headerSize, weight: pw.FontWeight.bold)),
        if (vis.showBranch && config.company.branch != null && config.company.branch!.isNotEmpty)
          pw.Text(config.company.branch!, style: _pts(config, size: config.typography.bodySize)),
        if (vis.showDocumentTitle)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: DesignTokens.spacingSm),
            child: pw.Text(_docTypeTitle(data.type), style: _pts(config, size: config.typography.titleSize, weight: pw.FontWeight.bold)),
          ),
      ],
    ),
  );
}

// ── Amount Card ──

Widget _buildAmountWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showAmount) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
    ),
    child: Column(
      children: [
        Text(fmtNum(data.total), style: _ts(context, config, size: config.typography.amountSize + 4, color: config.colors.amountText, weight: FontWeight.w700)),
        if (config.visibility.showAmountInWords && data.amountInWords != null && data.amountInWords!.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: R.spacing(context, DesignTokens.spacingXs)),
            child: Text(data.amountInWords!, style: _ts(context, config, size: config.typography.smallSize, color: config.colors.textSecondary)),
          ),
        if (data.status != null && config.visibility.showStatus)
          Container(
            margin: EdgeInsets.only(top: R.spacing(context, DesignTokens.spacingSm)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(data.status, config.colors).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_statusText(data.status), style: _ts(context, config, size: config.typography.smallSize, color: _statusColor(data.status, config.colors))),
          ),
      ],
    ),
  );
}

pw.Widget _buildAmountPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showAmount) return pw.SizedBox();
  final pdfColorAmt = pdfColor(config.colors.amountText.toARGB32());
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    padding: const pw.EdgeInsets.all(DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColorWithAlpha(config.colors.primary.toARGB32(), 0.08),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
    ),
    child: pw.Column(
      children: [
        pw.Text(fmtNum(data.total), style: pw.TextStyle(fontSize: config.typography.amountSize + 4, fontWeight: pw.FontWeight.bold, color: pdfColorAmt)),
        if (config.visibility.showAmountInWords && data.amountInWords != null && data.amountInWords!.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: DesignTokens.spacingXs),
            child: pw.Text(data.amountInWords!, style: pw.TextStyle(fontSize: config.typography.smallSize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
          ),
      ],
    ),
  );
}

// ── Info Card ──

Widget _buildInfoWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showDocumentNumber && !config.visibility.showDate) return const SizedBox.shrink();
  final df = DateFormat('yyyy/MM/dd');
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.cardBackground,
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      border: Border.all(color: config.colors.border),
    ),
    child: Row(
      children: [
        if (config.visibility.showDocumentNumber)
          Expanded(child: Text(AppLocalizations.of(context).translate('receiptDocNumber', params: {'number': data.documentNumber}), style: _ts(context, config, size: config.typography.smallSize))),
        if (config.visibility.showDate)
          Expanded(child: Text(AppLocalizations.of(context).translate('receiptDate', params: {'date': df.format(data.date)}), style: _ts(context, config, size: config.typography.smallSize), textAlign: TextAlign.end)),
      ],
    ),
  );
}

pw.Widget _buildInfoPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showDocumentNumber && !config.visibility.showDate) return pw.SizedBox();
  final df = DateFormat('yyyy/MM/dd');
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    padding: const pw.EdgeInsets.all(DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColor(config.colors.cardBackground.toARGB32()),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
      border: pw.Border.all(color: pdfColor(config.colors.border.toARGB32())),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        if (config.visibility.showDocumentNumber)
          pw.Text(AppLocalizations.t('receiptDocNumber', {'number': data.documentNumber}), style: pw.TextStyle(fontSize: config.typography.smallSize)),
        if (config.visibility.showDate)
          pw.Text(AppLocalizations.t('receiptDate', {'date': df.format(data.date)}), style: pw.TextStyle(fontSize: config.typography.smallSize)),
      ],
    ),
  );
}

// ── Party Card ──

Widget _buildPartyWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showParty || data.partyName == null || data.partyName!.isEmpty) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.cardBackground,
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      border: Border.all(color: config.colors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocalizations.of(context).translate('receiptPartyInfo'), style: _ts(context, config, size: config.typography.titleSize, weight: FontWeight.w600)),
        SizedBox(height: R.spacing(context, DesignTokens.spacingSm)),
        Text(data.partyName!, style: _ts(context, config)),
        if (data.partyAddress != null && data.partyAddress!.isNotEmpty)
          Text(data.partyAddress!, style: _ts(context, config, color: config.colors.textSecondary)),
        if (data.partyPhone != null && data.partyPhone!.isNotEmpty)
          Text(AppLocalizations.of(context).translate('receiptPhone', params: {'phone': data.partyPhone}), style: _ts(context, config, color: config.colors.textSecondary)),
        if (data.partyTaxNumber != null && data.partyTaxNumber!.isNotEmpty)
          Text(AppLocalizations.of(context).translate('receiptTaxNumber', params: {'tax': data.partyTaxNumber}), style: _ts(context, config, size: config.typography.smallSize, color: config.colors.textSecondary)),
      ],
    ),
  );
}

pw.Widget _buildPartyPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showParty || data.partyName == null || data.partyName!.isEmpty) return pw.SizedBox();
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    padding: const pw.EdgeInsets.all(DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColor(config.colors.cardBackground.toARGB32()),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
      border: pw.Border.all(color: pdfColor(config.colors.border.toARGB32())),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(AppLocalizations.t('receiptPartyInfo'), style: pw.TextStyle(fontSize: config.typography.titleSize, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: DesignTokens.spacingSm),
        pw.Text(data.partyName!, style: pw.TextStyle(fontSize: config.typography.bodySize)),
        if (data.partyAddress != null && data.partyAddress!.isNotEmpty)
          pw.Text(data.partyAddress!, style: pw.TextStyle(fontSize: config.typography.bodySize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
        if (data.partyPhone != null && data.partyPhone!.isNotEmpty)
          pw.Text(AppLocalizations.t('receiptPhone', {'phone': data.partyPhone}), style: pw.TextStyle(fontSize: config.typography.bodySize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
        if (data.partyTaxNumber != null && data.partyTaxNumber!.isNotEmpty)
          pw.Text(AppLocalizations.t('receiptTaxNumber', {'tax': data.partyTaxNumber}), style: pw.TextStyle(fontSize: config.typography.smallSize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
      ],
    ),
  );
}

// ── Items Card ──

Widget _buildItemsWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showItems || data.items.isEmpty) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.cardBackground,
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      border: Border.all(color: config.colors.border),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(3),
          1: FlexColumnWidth(1),
          2: FlexColumnWidth(1.5),
          3: FlexColumnWidth(1.5),
        },
        children: [
          TableRow(
            decoration: BoxDecoration(color: config.colors.tableHeader),
            children: [AppLocalizations.of(context).translate('receiptHeaderDesc'), AppLocalizations.of(context).translate('receiptHeaderQty'), AppLocalizations.of(context).translate('receiptHeaderPrice'), AppLocalizations.of(context).translate('receiptHeaderTotal')].map((h) => Padding(
              padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingSm)),
              child: Text(h, style: _ts(context, config, size: config.typography.smallSize, color: Colors.white, weight: FontWeight.w600)),
            )).toList(),
          ),
          ...data.items.asMap().entries.map((e) {
            final item = e.value;
            final isEven = e.key.isEven;
            return TableRow(
              decoration: BoxDecoration(color: isEven ? config.colors.tableRowEven : config.colors.tableRowOdd),
              children: [
                _itemCell(context, config, item.name),
                _itemCell(context, config, fmtNum(item.quantity)),
                _itemCell(context, config, fmtNum(item.price)),
                _itemCell(context, config, fmtNum(item.total), align: TextAlign.end),
              ],
            );
          }),
        ],
      ),
    ),
  );
}

Widget _itemCell(BuildContext context, DocumentConfig config, String text, {TextAlign align = TextAlign.start}) {
  return Padding(
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingSm)),
    child: Text(text, style: _ts(context, config, size: config.typography.smallSize), textAlign: align),
  );
}

pw.Widget _buildItemsPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showItems || data.items.isEmpty) return pw.SizedBox();
  final headers = [AppLocalizations.t('receiptHeaderDesc'), AppLocalizations.t('receiptHeaderQty'), AppLocalizations.t('receiptHeaderPrice'), AppLocalizations.t('receiptHeaderTotal')];
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColor(config.colors.cardBackground.toARGB32()),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
      border: pw.Border.all(color: pdfColor(config.colors.border.toARGB32())),
    ),
    child: pw.TableHelper.fromTextArray(
      border: null,
      cellAlignment: pw.Alignment.centerRight,
      cellStyle: pw.TextStyle(fontSize: config.typography.smallSize),
      headerStyle: pw.TextStyle(fontSize: config.typography.smallSize, fontWeight: pw.FontWeight.bold, color: pdfColor(0xFFFFFFFF)),
      headerDecoration: pw.BoxDecoration(color: pdfColor(config.colors.tableHeader.toARGB32())),
      headers: headers,
      data: data.items.map((item) => [
        item.name,
        fmtNum(item.quantity),
        fmtNum(item.price),
        fmtNum(item.total),
      ]).toList(),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(1),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(1.5),
      },
    ),
  );
}

// ── Totals Card ──

Widget _buildTotalsWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showTotals) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.cardBackground,
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      border: Border.all(color: config.colors.border),
    ),
    child: Column(
      children: [
        _totalRow(context, config, AppLocalizations.of(context).translate('receiptSubtotal'), fmtNum(data.subtotal)),
        if (data.discountAmount > 0) _totalRow(context, config, AppLocalizations.of(context).translate('receiptDiscount'), fmtNum(data.discountAmount)),
        if (data.taxAmount > 0) _totalRow(context, config, AppLocalizations.of(context).translate('receiptTax'), fmtNum(data.taxAmount)),
        Divider(color: config.colors.border, height: R.spacing(context, DesignTokens.spacingMd)),
        _totalRow(context, config, AppLocalizations.of(context).translate('receiptTotal'), fmtNum(data.total), bold: true, color: config.colors.amountText),
        if (data.paid > 0) _totalRow(context, config, AppLocalizations.of(context).translate('detailPaid'), fmtNum(data.paid)),
        if (data.due > 0) _totalRow(context, config, AppLocalizations.of(context).translate('remainingLabel'), fmtNum(data.due), color: config.colors.danger),
      ],
    ),
  );
}

Widget _totalRow(BuildContext context, DocumentConfig config, String label, String value, {bool bold = false, Color? color}) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: R.spacing(context, DesignTokens.spacingXs)),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: _ts(context, config, size: config.typography.bodySize, weight: bold ? FontWeight.w600 : FontWeight.w400)),
        Text(value, style: _ts(context, config, size: config.typography.bodySize + 1, color: color, weight: bold ? FontWeight.w700 : FontWeight.w600)),
      ],
    ),
  );
}

pw.Widget _buildTotalsPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showTotals) return pw.SizedBox();
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    padding: const pw.EdgeInsets.all(DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColor(config.colors.cardBackground.toARGB32()),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
      border: pw.Border.all(color: pdfColor(config.colors.border.toARGB32())),
    ),
    child: pw.Column(
      children: [
        _pdfTotalRow(config, AppLocalizations.t('receiptSubtotal'), fmtNum(data.subtotal)),
        if (data.discountAmount > 0) _pdfTotalRow(config, AppLocalizations.t('receiptDiscount'), fmtNum(data.discountAmount)),
        if (data.taxAmount > 0) _pdfTotalRow(config, AppLocalizations.t('receiptTax'), fmtNum(data.taxAmount)),
        pw.Divider(color: pdfColor(config.colors.border.toARGB32())),
        _pdfTotalRow(config, AppLocalizations.t('receiptTotal'), fmtNum(data.total), bold: true, color: config.colors.amountText),
        if (data.paid > 0) _pdfTotalRow(config, AppLocalizations.t('detailPaid'), fmtNum(data.paid)),
        if (data.due > 0) _pdfTotalRow(config, AppLocalizations.t('remainingLabel'), fmtNum(data.due), color: config.colors.danger),
      ],
    ),
  );
}

pw.Widget _pdfTotalRow(DocumentConfig config, String label, String value, {bool bold = false, Color? color}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: DesignTokens.spacingXs),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: pw.TextStyle(fontSize: config.typography.bodySize, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        pw.Text(value, style: pw.TextStyle(
          fontSize: config.typography.bodySize + 1,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.bold,
          color: color != null ? pdfColor(color.toARGB32()) : null,
        )),
      ],
    ),
  );
}

// ── Notes Card ──

Widget _buildNotesWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showNotes) return const SizedBox.shrink();
  final notes = data.notes ?? config.notes;
  if (notes == null || notes.isEmpty) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: EdgeInsets.only(bottom: R.spacing(context, DesignTokens.spacingMd)),
    padding: EdgeInsets.all(R.spacing(context, DesignTokens.spacingMd)),
    decoration: BoxDecoration(
      color: config.colors.cardBackground,
      borderRadius: BorderRadius.circular(DesignTokens.radiusMd),
      border: Border.all(color: config.colors.border),
    ),
    child: Text(notes, style: _ts(context, config, size: config.typography.smallSize, color: config.colors.textSecondary)),
  );
}

pw.Widget _buildNotesPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showNotes) return pw.SizedBox();
  final notes = data.notes ?? config.notes;
  if (notes == null || notes.isEmpty) return pw.SizedBox();
  return pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.only(bottom: DesignTokens.spacingMd),
    padding: const pw.EdgeInsets.all(DesignTokens.spacingMd),
    decoration: pw.BoxDecoration(
      color: pdfColor(config.colors.cardBackground.toARGB32()),
      borderRadius: pw.BorderRadius.circular(DesignTokens.radiusMd),
      border: pw.Border.all(color: pdfColor(config.colors.border.toARGB32())),
    ),
    child: pw.Text(notes, style: pw.TextStyle(fontSize: config.typography.smallSize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
  );
}

// ── Footer Card ──

Widget _buildFooterWidget(BuildContext context, ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showFooter) return const SizedBox.shrink();
  return Container(
    margin: EdgeInsets.only(top: R.spacing(context, DesignTokens.spacingSm)),
    child: Column(
      children: [
        if (config.footer.text != null && config.footer.text!.isNotEmpty)
          Text(config.footer.text!, style: _ts(context, config, size: config.typography.smallSize, color: config.colors.textSecondary)),
        if (config.footer.showPoweredBy)
          Padding(
            padding: EdgeInsets.only(top: R.spacing(context, DesignTokens.spacingXs)),
            child: Text(AppLocalizations.of(context).translate('receiptPoweredBy'), style: _ts(context, config, size: config.typography.smallSize, color: config.colors.textDisabled)),
          ),
      ],
    ),
  );
}

pw.Widget _buildFooterPdf(ReceiptData data, DocumentConfig config) {
  if (!config.visibility.showFooter) return pw.SizedBox();
  return pw.Container(
    margin: const pw.EdgeInsets.only(top: DesignTokens.spacingSm),
    child: pw.Column(
      children: [
        if (config.footer.text != null && config.footer.text!.isNotEmpty)
          pw.Text(config.footer.text!, style: pw.TextStyle(fontSize: config.typography.smallSize, color: pdfColor(config.colors.textSecondary.toARGB32()))),
        if (config.footer.showPoweredBy)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: DesignTokens.spacingXs),
            child: pw.Text(AppLocalizations.t('receiptPoweredBy'), style: pw.TextStyle(fontSize: config.typography.smallSize, color: pdfColor(config.colors.textDisabled.toARGB32()))),
          ),
      ],
    ),
  );
}
