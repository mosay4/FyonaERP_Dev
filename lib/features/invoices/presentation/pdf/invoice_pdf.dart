import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../core/utils/currency_formatter.dart' as cf;
import '../../data/invoice_design_models.dart';
import '../../data/invoice_doc.dart';
import '../../data/invoice_labels.dart';

/// Invoice PDF templates (Business).
///
/// `paper`     → A4 professional invoice with real pagination (extra pages
///               when there are many products — nothing is ever lost).
/// `thermal`   → 80mm thermal receipt with an automatic length.
/// `thermal58` → 58mm thermal receipt with an automatic length.
///
/// The SAME normalized [InvoiceDoc] feeds the preview and every export path.
Future<Uint8List> buildInvoicePdf(
  Map<String, dynamic> inv,
  InvoiceDesignPreset d, {
  required String templateId,
  required bool isPurchase,
  Map<String, Uint8List>? images,
}) async {
  final doc = InvoiceDoc.from(inv);
  final reg = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
  final bold =
      pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
  final file = pw.Document();
  final theme = pw.ThemeData.withFont(base: reg, bold: bold);

  if (templateId.contains('thermal')) {
    final widthMm = templateId.contains('thermal58') ? 58.0 : 80.0;
    final width = widthMm * PdfPageFormat.mm;
    final height = _thermalHeight(doc, d, width, widthMm < 70);
    file.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat(width, height),
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      margin: const pw.EdgeInsets.all(10),
      build: (ctx) => [_thermal(doc, d, narrow: widthMm < 70)],
    ));
  } else {
    file.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      margin: const pw.EdgeInsets.fromLTRB(24, 16, 24, 14),
      build: (ctx) => [
        ..._paperHeader(doc, d),
        _paperTable(doc, d, images),
        pw.SizedBox(height: 12),
        _paperTotalsAndSignature(doc, d),
      ],
    ));
  }
  return file.save();
}

// ── Shared helpers ───────────────────────────────────────────────────

String _money(double v) => cf.fmtNum(v);

PdfColor _c(int argb) => PdfColor.fromInt(argb);

String _date(DateTime? dt, String raw) {
  if (dt == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}/${two(dt.month)}/${two(dt.day)}';
}

String _time(DateTime? dt) {
  if (dt == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

pw.Widget _logoOrBrand(InvoiceDesignPreset d, double size) {
  if (d.showLogo && d.logoBytes != null) {
    return pw.Image(pw.MemoryImage(d.logoBytes!), width: size, height: size);
  }
  return pw.Container(
    width: size,
    height: size,
    decoration: pw.BoxDecoration(
        color: _c(d.primaryColor),
        borderRadius: pw.BorderRadius.circular(size / 2)),
    alignment: pw.Alignment.center,
    child: pw.Text(
      d.brandName.isNotEmpty ? d.brandName.substring(0, 1) : 'F',
      style:
          pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: size * 0.5),
    ),
  );
}

pw.Widget _qr(InvoiceDesignPreset d, InvoiceDoc doc, double size) =>
    pw.BarcodeWidget(
      barcode: pw.Barcode.qrCode(),
      data: doc.number.isEmpty ? 'FYONA' : doc.number,
      width: size,
      height: size,
      color: _c(d.textColor),
    );

// ── Paper (A4) — header is plain widgets, the table paginates ─────────

List<pw.Widget> _paperHeader(InvoiceDoc doc, InvoiceDesignPreset d) {
  final L = InvoiceLabels.current();
  final primary = _c(d.primaryColor);
  final text = _c(d.textColor);
  final secondary = _c(d.secondaryTextColor);
  final panel = _c(d.panelColor);
  final title = doc.titleFor(d);

  pw.Widget box(String label, List<pw.Widget> lines) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: panel,
            border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label,
                  style: pw.TextStyle(
                      color: primary, fontWeight: pw.FontWeight.bold, fontSize: 10.5)),
              pw.SizedBox(height: 5),
              ...lines,
            ],
          ),
        ),
      );

  pw.Widget kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Text('$k: $v',
            style: pw.TextStyle(color: text, fontSize: 9)),
      );

  return [
    pw.Container(height: 6, color: primary),
    pw.SizedBox(height: 14),
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Row(children: [
            _logoOrBrand(d, 34),
            pw.SizedBox(width: 10),
            pw.Flexible(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(d.brandName,
                      style: pw.TextStyle(
                          color: text, fontWeight: pw.FontWeight.bold, fontSize: 22)),
                  if (d.showCompanyInfo)
                    pw.Text('${d.companyName} - ${d.companyAddress}',
                        style:
                            pw.TextStyle(color: secondary, fontSize: 8.5)),
                ],
              ),
            ),
          ]),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(title,
                style: pw.TextStyle(
                    color: text, fontWeight: pw.FontWeight.bold, fontSize: 22)),
            pw.SizedBox(height: 4),
            pw.Container(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: pw.BoxDecoration(
                  color: primary.withAlpha(0.10),
                  borderRadius: pw.BorderRadius.circular(5)),
              child: pw.Text(doc.number,
                  style: pw.TextStyle(
                      color: primary, fontWeight: pw.FontWeight.bold, fontSize: 10)),
            ),
          ],
        ),
      ],
    ),
    pw.SizedBox(height: 10),
    pw.Container(height: 1.2, color: primary),
    pw.SizedBox(height: 12),
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (d.showCustomer)
          box(doc.isPurchase ? L.supplierInfo : L.customerInfo, [
            pw.Text(doc.partyName.isEmpty ? '-' : doc.partyName,
                style: pw.TextStyle(
                    color: text, fontWeight: pw.FontWeight.bold, fontSize: 10)),
            if (doc.partyPhone.isNotEmpty)
              pw.Text(doc.partyPhone,
                  style: pw.TextStyle(color: secondary, fontSize: 9)),
          ]),
        if (d.showCustomer) pw.SizedBox(width: 10),
        box(L.invoiceInfo, [
          kv(L.date, _date(doc.date, doc.dateRaw)),
          kv(L.time, _time(doc.date)),
          if (doc.branch.isNotEmpty) kv(L.branch, doc.branch),
          if (doc.cashier.isNotEmpty) kv(L.cashier, doc.cashier),
          if (doc.isReturn && doc.originalInvoice.isNotEmpty)
            kv(L.originalInvoice, doc.originalInvoice),
        ]),
        if (d.showCompanyInfo) ...[
          pw.SizedBox(width: 10),
          box(L.storeInfo, [
            pw.Text(d.companyName,
                style: pw.TextStyle(
                    color: text, fontWeight: pw.FontWeight.bold, fontSize: 10)),
            pw.Text(d.companyAddress,
                style: pw.TextStyle(color: secondary, fontSize: 9)),
            if (d.companyPhone.isNotEmpty)
              pw.Text(d.companyPhone,
                  style: pw.TextStyle(color: secondary, fontSize: 9)),
          ]),
        ],
      ],
    ),
    pw.SizedBox(height: 12),
  ];
}

