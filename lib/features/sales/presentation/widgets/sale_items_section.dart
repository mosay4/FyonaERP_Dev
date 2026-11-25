import 'dart:async';

import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/shared/widgets/biz_currency_items.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/services/units/custom_units.dart';
import '../../../../../shared/services/scan_sfx.dart';
import '../../../../../shared/widgets/styled_snack.dart';
import '../../../../../shared/widgets/business_selection_sheet.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../../core/utils/amount_input_formatter.dart';
import '../../../inventory/presentation/widgets/business_unit_image.dart';
import '../../../inventory/presentation/widgets/product_picker.dart';
import '../../../inventory/presentation/providers/inventory_providers.dart';
import '../../../inventory/presentation/providers/warehouse_settings.dart';
import '../providers/sale_providers.dart';
import '../../../core_business/presentation/widgets/invoice_line_widgets.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import 'sale_section_card.dart';
import 'sale_payment_section.dart' show applySaleInvoiceCurrency;
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Products & services lines: name search, barcode entry, qty, unit picker
/// (when the product has several units), editable price, line discount, and
/// manual non-stock entries. Stockable lines decrement stock on issue;
/// services never do.
class SaleItemsSection extends ConsumerStatefulWidget {
  const SaleItemsSection({super.key});
  @override
  ConsumerState<SaleItemsSection> createState() => _SaleItemsSectionState();
}

