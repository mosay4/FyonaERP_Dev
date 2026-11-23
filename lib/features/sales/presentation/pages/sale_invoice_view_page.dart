import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../../shared/widgets/invoice_amount.dart';
import '../../../../shared/widgets/pdf_actions.dart';
import '../../../../core/utils/currency_formatter.dart'
    show fmtNum, currencyLabel;
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../domain/sale_totals.dart' show parseMoney;
import '../providers/sale_providers.dart';
import 'sale_invoice_pdf.dart';

/// Sale invoice detail (the «عرض الفاتورة» target): header, lines with
/// snapshots, payments, totals, print/share. Read-only.
class SaleInvoiceViewPage extends ConsumerWidget {
  final String invoiceId;
  final LocalCommerceTarget? localTarget;
  const SaleInvoiceViewPage({super.key, required this.invoiceId, this.localTarget});

  Future<Map<String, Uint8List>?> _images(
      BuildContext context, Map<String, dynamic> inv) async {
    if (!await invoiceImagesEnabled()) return null;
    final dio = ProviderScope.containerOf(context, listen: false)
        .read(dioProvider);
    return collectInvoiceImages(inv, dio, localOnly: localTarget != null);
  }

  Future<void> _print(BuildContext context, Map<String, dynamic> inv) async {
    final imgs = await _images(context, inv);
    final bytes = await buildSaleInvoicePdf(inv, images: imgs);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _share(BuildContext context, Map<String, dynamic> inv) async {
    final imgs = await _images(context, inv);
    final bytes = await buildSaleInvoicePdf(inv, images: imgs);
    final no = (inv['invoice_number'] ?? '').toString();
    await Printing.sharePdf(bytes: bytes, filename: 'invoice-$no.pdf');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final target = localTarget;
    if (target != null &&
        (!target.allows(ref.watch(businessLocalLedgerScopeProvider), RouteNames.salesView) ||
            !ref.watch(employeeCanProvider('sales.view')))) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('saleInvoiceDetails'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(RouteNames.sales);
            }
          },
        ),
      ),
      body: SafeArea(
        child: FutureBuilder(
          future: ref.read(salesApiProvider).getInvoice(invoiceId),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snap.hasData || snap.data!.isEmpty) {
              return Center(
                  child: Text(l10n.translate('saleInvoiceNotFound'),
                      style: const TextStyle(fontFamily: 'Cairo')));
            }
            final inv = snap.data!;
            final cur = (inv['currency'] ?? 'SAR').toString();
            final items = (inv['items'] as List?)?.whereType<Map>().toList() ?? const [];
            final payments = (inv['payments'] as List?)?.whereType<Map>().toList() ?? const [];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _HeadCard(invoice: inv, currency: cur),
                const SizedBox(height: 12),
                _LinesCard(items: items, currency: cur),
                const SizedBox(height: 12),
                _TotalsCard(invoice: inv, currency: cur),
                if (payments.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _PaymentsCard(payments: payments, currency: cur),
                ],
                const SizedBox(height: 16),
                PdfActions(
                  title: (inv['invoice_number'] ?? '').toString(),
                  pdfBytes: null,
                  fileName: 'invoice-${inv['invoice_number']}.pdf',
                  onPrint: () => _print(context, inv),
                  onShare: () => _share(context, inv),
                  onDownload: null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeadCard extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final String currency;
  const _HeadCard({required this.invoice, required this.currency});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text((invoice['invoice_number'] ?? '').toString(),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 17), fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ),
              StatusBadge(status: (invoice['status'] ?? '').toString()),
            ],
          ),
          const SizedBox(height: 8),
          Text(
              '${l10n.translate('saleCustomer')}: ${(invoice['customer_name'] ?? l10n.translate('saleCashCustomer')).toString()}',
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
          Text(
              '${l10n.translate('saleDate')}: ${(invoice['invoice_date'] ?? '').toString()}',
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
          if ((invoice['branch_name']?.toString().isNotEmpty ?? false))
            Text('${l10n.translate('saleBranch')}: ${invoice['branch_name']}',
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _LinesCard extends StatelessWidget {
  final List<Map> items;
  final String currency;
  const _LinesCard({required this.items, required this.currency});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(AppLocalizations.of(context).translate('saleItems'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Row(children: [
            _h(context, 'المنتج', 5, align: TextAlign.start),
            _h(context, 'الكمية', 2),
            _h(context, 'سعر الوحدة', 3),
            _h(context, 'الخصم', 2),
            _h(context, 'الإجمالي', 3),
          ]),
          const Divider(height: 10),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Text((it['description'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  ),
                  _c(context, '${it['quantity']} ${(it['unit_name'] ?? '').toString()}'.trim(), 2),
                  _c(context, fmtNum(parseMoney(it['unit_price'])), 3),
                  _c(context, parseMoney(it['discount']) > 0 ? fmtNum(parseMoney(it['discount'])) : '-', 2),
                  _c(context, fmtNum(parseMoney(it['total'])), 3, bold: true),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(currencyLabel(currency),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _h(BuildContext c, String t, int flex, {TextAlign align = TextAlign.center}) =>
      Expanded(
        flex: flex,
        child: Text(t,
            textAlign: align,
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(c, 11), fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
      );

  Widget _c(BuildContext c, String t, int flex, {bool bold = false}) => Expanded(
        flex: flex,
        child: InvoiceAmount(t,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(c, 12),
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                color: AppColors.textPrimary)),
      );
}

class _TotalsCard extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final String currency;
  const _TotalsCard({required this.invoice, required this.currency});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget row(String key, dynamic value, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(l10n.translate(key),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary))),
              Expanded(child: InvoiceAmount('${fmtNum(parseMoney(value))} ${currencyLabel(currency)}',
                  alignment: AlignmentDirectional.centerEnd,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, bold ? 16 : 13), fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color ?? AppColors.textPrimary))),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          row('saleSubtotal', invoice['subtotal']),
          if (parseMoney(invoice['discount_amount']) > 0)
            row('saleHeaderDiscount', invoice['discount_amount'], color: AppColors.success),
          if (parseMoney(invoice['tax_amount']) > 0)
            row('saleTax', invoice['tax_amount']),
          const Divider(height: 16),
          row('saleGrandTotal', invoice['total'], bold: true, color: AppColors.primary),
          row('salePaid', invoice['paid_amount']),
          row('saleRemaining', invoice['balance'],
              color: parseMoney(invoice['balance']) > 0 ? AppColors.danger : null),
        ],
      ),
    );
  }
}

