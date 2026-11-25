import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../../shared/widgets/invoice_amount.dart';

import '../../../../core/utils/currency_formatter.dart' as cf;
import '../../data/invoice_design_models.dart';
import '../../data/invoice_doc.dart';
import '../../data/invoice_labels.dart';

/// Live preview of an invoice in the Business design language, matching the
/// PDF templates. Consumes the SAME [InvoiceDoc] as the PDF builders so the
/// preview and every export path are identical.
///
/// The signature/stamp can be dragged AND pinched to resize when
/// [onSignatureChange]/[onStampChange] are supplied (editor live positioning).
class InvoicePreviewCard extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final InvoiceDesignPreset design;
  final bool isPurchase;
  final bool interactive;
  final void Function(double x, double y, double w)? onSignatureChange;
  final void Function(double x, double y, double w)? onStampChange;

  const InvoicePreviewCard({
    super.key,
    required this.invoice,
    required this.design,
    required this.isPurchase,
    this.interactive = false,
    this.onSignatureChange,
    this.onStampChange,
  });

  Color get _primary => Color(design.primaryColor);
  Color get _panel => Color(design.panelColor);
  Color get _text => Color(design.textColor);
  Color get _secondary => Color(design.secondaryTextColor);

  bool get _isThermal => design.templateId.contains('thermal');
  bool get _narrow => design.templateId.endsWith('thermal58');

  @override
  Widget build(BuildContext context) {
    final doc = InvoiceDoc.from(invoice);
    return Container(
      color: Colors.white,
      padding: EdgeInsets.all(_isThermal ? 8 : 16),
      child: _isThermal ? _thermal(doc) : _paper(doc),
    );
  }

  TextStyle _t(double size,
          {Color? color, FontWeight weight = FontWeight.w500}) =>
      TextStyle(
          fontFamily: 'Cairo',
          fontSize: size * design.fontSizeScale,
          color: color ?? _text,
          height: 1.25,
          fontWeight: weight);

  String _money(double v) => cf.fmtNum(v);

  Widget _logo(double size) {
    if (design.showLogo && design.logoBytes != null) {
      return Image.memory(design.logoBytes!,
          width: size, height: size, fit: BoxFit.contain);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _primary, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        design.brandName.isNotEmpty ? design.brandName[0] : 'F',
        style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.5,
            fontFamily: 'Cairo'),
      ),
    );
  }

  Widget _qr(double size) => QrImageView(
        data: invoice['invoice_number'].toString(),
        size: size,
        version: QrVersions.auto,
        backgroundColor: Colors.white,
      );

  String _date(InvoiceDoc doc) {
    final dt = doc.date;
    if (dt == null) return doc.dateRaw;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)}';
  }

  // ── Paper (A4) ─────────────────────────────────────────────────────

  Widget _paper(InvoiceDoc doc) {
    final title = doc.titleFor(design);
    final L = InvoiceLabels.current();

    Widget infoBox(String label, List<Widget> lines) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _panel,
              border: Border.all(color: const Color(0xFFE3DADD)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        _t(11, color: _primary, weight: FontWeight.w800)),
                const SizedBox(height: 5),
                ...lines,
              ],
            ),
          ),
        );

    Widget totRow(String l, String v,
            {bool strong = false, bool highlight = false, String currency = ''}) =>
        Container(
          color: highlight ? _primary : Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
          child: Row(children: [
            Expanded(
              child: Text(l,
                  style: _t(strong || highlight ? 11.5 : 10,
                      color: highlight ? Colors.white : _text,
                      weight: strong || highlight
                          ? FontWeight.w800
                          : FontWeight.w500)),
            ),
            Expanded(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.center, child: Text.rich(
                TextSpan(
                  text: v,
                  children: [
                    if (currency.isNotEmpty)
                      TextSpan(
                          text: ' $currency',
                          style: _t((strong || highlight ? 11.5 : 10) - 2.5,
                              color: (highlight ? Colors.white : _text)
                                  .withAlpha(200),
                              weight: FontWeight.w600)),
                  ],
                ),
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                style: _t(strong || highlight ? 11.5 : 10,
                    color: highlight ? Colors.white : _text,
                    weight:
                        strong || highlight ? FontWeight.w800 : FontWeight.w500),
              )),
            ),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 6, color: _primary),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(children: [
                _logo(36),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(design.brandName,
                          style: _t(22, weight: FontWeight.w900)),
                      if (design.showCompanyInfo)
                        Text(
                            '${design.companyName} - ${design.companyAddress}',
                            style: _t(9, color: _secondary)),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(title, style: _t(22, weight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: _primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(6)),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(doc.number,
                          style: _t(11, color: _primary, weight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(height: 1.4, color: _primary),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (design.showCustomer)
              infoBox(doc.isPurchase ? L.supplierInfo : L.customerInfo, [
                Text(doc.partyName.isEmpty ? '-' : doc.partyName,
                    style: _t(11, weight: FontWeight.w700)),
                if (doc.partyPhone.isNotEmpty)
                  Text(doc.partyPhone, style: _t(9, color: _secondary)),
              ]),
            if (design.showCustomer) const SizedBox(width: 10),
            infoBox(L.invoiceInfo, [
              Text('${L.date}: ${_date(doc)}', style: _t(10)),
              if (doc.branch.isNotEmpty)
                Text('${L.branch}: ${doc.branch}', style: _t(10)),
              if (doc.cashier.isNotEmpty)
                Text('${L.cashierFor(doc.cashierRole)}: ${doc.cashier}', style: _t(10)),
              if (doc.isReturn && doc.originalInvoice.isNotEmpty)
                Text('${L.originalInvoice}: ${doc.originalInvoice}', style: _t(10)),
            ]),
            if (design.showCompanyInfo) ...[
              const SizedBox(width: 10),
              infoBox(L.storeInfo, [
                Text(design.companyName,
                    style: _t(11, weight: FontWeight.w700)),
                Text(design.companyPhone, style: _t(10, color: _secondary)),
              ]),
            ],
          ],
        ),
        const SizedBox(height: 12),
        _paperTable(doc),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Column(children: [
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE3DADD)),
                      borderRadius: BorderRadius.circular(8)),
                  child: Column(children: [
                    if (!doc.isReturn) ...[
                      // No discount/tax → hide those fields AND the subtotal;
                      // show only the total (then paid/remaining below).
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
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE3DADD)),
                      borderRadius: BorderRadius.circular(8)),
                  child: Column(children: [
                    Container(
                      width: double.infinity,
                      color: _panel,
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 10),
                      child: Text(doc.isReturn ? L.returnDetails : L.paymentMethod,
                          style: _t(11,
                              color: _primary, weight: FontWeight.w800)),
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
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (design.showQR)
                    _boxed(
                      Row(children: [
                         Expanded(
                           child: Column(
                             crossAxisAlignment: CrossAxisAlignment.start,
                             children: [
                               Text(L.viewInvoice,
                                   style: _t(11,
                                       color: _primary,
                                       weight: FontWeight.w800)),
                               const SizedBox(height: 4),
                               Text(L.scanHint,
                                   style: _t(9, color: _secondary)),
                             ],
                           ),
                         ),
                         const SizedBox(width: 8),
                        _qr(60),
                      ]),
                    ),
                  if (design.showSignature || design.showStamp) ...[
                    const SizedBox(height: 8),
                    _signatureArea(),
                  ],
                  if (design.showNotes) ...[
                    const SizedBox(height: 8),
                    _boxed(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(L.notes,
                              style: _t(11,
                                  color: _primary, weight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(
                              doc.notes.isNotEmpty
                                  ? doc.notes
                                  : design.notesText,
                              style: _t(9, color: _secondary)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (design.showFooter) ...[
          const SizedBox(height: 14),
          Container(height: 1.4, color: _primary),
          const SizedBox(height: 6),
          Center(child: Text(design.footerText, style: _t(9, color: _secondary))),
        ],
      ],
    );
  }

  // ── Thermal (80 / 58) ──────────────────────────────────────────────

  Widget _thermal(InvoiceDoc doc) {
    final L = InvoiceLabels.current();
    final title = doc.titleFor(design);
    final base = _narrow ? 8.0 : 9.0;

    Widget row(String l, String v,
            {bool strong = false, Color? c, String currency = ''}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Text(l, style: _t(base, color: _secondary)),
            const Spacer(),
            Expanded(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.center, child: Text.rich(
                TextSpan(
                  text: v,
                  children: [
                    if (currency.isNotEmpty)
                      TextSpan(
                          text: ' $currency',
                          style: _t((strong ? base + 2 : base) - 2,
                              color: (c ?? _text).withAlpha(200),
                              weight: FontWeight.w600)),
                  ],
                ),
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                style: _t(strong ? base + 2 : base,
                    color: c ?? _text,
                    weight: strong ? FontWeight.w800 : FontWeight.w500),
              )),
            ),
          ]),
        );

    Widget divider() => Container(
        height: 0.6,
        color: const Color(0xFFE3DADD),
        margin: const EdgeInsets.symmetric(vertical: 5));

    Widget headerCell(String t, {int flex = 1}) => Expanded(
          flex: flex,
          child: Text(t,
              textAlign: TextAlign.center,
              style: _t(base, color: Colors.white, weight: FontWeight.w700)),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 4, color: _primary),
        const SizedBox(height: 8),
        Row(children: [
          _logo(26),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(design.brandName, style: _t(15, weight: FontWeight.w900)),
                if (design.showCompanyInfo)
                  Text(design.companyName, style: _t(7.5, color: _secondary)),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Flexible(
              child: Text(doc.number, style: _t(base, color: _secondary))),
          const Spacer(),
          Text(title, style: _t(13, color: _primary, weight: FontWeight.w900)),
        ]),
        divider(),
        row('التاريخ', _date(doc)),
        row('الوقت',
            '${doc.date?.hour.toString().padLeft(2, '0') ?? ''}:${doc.date?.minute.toString().padLeft(2, '0') ?? ''}'),
        if (doc.branch.isNotEmpty) row('الفرع', doc.branch),
        if (doc.cashier.isNotEmpty)
          row(const InvoiceLabels(true).cashierFor(doc.cashierRole), doc.cashier),
        if (design.showCustomer && doc.partyName.isNotEmpty)
          row('العميل', doc.partyName),
        if (doc.isReturn && doc.originalInvoice.isNotEmpty)
          row('الفاتورة الأصلية', doc.originalInvoice),
        divider(),
        Container(
          color: _primary,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
          child: Row(children: [
            headerCell('المنتج', flex: 4),
            headerCell('الكمية'),
            headerCell('السعر'),
            headerCell('الإجمالي'),
          ]),
        ),
        for (final it in doc.items)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
            decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: Color(0xFFE3DADD), width: 0.5))),
            child: Row(children: [
              Expanded(
                  flex: 4,
                  child: Text(it.description, style: _t(base))),
              Expanded(
                  child: InvoiceAmount(it.quantityText, style: _t(base))),
              Expanded(
                  child: InvoiceAmount(_money(it.unitPrice), style: _t(base))),
              Expanded(
                  child: InvoiceAmount(_money(it.total), style: _t(base))),
            ]),
          ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE3DADD)),
              borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            if (!doc.isReturn) ...[
              row('المجموع الفرعي', _money(doc.subtotal),
                  currency: doc.currencyName),
              row('الخصم', _money(doc.discount), currency: doc.currencyName),
              row('الضريبة', _money(doc.tax), currency: doc.currencyName),
            ],
            Container(
              color: _primary,
              padding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Row(children: [
                Text(doc.isReturn ? 'قيمة المرتجع' : 'الإجمالي',
                    style:
                        _t(base + 2, color: Colors.white, weight: FontWeight.w800)),
                const Spacer(),
                Expanded(
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.center, child: Text.rich(
                    TextSpan(
                      text: _money(doc.total),
                      children: [
                        if (doc.currencyName.isNotEmpty)
                          TextSpan(
                              text: ' ${doc.currencyName}',
                              style: _t(base,
                                  color: Colors.white.withAlpha(200),
                                  weight: FontWeight.w600)),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    style: _t(base + 2,
                        color: Colors.white, weight: FontWeight.w800),
                  )),
                ),
              ]),
            ),
            if (!doc.isReturn) ...[
              row('المدفوع', _money(doc.paid), currency: doc.currencyName),
              row('المتبقي', _money(doc.balance),
                  currency: doc.currencyName, strong: doc.balance > 0, c: _primary),
            ] else if (doc.notes.isNotEmpty)
              row('السبب', doc.notes),
            for (final p in doc.payments)
              row(
                  p.accountName.isNotEmpty ? p.accountName : L.payment,
                  _money(p.amount),
                  currency:
                      p.currency.isEmpty ? doc.currencyName : cf.currencyName(p.currency)),
          ]),
        ),
        if (design.showQR) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _qr(_narrow ? 46 : 54),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('تفاصيل الفاتورة',
                        style:
                            _t(10, color: _primary, weight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(L.scanHint,
                        style: _t(8, color: _secondary)),
                  ],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Container(height: 4, color: _primary),
      ],
    );
  }

  // ── Items table (paper) ────────────────────────────────────────────

  Widget _paperTable(InvoiceDoc doc) {
    final L = InvoiceLabels.current();
    Widget head(String t, {int flex = 1}) => Expanded(
          flex: flex,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
            child: Text(t,
                style: _t(10.5, color: Colors.white, weight: FontWeight.w800)),
          ),
        );
    Widget cell(String t, {int flex = 1, TextAlign align = TextAlign.center}) =>
        Expanded(
          flex: flex,
          child: Container(
            alignment: align == TextAlign.start
                ? AlignmentDirectional.centerStart
                : (align == TextAlign.right
                    ? Alignment.centerRight
                    : Alignment.center),
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
            child: align == TextAlign.start
                ? Text(t, style: _t(10), textAlign: align)
                : InvoiceAmount(t, style: _t(10)),
          ),
        );

    return Container(
      decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE3DADD)),
          borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: _primary,
          child: Row(children: [
            head('#', flex: 1),
            head(L.colProduct, flex: 6),
            head(L.colQty, flex: 2),
            head(L.colUnitPrice, flex: 3),
            head(L.colDiscount, flex: 2),
            head(L.colTotal, flex: 3),
          ]),
        ),
        for (var i = 0; i < doc.items.length; i++)
          Container(
            decoration: const BoxDecoration(
                border: Border(
                    top: BorderSide(color: Color(0xFFE3DADD), width: 0.5))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              cell('${i + 1}', flex: 1),
              cell(doc.items[i].description, flex: 6, align: TextAlign.start),
              cell(doc.items[i].quantityText, flex: 2),
              cell(_money(doc.items[i].unitPrice), flex: 3),
              cell(
                  doc.items[i].discount > 0
                      ? _money(doc.items[i].discount)
                      : '-',
                  flex: 2),
              cell(_money(doc.items[i].total), flex: 3),
            ]),
          ),
      ]),
    );
  }

  Widget _boxed(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE3DADD)),
            borderRadius: BorderRadius.circular(8)),
        child: child,
      );

  Widget _signatureArea() {
    final L = InvoiceLabels.current();
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      const h = 96.0;

      Widget item(Uint8List? bytes, double rx, double ry, double rw,
          void Function(double, double, double)? change, Key key) {
        if (bytes == null) return const SizedBox.shrink();
        final posW = w * 0.5;
        final img = Image.memory(bytes, width: posW * rw);
        if (!interactive || change == null) {
          return Positioned(
              key: key, left: w * rx, top: h * ry, child: img);
        }
        return Positioned(
          key: key,
          left: w * rx,
          top: h * ry,
          child: _SigGesture(
            frameW: w,
            frameH: h,
            baseX: rx,
            baseY: ry,
            baseW: rw,
            onChanged: change,
            detailColor: _primary,
            child: img,
          ),
        );
      }

      return Container(
        height: h,
        width: double.infinity,
        decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE3DADD)),
            borderRadius: BorderRadius.circular(8)),
        child: Stack(children: [
          Positioned(
              left: 8,
              top: 6,
              child: Text(L.signature, style: _t(10, weight: FontWeight.w700))),
          Positioned(
              right: 8,
              top: 6,
              child: Text(L.stamp, style: _t(8.5, color: _secondary))),
          if (design.showStamp)
            item(design.stampBytes, design.stampX, design.stampY, design.stampW,
                onStampChange, const ValueKey('stamp')),
          if (design.showSignature)
            item(design.signatureBytes, design.sigX, design.sigY, design.sigW,
                onSignatureChange, const ValueKey('signature')),
        ]),
      );
    });
  }
}

