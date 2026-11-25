import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../invoices/presentation/pdf/invoice_pdf.dart';
import '../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../printing/presentation/pages/print_page.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../providers/returns_providers.dart';
import '../../data/returns_api.dart';
import 'return_view_page.dart';

/// Post-confirm success card for a return — same design language as the
/// sale/purchase success dialog: «تم تسجيل المرتجع» (NO amount), a primary
/// «مرتجع جديد» and a secondary «عرض تفاصيل الفاتورة» that reveals
/// print / share / view.
class ReturnSuccessDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> result;
  final bool isSale;
  const ReturnSuccessDialog({
    super.key,
    required this.result,
    required this.isSale,
  });
  @override
  ConsumerState<ReturnSuccessDialog> createState() =>
      _ReturnSuccessDialogState();
}

class _ReturnSuccessDialogState extends ConsumerState<ReturnSuccessDialog> {
  bool _busy = false;
  late final ReturnsApi _source;
  late final _scope = ref.read(businessLocalLedgerScopeProvider);

  Map<String, InvoiceDesignPreset>? get _localPresets => _scope == null
      ? null
      : ref.read(localInvoiceDesignProvider(_scope)).valueOrNull ?? const {};

  @override
  void initState() {
    super.initState();
    _source = ref.read(returnsApiProvider);
  }

  Map<String, dynamic> get _ret =>
      Map<String, dynamic>.from((widget.result['return'] as Map?) ?? const {});
  String get _no => shortDocumentNumber(_ret['return_number']);
  String get _id => (_ret['id'] ?? '').toString();
  String get _kind =>
      (_ret['kind'] ?? (widget.isSale ? 'sale_return' : 'purchase_return'))
          .toString();

  Future<Map<String, dynamic>?> _detail() async {
    if (_id.isEmpty || !identical(_source, ref.read(returnsApiProvider)))
      return null;
    try {
      return await _source.detail(_kind, _id);
    } catch (_) {
      return null;
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
      'invoice_number': shortDocumentNumber(r['return_number']),
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
      'original_invoice': shortDocumentNumber(r['invoice_number']),
      'status': r['status'],
      'cashier_name': r['cashier_name'],
      'cashier_role': r['cashier_role'],
      'items': items,
    };
  }

  Future<void> _openPrint() async {
    final r = await _detail();
    if (r == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InvoicePrintPage(
          invoice: _printMap(r),
          isPurchase: !widget.isSale,
          isReturn: true,
          localPresets: _localPresets,
        ),
      ),
    );
  }

  Future<void> _share() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await _detail();
      if (r == null) return;
      final design = _scope == null
          ? ref.read(invoiceDesignProvider.notifier).getPreset('return_paper')
          : _localPresets!['return_paper'] ??
                InvoiceDesignPreset.defaults('return_paper');
      final bytes = await buildInvoicePdf(
        _printMap(r),
        design,
        templateId: 'return_paper',
        isPurchase: !widget.isSale,
      );
      await Printing.sharePdf(bytes: bytes, filename: 'return-$_no.pdf');
    } catch (_) {
      if (mounted) {
        _snack(l10n.translate('txOperationFailed'), AppColors.danger);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openView() async {
    final r = await _detail();
    if (r == null || !mounted) return;
    if (_scope != null) {
      await openCommerceRecord(
        context,
        RouteNames.returnsView,
        _id,
        kind: _kind,
        fromLocal: _scope,
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReturnViewPage(kind: _kind, id: _id),
        ),
      );
    }
  }

  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _more() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16 + MediaQuery.of(ctx).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            _Option(
              icon: Icons.print_outlined,
              label: l10n.translate('retPrintInvoice'),
              onTap: () => Navigator.pop(ctx, 'print'),
            ),
            const SizedBox(height: 8),
            _Option(
              icon: Icons.share_outlined,
              label: l10n.translate('retShareInvoice'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            const SizedBox(height: 8),
            _Option(
              icon: Icons.visibility_outlined,
              label: l10n.translate('retViewInvoiceFull'),
              onTap: () => Navigator.pop(ctx, 'view'),
            ),
          ],
        ),
      ),
    );
    if (picked == 'print') {
      await _openPrint();
    } else if (picked == 'share') {
      await _share();
    } else if (picked == 'view') {
      await _openView();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope != null) ref.watch(localInvoiceDesignProvider(scope));
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: AlignmentDirectional.topStart,
            child: IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.translate('saleClose'),
              onPressed: () {
                Navigator.pop(context);
                context.go(RouteNames.returns);
              },
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
            child: const Icon(
              Icons.check_rounded,
              size: 34,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${l10n.translate('retRecordedOk')} #$_no',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 16),
              height: 1.4,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                context.go(RouteNames.returns);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.add, size: 20),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  l10n.translate('retNewReturn'),
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _more,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.receipt_long_outlined, size: 20),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  l10n.translate('retInvoiceDetails'),
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Option({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  height: 1.4,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Icon(
              Icons.chevron_left_rounded,
              size: 22,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
