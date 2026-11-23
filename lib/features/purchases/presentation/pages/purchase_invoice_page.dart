import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/unsaved_exit_dialog.dart';
import '../../../sales/presentation/widgets/sale_section_card.dart';
import '../providers/purchase_providers.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../inventory/domain/services/invalidate_inventory_data.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../data/purchase_api.dart';
import '../widgets/purchase_items_section.dart';
import '../widgets/purchase_payment_section.dart';
import '../widgets/purchase_supplier_section.dart';
import 'purchase_success_dialog.dart';

/// Purchase invoice screen: supplier → items → payment → totals → issue.
/// Same five-block, seconds-to-finish philosophy as the sale invoice.
class PurchaseInvoicePage extends ConsumerStatefulWidget {
  final String? prefillSupplierId;
  final String? prefillGroupId;
  final bool debtMode;
  const PurchaseInvoicePage(
      {super.key,
      this.prefillSupplierId,
      this.prefillGroupId,
      this.debtMode = false});

  @override
  ConsumerState<PurchaseInvoicePage> createState() =>
      _PurchaseInvoicePageState();
}

class _PurchaseInvoicePageState extends ConsumerState<PurchaseInvoicePage> {
  final _scroll = ScrollController();
  final _itemsKey = GlobalKey();
  final _supplierKey = GlobalKey();
  final _paymentKey = GlobalKey();
  bool _exiting = false;
  late final PurchaseApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(purchaseApiProvider);

    final sid = widget.prefillSupplierId;
    if (sid != null && sid.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final notifier = ref.read(purchaseDraftProvider.notifier);
        notifier.reset();
        notifier.setDebtGroup(widget.prefillGroupId);
        try {
          final source = _source;
          final party = source is LocalPurchaseApi
              ? await source.supplier(sid)
              : Map<String, dynamic>.from((await ref.read(merchantApiProvider)
                    .businessOverview(partyKind: 'supplier', partyId: sid))['party'] as Map? ?? const {});
          if (!mounted || !notifier.mounted || !identical(_source, ref.read(purchaseApiProvider))) return;
          notifier.setSupplier(PurchaseSupplier(
              id: sid,
              name: '${party['name'] ?? ''}',
              phone: '${party['phone'] ?? ''}'));
        } catch (_) {
          if (mounted && notifier.mounted && _source is! LocalPurchaseApi) {
            notifier.setSupplier(PurchaseSupplier(id: sid, name: ''));
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _hasData => ref.read(purchaseDraftProvider).hasEnteredData;

  void _doExit() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RouteNames.dashboard);
    }
  }

  Future<void> _confirmExit() async {
    if (_exiting) return;
    if (!_hasData) {
      _doExit();
      return;
    }
    final action = await showUnsavedExitDialog(context);
    if (!mounted) return;
    if (action == UnsavedExitAction.cancel) return;
    if (action == UnsavedExitAction.discard) {
      ref.read(purchaseDraftProvider.notifier).reset();
    }
    _exiting = true;
    if (mounted) _doExit();
  }

  String _sectionFor(String problem) {
    if (problem == 'saleErrEmpty') return 'items';
    if (problem == 'saleErrNeedSupplier') return 'supplier';
    return 'payment';
  }