pw.Widget _paperTable(
    InvoiceDoc doc, InvoiceDesignPreset d, Map<String, Uint8List>? images) {
  final L = InvoiceLabels.current();
  final primary = _c(d.primaryColor);
  return pw.Table(
    border: pw.TableBorder.all(color: _c(0xFFE3DADD), width: 0.6),
    columnWidths: const {
      0: pw.FlexColumnWidth(0.5),
      1: pw.FlexColumnWidth(3.4),
      2: pw.FlexColumnWidth(1.0),
      3: pw.FlexColumnWidth(1.4),
      4: pw.FlexColumnWidth(1.0),
      5: pw.FlexColumnWidth(1.5),
    },
    children: [
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(color: primary),
        children: [
          _cell('#', head: true),
          _cell(L.colProduct, head: true),
          _cell(L.colQty, head: true),
          _cell(L.colUnitPrice, head: true),
          _cell(L.colDiscount, head: true),
          _cell(L.colTotal, head: true),
        ],
      ),
      for (var i = 0; i < doc.items.length; i++)
        pw.TableRow(children: [
          _cell('${i + 1}'),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: pw.Row(children: [
              if (images != null &&
                  doc.items[i].productId.isNotEmpty &&
                  images[doc.items[i].productId] != null) ...[
                pw.Image(pw.MemoryImage(images[doc.items[i].productId]!),
                    width: 18, height: 18),
                pw.SizedBox(width: 5),
              ],
              pw.Expanded(
                child: pw.Text(doc.items[i].description,
                    style: const pw.TextStyle(fontSize: 9.5)),
              ),
            ]),
          ),
          _cell(doc.items[i].quantityText),
          _cell(_money(doc.items[i].unitPrice)),
          _cell(doc.items[i].discount > 0 ? _money(doc.items[i].discount) : '-'),
          _cell(_money(doc.items[i].total)),
        ]),
    ],
  );
}

pw.Widget _cell(String t, {bool head = false, bool left = false}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      child: pw.Text(t,
          textAlign: left ? pw.TextAlign.left : pw.TextAlign.center,
          style: pw.TextStyle(
            color: head ? PdfColors.white : PdfColors.black,
            fontWeight: head ? pw.FontWeight.bold : pw.FontWeight.normal,
            fontSize: 9.5,
          )),
    );

