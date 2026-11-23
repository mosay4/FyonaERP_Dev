import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/business_selection_sheet.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/unsaved_exit_dialog.dart';
import '../providers/sale_providers.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../inventory/domain/services/invalidate_inventory_data.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../data/sales_api.dart';
import '../widgets/sale_field.dart';
import 'sale_success_dialog.dart';
import '../widgets/sale_customer_section.dart';
import '../widgets/sale_items_section.dart';
import '../widgets/sale_payment_section.dart';
import '../widgets/sale_section_card.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Sale invoice screen: customer → items → payment → totals → issue.
///
/// Deliberately simple for the merchant: the five blocks above, everything
/// else (tax, notes, due date, header discount) lives in extra options.
/// Emits atomic issues only — no drafts anywhere on this path.
class SaleInvoicePage extends ConsumerStatefulWidget {
  final String? prefillCustomerId;
  final String? prefillGroupId;
  final bool debtMode;
  const SaleInvoicePage(
      {super.key,
      this.prefillCustomerId,
      this.prefillGroupId,
      this.debtMode = false});

  @override
  ConsumerState<SaleInvoicePage> createState() => _SaleInvoicePageState();
}

class _SaleInvoicePageState extends ConsumerState<SaleInvoicePage> {
  final _scroll = ScrollController();
  final _itemsKey = GlobalKey();
  final _customerKey = GlobalKey();
  final _paymentKey = GlobalKey();
  bool _exiting = false;
  late final SalesApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(salesApiProvider);

    final cid = widget.prefillCustomerId;
    if (cid != null && cid.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final notifier = ref.read(saleDraftProvider.notifier);
        notifier.reset();
        notifier.setDebtGroup(widget.prefillGroupId);
        try {
          final source = _source;
          final party = source is LocalSalesApi
              ? await source.customer(cid)
              : Map<String, dynamic>.from((await ref.read(merchantApiProvider)
                    .businessOverview(partyKind: 'customer', partyId: cid))['party'] as Map? ?? const {});
          if (!mounted || !notifier.mounted || !identical(_source, ref.read(salesApiProvider))) return;
          notifier.setCustomer(SaleCustomer(
              id: cid,
              name: '${party['name'] ?? ''}',
              phone: '${party['phone'] ?? ''}'));
        } catch (_) {
          if (mounted && notifier.mounted && _source is! LocalSalesApi) {
            notifier.setCustomer(SaleCustomer(id: cid, name: ''));
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

  /// Whether the current sale draft holds anything the merchant entered.
  bool get _hasData => ref.read(saleDraftProvider).hasEnteredData;

  void _doExit() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RouteNames.dashboard);
    }
  }

  /// Leaving with data asks keep / discard / cancel. "Keep" leaves the draft
  /// intact (returning shows the same data); "discard" resets it (returning
  /// shows an empty invoice).
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
      ref.read(saleDraftProvider.notifier).reset();
    }
    _exiting = true;
    if (mounted) _doExit();
  }

  /// Maps an issue-blocking problem to the invoice section it belongs to.
  String _sectionFor(String problem) {
    if (problem == 'saleErrEmpty') return 'items';
    if (problem == 'saleErrNeedCustomer') return 'customer';
    return 'payment';
  }

  /// Jumps the user to the offending section, flashes it red for a few seconds
  /// and shows a short hint above it.
  Future<void> _flagProblem(String problem) async {
    final section = _sectionFor(problem);
    final key = switch (section) {
      'customer' => _customerKey,
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
    ref.read(saleHighlightProvider.notifier).state = section;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) ref.read(saleHighlightProvider.notifier).state = null;
    });
  }

  /// Wraps a section so it shows a red frame + hint while flagged.
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
    final notifier = ref.read(saleDraftProvider.notifier);
    final draft = ref.read(saleDraftProvider);
    final l10n = AppLocalizations.of(context);
    if (draft.issuing) return;
    if (BranchScope.readOnly || !identical(_source, ref.read(salesApiProvider))) {
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
        if (draft.customer?.id != null)
          'customer_id': draft.customer!.id,
        if (draft.debtGroupId != null)
          'debt_group_id': draft.debtGroupId,
        if (draft.discountType != null) ...{
          'discount_type': draft.discountType,
          'discount_value': draft.discountValue,
        },
        if (draft.taxType != null) ...{
          'tax_type': draft.taxType,
          'tax_rate': draft.taxRate,
        },
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
              'discount': it.discountAmount,
              if (it.newProduct != null) 'new_product': it.newProduct,
              if (it.originalUnitPrice != null)
                'original_price': it.originalUnitPrice,
              if ((it.priceCurrency ?? '').isNotEmpty)
                'price_currency': it.priceCurrency,
              if (it.exchangeRateUsed != null)
                'exchange_rate': it.exchangeRateUsed,
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
      final res = await _source.issueSale(body);
      if (!mounted || !identical(_source, ref.read(salesApiProvider))) return;

      // Selling changes stock: refresh EVERY stock-reading surface (list,
      // details, stats, lots, movements) in one shot.
      invalidateInventoryData(ref);
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => SaleSuccessDialog(invoice: res),
      );
    } catch (e) {
      if (!mounted) return;
      showSnackbar(
        context,
        message: businessOperationError(l10n, e, fallback: 'invoiceSaveFailed'),
        color: AppColors.danger,
      );
    } finally {
      notifier.finishIssuing(draft.idempotencyKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hl = ref.watch(saleHighlightProvider);
    return PopScope(
      canPop: _exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit();
      },
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('saleTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
                      hl == 'customer',
                      l10n.translate('saleErrNeedCustomer'),
                      KeyedSubtree(
                          key: _customerKey, child: const SaleCustomerSection())),
                  const SizedBox(height: 12),
                  _sectionFrame(
                      hl == 'items',
                      l10n.translate('saleErrEmpty'),
                      KeyedSubtree(
                          key: _itemsKey, child: const SaleItemsSection())),
                  const SizedBox(height: 12),
                  _sectionFrame(
                      hl == 'payment',
                      l10n.translate('saleNeedPayMode'),
                      KeyedSubtree(
                          key: _paymentKey, child: SalePaymentSection(allowedModes: widget.debtMode
                          ? const ['partial', 'credit']
                          : const ['full', 'partial', 'credit']))),
                  const SizedBox(height: 12),
                  const _ExtraOptions(),
                  const SizedBox(height: 12),
                  const _TotalsCard(),
                ],
              ),
            ),
            _IssueBar(onIssue: _issue, isLocal: _source is LocalSalesApi),
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
    final draft = ref.watch(saleDraftProvider);
    final t = draft.totals;
    return SaleSectionCard(
      titleKey: 'saleGrandTotal',
      trailing: Text(draft.currency,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.primary)),
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

