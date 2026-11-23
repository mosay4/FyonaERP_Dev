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
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_party.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../sales/presentation/pages/sale_invoice_pdf.dart'
    show collectInvoiceImages, invoiceImagesEnabled;
import '../../data/invoice_design_models.dart';
import '../../data/file_save_service.dart';
import '../../../printing/presentation/pages/print_page.dart';
import '../pdf/invoice_pdf.dart';
import '../providers/invoice_design_provider.dart';
import '../providers/invoices_providers.dart';
import '../widgets/invoice_preview_card.dart';

/// Professional invoice view for sale & purchase. Shows the SAME design the
/// merchant customized (paper template) and offers save / share / print
/// (thermal or paper) using the exact customized templates.
class InvoiceViewPage extends ConsumerStatefulWidget {
  final String type; // 'sale' | 'purchase'
  final String id;
  final DirectoryDebtInvoiceReference? localOpeningInvoice;
  final LocalCommerceTarget? localCommerce;
  const InvoiceViewPage({
    super.key, required this.type, required this.id, this.localOpeningInvoice,
    this.localCommerce,
  });
  @override
  ConsumerState<InvoiceViewPage> createState() => _InvoiceViewPageState();
}

class _InvoiceViewPageState extends ConsumerState<InvoiceViewPage> {
  Map<String, dynamic>? _inv;
  bool _loading = true;
  Object? _error;
  bool _busy = false;
  final TransformationController _tc = TransformationController();
  bool _fittedOnce = false;