class _PaymentsCard extends StatelessWidget {
  final List<Map> payments;
  final String currency;
  const _PaymentsCard({required this.payments, required this.currency});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context).translate('salePayment'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          for (final p in payments)
            _PaymentLine(payment: p, invoiceCurrency: currency),
        ],
      ),
    );
  }
}

/// One payment row: shows the amount in the account's own currency; when that
/// differs from the invoice currency it also shows the frozen rate snapshot
/// and the computed equivalent (no technical ids exposed).
class _PaymentLine extends StatelessWidget {
  final Map payment;
  final String invoiceCurrency;
  const _PaymentLine({required this.payment, required this.invoiceCurrency});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payCur =
        (payment['payment_currency'] ?? invoiceCurrency).toString();
    final original = payment['original_amount'] ?? payment['amount'];
    final rate = parseMoney(payment['exchange_rate'] ?? 1);
    final equivalent = payment['equivalent_amount'] ?? payment['amount'];
    final cross = payCur != invoiceCurrency;
    final name =
        ((payment['bank_account_name'] ?? payment['payment_method']) ?? '')
            .toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(name,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        color: AppColors.textSecondary)),
              ),
              Expanded(child: InvoiceAmount('${fmtNum(parseMoney(original))} ${currencyLabel(payCur)}',
                  alignment: AlignmentDirectional.centerEnd,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.success))),
            ],
          ),
          if (cross)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 2, start: 2),
              child: Text(
                '${l10n.translate('saleExchangeRate')}: 1 ${currencyLabel(payCur)} = ${_fmtRate(rate)} ${currencyLabel(invoiceCurrency)}  •  ${l10n.translate('saleEquivalent')}: ${fmtNum(parseMoney(equivalent))} ${currencyLabel(invoiceCurrency)}',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmtRate(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(4);
}
