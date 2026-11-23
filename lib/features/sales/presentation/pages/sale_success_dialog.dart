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
import '../../../invoices/presentation/pdf/invoice_pdf.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../printing/presentation/pages/print_page.dart';
import '../providers/sale_providers.dart';
import 'sale_invoice_pdf.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';

/// Post-issue success card: «تم إصدار الفاتورة #N بنجاح».
///
/// Layout: small close button (back to the main screen), then a full-width
/// «بيع جديد», then the same-size «عرض المزيد عن الفاتورة» which expands
/// inline to print / share / view. Printing offers paper (A4) or thermal
/// (80mm, tailored receipt) — one tap each, no extra steps.
class SaleSuccessDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> invoice;
  const SaleSuccessDialog({super.key, required this.invoice});
  @override
  ConsumerState<SaleSuccessDialog> createState() =>
      _SaleSuccessDialogState();
}

class _SaleSuccessDialogState extends ConsumerState<SaleSuccessDialog> {
  bool _expanded = false;
  bool _busy = false;

  Map<String, dynamic> get _inv => widget.invoice;
  late final _scope = ref.read(businessLocalLedgerScopeProvider);

  Map<String, InvoiceDesignPreset>? get _localPresets =>
      _scope == null ? null : ref.read(localInvoiceDesignProvider(_scope)).valueOrNull ?? const {};

  InvoiceDesignPreset _preset(String id) => _scope == null
      ? ref.read(invoiceDesignProvider.notifier).getPreset(id)
      : _localPresets![id] ?? InvoiceDesignPreset.defaults(id);

  Future<void> _printPaper() async {
    setState(() => _busy = true);
    try {
      Map<String, Uint8List>? imgs;
      if (await invoiceImagesEnabled()) {
        imgs = await collectInvoiceImages(_inv, ref.read(dioProvider), localOnly: _scope != null);
      }
      final d = _preset('paper');
      final bytes = await buildInvoicePdf(_inv, d,
          templateId: 'paper', isPurchase: false, images: imgs);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _printThermal() async {
    setState(() => _busy = true);
    try {
      final d = _preset('thermal');
      final bytes = await buildInvoicePdf(_inv, d,
          templateId: 'thermal', isPurchase: false);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _printThermal58() async {
    setState(() => _busy = true);
    try {
      final d = _preset('thermal58');
      final bytes = await buildInvoicePdf(_inv, d,
          templateId: 'thermal58', isPurchase: false);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final d = _preset('paper');
      final bytes = await buildInvoicePdf(_inv, d,
          templateId: 'paper', isPurchase: false);
      final no = (_inv['invoice_number'] ?? '').toString();
      await Printing.sharePdf(bytes: bytes, filename: 'invoice-$no.pdf');
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickPrint() async {
    if (!mounted) return;
    // Direct to the in-app print center — there the merchant chooses the
    // paper type (A4 / thermal 80 / thermal 58), copies, printer, etc.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InvoicePrintPage(
        invoice: _inv,
        isPurchase: false,
        localPresets: _localPresets,
      ),
    ));
    if (mounted) setState(() => _busy = false);
  }

  void _closeToHome() {
    ref.read(saleDraftProvider.notifier).reset();
    Navigator.pop(context);
    context.go(RouteNames.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope != null) ref.watch(localInvoiceDesignProvider(scope));
    final l10n = AppLocalizations.of(context);
    final no = (_inv['invoice_number'] ?? '').toString();
    return AlertDialog(
      scrollable: true,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: AlignmentDirectional.topStart,
            child: IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.translate('saleClose'),
              onPressed: _closeToHome,
              icon: const Icon(Icons.close_rounded, size: 20),
              color: AppColors.textSecondary,
            ),
          ),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.success.withAlpha(25),
            ),
            child: const Icon(Icons.check_rounded,
                size: 34, color: AppColors.success),
          ),
          const SizedBox(height: 12),
          Text(
            '${l10n.translate('saleIssuedOk')} #$no',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: () {
                ref.read(saleDraftProvider.notifier).reset();
                Navigator.pop(context);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.add, size: 20),
              label: Text(l10n.translate('saleNewSale'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 15),
                      height: 1.5,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.tonalIcon(
              onPressed: _busy
                  ? null
                  : () => setState(() => _expanded = !_expanded),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20),
              label: Text(l10n.translate('saleMoreAboutInvoice'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 15),
                      height: 1.5,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            child: _expanded
                ? Column(
                    children: [
                      const SizedBox(height: 10),
                      _MoreRow(
                        icon: Icons.print_outlined,
                        label: l10n.translate('salePrint'),
                        busy: _busy,
                        onTap: _pickPrint,
                      ),
                      const SizedBox(height: 8),
                      _MoreRow(
                        icon: Icons.share_outlined,
                        label: l10n.translate('saleShare'),
                        busy: _busy,
                        onTap: _share,
                      ),
                      const SizedBox(height: 8),
                      _MoreRow(
                        icon: Icons.visibility_outlined,
                        label: l10n.translate('saleViewInvoice'),
                        busy: _busy,
                        onTap: () {
                          Navigator.pop(context);
                          ref
                              .read(saleDraftProvider.notifier)
                              .reset();
                          openCommerceRecord(context, RouteNames.invoicesView,
                              '${_inv['id']}', kind: 'sale', fromLocal: _scope);
                        },
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback onTap;
  const _MoreRow(
      {required this.icon,
      required this.label,
      required this.busy,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        icon: Icon(icon, size: 19),
        label: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                height: 1.5,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _PrintOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _PrintOption(
      {required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withAlpha(70),
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
            ),
            Icon(Icons.chevron_left_rounded,
                size: 22, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