pw.Widget _paperTotalsAndSignature(InvoiceDoc doc, InvoiceDesignPreset d) {
  final L = InvoiceLabels.current();
  final primary = _c(d.primaryColor);
  final text = _c(d.textColor);
  final secondary = _c(d.secondaryTextColor);
  final panel = _c(d.panelColor);

  pw.Widget totRow(String label, String value,
      {bool strong = false, bool highlight = false, String currency = ''}) {
    final size = strong || highlight ? 11.0 : 9.5;
    final color = highlight ? PdfColors.white : text;
    final weight =
        (strong || highlight) ? pw.FontWeight.bold : pw.FontWeight.normal;
    return pw.Container(
      color: highlight ? primary : null,
      padding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(
                  color: color, fontWeight: weight, fontSize: size)),
          pw.Flexible(
            child: pw.RichText(
              textAlign: pw.TextAlign.left,
              text: pw.TextSpan(
                text: value,
                style: pw.TextStyle(
                    color: color, fontWeight: weight, fontSize: size),
                children: [
                  if (currency.isNotEmpty)
                    pw.TextSpan(
                        text: ' $currency',
                        style: pw.TextStyle(
                            color: color,
                            fontWeight: pw.FontWeight.normal,
                            fontSize: size - 2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        flex: 4,
        child: pw.Column(children: [
          pw.Container(
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
                borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              if (!doc.isReturn) ...[
                if (doc.discount.abs() > 0.0001 ||
                    doc.tax.abs() > 0.0001) ...[
                  totRow(L.sumBefore, _money(doc.subtotal),
                      currency: doc.currencyName),
                  if (doc.discount.abs() > 0.0001)
                    totRow(L.discount, _money(doc.discount),
                        currency: doc.currencyName),
                  if (doc.tax.abs() > 0.0001)
                    totRow(L.tax, _money(doc.tax),
                        currency: doc.currencyName),
                ],
                totRow(L.grandTotal, _money(doc.total),
                    currency: doc.currencyName, highlight: true),
              ] else
                totRow(L.returnValue, _money(doc.total),
                    currency: doc.currencyName, highlight: true),
            ]),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
                borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              pw.Container(
                width: double.infinity,
                color: panel,
                padding:
                    const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                child: pw.Text(doc.isReturn ? L.returnDetails : L.paymentMethod,
                    style: pw.TextStyle(
                        color: primary, fontWeight: pw.FontWeight.bold, fontSize: 10)),
              ),
              if (!doc.isReturn) ...[
                totRow(L.paid, _money(doc.paid),
                    currency: doc.currencyName),
                totRow(L.remaining, _money(doc.balance),
                    currency: doc.currencyName, strong: doc.balance > 0),
              ] else ...[
                totRow(L.originalInvoice,
                    doc.originalInvoice.isEmpty ? '-' : doc.originalInvoice),
                if (doc.notes.isNotEmpty) totRow(L.reason, doc.notes),
              ],
              for (final p in doc.payments)
                totRow(
                    p.accountName.isNotEmpty ? p.accountName : L.payment,
                    _money(p.amount),
                    currency:
                        p.currency.isEmpty ? doc.currencyName : cf.currencyName(p.currency)),
            ]),
          ),
          if (d.showFooter) ...[
            pw.SizedBox(height: 14),
            pw.Container(height: 1.2, color: primary),
            pw.SizedBox(height: 5),
            pw.Center(
                child: pw.Text(d.footerText,
                    style: pw.TextStyle(color: secondary, fontSize: 8.5))),
          ],
        ]),
      ),
      pw.SizedBox(width: 12),
      pw.Expanded(
        flex: 5,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            if (d.showQR)
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
                    borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Row(children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(L.viewInvoice,
                          style: pw.TextStyle(
                              color: primary, fontWeight: pw.FontWeight.bold, fontSize: 10)),
                      pw.SizedBox(height: 4),
                      pw.Text(L.scanHint,
                          style:
                              pw.TextStyle(color: secondary, fontSize: 8.5)),
                    ],
                  ),
                  pw.Spacer(),
                  _qr(d, doc, 62),
                ]),
              ),
            if (d.showSignature || d.showStamp) ...[
              pw.SizedBox(height: 8),
              pw.Container(
                height: 96,
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
                    borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Column(children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(L.signature,
                          style: pw.TextStyle(
                              color: text, fontWeight: pw.FontWeight.bold, fontSize: 9)),
                      pw.Text(L.stamp,
                          style: pw.TextStyle(color: secondary, fontSize: 8)),
                    ],
                  ),
                  pw.SizedBox(height: 2),
                  pw.Expanded(
                    child: pw.Stack(children: [
                      if (d.showStamp && d.stampBytes != null)
                        pw.Positioned(
                          left: 180 * d.stampX,
                          top: 42 * d.stampY,
                          child: pw.Image(pw.MemoryImage(d.stampBytes!),
                              width: 180 * d.stampW),
                        ),
                      if (d.showSignature && d.signatureBytes != null)
                        pw.Positioned(
                          left: 180 * d.sigX,
                          top: 42 * d.sigY,
                          child: pw.Image(pw.MemoryImage(d.signatureBytes!),
                              width: 180 * d.sigW),
                        ),
                    ]),
                  ),
                ]),
              ),
            ],
            if (d.showNotes) ...[
              pw.SizedBox(height: 8),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
                    borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(L.notes,
                          style: pw.TextStyle(
                              color: primary, fontWeight: pw.FontWeight.bold, fontSize: 10)),
                      pw.SizedBox(height: 4),
                      pw.Text(doc.notes.isNotEmpty ? doc.notes : d.notesText,
                          style:
                              pw.TextStyle(color: secondary, fontSize: 8.5)),
                    ]),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