class _SaleItemsSectionState extends ConsumerState<SaleItemsSection> {
  final _searchCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _addFromProduct(Map<String, dynamic> p) async {
    final notifier = ref.read(saleDraftProvider.notifier);
    final pid = p['id'].toString();
    List<dynamic> units = [];
    try {
      final u = await ref.read(salesApiProvider).productUnits(pid);
      units = (u['units'] as List?)?.whereType<Map>().toList() ?? const [];
    } catch (_) {}
    if (!mounted) return;
    if (units.length > 1) {
      String baseUnit = '${units.first['name'] ?? ''}';
      for (final e in units) {
        if (e['is_base'] == true) {
          baseUnit = '${e['name'] ?? ''}';
          break;
        }
      }
      final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => _UnitPickerSheet(
            units: units.map((e) => Map<String, dynamic>.from(e)).toList(),
            baseUnit: baseUnit,
            currency: ref.read(saleDraftProvider).currency),
      );
      if (picked == null || !mounted) return;
      final factor = (picked['factor'] as num?)?.toDouble() ?? 1.0;
      final price = picked['sale_price'] != null
          ? (picked['sale_price'] as num).toDouble()
          : asDoubleValue(p['price']);
      notifier.addItem(SaleItem(
        productId: pid,
        unitId: picked['id']?.toString(),
        description: (p['name'] ?? '').toString(),
        unitName: (picked['name'] ?? '').toString(),
        factor: factor,
        quantity: 1,
        unitPrice: price,
        isService: p['is_service'] == true,
        stock: asDoubleValue(p['stock']),
      ));
    } else {
      final price = asDoubleValue(p['price']);
      notifier.addItem(SaleItem(
        productId: pid,
        unitId: units.isNotEmpty ? units.first['id']?.toString() : null,
        description: (p['name'] ?? '').toString(),
        unitName: units.isNotEmpty
            ? (units.first['name'] ?? '').toString()
            : (p['unit']?.toString() ?? 'قطعة'),
        quantity: 1,
        unitPrice: price,
        isService: p['is_service'] == true,
        stock: asDoubleValue(p['stock']),
      ));
    }
  }

  Future<void> _addByBarcode() async {
    final code = _barcodeCtrl.text.trim();
    if (code.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    try {
      final res = await ref.read(salesApiProvider).resolveBarcode(code);
      if (!mounted) return;
      final p = Map<String, dynamic>.from(res['product'] as Map);
      final u = Map<String, dynamic>.from(res['unit'] as Map);
      ref.read(saleDraftProvider.notifier).addItem(SaleItem(
            productId: p['id']?.toString(),
            unitId: u['id']?.toString(),
            description: (p['name'] ?? '').toString(),
            unitName: (u['name'] ?? '').toString(),
            factor: (u['factor'] as num?)?.toDouble() ?? 1.0,
            quantity: (res['suggested_quantity'] as num?)?.toDouble() ?? 1,
            unitPrice: (res['suggested_price'] as num?)?.toDouble() ?? 0,
            isService: p['is_service'] == true,
            stock: asDoubleValue(p['stock']),
          ));
      _barcodeCtrl.clear();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('saleBarcodeNotFound'),
              style: const TextStyle(fontFamily: 'Cairo'))));
    }
  }

  /// Units for quick products: the shared default catalog + the merchant's
  /// custom units, with an «إضافة وحدة أخرى» option that persists their own.
  Future<Map<String, dynamic>?> _pickQuickUnit(
      BuildContext context, String current) async {
    final l10n = AppLocalizations.of(context);
    final isAr = l10n.locale.languageCode != 'en';
    final custom = ref.watch(customUnitsProvider);
    final units = <UnitDef>[
      ...defaultUnits,
      for (final c in custom) (name: c, en: c, factor: 1.0, weight: false, group: 'count'),
    ];
    return showBusinessSelectionSheet<Map<String, dynamic>>(
      context: context,
      title: l10n.translate('saleChooseUnit'),
      selected: {'name': current},
      items: [
        for (final u in units)
          BizSheetItem(
            value: {'name': u.name, 'factor': u.factor},
            title: isAr ? u.name : u.en,
            subtitle: u.weight
                ? l10n.translate('saleWeightUnit')
                : l10n.translate('saleUnitPieces',
                    params: {'n': _fmtNum(u.factor)}),
            icon: Icons.straighten_outlined,
          ),
      ],
      addNewLabel: l10n.translate('unitAddCustom'),
      onAddNew: () async {
        final name = await _promptUnitName(context);
        if (name == null || name.trim().isEmpty) return null;
        await ref.read(customUnitsProvider.notifier).add(name.trim());
        return {'name': name.trim(), 'factor': 1.0};
      },
    );
  }

  Future<String?> _promptUnitName(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('unitAddCustom'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: 'Cairo'),
          decoration: InputDecoration(
              hintText: l10n.translate('unitNameHint'),
              hintStyle: const TextStyle(fontFamily: 'Cairo')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(l10n.translate('addLabel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  /// Unit-aware price label («سعر القطعة» / «Price per Piece»): shows the
  /// price OF the chosen unit instead of a clipped generic caption.
  String _priceLabel(AppLocalizations l10n, String unitAr) {
    var unit = unitAr;
    if (l10n.locale.languageCode == 'en') {
      for (final u in defaultUnits) {
        if (u.name == unitAr) {
          unit = u.en;
          break;
        }
      }
    }
    return l10n.translate('salePricePerUnit', params: {'unit': unit});
  }

  /// Standalone currency box (separate from the price field so the full
  /// amount always fits when «save to inventory» is ON). When [showError]
  /// is set the frame turns red (no tiny clipped helper text).
  Widget _ccyBox(BuildContext ctx, StateSetter setDState, String current,
      void Function(String) onPick,
      {bool showError = false}) {
    final l10n = AppLocalizations.of(ctx);
    final missing = showError && current.isEmpty;
    return InkWell(
      onTap: () async {
        final items = bizCurrencySheetItems(await readBizCurrencies(ref));
        if (!ctx.mounted) return;
        final picked = await showBusinessSelectionSheet<String>(
          context: ctx,
          title: l10n.translate('invCurrency'),
          selected: current.isEmpty ? null : current,
          // Exactly the Business currencies enabled in profile settings.
          items: items,
        );
        if (picked != null) setDState(() => onPick(picked));
      },
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.translate('invCurrency'),
          labelStyle: missing
              ? const TextStyle(
                  color: AppColors.danger, fontFamily: 'Cairo')
              : null,
          enabledBorder: missing
              ? OutlineInputBorder(
                  borderSide:
                      const BorderSide(color: AppColors.danger),
                  borderRadius: BorderRadius.circular(12))
              : null,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Text(
              current.isEmpty
                  ? l10n.translate('invSelect')
                  : currencyName(current),
              maxLines: 1,
              style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary)),
        ),
      ),
    );
  }

  /// Mandatory-currency guard: scrolls the quick-add sheet to the currency
  /// box and shows a centered alert so the merchant sees exactly where to
  /// pick (the caller paints the box red first via setDState).
  void _requireCurrency(BuildContext ctx, GlobalKey ccyKey) {
    final c = ccyKey.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(c,
          duration: const Duration(milliseconds: 350), alignment: 0.5);
    }
    final l10n = AppLocalizations.of(ctx);
    showDialog(
      context: ctx,
      builder: (dctx) => AlertDialog(
        content: Text(l10n.translate('invCurrencyRequired'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(l10n.translate('ok'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Future<void> _addManual() async {
    final descCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final barcodeCtrl = TextEditingController();
    final minStockCtrl = TextEditingController();
    String unitName = defaultUnits.first.name;
    double unitFactor = 1;
    bool save = false;
    DateTime? expiry;
    String sellCurrency = '';
    bool ccyError = false;
    final scrollCtrl = ScrollController();
    final ccyKey = GlobalKey();
    final ws = ref.read(warehouseSettingsProvider);
    String? catId;
    String? catName;
    List<Map<String, dynamic>> cats = const [];
    if (ws.categories) {
      try {
        cats = await ref.read(inventoryApiProvider).categories();
      } catch (_) {}
    }
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: Text(l10n.translate('saleQuickProduct'),
              style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            controller: scrollCtrl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FyonaTextField(
                    controller: descCtrl,
                    decoration: InputDecoration(
                        labelText: l10n.translate('saleProductNameAdd')),
                    style: const TextStyle(fontFamily: 'Cairo')),
                const SizedBox(height: 12),
                if (!save) ...[
                  Row(children: [
                    Expanded(
                        child: BusinessNumberField(
                            controller: qtyCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: InputDecoration(
                                labelText: l10n.translate('saleQty')),
                            style:
                                const TextStyle(fontFamily: 'Cairo'))),
                    const SizedBox(width: 12),
                    Expanded(
                        child: BusinessNumberField(
                            controller: priceCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [AmountInputFormatter()],
                            decoration: InputDecoration(
                                labelText:
                                    _priceLabel(l10n, unitName)),
                            style:
                                const TextStyle(fontFamily: 'Cairo'))),
                  ]),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked =
                            await _pickQuickUnit(ctx, unitName);
                        if (picked != null) {
                          setDState(() {
                            unitName = picked['name'] as String;
                            unitFactor =
                                (picked['factor'] as num).toDouble();
                          });
                        }
                      },
                      icon: const Icon(Icons.straighten_outlined,
                          size: 18),
                      label: Text(
                          '${l10n.translate('saleChooseUnit')}: $unitName',
                          style:
                              const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ] else ...[
                  Row(children: [
                    Expanded(
                        child: BusinessNumberField(
                            controller: qtyCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: InputDecoration(
                                labelText: l10n.translate('saleQty')),
                            style:
                                const TextStyle(fontFamily: 'Cairo'))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked =
                              await _pickQuickUnit(ctx, unitName);
                          if (picked != null) {
                            setDState(() {
                              unitName = picked['name'] as String;
                              unitFactor =
                                  (picked['factor'] as num).toDouble();
                            });
                          }
                        },
                        icon: const Icon(Icons.straighten_outlined,
                            size: 18),
                        label: Text(unitName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'Cairo')),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 15),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(key: ccyKey, children: [
                    Expanded(
                        flex: 2,
                        child: BusinessNumberField(
                            controller: priceCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [AmountInputFormatter()],
                            decoration: InputDecoration(
                                labelText:
                                    _priceLabel(l10n, unitName)),
                            style:
                                const TextStyle(fontFamily: 'Cairo'))),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: _ccyBox(ctx, setDState, sellCurrency,
                          (v) {
                        sellCurrency = v;
                        ccyError = false;
                      }, showError: ccyError),
                    ),
                  ]),
                ],
                const SizedBox(height: 8),
                FyonaTextField(
                    controller: barcodeCtrl,
                    decoration: InputDecoration(
                        labelText: l10n.translate('purBarcodeOpt'),
                        suffixIcon: IconButton(
                          tooltip: l10n.translate('purScanWithCamera'),
                          icon: const Icon(Icons.photo_camera_outlined),
                          onPressed: () async {
                            final scanned =
                                await Navigator.of(ctx).push<String>(
                              MaterialPageRoute(
                                  builder: (_) => const BarcodeScanPage()),
                            );
                            if (scanned != null && scanned.isNotEmpty) {
                              setDState(() => barcodeCtrl.text = scanned);
                            }
                          },
                        )),
                    style: const TextStyle(fontFamily: 'Cairo')),
                if (save && ws.lowStockAlert) ...[
                  const SizedBox(height: 8),
                  BusinessNumberField(
                      controller: minStockCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText: l10n.translate('invMinQty')),
                      style: const TextStyle(fontFamily: 'Cairo')),
                ],
                if (save && ws.expiry) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: expiry ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 10),
                      );
                      if (picked != null) setDState(() => expiry = picked);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                          labelText: l10n.translate('invProductExpiry')),
                      child: Text(
                          expiry == null
                              ? l10n.translate('invNone')
                              : expiry!.toIso8601String().split('T').first,
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ],
                if (save && ws.categories) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final picked = await showBusinessSelectionSheet<
                          Map<String, dynamic>>(
                        context: ctx,
                        title: l10n.translate('invCategory'),
                        items: [
                          for (final c in cats)
                            BizSheetItem(
                                value: c,
                                title: (c['name'] ?? '').toString(),
                                icon: Icons.category_outlined),
                        ],
                      );
                      if (picked != null) {
                        setDState(() {
                          catId = picked['id']?.toString();
                          catName = (picked['name'] ?? '').toString();
                        });
                      }
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                          labelText: l10n.translate('invCategory')),
                      child: Text(catName ?? l10n.translate('invNone'),
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ],
                if (ref.read(employeeCanProvider('inventory.add'))) CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: save,
                  onChanged: (v) => setDState(() => save = v ?? true),
                  title: Text(l10n.translate('purSaveToInventory'),
                      style:
                          const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.translate('cancel'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
            FilledButton(
                onPressed: () {
                  // Currency is mandatory when saving to inventory.
                  if (save && sellCurrency.isEmpty) {
                    setDState(() => ccyError = true);
                    _requireCurrency(ctx, ccyKey);
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(l10n.translate('saleAdd'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      final desc = descCtrl.text.trim();
      final total = parseFormattedAmount(priceCtrl.text) ?? 0;
      final qty = double.tryParse(qtyCtrl.text.trim()) ?? 1;
      if (desc.isEmpty || qty <= 0) return;
      // The entered price is the FULL line total: distribute per unit so the
      // backend (qty × unit_price) stores exactly what the merchant sees.
      final unitPrice =
          double.parse((total / qty).toStringAsFixed(2));
      final barcode = barcodeCtrl.text.trim();
      ref.read(saleDraftProvider.notifier).addItem(SaleItem(
            description: desc,
            unitName: unitName,
            factor: unitFactor,
            quantity: qty,
            unitPrice: unitPrice,
            isService: !save,
            newProduct: save
                ? {
                    'name': desc,
                    'unit': unitName,
                    'sell_price': unitPrice,
                    'barcode': barcode,
                    'save_to_inventory': true,
                    if (sellCurrency.isNotEmpty) 'sell_currency': sellCurrency,
                    'min_stock': double.tryParse(minStockCtrl.text.trim()) ?? 0,
                    if (catId != null) 'category_id': catId,
                    if (expiry != null)
                      'expiry_date':
                          expiry!.toIso8601String().split('T').first,
                    'is_service': false,
                  }
                : null,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(saleDraftProvider);
    final l10n = AppLocalizations.of(context);
    return SaleSectionCard(
      titleKey: 'saleItems',
      trailing: TextButton.icon(
        onPressed: () => _openEntry(context),
        icon: const Icon(Icons.add, size: 18),
        label: Text(l10n.translate('saleAddProducts'),
            style: const TextStyle(fontFamily: 'Cairo')),
      ),
      child: Column(
        children: [
          if (draft.items.isEmpty) ...[
            const SizedBox(height: 12),
            Text(l10n.translate('saleNoItems'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textSecondary)),
          ] else ...[
            const SizedBox(height: 8),
            for (var i = 0; i < draft.items.length; i++)
              _LineRow(index: i, item: draft.items[i]),
          ],
        ],
      ),
    );
  }

  /// ONE elegant action: opens the few entry options only when needed.
  /// Barcode scanning lives INSIDE the search-&-pick sheet (camera button),
  /// so there is no separate big «scan» button here.
  Future<void> _openEntry(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('saleAddProducts'),
      items: [
        if (ref.read(employeeCanProvider('inventory'))) BizSheetItem(
            value: 'multi',
            title: l10n.translate('invPickProducts'),
            icon: Icons.checklist),
        BizSheetItem(
            value: 'quick',
            title: l10n.translate('saleQuickProduct'),
            icon: Icons.add_box_outlined),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == 'multi') {
      // Let the options sheet finish closing before opening the picker, so the
      // picker is never dismissed by the previous route's exit animation.
      await Future.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      final list = await showProductMultiPicker(
        context,
        api: ref.read(inventoryApiProvider),
        title: l10n.translate('invPickProducts'),
        showBarcode: ref.read(warehouseSettingsProvider).barcode,
        showCategories: ref.read(warehouseSettingsProvider).categories,
      );
      if (list != null && list.isNotEmpty) {
        _addPicked(list);
        if (mounted) {
          showFyonaSnack(
              context,
              l10n.translate('invAddedCount', params: {'n': '${list.length}'}),
              success: true);
        }
      }
    } else if (picked == 'quick') {
      await _addManual();
    }
  }

  void _addPicked(List<PickedProduct> picked) {
    final notifier = ref.read(saleDraftProvider.notifier);
    final l10n = AppLocalizations.of(context);
    var capped = false;
    for (final p in picked) {
      final prod = p.product;
      final unit = p.unit;
      final rawPrices = (prod['prices'] as List?)?.whereType<Map>() ?? const [];
      final sellPrices = <String, double>{
        for (final e in rawPrices)
          (e['currency']?.toString().toUpperCase() ?? ''): _num(e['price'])
      }..removeWhere((k, v) => k.isEmpty);
      final basePrice = _num(prod['price']);
      final factor = unit == null ? 1.0 : _num(unit['factor'], fallback: 1);
      final isService = prod['is_service'] == true;
      final stock = _num(prod['stock']);
      // Available units = stock (base) / unit factor. Services are unlimited.
      final avail = isService
          ? double.infinity
          : (factor > 0 ? stock / factor : stock);
      var qty = p.quantity;
      if (qty > avail + 1e-9) {
        qty = avail;
        capped = true;
      }
      notifier.addItem(SaleItem(
        productId: prod['id']?.toString(),
        unitId: unit?['id']?.toString(),
        description: (prod['name'] ?? '').toString(),
        unitName: (unit?['name'] ?? prod['unit'] ?? 'قطعة').toString(),
        factor: factor,
        quantity: qty,
        unitPrice: basePrice,
        isService: isService,
        stock: stock,
        sellPrices: sellPrices.isEmpty ? null : sellPrices,
        priceCurrency: sellPrices.isNotEmpty ? sellPrices.keys.first : null,
        originalUnitPrice: basePrice,
      ));
    }
    // Auto-convert the just-added lines to the invoice currency immediately
    // (so a SAR product added to a USD invoice shows the USD price at once,
    // never a stale 50 with only the label changed).
    final cur = ref.read(saleDraftProvider).currency;
    if (cur.isNotEmpty) applySaleInvoiceCurrency(ref, cur);
    if (capped) {
      // Red alert + buzz in sync when a line is capped by available stock.
      unawaited(ScanSfx.error());
      showFyonaSnack(context, l10n.translate('saleOutOfStock'), success: false);
    }
  }
}

/// Tolerant numeric parse: the API serializes Decimal as a STRING, so a raw
/// `as num?` cast would throw and silently drop the whole addition.
double _num(dynamic v, {double fallback = 0}) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? fallback;
}

class _ProductResults extends ConsumerWidget {
  final String query;
  final Future<void> Function(Map<String, dynamic>) onPick;
  const _ProductResults({required this.query, required this.onPick});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder(
      future: ref.read(salesApiProvider).searchProducts(query),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))));
        }
        final items = (snap.data ?? []).whereType<Map>().toList();
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          constraints: const BoxConstraints(maxHeight: 220),
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withAlpha(60),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final p = items[i];
              final isService = p['is_service'] == true;
              return ListTile(
                dense: true,
                title: Text((p['name'] ?? '').toString(),
                    style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${(p['price'] ?? 0)}${isService ? '' : ' • ${AppLocalizations.of(context).translate('saleStock')}: ${(p['stock'] ?? 0)}'}',
                    style: const TextStyle(fontFamily: 'Cairo')),
                trailing: isService
                    ? const Icon(Icons.miscellaneous_services_outlined, size: 18)
                    : null,
                onTap: () => onPick(Map<String, dynamic>.from(p)),
              );
            },
          ),
        );
      },
    );
  }
}

