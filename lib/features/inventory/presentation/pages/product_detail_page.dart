import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:fyona_flutter/features/auth/presentation/widgets/app_pin_sheet.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/business_selection_sheet.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../providers/inventory_providers.dart';
import '../../domain/services/invalidate_inventory_data.dart';
import '../providers/warehouse_settings.dart';
import '../widgets/business_product_image.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../data/inventory_api.dart';

/// Simple product page: picture + the few key numbers, then a short section
/// for units/barcodes and clear actions (تعديل / زود / نقص / تعديل الكمية /
/// عرض الحركات). No accounting jargon.
class ProductDetailPage extends ConsumerWidget {
  final String id;
  final LocalCommerceTarget? localTarget;
  const ProductDetailPage({super.key, required this.id, this.localTarget});

  InventoryProductKey get _record => (id: id, target: localTarget);

  bool _isCurrent(WidgetRef ref, InventoryApi source) {
    final target = localTarget;
    return identical(source, ref.read(inventoryApiProvider)) &&
        (target == null ||
            target.allows(ref.read(businessLocalLedgerScopeProvider), RouteNames.inventoryProduct));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final target = localTarget;
    if (!ref.watch(employeeCanProvider('inventory')) ||
        (target != null && !target.allows(
          ref.watch(businessLocalLedgerScopeProvider), RouteNames.inventoryProduct))) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    final async = ref.watch(productDetailProvider(_record));
    final role = ref.watch(currentUserRoleProvider);
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    final canSeeCost = role != 'employee' && role != 'staff' && ws.showCost;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(l10n.translate('invProduct'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        actions: [
          if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit')))
          IconButton(
            tooltip: l10n.translate('invEdit'),
            onPressed: () async {
              final ok = await openCommerceRecord<bool>(
                  context, RouteNames.inventoryProductEdit, id,
                  fromLocal: localTarget?.scope);
              if (ok == true && context.mounted) ref.invalidate(productDetailProvider(_record));
            },
            icon: const Icon(Icons.edit_outlined),
          ),
          if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.delete')))
          IconButton(
             tooltip: l10n.translate('invDeleteProduct'),
             onPressed: () async {
                final source = ref.read(inventoryApiProvider);
                if (!_isCurrent(ref, source)) return;
                final okc = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l10n.translate('invDeleteProduct'),
                      style: const TextStyle(fontFamily: 'Cairo')),
                  content: Text(l10n.translate('invDeleteProductConfirm'),
                      style: const TextStyle(fontFamily: 'Cairo')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(l10n.translate('cancel'),
                            style: const TextStyle(fontFamily: 'Cairo'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(l10n.translate('invDeleteProduct'),
                            style: const TextStyle(fontFamily: 'Cairo'))),
                  ],
                ),
              );
              if (okc == true && context.mounted && _isCurrent(ref, source)) {
                final okv = await verifySensitiveAction(context, ref,
                    reason: l10n.translate('invDeleteProduct'));
                if (!okv || !context.mounted || !_isCurrent(ref, source)) return;
                try {
                  await source.deleteProduct(id);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(businessOperationError(l10n, e, fallback: 'invActionFailed')),
                    ));
                  }
                  return;
                }
                if (!context.mounted || !_isCurrent(ref, source)) return;
                ref.invalidate(inventoryProductsProvider);
                ref.invalidate(productDetailProvider);
                if (context.mounted) context.pop();
              }
            },
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
          ),
        ],
      ),
      body: async.when(
        loading: () => target != null ? const SizedBox.shrink()
            : const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(
            child: Text(l10n.translate('invLoadError'),
                style: const TextStyle(fontFamily: 'Cairo'))),
        data: (p) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _header(context, p, ws.productImages),
            const SizedBox(height: 16),
            _actions(context, ref, p),
            const SizedBox(height: 16),
            // Units & quantities — the base unit is ALWAYS shown; extra units
            // get their own box only when «الخيارات الإضافية» is enabled.
            _unitsCard(context, ref, p, canSeeCost),
            const SizedBox(height: 16),
            _lotsCard(context, ref, p, canSeeCost, ws.productImages),
            if (ws.multiCurrency) ...[
              _pricesCard(context, ref),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  /// Even the first receipt has a date and a remaining quantity to track.
  Widget _lotsCard(
      BuildContext context, WidgetRef ref, Map<String, dynamic> p,
      bool canSeeCost, bool showImage) {
    final l10n = AppLocalizations.of(context);
    final lots = ref.watch(productLotsProvider(_record));
    return lots.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (list) {
        final batches = [
          for (final l in list)
            if (((l['received'] as num?) ?? 0) > 0)
              Map<String, dynamic>.from(l)
        ];
        if (batches.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showBatchesSheet(
                  context, p, batches, canSeeCost, showImage),
              icon: const Icon(Icons.layers_outlined, size: 18),
              label: Text(
                  '${l10n.translate('invShowBatches')} (${batches.length})',
                  style: const TextStyle(fontFamily: 'Cairo')),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showBatchesSheet(BuildContext context, Map<String, dynamic> p,
      List<Map<String, dynamic>> batches, bool canSeeCost, bool showImage) async {
    final l10n = AppLocalizations.of(context);
    final baseUnit = '${p['unit'] ?? ''}';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(l10n.translate('invBatches'),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    for (var i = 0; i < batches.length; i++)
                       _batchRow(context, l10n, p, batches[i], i + 1,
                           baseUnit, canSeeCost, showImage),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One batch in plain language: number, qty, purchase price + currency.
  Widget _batchRow(BuildContext context, AppLocalizations l10n,
       Map<String, dynamic> p, Map<String, dynamic> l, int n,
       String baseUnit, bool canSeeCost, bool showImage) {
    final lotNo = '${l['lot_number'] ?? ''}';
    final received = ((l['received'] as num?) ?? 0).toDouble();
    final remaining = ((l['remaining'] as num?) ?? 0).toDouble();
    final cost = canSeeCost ? l['unit_cost'] : null;
    final cur = '${l['currency'] ?? ''}';
    final date = '${l['purchase_date'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(90),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                  '${l10n.translate('invBatch')} $n'
                  '${lotNo.isNotEmpty ? ' ($lotNo)' : ''}',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ),
            if (date.isNotEmpty)
              Text(date,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            if (showImage) ...[
              BusinessProductImage(
                url: (l['product_image'] ?? p['image'])?.toString(),
                width: 32, height: 32, fit: BoxFit.cover,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text('${l['product_name'] ?? p['name'] ?? ''}',
                style: const TextStyle(fontFamily: 'Cairo'))),
          ]),
          const SizedBox(height: 4),
          Text(
              '${l10n.translate('invBatchReceived')}: ${_fmt(received)} $baseUnit'
              ' • ${l10n.translate('invRemaining')}: '
              '${_fmt(remaining)} $baseUnit',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  color: AppColors.textPrimary)),
          if (cost != null) ...[
            const SizedBox(height: 2),
            Text(
                '${l10n.translate('invPurchasePrice')}: '
                '${fmtNum(cost)} $cur'.trim(),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context, Map<String, dynamic> p,
      bool showImage) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showImage) ...[
            Container(
              width: 84,
              height: 84,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withAlpha(90),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: (p['image']?.toString().isNotEmpty ?? false)
                   ? BusinessProductImage(
                      url: p['image']?.toString(),
                      width: 84,
                      height: 84,
                      fit: BoxFit.cover)
                  : Icon(Icons.inventory_2_outlined,
                      color: AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Text((p['name'] ?? '').toString(),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  /// Approximate permission gate for cost visibility (backend still enforces).
  bool containerRole(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    final role = container.read(currentUserRoleProvider);
    return role != 'employee' && role != 'staff';
  }

  Widget _actions(
      BuildContext context, WidgetRef ref, Map<String, dynamic> p) {
    final l10n = AppLocalizations.of(context);
    final stock = (p['stock'] as num?)?.toDouble() ?? 0;
    return Column(
      children: [
        Row(
          children: [
            if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit'))) ...[
              Expanded(
                child: _actionBtn(
                  context,
                  Icons.tune,
                  l10n.translate('invSetQty'),
                  () => _openAdjustMenu(context, ref, p, stock),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: _actionBtn(
                context,
                Icons.history,
                l10n.translate('invProductStats'),
                 () => openCommerceRecord(context, RouteNames.inventoryProductMovements, '${p['id']}',
                     fromLocal: localTarget?.scope),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actionBtn(
      BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        icon: Icon(icon, size: 19),
        label: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Future<void> _openTransfer(
      BuildContext context, WidgetRef ref, double current) async {
    final l10n = AppLocalizations.of(context);
    List<Map<String, dynamic>> branches = [];
    try {
      branches = await ref.read(inventoryApiProvider).branches();
    } catch (_) {}
    if (!context.mounted) return;
    if (branches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('invNoBranches'),
              style: const TextStyle(fontFamily: 'Cairo'))));
      return;
    }
    final qty = TextEditingController();
    String? toId = branches.first['id']?.toString();
    String toName = (branches.first['name'] ?? '').toString();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).padding.bottom),
          child: StatefulBuilder(
            builder: (ctx, setSt) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.translate('invTransfer'),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('${l10n.translate('invQtyNow')}: ${_fmt(current)}',
                    style: TextStyle(
                        fontFamily: 'Cairo', color: AppColors.textSecondary)),
                const SizedBox(height: 12),
                BusinessNumberField(
                  controller: qty,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      InputDecoration(labelText: l10n.translate('invAmount')),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                const SizedBox(height: 10),
                // A clean selection field (opens a tidy bottom sheet) instead
                // of a dropdown that jumps with the keyboard.
                GestureDetector(
                  onTap: () async {
                    final picked =
                        await showBusinessSelectionSheet<Map<String, dynamic>>(
                      context: context,
                      title: l10n.translate('invToBranch'),
                      items: [
                        for (final b in branches)
                          BizSheetItem(
                            value: b,
                            title: (b['name'] ?? '').toString(),
                            icon: Icons.account_tree_outlined,
                          ),
                      ],
                    );
                    if (picked != null) {
                      setSt(() {
                        toId = picked['id']?.toString();
                        toName = (picked['name'] ?? '').toString();
                      });
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant.withAlpha(70),
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                              '${l10n.translate('invToBranch')}: $toName',
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w600)),
                        ),
                        Icon(Icons.keyboard_arrow_down_rounded,
                            color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(l10n.translate('save'),
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      final amt = double.tryParse(qty.text.trim()) ?? 0;
      try {
        await ref.read(inventoryApiProvider).transferStock({
          'product_id': id,
          'to_branch_id': toId,
          'quantity': amt,
        });
        invalidateInventoryData(ref);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$e', style: const TextStyle(fontFamily: 'Cairo'))));
        }
      }
    }
    qty.dispose();
  }

  Widget _unitsCard(BuildContext context, WidgetRef ref,
      Map<String, dynamic> p, bool showCost) {
    final l10n = AppLocalizations.of(context);
    final units = ref.watch(productUnitsProvider(_record));
    final extraOn = ref.watch(warehouseSettingsProvider).extraOptions;
    final stock = (p['stock'] as num?)?.toDouble() ?? 0;
    final baseUnit = '${p['unit'] ?? ''}';
    final curSymbol = currencySymbol('${p['cost_currency'] ?? ''}');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.translate('invUnitDetails'),
              style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          // The BASE unit is ALWAYS shown (its quantity now lives here instead
          // of the header).
          _unitBox(context, l10n,
              name: baseUnit,
              factor: 1,
              qtyText: '${_fmt(stock)} $baseUnit'.trim(),
              baseUnit: baseUnit,
              sale: p['price'],
              purchase: p['cost_price'],
              curSymbol: curSymbol,
              showCost: showCost,
              showFactor: false),
          // Extra units: one independent box each — rendered ONLY when the
          // «الخيارات الإضافية» inventory setting is enabled. The data always
          // exists; turning the setting off never deletes it.
          if (extraOn)
            units.when(
              loading: () => const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)))),
              error: (_, __) => const SizedBox.shrink(),
              data: (d) {
                final list =
                    (d['units'] as List?)?.whereType<Map>() ?? const [];
                final extras = [
                  for (final u in list)
                    if (u['is_base'] != true) Map<String, dynamic>.from(u)
                ];
                return Column(
                  children: [
                    for (final u in extras)
                      _unitBox(context, l10n,
                          name: '${u['name'] ?? ''}',
                          factor: ((u['factor'] ?? 1) as num).toDouble(),
                          qtyText: productUnitAvailableText(
                              stock,
                              ((u['factor'] ?? 1) as num).toDouble(),
                              '${u['name'] ?? ''}',
                              baseUnit),
                          baseUnit: baseUnit,
                          sale: u['sale_price'],
                          purchase: u['purchase_price'],
                          curSymbol: curSymbol,
                          showCost: showCost),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  /// One independent box for a unit: its real name, a plain-language
  /// equivalence («1 باكيت = 8 قطع»), the available quantity IN THAT UNIT,
  /// and its saved sale/purchase prices (with the currency). Technical group
  /// labels stay internal (compatibility) and are never shown.
  Widget _unitBox(
    BuildContext context,
    AppLocalizations l10n, {
    required String name,
    required double factor,
    required String qtyText,
    required String baseUnit,
    dynamic sale,
    dynamic purchase,
    required String curSymbol,
    required bool showCost,
    bool showFactor = true,
  }) {
    final showSale = sale != null;
    final showPurchase = purchase != null && showCost;
    final hasPrices = showSale || showPurchase;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(90),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withAlpha(40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(18),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.inventory_2_outlined,
                    size: 17, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? l10n.translate('invNone') : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13.5),
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                    if (showFactor)
                      Text(
                          '1 $name = ${_fmt(factor)} $baseUnit',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 11),
                              color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(14),
                    borderRadius: BorderRadius.circular(9)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(l10n.translate('invAvailQty'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 9),
                            color: AppColors.textSecondary)),
                    Text(qtyText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12.5),
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary)),
                  ],
                ),
              ),
            ],
          ),
          if (hasPrices) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (showSale)
                  _unitPriceChip(
                      context,
                      l10n.translate('invSellPrice'),
                      '${fmtNum(sale)} $curSymbol'.trim(),
                      AppColors.primary),
                if (showPurchase)
                  _unitPriceChip(
                      context,
                      l10n.translate('invPurchasePrice'),
                      '${fmtNum(purchase)} $curSymbol'.trim(),
                      AppColors.textSecondary),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _unitPriceChip(
      BuildContext context, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(8)),
      child: Text('$label: $value',
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              fontWeight: FontWeight.w700,
              color: color)),
    );
  }

  Widget _pricesCard(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prices = ref.watch(productPricesProvider(_record));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.translate('invPrices'),
              style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          prices.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => list.isEmpty
                ? Text(l10n.translate('invNone'),
                    style: TextStyle(
                        fontFamily: 'Cairo', color: AppColors.textSecondary))
                : Column(
                    children: [
                      for (final p in list)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                              '${fmtNum(p['price'])} ${currencyName('${p['currency']}')}',
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAdjustMenu(BuildContext context, WidgetRef ref,
      Map<String, dynamic> p, double current) async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(inventoryApiProvider);
    if (!_isCurrent(ref, api)) return;
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('invAdjustTitle'),
      items: [
        BizSheetItem(
            value: 'add',
            title: l10n.translate('invIncrease'),
            icon: Icons.add_circle_outline),
        BizSheetItem(
            value: 'remove',
            title: l10n.translate('invDecrease'),
            icon: Icons.remove_circle_outline),
        BizSheetItem(
            value: 'set',
            title: l10n.translate('invSetQty'),
            icon: Icons.tune),
      ],
    );
    if (picked == null || !context.mounted || !_isCurrent(ref, api)) return;

    // The product's real units (base + extras). The unit picker appears ONLY
    // when the product actually has more than one unit.
    List<Map<String, dynamic>> units = [];
    try {
      final d = await ref.read(productUnitsProvider(_record).future);
      final raw = (d['units'] as List?) ?? const [];
      units = [
        for (final u in raw)
          if (u is Map) Map<String, dynamic>.from(u)
      ];
    } catch (_) {}
    if (!context.mounted || !_isCurrent(ref, api)) return;

    Map<String, dynamic>? unit;
    if (units.length > 1) {
      final uid = await showBusinessSelectionSheet<String>(
        context: context,
        title: l10n.translate('invPickUnit'),
        items: [
          for (final u in units)
            BizSheetItem(
                value: '${u['id']}',
                title: u['is_base'] == true
                    ? '${u['name'] ?? ''} (${l10n.translate('invBaseUnit')})'
                    : '${u['name'] ?? ''} ×${_fmt(u['factor'])}',
                icon: Icons.inventory_2_outlined),
        ],
      );
      if (uid == null || !context.mounted || !_isCurrent(ref, api)) return;
      unit = units.firstWhere((u) => '${u['id']}' == uid,
          orElse: () => units.first);
    } else if (units.length == 1) {
      unit = units.first;
    }

    final factor =
        unit == null ? 1.0 : ((unit['factor'] ?? 1) as num).toDouble();
    final unitName =
        unit == null ? '${p['unit'] ?? ''}' : '${unit['name'] ?? ''}';
    await _openAdjust(context, ref, api, picked, current,
        factor: factor,
        unitName: unitName,
        baseUnit: '${p['unit'] ?? ''}',
        showUnit: units.length > 1);
  }

  Future<void> _openAdjust(
      BuildContext context, WidgetRef ref, InventoryApi api, String mode, double current,
      {required double factor,
      required String unitName,
      required String baseUnit,
      required bool showUnit}) async {
    final l10n = AppLocalizations.of(context);
    final amount = TextEditingController();
    String reason = 'wrong';
    final reasons = {
      'wrong': 'invReasonWrong',
      'damaged': 'invReasonDamaged',
      'lost': 'invReasonLost',
      'extra': 'invReasonExtra',
      'other': 'invReasonOther',
    };
    final label = mode == 'add'
        ? 'invAmountAdd'
        : mode == 'remove'
            ? 'invAmountRemove'
            : 'invNewQty';
    // A bottom sheet whose FIELDS scroll and whose save button is PINNED at the
    // bottom, so «حفظ التعديل» is never clipped by the keyboard or a long list.
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: StatefulBuilder(
                builder: (ctx, setSt) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.translate('invAdjustTitle'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            Text(
                                '${l10n.translate('invQtyNow')}: '
                                '${productUnitAvailableText(current, factor, unitName, baseUnit)}',
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    color: AppColors.textSecondary)),
                            if (showUnit) ...[
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                    color: AppColors.primary.withAlpha(14),
                                    borderRadius: BorderRadius.circular(8)),
                                child: Text(
                                    '${l10n.translate('invPickUnit')}: '
                                    '$unitName${factor > 1 ? ' ×${_fmt(factor)}' : ''}',
                                    style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.primary)),
                              ),
                            ],
                            const SizedBox(height: 12),
                            BusinessNumberField(
                              controller: amount,
                              autofocus: true,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: InputDecoration(
                                  labelText: l10n.translate(label),
                                  helperText: factor > 1
                                      ? '= ×${_fmt(factor)} $baseUnit'
                                      : null),
                              style: const TextStyle(fontFamily: 'Cairo'),
                            ),
                            const SizedBox(height: 12),
                            Text(l10n.translate('invReason'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final e in reasons.entries)
                                  ChoiceChip(
                                    label: Text(l10n.translate(e.value),
                                        style: const TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: 12)),
                                    selected: reason == e.key,
                                    onSelected: (_) =>
                                        setSt(() => reason = e.key),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(l10n.translate('invSaveAdjust'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (ok == true && context.mounted && _isCurrent(ref, api)) {
      // The amount is entered IN the chosen unit → convert to base (the single
      // stock number the backend stores).
      final amt = double.tryParse(amount.text.trim()) ?? 0;
      final baseAmt = factor > 0 ? amt * factor : amt;
      try {
        await api.adjustStock({
          'product_id': id,
          'mode': mode,
          'amount': baseAmt,
          'reason': reason,
          if (api is LocalInventoryApi) ...{
            'command_id': const Uuid().v4(),
            'expected_stock': current,
          },
        });

        if (context.mounted && _isCurrent(ref, api)) invalidateInventoryData(ref);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                   Text(businessOperationError(l10n, e, fallback: 'invActionFailed'),
                       style: const TextStyle(fontFamily: 'Cairo'))));
        }
      }
    }
    amount.dispose();
  }
}

String _fmt(dynamic v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
}

/// The real available quantity expressed IN a unit, using that unit's actual
/// conversion factor — never a fabricated balance. Indivisible units show
/// whole units + the leftover base units (so nothing is rounded away).
String productUnitAvailableText(
    double stock, double factor, String unitName, String baseUnit) {
  if (factor <= 0) return '0';
  final v = stock / factor;
  if ((v - v.roundToDouble()).abs() < 1e-9) {
    return '${_fmt(v)} $unitName'.trim();
  }
  final whole = v.floorToDouble();
  final remainder = stock - whole * factor;
  if (whole <= 0) {
    return '${_fmt(remainder)} $baseUnit'.trim();
  }
  final unitPart = '${_fmt(whole)} $unitName'.trim();
  final remPart = '${_fmt(remainder)} $baseUnit'.trim();
  return '$unitPart + $remPart';
}