// ── Thermal (80 / 58) — auto length ──────────────────────────────────

double _thermalHeight(
    InvoiceDoc doc, InvoiceDesignPreset d, double width, bool narrow) {
  final fs = d.fontSizeScale;
  final usable = width - 20;
  final baseFont = narrow ? 8.0 : 8.5;
  double lines(String s) {
    if (s.isEmpty) return 1;
    final perLine = (usable / (baseFont * 0.58)).floor().clamp(6, 200);
    return (s.length / perLine).ceilToDouble().clamp(1, 6);
  }

  var h = 6.0; // top bar
  h += 42 * fs; // header logo + brand
  h += 22 * fs; // number/title
  h += 12;
  var infoRows = 2 +
      (doc.branch.isNotEmpty ? 1 : 0) +
      (doc.cashier.isNotEmpty ? 1 : 0) +
      (doc.partyName.isNotEmpty && d.showCustomer ? 1 : 0);
  h += infoRows * 15;
  h += 14; // divider
  h += 18; // items header
  for (final it in doc.items) {
    h += (lines(it.description) * 14) + 16;
  }
  h += 12;
  h += 130; // totals block (with payments)
  if (d.showQR) h += 80;
  h += 14; // bottom bar
  h += 40; // safety
  // Generous margin so nothing is ever clipped; MultiPage still paginates as a
  // final guarantee (never loses a product).
  return h * 1.25 + 60;
}

