import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../invoices/data/file_save_service.dart';
import '../../../invoices/presentation/pdf/invoice_pdf.dart';
import '../../../invoices/presentation/widgets/invoice_preview_card.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/merchant_api.dart';
import '../../../../core/utils/time_format.dart';

/// «عرض الفاتورة الأصلية» — renders the merchant's EXACT A4 invoice (their
/// colours, logo, signature, stamp, footer and shop name) using the same
/// preview widget the merchant sees, with pinch-to-zoom / pan. The design is
/// the one the merchant synced from their app; when they never customized it,
/// the standard paper design is used with their real shop name/phone.
class PersonalInvoiceDocumentPage extends ConsumerStatefulWidget {
  final String linkId;
  final String invoiceId;
  final String name;
  const PersonalInvoiceDocumentPage(
      {super.key,
      required this.linkId,
      required this.invoiceId,
      required this.name});
  @override
  ConsumerState<PersonalInvoiceDocumentPage> createState() =>
      _PersonalInvoiceDocumentPageState();
}

class _PersonalInvoiceDocumentPageState
    extends ConsumerState<PersonalInvoiceDocumentPage> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  final TransformationController _tc = TransformationController();
  bool _fittedOnce = false;
  bool _busy = false;
  bool _showEdits = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ref
          .read(merchantApiProvider)
          .operationDetail(widget.linkId, widget.invoiceId);
      if (mounted) setState(() { _d = d; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  Map<String, dynamic> _document(Map<String, dynamic> d) {
    final doc = d['document'];
    if (doc is Map) return Map<String, dynamic>.from(doc);
    // Fallback shape for older responses.
    final isPurchase = '${d['perspective'] ?? ''}' == 'supplier';
    return {
      'invoice_number': d['number'],
      'invoice_type': d['type'],
      'invoice_date': d['date'],
      'currency': d['currency'],
      'customer_name': isPurchase ? null : d['party_name'],
      'supplier_name': isPurchase ? d['party_name'] : null,
      'subtotal': d['subtotal'],
      'discount_amount': d['discount'],
      'tax_amount': d['tax'],
      'total': d['total'],
      'paid_amount': d['paid'],
      'balance': d['remaining'],
      'items': [
        for (final it in ((d['items'] as List?) ?? const []).whereType<Map>())
          {
            'description': it['name'],
            'quantity': it['qty'],
            'unit_name': it['unit'],
            'unit_price': it['price'],
            'discount': it['discount'],
            'total': it['total'],
            'image': it['image'],
          }
      ],
      'payments': [
        for (final p in ((d['payments'] as List?) ?? const []).whereType<Map>())
          {
            'amount': p['amount'],
            'payment_currency': p['currency'],
            'payment_method': p['method'],
            'payment_date': p['date'],
          }
      ],
    };
  }

  InvoiceDesignPreset _design(Map<String, dynamic> d) {
    final merchant =
        Map<String, dynamic>.from(d['merchant'] as Map? ?? const {});
    final shopName = '${merchant['name'] ?? widget.name}'.trim();
    final phone = '${merchant['phone'] ?? ''}'.trim();
    final raw = d['design'];
    InvoiceDesignPreset base;
    if (raw is Map) {
      try {
        base = InvoiceDesignPreset.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        base = InvoiceDesignPreset.defaults('paper', phone: phone);
      }
    } else {
      base = InvoiceDesignPreset.defaults('paper', phone: phone);
    }
    // Never show the placeholder «Organization» — show the real shop name.
    final name = base.companyName.trim();
    if (name.isEmpty ||
        name.toLowerCase() == 'organization' ||
        name == InvoiceDesignPreset.companyPhonePlaceholder) {
      base = base.copyWith(
          companyName: shopName.isEmpty ? name : shopName,
          brandName: shopName.isEmpty ? base.brandName : shopName,
          companyPhone: base.companyPhone.trim().isEmpty ||
                  base.companyPhone == InvoiceDesignPreset.companyPhonePlaceholder
              ? phone
              : base.companyPhone);
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final d = _d;
    final modified = d?['is_modified'] == true;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(l10n.translate('debtOriginalInvoice'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && d == null
              ? DebtRetry(
                  message: debtFriendlyError(
                      _error ?? '', (k) => l10n.translate(k)),
                  retry: _load)
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (modified) _badge(l10n) else const SizedBox.shrink(),
                          const Spacer(),
                          const Icon(Icons.zoom_in_map_outlined,
                              size: 16, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(l10n.translate('debtZoomHint'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 10.5,
                                  color: Colors.grey)),
                        ]),
                        if (modified) _editsPanel(l10n),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      color: AppColors.surfaceVariant.withAlpha(60),
                      child: LayoutBuilder(builder: (ctx, c) {
                        const a4Width = 595.0;
                        final fit = c.maxWidth / a4Width;
                        if (!_fittedOnce) {
                          _fittedOnce = true;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _tc.value = Matrix4.identity()..scale(fit);
                            }
                          });
                        }
                        return InteractiveViewer(
                          transformationController: _tc,
                          constrained: false,
                          minScale: fit * 0.9,
                          maxScale: 6.0,
                          boundaryMargin: const EdgeInsets.all(900),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Container(
                              width: a4Width,
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: DebtStyle.red, width: 1.2),
                                  borderRadius: BorderRadius.circular(12)),
                              clipBehavior: Clip.antiAlias,
                              child: InvoicePreviewCard(
                                invoice: _document(d!),
                                design: _design(d),
                                isPurchase:
                                    '${d['perspective'] ?? ''}' == 'supplier',
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  _pdfBar(l10n),
                ]),
    );
  }

  Future<Uint8List> _pdfBytes() async {
    final d = _d!;
    return buildInvoicePdf(_document(d), _design(d),
        templateId: 'paper',
        isPurchase: '${d['perspective'] ?? ''}' == 'supplier',
        images: const {});
  }

  Future<void> _savePdf() async {
    if (_busy || _d == null) return;
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    try {
      final bytes = await _pdfBytes();
      final res = await FileSaveService.savePdf(
          bytes, 'invoice-${_d!['number'] ?? 'debt'}.pdf');
      if (!mounted) return;
      showFyonaSnack(
          context,
          res['success'] == true
              ? l10n.translate('invoiceSavedToDevice')
              : '${res['message'] ?? ''}',
          success: res['success'] == true);
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('debtErrGeneric'),
            success: false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sharePdf() async {
    if (_busy || _d == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await _pdfBytes();
      await Printing.sharePdf(
          bytes: bytes, filename: 'invoice-${_d!['number'] ?? 'debt'}.pdf');
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pdfBar(AppLocalizations l10n) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _savePdf,
                style: OutlinedButton.styleFrom(
                  foregroundColor: DebtStyle.red,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  side: BorderSide(color: DebtStyle.red.withAlpha(120)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(l10n.translate('invSavePdf'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 46,
              child: FilledButton.icon(
                onPressed: _busy ? null : _sharePdf,
                style: FilledButton.styleFrom(
                  backgroundColor: DebtStyle.red,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(l10n.translate('saleShare'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _badge(AppLocalizations l10n) {
    const color = Color(0xFFD32F2F);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _showEdits = !_showEdits),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(90)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.edit_note, size: 16, color: color),
          const SizedBox(width: 5),
          Text(l10n.translate('debtModified'),
              maxLines: 1,
              style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11.5,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  color: color)),
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _showEdits ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 17, color: color),
          ),
        ]),
      ),
    );
  }

  Widget _editsPanel(AppLocalizations l10n) {
    final d = _d;
    final changes = ((d?['item_changes'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final items =
        ((d?['items'] as List?) ?? const []).whereType<Map>().toList();
    String itemName(String key) {
      for (final it in items) {
        if ('${it['id'] ?? ''}' == key) return '${it['name'] ?? ''}';
      }
      for (final c in changes) {
        if ('${c['item_id'] ?? c['description'] ?? ''}' == key) {
          return '${c['description'] ?? ''}';
        }
      }
      return key;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _showEdits
          ? ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.34),
              child: SingleChildScrollView(
                child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withAlpha(8),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFD32F2F).withAlpha(45)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.history_rounded,
                          size: 17, color: Color(0xFFD32F2F)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(l10n.translate('debtEditDetailsTitle'),
                            style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFD32F2F))),
                      ),
                      InkWell(
                        onTap: () => setState(() => _showEdits = false),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close_rounded,
                              size: 17, color: Color(0xFFD32F2F)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    if (changes.isEmpty)
                      Text(l10n.translate('debtEditDetailsEmpty'),
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              color: Colors.grey))
                    else
                      for (final c in changes)
                        _editChangeCard(l10n,
                            itemName('${c['item_id'] ?? ''}'.isNotEmpty
                                ? '${c['item_id']}'
                                : '${c['description'] ?? ''}'),
                            c),
                  ]),
              ),
            ),
          )
          : const SizedBox.shrink(),
    );
  }

  Widget _editChangeCard(
      AppLocalizations l10n, String name, Map c) {
    final by = '${c['changed_by_name'] ?? ''}'.trim();
    final manager = c['changed_by_is_manager'] == true;
    final when = _fmtWhen('${c['changed_at'] ?? ''}');
    TextStyle h() => const TextStyle(
        fontFamily: 'Cairo', fontSize: 9.5, color: Colors.grey);
    TextStyle v() => const TextStyle(
        fontFamily: 'Cairo',
        fontSize: 11.5,
        fontWeight: FontWeight.w800);
    Widget diff(String label, String before, String after) => Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
              color: DebtStyle.red.withAlpha(6),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(flex: 3, child: Text(label, style: h())),
            Expanded(
              flex: 3,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('debtBefore'), style: h()),
                    Text(before,
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: v()),
                  ]),
            ),
            Icon(Icons.arrow_forward_rounded,
                size: 13, color: DebtStyle.red),
            const SizedBox(width: 5),
            Expanded(
              flex: 3,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('debtAfter'), style: h()),
                    Text(after,
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: v().copyWith(color: DebtStyle.red)),
                  ]),
            ),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: DebtStyle.border(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(name.isEmpty ? '—' : name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DebtStyle.text(context, size: 12, bold: true)),
          ),
          if (when.isNotEmpty)
            Text(when,
                textDirection: TextDirection.ltr,
                style: DebtStyle.text(context,
                    size: 9.5, color: Colors.grey)),
        ]),
        if (manager || by.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                manager
                    ? l10n.translate('debtEditByManager')
                    : l10n.translate('debtEditByEmployee',
                        params: {'name': by}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DebtStyle.text(context,
                    size: 10, color: Colors.grey)),
          ),
        if (c['new_quantity'] != null)
          diff(l10n.translate('debtQtyCol'),
              debtPlainNum(c['old_quantity']),
              debtPlainNum(c['new_quantity'])),
        if (c['new_unit_price'] != null)
          diff(l10n.translate('debtUnitPriceCol'),
              debtAmount(c['old_unit_price']),
              debtAmount(c['new_unit_price'])),
      ]),
    );
  }

  static String _fmtWhen(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${formatClock(l)}';
  }
}