class _UnitPickerSheet extends StatelessWidget {
  final List<Map<String, dynamic>> units;
  final String baseUnit;
  final String currency;
  const _UnitPickerSheet(
      {required this.units, required this.baseUnit, required this.currency});

  /// Plain-language unit line: «1 باكيت = 8 قطع • 60 USD». Base unit shows
  /// just its price (no redundant «1 قطعة = 1 قطعة»).
  String _subtitle(Map u) {
    final name = '${u['name'] ?? ''}';
    final factor = ((u['factor'] ?? 1) as num).toDouble();
    final price = u['sale_price'];
    final eq = factor == 1
        ? name
        : '1 $name = ${_fmtNum(factor)} $baseUnit';
    if (price == null) return eq;
    final cur = currency.isEmpty ? '' : ' $currency';
    return '$eq • ${fmtNum(price)}$cur';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final u in units)
            ListTile(
              // The unit's own photo (a carton) when it has one.
              leading: BusinessUnitImage(image: u['image']?.toString()),
              title: Text((u['name'] ?? '').toString(),
                  style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
              subtitle: Text(
                  _subtitle(u),
                  style: const TextStyle(fontFamily: 'Cairo')),
              onTap: () => Navigator.pop(context, u),
            ),
        ],
      ),
    );
  }
}