  Future<void> _flagProblem(String problem) async {
    final section = _sectionFor(problem);
    final key = switch (section) {
      'supplier' => _supplierKey,
      'items' => _itemsKey,
      _ => _paymentKey,
    };
    final ctx = key.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.1);
    } else if (_scroll.hasClients) {
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut);
    }
    if (!mounted) return;
    ref.read(purchaseHighlightProvider.notifier).state = section;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) ref.read(purchaseHighlightProvider.notifier).state = null;
    });
  }

  Widget _sectionFrame(bool on, String hint, Widget child) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: on ? Border.all(color: AppColors.danger, width: 2) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (on)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 4, left: 4),
              child: Text(hint,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger)),
            ),
          child,
        ],
      ),
    );
  }

  Future<void> _scrollToItems() async {
    final itemsCtx = _itemsKey.currentContext;
    if (itemsCtx != null) {
      await Scrollable.ensureVisible(
        itemsCtx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    } else if (_scroll.hasClients) {
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut);
    }
  }

  Future<void> _issue() async {
    final notifier = ref.read(purchaseDraftProvider.notifier);
    final draft = ref.read(purchaseDraftProvider);
    final l10n = AppLocalizations.of(context);
    if (draft.issuing) return;
    if (BranchScope.readOnly || !identical(_source, ref.read(purchaseApiProvider))) {
      showSnackbar(context, message: l10n.translate('unauthorized'), color: AppColors.danger);
      return;
    }

    final problem = notifier.validateForIssue();
    if (problem != null) {
      showSnackbar(context,
          message: l10n.translate(problem), color: AppColors.danger);
      await _flagProblem(problem);
      return;
    }
    notifier.setIssuing(true);
    try {
      final body = <String, dynamic>{
        'currency': draft.currency,
        if (draft.discountType != null) ...{
          'discount_type': draft.discountType, 'discount_value': draft.discountValue,
        },
        if (draft.taxType != null) ...{
          'tax_type': draft.taxType, 'tax_rate': draft.taxRate,
        },
        if (draft.supplier?.id != null) 'supplier_id': draft.supplier!.id,
        if (draft.debtGroupId != null)
          'debt_group_id': draft.debtGroupId,
        if ((draft.notes ?? '').isNotEmpty) 'notes': draft.notes,
        if (draft.dueDate != null)
          'due_date': draft.dueDate!.toIso8601String().split('T').first,
        'idempotency_key': draft.idempotencyKey,
        'items': [
          for (final it in draft.items)
            {
              if (it.productId != null) 'product_id': it.productId,
              if (it.unitId != null) 'unit_id': it.unitId,
              'description': it.description,
              'quantity': it.quantity,
              'unit_price': it.unitPrice,
              'discount': it.discount,
              if (it.newProduct != null) 'new_product': it.newProduct,
              if (it.originalUnitPrice != null)
                'original_price': it.originalUnitPrice,
              if ((it.priceCurrency ?? '').isNotEmpty)
                'price_currency': it.priceCurrency,
              if (it.exchangeRateUsed != null)
                'exchange_rate': it.exchangeRateUsed,
              if (it.expiryDate != null)
                'expiry_date': it.expiryDate!.toIso8601String().split('T').first,
              if ((it.lotNumber ?? '').isNotEmpty) 'lot_number': it.lotNumber,
            },
        ],
        'payments': [
          for (final p in draft.payments)
            if (p.accountId.isNotEmpty)
              {
                'bank_account_id': p.accountId,
                'amount': p.amount,
                'payment_method': p.method,
                'currency': p.currency,
                'exchange_rate': p.exchangeRate,
                'equivalent_amount': p.equivalent,
                'exchange_rate_source': p.rateSource,
                if (p.rateTimestamp != null)
                  'exchange_rate_timestamp':
                      p.rateTimestamp!.toIso8601String(),
              },
        ],
      };
      final res = await _source.issuePurchase(body);
      if (!mounted || !identical(_source, ref.read(purchaseApiProvider))) return;

      // A purchase can create products inline and always changes stock, so the
      // inventory list must refresh (otherwise a just-added product looks
      // "missing" until a manual pull-to-refresh).
      invalidateInventoryData(ref);
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PurchaseSuccessDialog(invoice: res),
      );
    } catch (e) {
      if (!mounted) return;
      showSnackbar(context,
          message: businessOperationError(l10n, e, fallback: 'invoiceSaveFailed'),
          color: AppColors.danger);
    } finally {
      notifier.finishIssuing(draft.idempotencyKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hl = ref.watch(purchaseHighlightProvider);
    return PopScope(
      canPop: _exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit();
      },
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('bizPurchaseInvoice'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 18),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: _confirmExit,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [

                  _sectionFrame(
                      hl == 'supplier',
                      l10n.translate('saleErrNeedSupplier'),
                      KeyedSubtree(
                          key: _supplierKey,
                          child: const PurchaseSupplierSection())),
                  const SizedBox(height: 12),
                  _sectionFrame(
                      hl == 'items',
                      l10n.translate('saleErrEmpty'),
                      KeyedSubtree(
                          key: _itemsKey, child: const PurchaseItemsSection())),
                  const SizedBox(height: 12),
                  _sectionFrame(
                      hl == 'payment',
                      l10n.translate('saleNeedPayMode'),
                      KeyedSubtree(
                          key: _paymentKey,
                          child: PurchasePaymentSection(allowedModes: widget.debtMode
                          ? const ['partial', 'credit']
                          : const ['full', 'partial', 'credit']))),
                  const SizedBox(height: 12),
                  const _TotalsCard(),
                ],
              ),
            ),
            _IssueBar(onIssue: _issue, isLocal: _source is LocalPurchaseApi),
          ],
        ),
      ),
      ),
    );
  }
}

class _TotalsCard extends ConsumerWidget {
  const _TotalsCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(purchaseDraftProvider);
    final t = draft.totals;
    return SaleSectionCard(
      titleKey: 'saleGrandTotal',
      trailing: Text(draft.currency,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w700,
              color: AppColors.primary)),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          '${_fmt(t['total']!)} ${draft.currency}',
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 22),
              fontWeight: FontWeight.w800,
              color: AppColors.primary),
        ),
      ),
    );
  }
}

String _fmt(double v) => fmtNum(v);

class _IssueBar extends ConsumerWidget {
  final VoidCallback onIssue;
  final bool isLocal;
  const _IssueBar({required this.onIssue, required this.isLocal});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(purchaseDraftProvider);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding:
          EdgeInsets.fromLTRB(16, 10, 16, 16 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton(
          onPressed: draft.issuing ? null : onIssue,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
           child: draft.issuing && !isLocal
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(l10n.translate('purIssue'),
                  maxLines: 1,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