pw.Widget _thermal(InvoiceDoc doc, InvoiceDesignPreset d,
    {required bool narrow}) {
  final primary = _c(d.primaryColor);
  final text = _c(d.textColor);
  final secondary = _c(d.secondaryTextColor);
  final title = doc.titleFor(d);
  final baseFont = narrow ? 8.0 : 8.5;

  pw.Widget row(String label, String value,
      {bool strong = false, int color = 0, String currency = ''}) {
    final size = strong ? baseFont + 1.5 : baseFont;
    final col = color == 0 ? text : PdfColor.fromInt(color);
    final weight = strong ? pw.FontWeight.bold : pw.FontWeight.normal;
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(color: secondary, fontSize: baseFont)),
          pw.Flexible(
            child: pw.RichText(
              textAlign: pw.TextAlign.left,
              text: pw.TextSpan(
                text: value,
                style: pw.TextStyle(
                    color: col, fontWeight: weight, fontSize: size),
                children: [
                  if (currency.isNotEmpty)
                    pw.TextSpan(
                        text: ' $currency',
                        style: pw.TextStyle(
                            color: col,
                            fontWeight: pw.FontWeight.normal,
                            fontSize: size - 2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget divider() => pw.Container(
      height: 0.6,
      color: _c(0xFFE3DADD),
      margin: const pw.EdgeInsets.symmetric(vertical: 4));

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(height: 4, color: primary),
      pw.SizedBox(height: 8),
      pw.Row(children: [
        _logoOrBrand(d, 26),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(d.brandName,
                  style: pw.TextStyle(
                      color: text, fontWeight: pw.FontWeight.bold, fontSize: 15)),
              if (d.showCompanyInfo)
                pw.Text(d.companyName,
                    style: pw.TextStyle(color: secondary, fontSize: 7.5)),
            ],
          ),
        ),
      ]),
      pw.SizedBox(height: 6),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Flexible(
              child: pw.Text(doc.number,
                  style: pw.TextStyle(color: secondary, fontSize: 8))),
          pw.Text(title,
              style: pw.TextStyle(
                  color: primary, fontWeight: pw.FontWeight.bold, fontSize: 13)),
        ],
      ),
      divider(),
      row('التاريخ', _date(doc.date, doc.dateRaw)),
      row('الوقت', _time(doc.date)),
      if (doc.branch.isNotEmpty) row('الفرع', doc.branch),
      if (doc.cashier.isNotEmpty) row('الكاشير', doc.cashier),
      if (d.showCustomer && doc.partyName.isNotEmpty)
        row('العميل', doc.partyName),
      if (doc.isReturn && doc.originalInvoice.isNotEmpty)
        row('الفاتورة الأصلية', doc.originalInvoice),
      divider(),
      pw.Container(
        color: primary,
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
        child: pw.Row(children: [
          pw.Expanded(
              flex: 4,
              child: pw.Text('المنتج',
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: baseFont))),
          pw.Expanded(
              child: pw.Text('الكمية',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: baseFont))),
          pw.Expanded(
              child: pw.Text('السعر',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: baseFont))),
          pw.Expanded(
              child: pw.Text('الإجمالي',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: baseFont))),
        ]),
      ),
      for (final it in doc.items)
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
          decoration: pw.BoxDecoration(
              border: pw.Border(
                  bottom:
                      pw.BorderSide(color: _c(0xFFE3DADD), width: 0.5))),
          child: pw.Row(children: [
            pw.Expanded(
                flex: 4,
                child: pw.Text(it.description,
                    style: pw.TextStyle(color: text, fontSize: baseFont))),
            pw.Expanded(
                child: pw.Text(it.quantityText,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: text, fontSize: baseFont))),
            pw.Expanded(
                child: pw.Text(_money(it.unitPrice),
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: text, fontSize: baseFont))),
            pw.Expanded(
                child: pw.Text(_money(it.total),
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: text, fontSize: baseFont))),
          ]),
        ),
      pw.SizedBox(height: 6),
      pw.Container(
        decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _c(0xFFE3DADD), width: 0.6),
            borderRadius: pw.BorderRadius.circular(5)),
        padding: const pw.EdgeInsets.all(8),
        child: pw.Column(children: [
          if (!doc.isReturn) ...[
            row('المجموع الفرعي', _money(doc.subtotal),
                currency: doc.currencyName),
            row('الخصم', _money(doc.discount), currency: doc.currencyName),
            row('الضريبة', _money(doc.tax), currency: doc.currencyName),
          ],
          pw.Container(
            color: primary,
            padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(doc.isReturn ? 'قيمة المرتجع' : 'الإجمالي',
                    style: pw.TextStyle(
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: baseFont + 2)),
                pw.Flexible(
                  child: pw.RichText(
                    textAlign: pw.TextAlign.left,
                    text: pw.TextSpan(
                      text: _money(doc.total),
                      style: pw.TextStyle(
                          color: PdfColors.white,
                          fontWeight: pw.FontWeight.bold,
                          fontSize: baseFont + 2),
                      children: [
                        if (doc.currencyName.isNotEmpty)
                          pw.TextSpan(
                              text: ' ${doc.currencyName}',
                              style: pw.TextStyle(
                                  color: PdfColors.white,
                                  fontWeight: pw.FontWeight.normal,
                                  fontSize: baseFont)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!doc.isReturn) ...[
            row('المدفوع', _money(doc.paid), currency: doc.currencyName),
            row('المتبقي', _money(doc.balance),
                currency: doc.currencyName, strong: doc.balance > 0, color: d.primaryColor),
          ] else if (doc.notes.isNotEmpty)
            row('السبب', doc.notes),
          for (final p in doc.payments)
            row(
                p.accountName.isNotEmpty ? p.accountName : 'دفعة',
                _money(p.amount),
                currency:
                    p.currency.isEmpty ? doc.currencyName : cf.currencyName(p.currency)),
        ]),
      ),
      if (d.showQR) ...[
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            _qr(d, doc, narrow ? 46 : 54),
            pw.SizedBox(width: 8),
            pw.Flexible(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('تفاصيل الفاتورة',
                      style: pw.TextStyle(
                          color: primary, fontWeight: pw.FontWeight.bold, fontSize: 9)),
                  pw.SizedBox(height: 3),
                  pw.Text('امسح الرمز لعرضها والتحقق منها.',
                      style: pw.TextStyle(color: secondary, fontSize: 7.5)),
                ],
              ),
            ),
          ],
        ),
      ],
      pw.SizedBox(height: 6),
      pw.Container(height: 4, color: primary),
    ],
  );
}
