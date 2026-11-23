import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../sales/presentation/widgets/sale_section_card.dart';
import '../providers/inventory_providers.dart';
import '../widgets/falcon_icon.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';

/// «إحصائيات المنتج»: real summary (sales, purchases, COGS, profit) for a
/// chosen period, followed by the product movement timeline.
class ProductMovementsPage extends ConsumerStatefulWidget {
  final String id;
  final LocalCommerceTarget? localTarget;
  const ProductMovementsPage({super.key, required this.id, this.localTarget});
  @override
  ConsumerState<ProductMovementsPage> createState() =>
      _ProductMovementsPageState();
}

class _ProductMovementsPageState extends ConsumerState<ProductMovementsPage> {
  String _from = '';
  String _to = '';
  String _chip = 'all';

  /// Display currency: the product's FIRST priced currency by default
  /// (resolved from the report payload; never USD-hardcoded).
  String? _ccy;

  InventoryStatsKey get _key => (
    product: (id: widget.id, target: widget.localTarget),
    from: _from,
    to: _to,
    currency: _ccy,
  );

  String _iso(DateTime d) => d.toIso8601String().split('T').first;

  Widget _rangeChip(BuildContext context,
      {required bool selected,
      required String label,
      required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: selected ? Colors.white : AppColors.textPrimary)),
        selected: selected,
        selectedColor: AppColors.primary,
        backgroundColor: AppColors.surface,
        side: BorderSide(color: AppColors.border),
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Future<void> _pickRange() async {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final from = await showDatePicker(
      context: context,
      helpText: l10n.translate('invFromDate'),
      initialDate: now.subtract(const Duration(days: 30)),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (from == null || !mounted) return;
    final to = await showDatePicker(
      context: context,
      helpText: l10n.translate('invToDate'),
      initialDate: now,
      firstDate: from,
      lastDate: DateTime(now.year + 1),
    );
    if (to == null || !mounted) return;
    setState(() {
      _from = _iso(from);
      _to = _iso(to);
      _chip = 'range';
    });
  }

  void _applyChip(String chip) {
    final now = DateTime.now();
    setState(() {
      _chip = chip;
      switch (chip) {
        case 'today':
          _from = _iso(now);
          _to = _iso(now);
          break;
        case 'week':
          _from = _iso(now.subtract(const Duration(days: 7)));
          _to = _iso(now);
          break;
        case 'month':
          _from = _iso(now.subtract(const Duration(days: 30)));
          _to = _iso(now);
          break;
        default:
          _from = '';
          _to = '';
      }
    });
  }

  static const _labels = {
    'purchase': 'invMovementPurchase',
    'sale': 'invMovementSale',
    'sale_return': 'invMovementSaleReturn',
    'purchase_return': 'invMovementPurchaseReturn',
    'sale_return_no_stock': 'invMovementSaleReturnNoStock',
    'purchase_return_no_stock': 'invMovementPurchaseReturnNoStock',
    'adjust_add': 'invMovementIncrease',
    'adjust_remove': 'invMovementDecrease',
    'adjust_set': 'invMovementSetQty',
    'transfer': 'invMovementTransfer',
    'transfer_in': 'invMovementTransfer',
    'transfer_out': 'invMovementTransfer',
    'transfer_reversal_in': 'invMovementTransferReversal',
    'transfer_reversal_out': 'invMovementTransferReversal',
  };

  /// Backend stats rows carry `type`; the dedicated movements endpoint
  /// carries `movement_type` — accept both.
  static String _typeOf(Map m) =>
      ((m['movement_type'] ?? m['type']) ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final target = widget.localTarget;
    if (target != null && !target.allows(
        ref.watch(businessLocalLedgerScopeProvider), RouteNames.inventoryProductMovements)) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    final stats = ref.watch(productStatsProvider(_key));
    final canFalcon = ref.watch(employeeCanProvider('falcon'));
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(l10n.translate('invProductStats'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        actions: [
          if (canFalcon)
            IconButton(
              tooltip: l10n.translate('invFalcon'),
              onPressed: () async {
                 if (!await ensureBusinessOnline(context) || !context.mounted) {
                   return;
                 }
                 if (target != null) {
                   // The connected Falcon route takes a server product ID;
                   // it cannot receive a local record from this branch.
                   ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                     content: Text(l10n.translate('falconLocalAccessRequired')),
                   ));
                   return;
                 }
                context.push('/inventory/falcon?scope=product&id=${widget.id}');
              },
              icon: const FalconIcon(size: 20),
            ),
        ],
      ),
      body: stats.when(
        loading: () => target != null
            ? const SizedBox.shrink() : const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(
            child: Text(l10n.translate('invLoadError'),
                style: const TextStyle(fontFamily: 'Cairo'))),
        data: (s) {
          // Currency filter: ONLY the currencies the product is actually
          // priced in. Single currency → the row stays hidden entirely.
          final priced = ((s['priced_currencies'] as List?) ?? const [])
              .map((e) => e.toString().toUpperCase())
              .toList();
          final display = (s['display_currency'] ?? '').toString().toUpperCase();
          if (_ccy == null && display.isNotEmpty) _ccy = display;
          final showCcyRow = priced.length > 1;
          return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _rangeChip(
                  context,
                  selected: _chip == 'all',
                  label: l10n.translate('invFilterAll'),
                  onTap: () => setState(() {
                    _from = '';
                    _to = '';
                    _chip = 'all';
                  }),
                ),
                _rangeChip(
                  context,
                  selected: _chip == 'range',
                  label: (_chip == 'range' && _from.isNotEmpty)
                      ? '$_from  →  $_to'
                      : l10n.translate('invPickRange'),
                  onTap: _pickRange,
                ),
              ]),
            ),
            if (showCcyRow) ...[
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final c in priced)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: ChoiceChip(
                        label: Text(currencyName(c, locale: _localeName),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: c == display
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: c == display
                                    ? Colors.white
                                    : AppColors.textPrimary)),
                        selected: c == display,
                        selectedColor: AppColors.primary,
                        backgroundColor: AppColors.surface,
                        side: BorderSide(color: AppColors.border),
                        showCheckmark: false,
                        onSelected: (_) => setState(
                            () => _ccy = c), // recompute → new stats key
                      ),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            SaleSectionCard(
              titleKey: 'invProductStats',
              child: Column(children: [
                _stat(context, l10n.translate('invStatSales'),
                    _money(s['sales_total'], display)),
                _stat(context, l10n.translate('invStatSalesQty'),
                    _fmt(s['sales_quantity'])),
                _stat(context, l10n.translate('invStatSalesCount'),
                    _fmt(s['sales_count'])),
                const Divider(height: 16),
                _stat(context, l10n.translate('invStatPurchases'),
                    _money(s['purchases_total'], display)),
                _stat(context, l10n.translate('invStatPurchasesQty'),
                    _fmt(s['purchases_quantity'])),
                _stat(context, l10n.translate('invStatPurchasesCount'),
                    _fmt(s['purchases_count'])),
                const Divider(height: 16),
                _stat(context, l10n.translate('invStatCogs'),
                    _money(s['cogs'], display)),
                _stat(context, l10n.translate('invStatProfit'),
                    _money(s['profit'], display),
                    color: AppColors.primary),
              ]),
            ),
            const SizedBox(height: 16),
            SaleSectionCard(
              titleKey: 'invMovements',
              child: Column(
                children: [
                  for (final m in (s['movements'] as List? ?? const [])
                      .whereType<Map>())
                      _MoveRow(
                        m: Map<String, dynamic>.from(m),
                        label: _labels[_typeOf(m)] ?? 'invMovementOther',
                        scope: target?.scope,
                    ),
                ],
              ),
            ),
          ],
        );
        },
      ),
    );
  }

  String? get _localeName {
    try {
      return Localizations.localeOf(context).languageCode;
    } catch (_) {
      return null;
    }
  }

  Widget _stat(BuildContext context, String label, String value,
      {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textSecondary)),
          Text(value,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w700,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _MoveRow extends ConsumerWidget {
  final Map<String, dynamic> m;
  final String label;
  final DirectoryAccess? scope;
  const _MoveRow({required this.m, required this.label, this.scope});

  static const _reasonKeys = {
    'wrong': 'invReasonWrong',
    'damaged': 'invReasonDamaged',
    'lost': 'invReasonLost',
    'extra': 'invReasonExtra',
    'other': 'invReasonOther',
  };

  bool get _isAdjust {
    final t = ((m['movement_type'] ?? m['type']) ?? '').toString();
    return t.startsWith('adjust_');
  }

  String _reasonText(AppLocalizations l10n) {
    final raw = (m['reason'] ?? '').toString();
    final key = _reasonKeys[raw];
    return key == null ? raw : l10n.translate(key);
  }

  String _dateTime() {
    final raw = (m['created_at'] ?? '').toString();
    if (raw.isEmpty) return '';
    final parts = raw.split('T');
    if (parts.length < 2) return parts.first;
    final hm = parts[1].split(':');
    final time = hm.length >= 2 ? '${hm[0]}:${hm[1]}' : parts[1];
    return '${parts[0]} $time';
  }

  void _openDetails(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final refId = (m['reference_id'] ?? '').toString();
    final refType = (m['reference_type'] ?? '').toString();
    final oldQ = m['old_quantity'] as num?;
    final newQ = m['new_quantity'] as num?;
    final diff = m['difference'] as num?;
    final performer = (m['performer_name'] ?? '').toString();
    final byManager = m['performed_by_manager'] == true;
    final type = m['invoice_type'] == 'purchase' ? 'purchase' : 'sale';
    final canOpen = refId.isNotEmpty &&
        (refType == 'invoice'
            ? ref.read(employeeCanProvider(type == 'purchase' ? 'purchases.view' : 'sales.view'))
            : const {'invoice_return', 'purchase_return'}.contains(refType) &&
                ref.read(employeeCanProvider('returns')) &&
                ref.read(employeeCanProvider(
                    refType == 'purchase_return' ? 'purchases.returns' : 'sales.returns')));
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.translate(label),
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ),
                  if (byManager)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(28),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(l10n.translate('invMoveByManager'),
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (_isAdjust) ...[
                if (oldQ != null)
                  _line(ctx, l10n.translate('invMoveBefore'), _fmt(oldQ)),
                if (newQ != null)
                  _line(ctx, l10n.translate('invMoveAfter'), _fmt(newQ)),
                if (diff != null)
                  _line(
                      ctx,
                      l10n.translate('invMoveChange'),
                      '${diff.toDouble() > 0 ? '+' : ''}${_fmt(diff)}'),
                if (_reasonText(l10n).isNotEmpty)
                  _line(ctx, l10n.translate('invReason'),
                      _reasonText(l10n)),
              ] else ...[
                _line(ctx, l10n.translate('invQtyNow'), _fmt(qty)),
              ],
              if (!_isAdjust && asDoubleValue(m['unit_price']) != 0)
                _line(ctx, l10n.translate('invSellPrice'),
                    '${fmtNum(m['unit_price'])} ${currencySymbol((m['currency'] ?? '').toString())}'),
              if (!_isAdjust && asDoubleValue(m['total']) != 0)
                _line(ctx, l10n.translate('saleGrandTotal'),
                    '${fmtNum(m['total'])} ${currencySymbol((m['currency'] ?? '').toString())}'),
              if (!_isAdjust && _reasonText(l10n).isNotEmpty)
                _line(ctx, l10n.translate('invReason'),
                    _reasonText(l10n)),
              if (_dateTime().isNotEmpty)
                _line(ctx, l10n.translate('invMoveDateTime'), _dateTime()),
              if (performer.isNotEmpty)
                _line(ctx, l10n.translate('invMoveBy'), performer),
              if ((m['notes'] ?? '').toString().isNotEmpty)
                _line(ctx, l10n.translate('saleNotes'),
                    (m['notes'] ?? '').toString()),
               if (canOpen) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                       if (!context.mounted) return;
                       if (refType == 'invoice') {
                         openCommerceRecord(context, type == 'purchase'
                             ? RouteNames.purchasesView : RouteNames.salesView,
                             refId, fromLocal: scope);
                       } else {
                         openCommerceRecord(context, RouteNames.returnsView, refId,
                             kind: refType == 'purchase_return' ? refType : 'sale_return',
                             fromLocal: scope);
                       }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: Text(l10n.translate('saleViewInvoice'),
                        style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textSecondary)),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final positive = qty >= 0;
    final date = (m['created_at'] ?? '').toString();
    final day = date.length >= 10 ? date.substring(0, 10) : date;
    final notes = (m['notes'] ?? '').toString();
    // Manual stock changes are always yellow; sale stays red, purchase green.
    final adjust = _isAdjust;
    final subtype = ((m['movement_type'] ?? m['type']) ?? '').toString();
    // A return that was NOT put back into stock (damaged) → yellow warning.
    final noStock = subtype.endsWith('_no_stock');
    final IconData icon = noStock
        ? Icons.warning_amber_rounded
        : adjust
            ? (subtype == 'adjust_add'
                ? Icons.arrow_downward
                : subtype == 'adjust_remove'
                    ? Icons.arrow_upward
                    : Icons.edit)
            : (positive ? Icons.south_west : Icons.north_east);
    final Color color = noStock
        ? AppColors.warning
        : adjust
            ? AppColors.warning
            : (positive ? AppColors.success : AppColors.danger);
    return InkWell(
      onTap: () => _openDetails(context, ref, l10n),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.translate(label),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  if (notes.isNotEmpty)
                    Text(notes,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: AppColors.textSecondary)),
                  Text(day,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
            Text('${positive ? '+' : ''}${_fmt(qty)}',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w800,
                    color: color)),
          ],
        ),
      ),
    );
  }
}

String _fmt(dynamic v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
}

/// Money stat with its display currency beside it («33.71 دولار أمريكي» /
/// «33.71 US Dollar») — one currency only, resolved server-side.
String _money(dynamic v, String ccy) {
  if (v == null) return '—';
  return '${fmtNum(v)} ${currencyName(ccy.toUpperCase())}';
}