class _LineRow extends ConsumerWidget {
  final int index;
  final SaleItem item;
  const _LineRow({required this.index, required this.item});

  /// Quick (non-inventory) lines: no discount field, no service badge, no
  /// bottom total — just quantity + unit + the FULL price, as specified.
  bool get _isQuick => item.productId == null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(saleDraftProvider.notifier);
    final l10n = AppLocalizations.of(context);
    // Displayed full price of a quick line (stored distributed per unit).
    final quickTotal = item.quantity * item.unitPrice;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(60),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.description,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ),
              IconButton(
                onPressed: () => notifier.removeItem(index),
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppColors.danger,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _QtyStepper(
                value: item.quantity,
                // Available units = stock (base) / unit factor.
                stock: item.factor > 0 ? item.stock / item.factor : item.stock,
                isService: item.isService,
                onChanged: (v) => notifier.updateItem(index, item.copyWith(quantity: v)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniField(
                  label: _isQuick
                      ? l10n.translate('saleFullPrice')
                      : l10n.translate('salePrice'),
                  value: fmtNum(_isQuick ? quickTotal : item.unitPrice),
                  onChanged: (v) {
                    final invCur = ref.read(saleDraftProvider).currency;
                    if (_isQuick) {
                      // Full-price edit: redistribute per unit so the stored
                      // line matches exactly what the merchant sees.
                      final qty = item.quantity <= 0 ? 1 : item.quantity;
                      final perUnit = double.parse((v / qty).toStringAsFixed(2));
                      notifier.updateItem(
                          index,
                          item.copyWith(
                              unitPrice: perUnit,
                              priceManual: true,
                              manualPriceCurrency: invCur));
                    } else {
                      // Manual price: frozen as the ACTUAL line price; the
                      // catalogue FX snapshot (priceCurrency/rate) is kept so
                      // statistics can convert the real amount historically.
                      notifier.updateItem(
                          index,
                          item.copyWith(
                              unitPrice: v,
                              priceManual: true,
                              manualPriceCurrency: invCur));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: UnitLineField(
                  label: l10n.translate('saleUnit'),
                  value: item.unitName.isEmpty ? 'قطعة' : item.unitName,
                  productId: item.productId,
                  loadUnitCount: item.productId == null
                      ? null
                      : () async {
                          final u = await ref
                              .read(salesApiProvider)
                              .productUnits(item.productId!);
                          return ((u['units'] as List?) ?? const []).length;
                        },
                  onTap: () => _changeUnit(context, ref),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              GestureDetector(
                onTap: () => _changeUnit(context, ref),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                      '${l10n.translate('invQtyNow')}: ${_fmtNum(item.quantity)} ${item.unitName}',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w600, color: AppColors.primary)),
                ),
              ),
              if (!item.isService && item.productId != null) ...[
                const SizedBox(width: 8),
                Text(
                    '${l10n.translate('saleStock')}: ${_fmtNum(item.stock)}',
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
              ],
              if (!_isQuick) ...[
                const Spacer(),
                Text(
                  fmtNum(item.lineTotal),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _changeUnit(BuildContext context, WidgetRef ref) async {
    // Quick lines pick from the generic unit list; inventory lines from
    // the product's own units.
    if (_isQuick) {
      final l10n = AppLocalizations.of(context);
      final isAr = l10n.locale.languageCode != 'en';
      final picked =
          await showBusinessSelectionSheet<Map<String, dynamic>>(
        context: context,
        title: l10n.translate('saleChooseUnit'),
        selected: {'name': item.unitName},
        items: [
          for (final u in defaultUnits)
            BizSheetItem(
              value: {'name': u.name, 'factor': u.factor},
              title: isAr ? u.name : u.en,
              subtitle: u.weight
                  ? l10n.translate('saleWeightUnit')
                  : l10n.translate('saleUnitPieces',
                      params: {'n': _fmtNum(u.factor)}),
              icon: Icons.straighten_outlined,
            ),
        ],
      );
      if (picked == null || !context.mounted) return;
      ref.read(saleDraftProvider.notifier).updateItem(
            index,
            item.copyWith(
              unitName: picked['name'] as String,
              factor: (picked['factor'] as num).toDouble(),
            ),
          );
      return;
    }
    try {
      final u = await ref.read(salesApiProvider).productUnits(item.productId!);
      final units =
          ((u['units'] as List?)?.whereType<Map>() ?? const []).toList();
      if (!context.mounted || units.length < 2) return;
      String baseUnit = '${units.first['name'] ?? ''}';
      for (final e in units) {
        if (e['is_base'] == true) {
          baseUnit = '${e['name'] ?? ''}';
          break;
        }
      }
      final invCur = ref.read(saleDraftProvider).currency;
      final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => _UnitPickerSheet(
            units: units.map((e) => Map<String, dynamic>.from(e)).toList(),
            baseUnit: baseUnit,
            currency: invCur),
      );
      if (picked == null || !context.mounted) return;
      final price = picked['sale_price'] != null
          ? (picked['sale_price'] as num).toDouble()
          : item.unitPrice;
      ref.read(saleDraftProvider.notifier).updateItem(
            index,
            item.copyWith(
              unitId: picked['id']?.toString(),
              unitName: (picked['name'] ?? '').toString(),
              factor: (picked['factor'] as num?)?.toDouble() ?? 1.0,
              unitPrice: price,
            ),
          );
    } catch (_) {}
  }
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

class _QtyStepper extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  /// Available stock (base units). Sales cannot exceed it; 0 means unlimited
  /// (services / non-stock lines).
  final double stock;
  final bool isService;
  const _QtyStepper({
    required this.value,
    required this.onChanged,
    this.stock = 0,
    this.isService = false,
  });
  @override
  State<_QtyStepper> createState() => _QtyStepperState();
}

class _QtyStepperState extends State<_QtyStepper> {
  late final TextEditingController _ctrl =
      TextEditingController(text: _fmtNum(widget.value));
  final FocusNode _focus = FocusNode();

  double get _maxQty =>
      (widget.isService || widget.stock <= 0) ? double.infinity : widget.stock;

  bool get _capped => _maxQty != double.infinity;

  void _warnOut() {
    // Red alert + buzz in sync when qty exceeds available stock.
    unawaited(ScanSfx.error());
    showFyonaSnack(context,
        AppLocalizations.of(context).translate('saleOutOfStock'),
        success: false);
  }

  void _apply(double v) {
    if (_capped && v > _maxQty + 1e-9) {
      _warnOut();
      widget.onChanged(_maxQty);
      return;
    }
    widget.onChanged(v);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QtyStepper old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) {
      final current = double.tryParse(_ctrl.text.trim());
      if (current == null || (current - widget.value).abs() > 0.0001) {
        _ctrl.text = _fmtNum(widget.value);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _apply(
                (widget.value - 1) < 0.001 ? widget.value : widget.value - 1),
            icon: const Icon(Icons.remove, size: 16),
          ),
          SizedBox(
            width: 40,
            child: BusinessNumberField(
              controller: _ctrl,
              focusNode: _focus,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                  border: InputBorder.none, isDense: true,
                  contentPadding: EdgeInsets.zero),
              onChanged: (v) {
                final parsed = double.tryParse(v.trim());
                if (parsed != null && parsed >= 0) _apply(parsed);
              },
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _apply(widget.value + 1),
            icon: const Icon(Icons.add, size: 16),
          ),
        ],
      ),
    );
  }
}

class _MiniField extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<double> onChanged;
  const _MiniField({required this.label, required this.value, required this.onChanged});
  @override
  State<_MiniField> createState() => _MiniFieldState();
}

class _MiniFieldState extends State<_MiniField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MiniField old) {
    super.didUpdateWidget(old);
    // Do not rewrite the text (or swap the controller) while typing — that is
    // what was dropping focus and hiding the keyboard.
    if (!_focus.hasFocus && _ctrl.text != widget.value) {
      final current = parseFormattedAmount(_ctrl.text);
      final next = parseFormattedAmount(widget.value);
      if (current == null || next == null || (current - next).abs() > 0.0001) {
        _ctrl.text = widget.value;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BusinessNumberField(
      controller: _ctrl,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onChanged: (v) {
        // Live recalculation while typing (no ENTER needed).
        final parsed = v.trim().isEmpty ? 0.0 : parseFormattedAmount(v);
        if (parsed != null && parsed >= 0) widget.onChanged(parsed);
      },
      onSubmitted: (v) {
        final parsed = parseFormattedAmount(v);
        if (parsed != null && parsed >= 0) widget.onChanged(parsed);
      },
    );
  }
}

/// A read-only, tappable field that matches [_MiniField]'s look and opens the
/// unit picker. Replaces the old per-line discount field (fields are now:
/// الوحدة | السعر | الكمية).
class _UnitMiniField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _UnitMiniField(
      {required this.label, required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w600)),
          ),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
        ]),
      ),
    );
  }
}