  bool get _isPurchase => widget.type == 'purchase';
  DirectoryAccess? get _localScope =>
      widget.localOpeningInvoice?.party.scope ?? widget.localCommerce?.scope;

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
    try {
      final target = widget.localOpeningInvoice;
      final commerce = widget.localCommerce;
      if (commerce != null && !commerce.allows(
          ref.read(businessLocalLedgerScopeProvider), RouteNames.invoicesView)) {
        throw const DirectoryAccessDenied();
      }
      final inv = target == null
          ? await ref.read(invoicesApiProvider).getInvoice(widget.id)
          : await withBusinessLedger(
              ref, target.party.scope, BusinessLedgerAction.readDebt,
              ['debts.details', '${target.party.kind.name}s.details',
                _isPurchase ? 'purchases.view' : 'sales.view'],
               (ledger, grant) => ledger.openingInvoice(grant, target),
             );
      if (!mounted) return;
      if (commerce != null &&
          (inv['invoice_type'] != widget.type ||
              !commerce.allows(ref.read(businessLocalLedgerScopeProvider), RouteNames.invoicesView))) {
        throw const DirectoryAccessDenied();
      }
      setState(() {
        _inv = inv;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  InvoiceDesignPreset _design(String templateId) {
    final scope = _localScope;
    return scope == null
          ? ref.read(invoiceDesignProvider.notifier).getPreset(templateId)
          : ref.read(localInvoiceDesignProvider(scope))
                .valueOrNull?[templateId] ?? InvoiceDesignPreset.defaults(templateId);
  }

  Future<Map<String, Uint8List>> _images() async {
    if (widget.localOpeningInvoice != null) return {};
    try {
      if (await invoiceImagesEnabled()) {
        return await collectInvoiceImages(_inv!, ref.read(dioProvider), localOnly: _localScope != null);
      }
    } catch (_) {}
    return {};
  }

  Future<void> _savePdf() async {
    if (_inv == null) return;
    setState(() => _busy = true);
    try {
      final imgs = await _images();
      final bytes = await buildInvoicePdf(_inv!, _design('paper'),
          templateId: 'paper', isPurchase: _isPurchase, images: imgs);
      final res = await FileSaveService.savePdf(
          bytes, 'invoice-${_inv!['invoice_number']}.pdf');
      if (!mounted) return;
      if (res['success'] == true) {
        _snack(
            AppLocalizations.of(context).translate('invoiceSavedToDevice'),
            AppColors.success);
      } else {
        _snack((res['message'] ?? '').toString(), AppColors.danger);
      }
    } catch (e) {
      if (mounted) _snack('$e', AppColors.danger);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _share() async {
    if (_inv == null) return;
    setState(() => _busy = true);
    try {
      final imgs = await _images();
      final bytes = await buildInvoicePdf(_inv!, _design('paper'),
          templateId: 'paper', isPurchase: _isPurchase, images: imgs);
      await Printing.sharePdf(
          bytes: bytes, filename: 'invoice-${_inv!['invoice_number']}.pdf');
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickPrint() async {
    if (_inv == null) return;
    final scope = _localScope;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InvoicePrintPage(
          invoice: _inv!, isPurchase: _isPurchase,
          localPresets: scope == null ? null
              : ref.read(localInvoiceDesignProvider(scope))
                  .valueOrNull ?? const {}),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    final local = widget.localOpeningInvoice;
    final commerce = widget.localCommerce;
    final localScope = _localScope;
     if (commerce != null &&
         (!commerce.allows(ref.watch(businessLocalLedgerScopeProvider), RouteNames.invoicesView) ||
             !ref.watch(employeeCanProvider(_isPurchase ? 'purchases.view' : 'sales.view')))) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    if (local != null) {
      final scope = ref.watch(businessLocalLedgerScopeProvider);
      if (!sameDirectoryScope(scope, local.party.scope) ||
          !ref.watch(employeeCanProvider('${local.party.kind.name}s.details')) ||
          !ref.watch(employeeCanProvider('debts.details')) ||
          !ref.watch(employeeCanProvider(_isPurchase ? 'purchases.view' : 'sales.view'))) {
        return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
      }
    }
    final design = (localScope == null
         ? ref.watch(invoiceDesignProvider)['paper']
         : ref.watch(localInvoiceDesignProvider(localScope)).valueOrNull?['paper']) ??
        InvoiceDesignPreset.defaults('paper');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
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
              context.go(RouteNames.invoices);
            }
          },
        ),
        title: Text(
            '${l10n.translate(_isPurchase ? 'bizPurchaseInvoice' : 'bizSaleInvoice')}'
            '${_inv != null ? ' • ${_inv!['invoice_number']}' : ''}',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: _loading
           ? (localScope == null ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
           : error != null || _inv == null
               ? EmptyStateWidget(
                     title: l10n.translate('errorOccurred'),
                     subtitle: error == null ? '' :
                         businessOperationError(l10n, error, fallback: 'txOperationFailed'))
              : Column(children: [
                  Expanded(
                    child: Container(
                      color: AppColors.surfaceVariant.withAlpha(60),
                      child: LayoutBuilder(builder: (ctx, c) {
                        // True A4 proportions at 100% (fit to width), with
                        // zoom + pan. Long invoices render as one tall A4 page
                        // the user can scroll/pan.
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
                          boundaryMargin: const EdgeInsets.all(800),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Container(
                              width: a4Width,
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: AppColors.primary, width: 1.4),
                                  borderRadius: BorderRadius.circular(12)),
                              clipBehavior: Clip.antiAlias,
                              child: InvoicePreviewCard(
                                invoice: _inv!,
                                design: design,
                                isPurchase: _isPurchase,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  _actionsBar(l10n),
                ]),
    );
  }

  Widget _actionsBar(AppLocalizations l10n) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 10, 12, 10 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(children: [
        Expanded(
          child: _actionBtn(Icons.download_outlined,
              l10n.translate('invSavePdf'), _savePdf),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionBtn(Icons.share_outlined,
              l10n.translate('saleShare'), _share),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionBtn(Icons.print_outlined,
              l10n.translate('salePrint'), _pickPrint),
        ),
      ]),
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      height: 46,
      child: OutlinedButton.icon(
        onPressed: _busy ? null : onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: BorderSide(color: AppColors.primary.withAlpha(120)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        icon: Icon(icon, size: 18),
        label: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo', fontSize: R.fontSize(context, 11.5))),
      ),
    );
  }
}
