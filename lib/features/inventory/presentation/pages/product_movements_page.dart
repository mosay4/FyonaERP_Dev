import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/document_number.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../providers/inventory_providers.dart';
import '../widgets/business_product_image.dart';
import '../widgets/falcon_icon.dart';
import 'product_detail_page.dart' show productRecordReplaces;
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

  /// The record this page was opened for. A router re-parse (app resume,
  /// auth refresh) rebuilds the page without its in-memory target and with
  /// an empty id; the page keeps its record (scope is still checked).
  late String _id = widget.id;
  late LocalCommerceTarget? _target = widget.localTarget;

  /// The last statistics read for the CURRENT key: a failing re-read keeps
  /// them on screen instead of an error.
  Map<String, dynamic>? _last;
  InventoryStatsKey? _lastKey;

  @override
  void didUpdateWidget(covariant ProductMovementsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (productRecordReplaces(
        widget.id, widget.localTarget, _id, _target)) {
      _id = widget.id;
      _target = widget.localTarget;
      _last = null;
      _lastKey = null;
    }
  }

  InventoryStatsKey get _key => (
    product: (id: _id, target: _target),
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
    final target = _target;
    if (target != null && !target.allows(
        ref.watch(businessLocalLedgerScopeProvider), RouteNames.inventoryProductMovements)) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    final key = _key;
    final stats = ref.watch(productStatsProvider(key));
    final canFalcon = ref.watch(employeeCanProvider('falcon'));
    final fresh = stats.valueOrNull;
    if (fresh != null) {
      _last = fresh;
      _lastKey = key;
    }
    // Same product: a re-read (or a new period) keeps the last figures
    // visible until the new ones arrive.
    final shown = fresh ??
        (_lastKey?.product == key.product &&
                (!stats.hasError || _lastKey == key)
            ? _last
            : null);
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
                // Device-ledger branches work too: the Falcon request
                // carries this product's figures computed from the phone's
                // ledger at request time (latest edits included).
                final name = '${shown?['name'] ?? ''}';
                context.push(Uri(path: RouteNames.inventoryFalcon, queryParameters: {
                  'scope': 'product',
                  'id': _id,
                  if (name.isNotEmpty) 'title': name,
                }).toString());
              },
              icon: const FalconIcon(size: 20),
            ),
        ],
      ),
      body: shown != null
          ? _body(context, l10n, shown, target)
          : stats.when(
              loading: () => target != null
                  ? const SizedBox.shrink()
                  : const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                  child: Text(l10n.translate('invLoadError'),
                      style: const TextStyle(fontFamily: 'Cairo'))),
              data: (s) => _body(context, l10n, s, target),
            ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n,
      Map<String, dynamic> s, LocalCommerceTarget? target) {
    // Currency filter: ONLY the currencies the product is actually priced
    // in. Single currency → the row stays hidden entirely.
    final priced = ((s['priced_currencies'] as List?) ?? const [])
        .map((e) => e.toString().toUpperCase())
        .toList();
    final display = (s['display_currency'] ?? '').toString().toUpperCase();
    if (_ccy == null && display.isNotEmpty) _ccy = display;
    final showCcyRow = priced.length > 1;
    final movements = [
      for (final m in (s['movements'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(m),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if ('${s['name'] ?? ''}'.isNotEmpty) ...[
          _productHeader(context, l10n, s),
          const SizedBox(height: 12),
        ],
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
            for (final c in const ['today', 'week', 'month'])
              _rangeChip(
                context,
                selected: _chip == c,
                label: l10n.translate(switch (c) {
                  'today' => 'invStatsToday',
                  'week' => 'invStatsWeek',
                  _ => 'invStatsMonth',
                }),
                onTap: () => _applyChip(c),
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
                            fontWeight:
                                c == display ? FontWeight.w700 : FontWeight.w500,
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
        _kpiGrid(context, l10n, s, display, movements),
        if (s['fx_incomplete'] == true) ...[
          const SizedBox(height: 8),
          _note(context, l10n.translate('invStatsFxPartial')),
        ],
        if (_chartDays(movements).length >= 2) ...[
          const SizedBox(height: 12),
          _qtyChart(context, l10n, _chartDays(movements)),
        ],
        const SizedBox(height: 12),
        _movementsCard(context, l10n, movements, target),
      ],
    );
  }

  Widget _productHeader(
      BuildContext context, AppLocalizations l10n, Map<String, dynamic> s) {
    final image = '${s['image'] ?? ''}';
    const icon = Icon(Icons.inventory_2_outlined,
        size: 19, color: AppColors.primary);
    return Row(children: [
      Container(
        width: image.isEmpty ? 36 : 44,
        height: image.isEmpty ? 36 : 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(22),
            border: image.isEmpty
                ? null
                : Border.all(color: AppColors.primary.withAlpha(40)),
            borderRadius: BorderRadius.circular(image.isEmpty ? 10 : 12)),
        // The product's own photo when it has one.
        child: image.isEmpty
            ? icon
            : BusinessProductImage(
                url: image,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                placeholder: const Center(child: icon)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text('${s['name']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
    ]);
  }

  /// The few numbers a merchant reads first, each in its own tile.
  Widget _kpiGrid(BuildContext context, AppLocalizations l10n,
      Map<String, dynamic> s, String display, List<Map<String, dynamic>> moves) {
    final unit = '${s['unit'] ?? ''}';
    final canProfit = ref.watch(employeeCanProvider('inventory_profit.read'));
    final sales = _numOrNull(s['sales_total']);
    final profit = _numOrNull(s['profit']);
    final margin = sales != null && sales > 0 && profit != null
        ? (profit / sales * 100)
        : null;
    final lastBuy = moves.firstWhere(
        (m) =>
            _typeOf(m) == 'purchase' &&
            m['unit_price'] != null &&
            asDoubleValue(m['unit_price']) != 0,
        orElse: () => const {});
    final stock = _numOrNull(s['stock']);
    final minStock = _numOrNull(s['min_stock']) ?? 0;
    final tiles = <_Kpi>[
      _Kpi(
          label: l10n.translate('invKpiSales'),
          value: _money(s['sales_total'], display),
          hint: l10n.translate('invKpiSalesCount',
              params: {'n': _fmt(s['sales_count'])}),
          icon: Icons.point_of_sale_rounded,
          color: AppColors.primary),
      _Kpi(
          label: l10n.translate('invKpiSoldQty'),
          value: '${_fmt(s['sales_quantity'])} $unit'.trim(),
          icon: Icons.shopping_bag_outlined,
          color: AppColors.info),
      if (canProfit || profit != null)
        _Kpi(
            label: l10n.translate('invKpiProfit'),
            value: _money(s['profit'], display),
            hint: margin == null
                ? null
                : l10n.translate('invKpiMargin',
                    params: {'p': margin.toStringAsFixed(margin.abs() >= 10 ? 0 : 1)}),
            icon: Icons.trending_up_rounded,
            color: (profit ?? 0) < 0 ? AppColors.danger : AppColors.success),
      if (stock != null && s['is_service'] != true)
        _Kpi(
            label: l10n.translate('invKpiStock'),
            value: '${_fmt(stock)} $unit'.trim(),
            hint: stock <= 0
                ? l10n.translate('invKpiStockOut')
                : (minStock > 0 && stock <= minStock)
                    ? l10n.translate('invKpiStockLow')
                    : null,
            icon: Icons.warehouse_outlined,
            color: stock <= 0
                ? AppColors.danger
                : (minStock > 0 && stock <= minStock)
                    ? AppColors.warning
                    : AppColors.success),
      _Kpi(
          label: l10n.translate('invStatPurchases'),
          value: _money(s['purchases_total'], display),
          hint: l10n.translate('invKpiBoughtQty',
              params: {'q': '${_fmt(s['purchases_quantity'])} $unit'.trim()}),
          icon: Icons.local_shipping_outlined,
          color: AppColors.warning),
      if (lastBuy.isNotEmpty)
        _Kpi(
            label: l10n.translate('invKpiLastCost'),
            value: '${fmtNum(lastBuy['unit_price'])} '
                    '${currencySymbol('${lastBuy['currency'] ?? ''}')}'
                .trim(),
            hint: _day(lastBuy['created_at']),
            icon: Icons.receipt_long_outlined,
            color: AppColors.textSecondary),
    ];
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 10) / 2;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final t in tiles) SizedBox(width: w, child: _kpiTile(context, t)),
        ],
      );
    });
  }

  Widget _kpiTile(BuildContext context, _Kpi t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.color.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  color: t.color.withAlpha(30), shape: BoxShape.circle),
              child: Icon(t.icon, size: 14, color: t.color),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(t.value,
                maxLines: 1,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
          SizedBox(
            height: 18,
            child: t.hint == null
                ? null
                : Text(t.hint!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 10.5),
                        fontWeight: FontWeight.w600,
                        // Brand red is too dim for small text on dark.
                        color: t.color == AppColors.textSecondary ||
                                t.color == AppColors.primary
                            ? AppColors.textSecondary
                            : t.color)),
          ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.warning.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11.5),
                    color: AppColors.textPrimary)),
          ),
        ]),
      );

  /// Quantity in / out per day for the most recent active days (max 7).
  List<({String day, double inQty, double outQty})> _chartDays(
      List<Map<String, dynamic>> moves) {
    final byDay = <String, ({double inQty, double outQty})>{};
    for (final m in moves) {
      final day = _day(m['created_at']);
      if (day.isEmpty) continue;
      final q = asDoubleValue(m['quantity']);
      if (q == 0) continue;
      final cur = byDay[day] ?? (inQty: 0.0, outQty: 0.0);
      byDay[day] = q > 0
          ? (inQty: cur.inQty + q, outQty: cur.outQty)
          : (inQty: cur.inQty, outQty: cur.outQty - q);
    }
    final days = byDay.keys.toList()..sort();
    final recent = days.length > 7 ? days.sublist(days.length - 7) : days;
    return [
      for (final d in recent)
        (day: d, inQty: byDay[d]!.inQty, outQty: byDay[d]!.outQty),
    ];
  }

  Widget _qtyChart(BuildContext context, AppLocalizations l10n,
      List<({String day, double inQty, double outQty})> days) {
    final top = days.fold<double>(
        0, (m, d) => math.max(m, math.max(d.inQty, d.outQty)));
    Widget legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 4),
          Text(t,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  color: AppColors.textSecondary)),
        ]);
    const barArea = 90.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(l10n.translate('invQtyChart'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ),
            legend(AppColors.success, l10n.translate('invChartIn')),
            const SizedBox(width: 10),
            legend(AppColors.danger, l10n.translate('invChartOut')),
          ]),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final d in days)
                Expanded(
                  child: Column(children: [
                    SizedBox(
                      height: barArea + 16,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final (v, c) in [
                            (d.inQty, AppColors.success),
                            (d.outQty, AppColors.danger),
                          ])
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 1.5),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (v > 0)
                                    Text(_fmt(v),
                                        style: TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: 8.5,
                                            height: 1.2,
                                            color: AppColors.textSecondary)),
                                  Container(
                                    width: 9,
                                    height: top <= 0
                                        ? 0
                                        : math.max(v > 0 ? 3.0 : 0.0,
                                            v / top * barArea),
                                    decoration: BoxDecoration(
                                      color: c,
                                      borderRadius:
                                          const BorderRadius.vertical(
                                              top: Radius.circular(3)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(d.day.length >= 10 ? d.day.substring(5) : d.day,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 9.5,
                            color: AppColors.textSecondary)),
                  ]),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _movementsCard(BuildContext context, AppLocalizations l10n,
      List<Map<String, dynamic>> moves, LocalCommerceTarget? target) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.swap_vert_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l10n.translate('invMovements'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ),
            if (moves.isNotEmpty)
              Text('${moves.length}',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 6),
          if (moves.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(l10n.translate('invNoMovements'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: 'Cairo', color: AppColors.textSecondary)),
            )
          else
            for (var i = 0; i < moves.length; i++) ...[
              if (i > 0) Divider(height: 1, color: AppColors.divider),
              _MoveRow(
                m: moves[i],
                label: _labels[_typeOf(moves[i])] ?? 'invMovementOther',
                scope: target?.scope,
              ),
            ],
        ],
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
}