/// Rarely-used knobs live here: header discount, tax, notes, due date.
class _ExtraOptions extends ConsumerStatefulWidget {
  const _ExtraOptions();
  @override
  ConsumerState<_ExtraOptions> createState() => _ExtraOptionsState();
}

class _ExtraOptionsState extends ConsumerState<_ExtraOptions> {
  bool _open = false;
  final _discountCtrl = TextEditingController();
  final _taxCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  @override
  void dispose() {
    _discountCtrl.dispose();
    _taxCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickKind(
    BuildContext context,
    String titleKey,
    String? current,
    ValueChanged<String?> onPick,
  ) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate(titleKey),
      selected: current,
      items: [
        BizSheetItem(
            value: 'none',
            title: l10n.translate('saleNone'),
            icon: Icons.remove_circle_outline),
        BizSheetItem(
            value: 'percentage',
            title: l10n.translate('salePercent'),
            icon: Icons.percent),
        BizSheetItem(
            value: 'fixed',
            title: l10n.translate('saleFixed'),
            icon: Icons.attach_money),
      ],
    );
    if (picked == null || !context.mounted) return;
    onPick(picked == 'none' ? null : picked);
  }

  String _kindLabel(String? kind) {
    final l10n = AppLocalizations.of(context);
    return switch (kind) {
      'percentage' => l10n.translate('salePercent'),
      'fixed' => l10n.translate('saleFixed'),
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(saleDraftProvider);
    final notifier = ref.read(saleDraftProvider.notifier);
    final l10n = AppLocalizations.of(context);
    return SaleSectionCard(
      titleKey: 'saleExtraOptions',
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: () => setState(() => _open = !_open),
        icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
        color: AppColors.textSecondary,
      ),
      child: _open
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MiniLabel(text: l10n.translate('saleHeaderDiscount')),
                Row(
                  children: [
                    Expanded(
                      child: SaleField(
                        value: _kindLabel(draft.discountType),
                        placeholder: l10n.translate('saleTapToSelect'),
                        onTap: () => _pickKind(
                          context,
                          'saleHeaderDiscount',
                          draft.discountType,
                          (v) {
                            _discountCtrl.text =
                                v == null ? '' : fmtNum(draft.discountValue);
                            notifier.setHeaderDiscount(
                                v, v == null ? 0 : draft.discountValue);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BusinessNumberField(
                        controller: _discountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [AmountInputFormatter()],
                        decoration: InputDecoration(labelText: l10n.translate('saleValue'), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                        style: const TextStyle(fontFamily: 'Cairo'),
                        onChanged: (v) => notifier.setHeaderDiscount(
                            draft.discountType, parseFormattedAmount(v) ?? 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _MiniLabel(text: l10n.translate('saleTax')),
                Row(
                  children: [
                    Expanded(
                      child: SaleField(
                        value: _kindLabel(draft.taxType),
                        placeholder: l10n.translate('saleTapToSelect'),
                        onTap: () => _pickKind(
                          context,
                          'saleTax',
                          draft.taxType,
                          (v) => notifier.setTax(
                              v, v == null ? 0 : draft.taxRate),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BusinessNumberField(
                        controller: _taxCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [AmountInputFormatter()],
                        decoration: InputDecoration(labelText: l10n.translate('saleValue'), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                        style: const TextStyle(fontFamily: 'Cairo'),
                        onChanged: (v) => notifier.setTax(
                            draft.taxType, parseFormattedAmount(v) ?? 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FyonaTextField(
                  controller: _notesCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(labelText: l10n.translate('saleNotes'), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  style: const TextStyle(fontFamily: 'Cairo'),
                  onChanged: (v) => notifier.setNotes(v.trim().isEmpty ? null : v.trim()),
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

class _MiniLabel extends StatelessWidget {
  final String text;
  const _MiniLabel({required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
    );
  }
}

class _IssueBar extends ConsumerWidget {
  final VoidCallback onIssue;
  final bool isLocal;
  const _IssueBar({required this.onIssue, required this.isLocal});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(saleDraftProvider);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 16 + MediaQuery.of(context).padding.bottom),
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
              : Text(l10n.translate('saleIssue'),
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