/// Handles drag + pinch on the signature/stamp, clamped INSIDE the signature
/// frame (never larger than the frame, never outside it). Values are the same
/// [sigX]/[sigY]/[sigW] persisted by the editor.
class _SigGesture extends StatefulWidget {
  final double frameW;
  final double frameH;
  final double baseX;
  final double baseY;
  final double baseW;
  final Color detailColor;
  final void Function(double x, double y, double w) onChanged;
  final Widget child;
  const _SigGesture({
    required this.frameW,
    required this.frameH,
    required this.baseX,
    required this.baseY,
    required this.baseW,
    required this.detailColor,
    required this.onChanged,
    required this.child,
  });
  @override
  State<_SigGesture> createState() => _SigGestureState();
}

class _SigGestureState extends State<_SigGesture> {
  late double _x = widget.baseX;
  late double _y = widget.baseY;
  late double _w = widget.baseW;
  double _startW = 1.0;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _SigGesture old) {
    super.didUpdateWidget(old);
    if (!_dragging) {
      _x = widget.baseX;
      _y = widget.baseY;
      _w = widget.baseW;
    }
  }

  void _emit(double x, double y, double w) {
    // Clamp: width never exceeds the frame (w=2 → full frame width) and the
    // element never leaves the frame.
    final nw = w.clamp(0.08, 2.0);
    final maxX = (1.0 - 0.5 * nw).clamp(0.0, 1.0);
    final maxY = (1.0 - 0.35 * nw).clamp(0.0, 1.0);
    _x = x.clamp(0.0, maxX);
    _y = y.clamp(0.0, maxY);
    _w = nw;
    widget.onChanged(_x, _y, _w);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (_) {
        _dragging = true;
        _startW = _w;
      },
      onScaleUpdate: (d) {
        final nx = _x + d.focalPointDelta.dx / widget.frameW;
        final ny = _y + d.focalPointDelta.dy / widget.frameH;
        _emit(nx, ny, _startW * d.scale);
      },
      onScaleEnd: (_) => _dragging = false,
      child: Container(
        decoration: BoxDecoration(
            border: Border.all(color: widget.detailColor.withAlpha(120))),
        child: widget.child,
      ),
    );
  }
}