final class _Kpi {
  const _Kpi(
      {required this.label,
      required this.value,
      this.hint,
      required this.icon,
      required this.color});
  final String label;
  final String value;
  final String? hint;
  final IconData icon;
  final Color color;
}

double? _numOrNull(dynamic v) =>
    v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

String _day(dynamic raw) {
  final s = '${raw ?? ''}';
  return s.length >= 10 ? s.substring(0, 10) : s;
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

  /// The document this movement belongs to, shown short (INV-49A55AD4):
  /// the ledger's own number, or the one older rows kept in their notes.
  String get _docNumber {
    final raw = '${m['reference_number'] ?? m['invoice_number'] ?? ''}'.trim();
    if (raw.isNotEmpty && raw != 'null') return shortDocumentNumber(raw);
    final notes = '${m['notes'] ?? ''}';
    final hit = _longNumber.firstMatch(notes);
    return hit == null ? '' : shortDocumentNumber(hit[0]);
  }

  /// The merchant's own notes only: the automatic «بيع INV-…» / «شراء INV-…»
  /// text is the document number, which has its own line.
  String get _realNotes {
    var notes = '${m['notes'] ?? ''}'.trim();
    if (notes.isEmpty || notes == 'null') return '';
    final raw = '${m['reference_number'] ?? ''}'.trim();
    if (raw.isNotEmpty && raw != 'null') notes = notes.replaceAll(raw, '');
    notes = notes.replaceAll(_longNumber, '').trim();
    return const {'بيع', 'شراء', 'مرتجع', 'Sale', 'Purchase'}.contains(notes)
        ? ''
        : notes;
  }

  static final _longNumber = RegExp(r'[A-Za-z]{2,5}-\d{8}-[0-9A-Fa-f]{32}');

  String get _subtype => ((m['movement_type'] ?? m['type']) ?? '').toString();

  (IconData, Color) _look() {
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final subtype = _subtype;
    // A return that was NOT put back into stock (damaged) → yellow warning.
    if (subtype.endsWith('_no_stock')) {
      return (Icons.warning_amber_rounded, AppColors.warning);
    }
    // Manual stock changes are always yellow; sale stays red, purchase green.
    if (_isAdjust) {
      return (
        subtype == 'adjust_add'
            ? Icons.arrow_downward
            : subtype == 'adjust_remove'
                ? Icons.arrow_upward
                : Icons.edit,
        AppColors.warning,
      );
    }
    return qty >= 0
        ? (Icons.south_west, AppColors.success)
        : (Icons.north_east, AppColors.danger);
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
    final type = m['invoice_type'] == 'purchase' ||
            _subtype.startsWith('purchase')
        ? 'purchase'
        : 'sale';
    final isReturn = const {'invoice_return', 'purchase_return'}.contains(refType);
    final canOpen = refId.isNotEmpty &&
        (refType == 'invoice'
            ? ref.read(employeeCanProvider(type == 'purchase' ? 'purchases.view' : 'sales.view'))
            : isReturn &&
                ref.read(employeeCanProvider('returns')) &&
                ref.read(employeeCanProvider(
                    refType == 'purchase_return' ? 'purchases.returns' : 'sales.returns')));
    final (icon, color) = _look();
    final cur = currencySymbol((m['currency'] ?? '').toString());
    final docNo = _docNumber;
    final notes = _realNotes;
    final reason = _reasonText(l10n);
    final when = _dateTime();
    final rows = <(String, String, Color?)>[
      if (_isAdjust) ...[
        if (oldQ != null) (l10n.translate('invMoveBefore'), _fmt(oldQ), null),
        if (newQ != null) (l10n.translate('invMoveAfter'), _fmt(newQ), null),
        if (diff != null)
          (l10n.translate('invMoveChange'),
              _ltr('${diff.toDouble() > 0 ? '+' : ''}${_fmt(diff)}'), color),
      ] else
        (l10n.translate('invMoveQty'),
            _ltr('${qty >= 0 ? '+' : ''}${_fmt(qty)}'), color),
      if (!_isAdjust && asDoubleValue(m['unit_price']) != 0)
        (l10n.translate('invMoveUnitPrice'),
            '${fmtNum(m['unit_price'])} $cur'.trim(), null),
      if (reason.isNotEmpty) (l10n.translate('invReason'), reason, null),
      if (performer.isNotEmpty) (l10n.translate('invMoveBy'), performer, null),
    ];
    final total = !_isAdjust && asDoubleValue(m['total']) != 0
        ? '${fmtNum(m['total'])} $cur'.trim()
        : '';
    TextStyle text(double size,
            {FontWeight weight = FontWeight.w600, Color? tone}) =>
        TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, size),
            fontWeight: weight,
            height: 1.35,
            color: tone ?? AppColors.textPrimary);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
            18, 10, 18, 18 + MediaQuery.of(ctx).padding.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(4)),
                ),
              ),
              const SizedBox(height: 14),
              // Header: what happened, when, and its signed quantity.
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                        color: color.withAlpha(30), shape: BoxShape.circle),
                    child: Icon(icon, size: 22, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.translate(label),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text(16, weight: FontWeight.w800)),
                        if (when.isNotEmpty)
                          Text(when,
                              textDirection: TextDirection.ltr,
                              style: text(12,
                                  weight: FontWeight.w500,
                                  tone: AppColors.textSecondary)),
                      ],
                    ),
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
                          style: text(11,
                              weight: FontWeight.w700,
                              tone: AppColors.primary)),
                    ),
                ],
              ),
              if (docNo.isNotEmpty) ...[
                const SizedBox(height: 14),
                // The document number on its own line, always short.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withAlpha(45)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.receipt_long_outlined,
                          size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            l10n.translate(isReturn
                                ? 'invMoveReturnNo'
                                : 'invMoveInvoiceNo'),
                            style: text(13,
                                weight: FontWeight.w600,
                                tone: AppColors.textSecondary)),
                      ),
                      Text(docNo,
                          key: const ValueKey('movement-doc-number'),
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                          style: text(14,
                              weight: FontWeight.w800,
                              tone: AppColors.primary)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: AppColors.divider),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(rows[i].$1,
                                style: text(13,
                                    weight: FontWeight.w500,
                                    tone: AppColors.textSecondary)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(rows[i].$2,
                                  textAlign: TextAlign.end,
                                  style: text(13.5,
                                      weight: FontWeight.w700,
                                      tone: rows[i].$3)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (total.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: color.withAlpha(20),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(l10n.translate('saleGrandTotal'),
                            style: text(14, weight: FontWeight.w700)),
                      ),
                      Text(total,
                          style: text(16, weight: FontWeight.w800, tone: color)),
                    ],
                  ),
                ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(l10n.translate('saleNotes'),
                    style: text(12.5,
                        weight: FontWeight.w700,
                        tone: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(notes, style: text(13, weight: FontWeight.w500)),
                ),
              ],
              if (canOpen) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('movement-open-document'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (!context.mounted) return;
                    if (refType == 'invoice') {
                      // The same invoice screen the Business invoices
                      // section opens.
                      openCommerceRecord(context, RouteNames.invoicesView,
                          refId, kind: type, fromLocal: scope);
                    } else {
                      openCommerceRecord(context, RouteNames.returnsView, refId,
                          kind: refType == 'purchase_return' ? refType : 'sale_return',
                          fromLocal: scope);
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.receipt_long_outlined, size: 20),
                  label: Text(
                      l10n.translate(
                          isReturn ? 'invMoveViewReturn' : 'saleViewInvoice'),
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final positive = qty >= 0;
    final date = (m['created_at'] ?? '').toString();
    final day = date.length >= 10 ? date.substring(0, 10) : date;
    final notes = _realNotes;
    final docNo = _docNumber;
    final adjust = _isAdjust;
    final (icon, color) = _look();
    final time = _dateTime();
    final total = asDoubleValue(m['total']);
    final cur = currencySymbol((m['currency'] ?? '').toString());
    return InkWell(
      onTap: () => _openDetails(context, ref, l10n),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: color.withAlpha(28), shape: BoxShape.circle),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.translate(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  Text(
                      [
                        time.isEmpty ? day : time,
                        if (docNo.isNotEmpty) docNo,
                        if (notes.isNotEmpty) notes,
                      ].join(' • '),
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${positive ? '+' : ''}${_fmt(qty)}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w800,
                        color: color)),
                if (!adjust && total != 0)
                  Text('${fmtNum(m['total'])} $cur'.trim(),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10.5),
                          color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A signed number keeps its sign in front inside Arabic text («-3», not «3-»).
String _ltr(String value) => '\u2066$value\u2069';

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
