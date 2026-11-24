import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/invoice_amount.dart';
import '../../../../core/utils/currency_formatter.dart'
    show fmtNum, currencyLabel;
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../sales/domain/sale_totals.dart' show parseMoney;
import '../../../sales/presentation/pages/sale_invoice_pdf.dart';
import '../providers/purchase_providers.dart';

/// Read-only purchase invoice detail: header, lines, payments, totals.
class PurchaseInvoiceViewPage extends ConsumerWidget {
  final String invoiceId;
  final LocalCommerceTarget? localTarget;
  const PurchaseInvoiceViewPage({super.key, required this.invoiceId, this.localTarget});

  Future<Map<String, Uint8List>?> _images(
      BuildContext context, Map<String, dynamic> inv) async {
    if (!await invoiceImagesEnabled()) return null;
    final dio = ProviderScope.containerOf(context, listen: false)
        .read(dioProvider);
    return collectInvoiceImages(inv, dio, localOnly: localTarget != null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final target = localTarget;
    if (target != null &&
        (!target.allows(ref.watch(businessLocalLedgerScopeProvider), RouteNames.purchasesView) ||
            !ref.watch(employeeCanProvider('purchases.view')))) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('saleViewInvoice'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
      ),
      body: FutureBuilder(
        future: ref.read(purchaseApiProvider).getInvoice(invoiceId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData || snap.data!.isEmpty) {
            return Center(
                child: Text(l10n.translate('saleNoInvoices'),
                    style: const TextStyle(fontFamily: 'Cairo')));
          }
          final inv = snap.data!;
          final cur = (inv['currency'] ?? 'SAR').toString();
          final items =
              (inv['items'] as List?)?.whereType<Map>().toList() ?? const [];
          final payments =
              (inv['payments'] as List?)?.whereType<Map>().toList() ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Card(children: [
                _row(context, l10n.translate('purSupplier'),
                    (inv['supplier_name'] ?? l10n.translate('purCashSupplier'))
                        .toString()),
                _row(context, '#', shortDocumentNumber(inv['invoice_number'])),
                if ((inv['due_date'] ?? '').toString().isNotEmpty)
                  _row(context, l10n.translate('saleDueDateOptional'),
                      inv['due_date'].toString()),
              ]),
              const SizedBox(height: 12),
              _Card(children: [
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
              ]),
              const SizedBox(height: 12),
              if (payments.isNotEmpty)
                _Card(children: [
                  for (final p in payments)
                    _row(
                      context,
                      (p['bank_account_name'] ?? p['payment_method'] ?? '')
                          .toString(),
                      '${fmtNum(parseMoney(p['original_amount'] ?? p['amount']))} ${currencyLabel((p['payment_currency'] ?? cur).toString())}',
                    ),
                ]),
              const SizedBox(height: 12),
              _Card(children: [
                _row(context, l10n.translate('saleSubtotal'),
                    '${fmtNum(parseMoney(inv['subtotal']))} ${currencyLabel(cur)}'),
                _row(context, l10n.translate('saleGrandTotal'),
                    '${fmtNum(parseMoney(inv['total']))} ${currencyLabel(cur)}'),
                _row(context, l10n.translate('salePaid'),
                    '${fmtNum(parseMoney(inv['paid_amount']))} ${currencyLabel(cur)}'),
                _row(context, l10n.translate('saleRemaining'),
                    '${fmtNum(parseMoney(inv['balance']))} ${currencyLabel(cur)}'),
              ]),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final imgs = await _images(context, inv);
                        final bytes =
                            await buildSaleInvoicePdf(inv, images: imgs);
                        await Printing.layoutPdf(
                            onLayout: (_) async => bytes);
                      },
                      icon: const Icon(Icons.print_outlined, size: 18),
                      label: Text(l10n.translate('salePrint'),
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final imgs = await _images(context, inv);
                        final bytes =
                            await buildSaleInvoicePdf(inv, images: imgs);
                        final no = shortDocumentNumber(inv['invoice_number']);
                        await Printing.sharePdf(
                            bytes: bytes, filename: 'purchase-$no.pdf');
                      },
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: Text(l10n.translate('saleShare'),
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _h(BuildContext c, String t, int flex,
          {TextAlign align = TextAlign.center}) =>
      Expanded(
        flex: flex,
        child: Text(t,
            textAlign: align,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(c, 11),
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary)),
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

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textSecondary)),
            ),
            Expanded(child: InvoiceAmount(value,
                alignment: AlignmentDirectional.centerEnd,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary))),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
