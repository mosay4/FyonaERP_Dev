import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../invoices/data/file_save_service.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../invoices/presentation/pdf/invoice_pdf.dart';
import '../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../invoices/presentation/widgets/invoice_preview_card.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../printing/presentation/pages/print_page.dart';
import '../../data/returns_api.dart';
import '../providers/returns_providers.dart';

/// Read-only A4 view of one return (customer or supplier), linked to its
/// invoice — same professional preview + zoom as the sale/purchase invoice
/// view, using the merchant's return-paper customization.
class ReturnViewPage extends ConsumerStatefulWidget {
  final String kind;
  final String id;
  final LocalCommerceTarget? localTarget;
  const ReturnViewPage({
    super.key,
    required this.kind,
    required this.id,
    this.localTarget,
  });
  @override
  ConsumerState<ReturnViewPage> createState() => _ReturnViewPageState();
}

class _ReturnViewPageState extends ConsumerState<ReturnViewPage> {
  Map<String, dynamic>? _ret;
  bool _loading = true;
  bool _busy = false;
  final TransformationController _tc = TransformationController();
  bool _fittedOnce = false;

  bool get _isSupplier => widget.kind == 'purchase_return';
  late final ReturnsApi _source;
  final _permissionByKind = const {
    'sale_return': 'sales.returns',
    'purchase_return': 'purchases.returns',
  };
  String get _permission => _permissionByKind[widget.kind] ?? 'sales.returns';
  bool get _isCurrent =>
      mounted &&
      identical(_source, ref.read(returnsApiProvider)) &&
      (widget.localTarget?.allows(
            ref.read(businessLocalLedgerScopeProvider),
            RouteNames.returnsView,
          ) ??
          true);

  DirectoryAccess? get _scope => widget.localTarget?.scope;

  Map<String, InvoiceDesignPreset>? get _localPresets {
    final scope = _scope;
    return scope == null
        ? null
        : ref.read(localInvoiceDesignProvider(scope)).valueOrNull ?? const {};
  }

  InvoiceDesignPreset _preset(String id) => _scope == null
      ? ref.read(invoiceDesignProvider.notifier).getPreset(id)
      : _localPresets![id] ?? InvoiceDesignPreset.defaults(id);

  @override
  void initState() {
    super.initState();
    _source = ref.read(returnsApiProvider);
    if (_isCurrent) _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _source.detail(widget.kind, widget.id);
      if (!_isCurrent) return;
      setState(() {
        _ret = r;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _printMap(Map<String, dynamic> r) {
    final isSupplier = (r['kind'] ?? '') == 'purchase_return';
    final items = <Map<String, dynamic>>[];
    for (final m in (r['items'] as List? ?? const [])) {
      if (m is Map) {
        items.add({
          'description': (m['description'] ?? '').toString(),
          'quantity': m['quantity'],
          'unit_price': m['unit_price'],
          'discount': 0,
          'total': m['total'],
        });
      }
    }
    return {
      'invoice_number': (r['return_number'] ?? '').toString(),
      'invoice_type': isSupplier ? 'purchase_return' : 'sale_return',
      'customer_name': isSupplier ? '' : (r['party'] ?? '').toString(),
      'supplier_name': isSupplier ? (r['party'] ?? '').toString() : '',
      'invoice_date': r['date'],
      'currency': (r['currency'] ?? '').toString(),
      'subtotal': r['total'],
      'total': r['total'],
      'paid_amount': r['total'],
      'balance': 0,
      'notes': (r['reason'] ?? '').toString(),
      'original_invoice': (r['invoice_number'] ?? '').toString(),
      'status': r['status'],
      'items': items,
    };
  }

  Future<void> _share() async {
    if (_ret == null || !_isCurrent) return;
    setState(() => _busy = true);
    try {
      final design = _preset('return_paper');
      final bytes = await buildInvoicePdf(
        _printMap(_ret!),
        design,
        templateId: 'return_paper',
        isPurchase: _isSupplier,
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'return-${_ret!['return_number']}.pdf',
      );
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _print() async {
    if (_ret == null || !_isCurrent) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InvoicePrintPage(
          invoice: _printMap(_ret!),
          isPurchase: _isSupplier,
          isReturn: true,
          localPresets: _localPresets,
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_ret == null || !_isCurrent) return;
    setState(() => _busy = true);
    try {
      final design = _preset('return_paper');
      final bytes = await buildInvoicePdf(
        _printMap(_ret!),
        design,
        templateId: 'return_paper',
        isPurchase: _isSupplier,
      );
      final res = await FileSaveService.savePdf(
        bytes,
        'return-${_ret!['return_number']}.pdf',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              res['success'] == true
                  ? AppLocalizations.of(
                      context,
                    ).translate('invoiceSavedToDevice')
                  : (res['message'] ?? '').toString(),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: res['success'] == true
                ? AppColors.success
                : AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = _scope;
    if (!identical(_source, ref.watch(returnsApiProvider)) ||
        (scope != null &&
            (!_isCurrent ||
                !ref.watch(employeeCanProvider('returns')) ||
                !ref.watch(employeeCanProvider(_permission))))) {
      return Scaffold(
        body: Center(child: Text(l10n.translate('unauthorized'))),
      );
    }
    final design =
        (scope == null
            ? ref.watch(invoiceDesignProvider)
            : ref
                  .watch(localInvoiceDesignProvider(scope))
                  .valueOrNull)?['return_paper'] ??
        InvoiceDesignPreset.defaults('return_paper');
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
              context.go('/returns');
            }
          },
        ),
        title: Text(
          l10n.translate(
            _isSupplier ? 'retSupplierReturn' : 'retCustomerReturn',
          ),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: _loading
          ? (scope != null ? const SizedBox.shrink()
              : const Center(child: CircularProgressIndicator()))
          : _ret == null
          ? EmptyStateWidget(
              title: l10n.translate('errorOccurred'),
              subtitle: '',
            )
          : Column(
              children: [
                Expanded(
                  child: Container(
                    color: AppColors.surfaceVariant.withAlpha(60),
                    child: LayoutBuilder(
                      builder: (ctx, c) {
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
                                  color: AppColors.primary,
                                  width: 1.4,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InvoicePreviewCard(
                                invoice: _printMap(_ret!),
                                design: design,
                                isPurchase: _isSupplier,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    10,
                    12,
                    10 + MediaQuery.of(context).padding.bottom,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border(top: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _actionBtn(
                          Icons.download_outlined,
                          l10n.translate('invSavePdf'),
                          _save,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _actionBtn(
                          Icons.share_outlined,
                          l10n.translate('saleShare'),
                          _share,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _actionBtn(
                          Icons.print_outlined,
                          l10n.translate('salePrint'),
                          _print,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 12),
          ),
        ),
      ),
    );
  }
}
