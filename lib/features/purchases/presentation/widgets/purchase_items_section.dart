import 'dart:async';

import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/services/units/custom_units.dart';
import '../../../../../shared/services/scan_sfx.dart';
import '../../../../../shared/widgets/styled_snack.dart';
import '../../../../../shared/widgets/business_selection_sheet.dart';
import '../../../sales/presentation/widgets/sale_section_card.dart';
import '../../../sales/presentation/providers/sale_providers.dart'
    show SaleItem;
import '../providers/purchase_providers.dart';
import '../../../core_business/presentation/widgets/invoice_line_widgets.dart';
import '../pages/barcode_scan_page.dart';
import '../../../inventory/presentation/widgets/business_unit_image.dart';
import '../../../inventory/presentation/widgets/product_picker.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../inventory/presentation/providers/inventory_providers.dart';
import '../../../inventory/presentation/providers/warehouse_settings.dart';
import 'purchase_payment_section.dart' show applyPurchaseInvoiceCurrency;
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Products & services for a purchase invoice: search, barcode, quick-add.
/// Same compact language as the sale items section.
class PurchaseItemsSection extends ConsumerWidget {
  const PurchaseItemsSection({super.key});


  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('purAddProducts'),
      items: [
        if (ref.read(employeeCanProvider('inventory'))) BizSheetItem(
            value: 'search',
            title: l10n.translate('invPickProducts'),
            icon: Icons.checklist),
        BizSheetItem(
            value: 'quick',
            title: l10n.translate('saleQuickProduct'),
            icon: Icons.add_box_outlined),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked == 'search') {
      await Future.delayed(const Duration(milliseconds: 280));
      if (context.mounted) _pickProductsMulti(context, ref);
    } else {
      _quickAdd(context, ref);
    }
  }

  /// Fast multi-select: pick several products once, with quantities, and add
  /// them all in a single step (no repeated search screen visits).
  Future<void> _pickProductsMulti(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showProductMultiPicker(
      context,
      api: ref.read(inventoryApiProvider),
      title: l10n.translate('invPickProducts'),
      showBarcode: ref.read(warehouseSettingsProvider).barcode,
      // Buying ADDS stock: a 0-stock product must be addable without the
      // «نفذت كمية هذا المنتج» blocker.
      checkStock: false,
    );
    if (picked == null || picked.isEmpty) return;
    final notifier = ref.read(purchaseDraftProvider.notifier);
    for (final p in picked) {
      final prod = p.product;
      final unit = p.unit;
      // Per-currency BUY prices (fallback to sell) so a currency change can
      // re-price like the sale invoice.
      final rawPrices = (prod['prices'] as List?)?.whereType<Map>() ?? const [];
      final buyByCur = <String, double>{};
      for (final e in rawPrices) {
        final cur = (e['currency']?.toString().toUpperCase() ?? '');
        if (cur.isEmpty) continue;
        final bp = e['buy_price'];
        buyByCur[cur] = bp != null
            ? (double.tryParse('$bp') ?? 0)
            : (double.tryParse('${e['price']}') ?? 0);
      }
      final base = _priceOf(prod);
      notifier.addItem(SaleItem(
        productId: prod['id']?.toString(),
        unitId: unit?['id']?.toString(),
        description: (prod['name'] ?? '').toString(),
        unitName: (unit?['name'] ?? prod['unit'] ?? 'قطعة').toString(),
        factor: unit == null ? 1 : (double.tryParse('${unit['factor']}') ?? 1),
        quantity: p.quantity,
        unitPrice: base,
        isService: prod['is_service'] == true,
        sellPrices: buyByCur.isEmpty ? null : buyByCur,
        priceCurrency: buyByCur.isNotEmpty ? buyByCur.keys.first : null,
        originalUnitPrice: base,
      ));
    }
    // Auto-convert the just-added lines to the invoice currency immediately.
    final cur = ref.read(purchaseDraftProvider).currency;
    if (cur.isNotEmpty) applyPurchaseInvoiceCurrency(ref, cur);
    if (context.mounted) {
      showFyonaSnack(
          context,
          l10n.translate('invAddedCount', params: {'n': '${picked.length}'}),
          success: true);
    }
  }

  Future<void> _pickProduct(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<Map<String, dynamic>>(
      context: context,
      title: l10n.translate('saleSearchProductHint'),
      showSearch: true,
      searchHint: l10n.translate('saleSearchProductHint'),
      onSearch: (q) async {
        final raw = await ref.read(purchaseApiProvider).searchProducts(q);
        return [
          for (final p in raw.whereType<Map>())
            BizSheetItem(
              value: Map<String, dynamic>.from(p),
              title: (p['name'] ?? '').toString(),
              subtitle: (p['sku']?.toString().isNotEmpty ?? false)
                  ? p['sku'].toString()
                  : null,
              icon: Icons.inventory_2_outlined,
            ),
        ];
      },
    );
    if (picked == null || !context.mounted) return;
    _addProduct(
      ref,
      productId: picked['id']?.toString(),
      name: (picked['name'] ?? '').toString(),
      unitName: (picked['unit'] ?? 'قطعة').toString(),
      price: _priceOf(picked),
      isService: picked['is_service'] == true,
    );
  }

  static double _priceOf(Map p) {
    final cost = p['cost_price'];
    final price = p['price'];
    final v = (cost is num && cost > 0) ? cost : price;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<void> _scanBarcode(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('purScanBarcode'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.translate('purBarcodeHint'),
            suffixIcon: IconButton(
              tooltip: l10n.translate('purScanWithCamera'),
              onPressed: () async {
                final scanned = await Navigator.of(ctx).push<String>(
                  MaterialPageRoute(builder: (_) => const BarcodeScanPage()),
                );
                if (scanned != null && scanned.isNotEmpty) {
                  ctrl.text = scanned;
                }
              },
              icon: const Icon(Icons.photo_camera_outlined),
            ),
          ),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(l10n.translate('saleSearch'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    ctrl.dispose();
    if (code == null || code.isEmpty || !context.mounted) return;
    await _handleBarcode(context, ref, code);
  }

  /// Barcode → product. Known codes reuse the linked product/unit (no
  /// duplicates); unknown codes offer a one-tap «create product with this
  /// barcode» that opens quick-add with the code pre-filled.
  Future<void> _handleBarcode(
      BuildContext context, WidgetRef ref, String code) async {
    final l10n = AppLocalizations.of(context);
    final existing = await _resolveByBarcode(ref, code);
    if (existing != null) {
      _addResolved(ref, existing);
      return;
    }
    if (!context.mounted) return;
    // Alert buzz exactly when the «باركود غير موجود» dialog appears.
    unawaited(ScanSfx.error());
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('purBarcodeNotFound'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: Text(
            l10n.translate('purCreateWithBarcode', params: {'code': code}),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('purCreateNewProduct'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (create == true && context.mounted) {
      await _quickAdd(context, ref, initialBarcode: code);
    }
  }

  void _addResolved(
      WidgetRef ref, (Map<String, dynamic>, Map<String, dynamic>?) existing) {
    final product = existing.$1;
    final unit = existing.$2;
    // Product found by barcode → success beep in sync with the added line.
    unawaited(ScanSfx.success());
    ref.read(purchaseDraftProvider.notifier).addItem(SaleItem(
          productId: product['id']?.toString(),
          unitId: unit?['id']?.toString(),
          description: (product['name'] ?? '').toString(),
          unitName: (unit?['name'] ?? product['unit'] ?? 'قطعة').toString(),
          factor: (unit?['factor'] as num?)?.toDouble() ?? 1,
          unitPrice: _priceOf(product),
          isService: product['is_service'] == true,
        ));
  }

  void _addProduct(
    WidgetRef ref, {
    String? productId,
    required String name,
    required String unitName,
    double price = 0,
    double factor = 1,
    String? unitId,
    bool isService = false,
  }) {
    ref.read(purchaseDraftProvider.notifier).addItem(SaleItem(
          productId: productId,
          unitId: unitId,
          description: name,
          unitName: unitName,
          factor: factor,
          unitPrice: price,
          isService: isService,
        ));
  }

  /// Standalone currency box beside the price field (used when «save to
  /// inventory» is ON so the full amount always fits). When [showError]
  /// is set the frame turns red (no tiny clipped helper text).
  Widget _ccyBox(BuildContext ctx, StateSetter setSt, String current,
      void Function(String) onPick,
      {bool showError = false}) {
    final l10n = AppLocalizations.of(ctx);
    final missing = showError && current.isEmpty;
    return InkWell(
      onTap: () async {
        final picked = await showBusinessSelectionSheet<String>(
          context: ctx,
          title: l10n.translate('invCurrency'),
          selected: current.isEmpty ? null : current,
          items: [
            for (final c in const ['SAR', 'USD', 'YER_NEW', 'YER_OLD'])
              BizSheetItem(
                  value: c,
                  title: currencyName(c),
                  icon: Icons.monetization_on_outlined),
          ],
        );
        if (picked != null) setSt(() => onPick(picked));
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
  /// pick (the caller paints the box red first via setSt).
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

  Future<void> _quickAdd(BuildContext context, WidgetRef ref,
      {String? initialBarcode}) async {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController();
    String unitName = 'قطعة';
    final qtyCtrl = TextEditingController(text: '1');
    final costCtrl = TextEditingController();
    final barcodeCtrl = TextEditingController(text: initialBarcode ?? '');
    final minStockCtrl = TextEditingController();
    DateTime? expiry;
    bool save = false;
    String buyCurrency = '';
    bool buyCcyError = false;
    final scrollCtrl = ScrollController();
    final buyCcyKey = GlobalKey();
    final ws = ref.read(warehouseSettingsProvider);
    String? catId;
    String? catName;
    List<Map<String, dynamic>> cats = const [];
    if (ws.categories) {
      try {
        cats = await ref.read(inventoryApiProvider).categories();
      } catch (_) {}
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final buyLabel = l10n.translate('purBuyPrice');
          Future<void> pickUnit() async {
            final picked = await showBusinessSelectionSheet<String>(
              context: ctx,
              title: l10n.translate('saleChooseUnit'),
              selected: unitName,
              items: [
                for (final u in <UnitDef>[
                  ...defaultUnits,
                  for (final c in ref.read(customUnitsProvider))
                    (name: c, en: c, factor: 1.0, weight: false, group: 'count'),
                ])
                  BizSheetItem(
                    value: u.name,
                    title: l10n.locale.languageCode == 'en' ? u.en : u.name,
                    subtitle: l10n.translate(
                        u.weight ? 'saleWeightUnit' : 'saleUnitPieces',
                        params: {
                          'n': u.factor == u.factor.roundToDouble()
                              ? '${u.factor.toInt()}'
                              : '${u.factor}'
                        }),
                    icon: Icons.straighten_outlined,
                  ),
              ],
              addNewLabel: l10n.translate('unitAddCustom'),
              onAddNew: () async {
                final ctrl = TextEditingController();
                final name = await showDialog<String>(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
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
                          onPressed: () => Navigator.pop(dctx),
                          child: Text(l10n.translate('cancel'),
                              style: const TextStyle(fontFamily: 'Cairo'))),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(dctx, ctrl.text.trim()),
                          child: Text(l10n.translate('addLabel'),
                              style: const TextStyle(fontFamily: 'Cairo'))),
                    ],
                  ),
                );
                if (name == null || name.trim().isEmpty) return null;
                await ref.read(customUnitsProvider.notifier).add(name.trim());
                return name.trim();
              },
            );
            if (picked != null && ctx.mounted) setSt(() => unitName = picked);
          }
          Widget stepBtn(IconData icon, int delta) => SizedBox(
                width: 30,
                height: 48,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: () {
                    final d = double.tryParse(qtyCtrl.text.trim()) ?? 1;
                    final n = (d + delta).clamp(1.0, 999999.0);
                    final t = n == n.roundToDouble()
                        ? n.toInt().toString()
                        : n.toString();
                    qtyCtrl.text = t;
                    qtyCtrl.selection =
                        TextSelection.collapsed(offset: t.length);
                  },
                  icon: Icon(icon),
                ),
              );
          Widget qtyBox() => Row(children: [
                stepBtn(Icons.add, 1),
                Expanded(
                  child: BusinessNumberField(
                    controller: qtyCtrl,
                    textAlign: TextAlign.center,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: l10n.translate('saleQty'), isDense: true),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
                stepBtn(Icons.remove, -1),
              ]);
          return AlertDialog(
          title: Text(l10n.translate('saleQuickProduct'),
              style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            controller: scrollCtrl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FyonaTextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                        labelText: l10n.translate('saleProductNameAdd')),
                    style: const TextStyle(fontFamily: 'Cairo')),
                const SizedBox(height: 12),
                if (!save) ...[
                  Row(children: [
                    Expanded(flex: 3, child: qtyBox()),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: BusinessNumberField(
                      controller: costCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [AmountInputFormatter()],
                      decoration: InputDecoration(
                          labelText: buyLabel),
                      style: const TextStyle(fontFamily: 'Cairo'))),
                  ]),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: pickUnit,
                      icon: const Icon(Icons.straighten_outlined, size: 18),
                      label: Text('${l10n.translate('saleChooseUnit')}: $unitName',
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ] else ...[
                  Row(children: [
                    Expanded(flex: 3, child: qtyBox()),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: pickUnit,
                        icon: const Icon(Icons.straighten_outlined, size: 18),
                        label: Text(unitName, maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'Cairo')),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(key: buyCcyKey, children: [
                    Expanded(
                      flex: 2,
                      child: BusinessNumberField(
                          controller: costCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [AmountInputFormatter()],
                          decoration: InputDecoration(
                              labelText: buyLabel),
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: _ccyBox(ctx, setSt, buyCurrency, (v) {
                        buyCurrency = v;
                        buyCcyError = false;
                      }, showError: buyCcyError),
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
                        onPressed: () async {
                          final scanned = await Navigator.of(ctx).push<String>(
                            MaterialPageRoute(
                                builder: (_) => const BarcodeScanPage()),
                          );
                          if (scanned != null && scanned.isNotEmpty) {
                            setSt(() => barcodeCtrl.text = scanned);
                          }
                        },
                        icon: const Icon(Icons.photo_camera_outlined),
                      ),
                    ),
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
                        context: ctx, initialDate: expiry ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 10));
                      if (picked != null) setSt(() => expiry = picked);
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(labelText: l10n.translate('invProductExpiry')),
                      child: Text(expiry == null ? l10n.translate('invNone')
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
                        setSt(() {
                          catId = picked['id']?.toString();
                          catName = (picked['name'] ?? '').toString();
                        });
                      }
                    },
                    child: InputDecorator(
                      decoration:
                          InputDecoration(labelText: l10n.translate('invCategory')),
                      child: Text(catName ?? l10n.translate('invNone'),
                          style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                ],
                if (ref.read(employeeCanProvider('inventory.add'))) CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: save,
                  onChanged: (v) => setSt(() => save = v ?? true),
                  title: Text(l10n.translate('purSaveToInventory'),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
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
                if (nameCtrl.text.trim().isEmpty) return;
                if (save && buyCurrency.isEmpty) {
                  setSt(() => buyCcyError = true);
                  _requireCurrency(ctx, buyCcyKey);
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(l10n.translate('saleAdd'),
                  style: const TextStyle(fontFamily: 'Cairo')),
            ),
          ],
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    final name = nameCtrl.text.trim();
    final qty = double.tryParse(qtyCtrl.text.trim()) ?? 1;
    final cost = parseFormattedAmount(costCtrl.text) ?? 0;
    final barcode = barcodeCtrl.text.trim();
    final notifier = ref.read(purchaseDraftProvider.notifier);

    // Barcode stays optional. When it is already known, REUSE the linked
    // product (and unit) instead of creating a duplicate product line.
    if (barcode.isNotEmpty) {
      final existing = await _resolveByBarcode(ref, barcode);
      if (existing != null && context.mounted) {
        final product = existing.$1;
        final unit = existing.$2;
        notifier.addItem(SaleItem(
          productId: product['id']?.toString(),
          unitId: unit?['id']?.toString(),
          description: (product['name'] ?? name).toString(),
          unitName:
              (unit?['name'] ?? product['unit'] ?? unitName).toString(),
          factor: (unit?['factor'] as num?)?.toDouble() ?? 1,
          quantity: qty <= 0 ? 1 : qty,
          unitPrice: cost,
          isService: product['is_service'] == true,
        ));
        return;
      }
    }

    notifier.addItem(SaleItem(
          description: name,
          unitName: unitName,
          quantity: qty <= 0 ? 1 : qty,
          unitPrice: cost,
          isService: !save,
          expiryDate: expiry,
          newProduct: {
            'name': name,
            'unit': unitName,
            'barcode': barcode,
            'save_to_inventory': save,
            if (save && buyCurrency.isNotEmpty) 'buy_currency': buyCurrency,
            'min_stock': double.tryParse(minStockCtrl.text.trim()) ?? 0,
            if (catId != null) 'category_id': catId,
            if (expiry != null)
              'expiry_date': expiry!.toIso8601String().split('T').first,
            'is_service': !save,
          },
        ));
  }

  /// Resolve a barcode to its product (+ optional unit) or null when unknown.
  Future<(Map<String, dynamic>, Map<String, dynamic>?)?> _resolveByBarcode(
      WidgetRef ref, String code) async {
    try {
      final res = await ref.read(purchaseApiProvider).resolveBarcode(code);
      final product = res['product'];
      if (product is! Map) return null;
      final unit = res['unit'];
      return (
        Map<String, dynamic>.from(product),
        unit is Map ? Map<String, dynamic>.from(unit) : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(purchaseDraftProvider);
    final l10n = AppLocalizations.of(context);
    return SaleSectionCard(
      titleKey: 'saleItems',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < draft.items.length; i++)
            _ItemRow(index: i, item: draft.items[i]),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.translate('purAddProducts'),
                  style: const TextStyle(fontFamily: 'Cairo')),
            ),
          ),
          if (draft.items.isEmpty)
            Text(l10n.translate('saleNoItems'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _ItemRow extends ConsumerWidget {
  final int index;
  final SaleItem item;
  const _ItemRow({required this.index, required this.item});

  /// Change the line's purchase unit — loads the unit's saved PURCHASE price
  /// (never assumed from the base). Only offered for products with >1 unit.
  Future<void> _changeUnit(BuildContext context, WidgetRef ref) async {
    if (item.productId == null) return;
    final l10n = AppLocalizations.of(context);
    try {
      final u =
          await ref.read(purchaseApiProvider).productUnits(item.productId!);
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
      final invCur = ref.read(purchaseDraftProvider).currency;
      final picked = await showBusinessSelectionSheet<Map<String, dynamic>>(
        context: context,
        title: l10n.translate('saleChooseUnit'),
        selected: {'id': item.unitId},
        items: [
          for (final e in units)
            BizSheetItem(
              value: Map<String, dynamic>.from(e),
              title: '${e['name'] ?? ''}',
              subtitle: _purchaseUnitSubtitle(
                  e, baseUnit: baseUnit, currency: invCur),
              icon: Icons.straighten_outlined,
              leading: BusinessUnitImage.has(e['image'])
                  ? BusinessUnitImage(image: '${e['image']}')
                  : null,
            ),
        ],
      );
      if (picked == null || !context.mounted) return;
      final price = picked['purchase_price'] != null
          ? asDoubleValue(picked['purchase_price'])
          : item.unitPrice;
      ref.read(purchaseDraftProvider.notifier).updateItem(
            index,
            item.copyWith(
              unitId: picked['id']?.toString(),
              unitName: '${picked['name'] ?? ''}',
              factor: (picked['factor'] as num?)?.toDouble() ?? 1.0,
              unitPrice: price,
            ),
          );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(purchaseDraftProvider.notifier);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
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
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => notifier.removeItem(index),
                icon: const Icon(Icons.close, size: 18),
                color: AppColors.danger,
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (item.productId != null) ...[
            // Product lines: ONE compact row — qty | buy price | unit.
            // The «القيمة» field is removed (it was a computed display; the
            // invoice totals still compute qty×price). Visual only.
            Row(
              children: [
                QtyStepper(
                  value: item.quantity,
                  onChanged: (v) => notifier.updateItem(
                      index, item.copyWith(quantity: v)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: AutoNumField(
                    label:
                        '${AppLocalizations.of(context).translate('purBuyPrice')}'
                        '${ref.watch(purchaseDraftProvider).currency.isEmpty ? '' : ' (${ref.watch(purchaseDraftProvider).currency})'}',
                    value: item.unitPrice,
                    onChanged: (v) {
                      final invCur = ref.read(purchaseDraftProvider).currency;
                      notifier.updateItem(
                          index,
                          item.copyWith(
                              unitPrice: v,
                              priceManual: true,
                              manualPriceCurrency: invCur));
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 4,
                  child: UnitLineField(
                    label: AppLocalizations.of(context).translate('saleUnit'),
                    value: item.unitName.isEmpty ? 'قطعة' : item.unitName,
                    productId: item.productId,
                    loadUnitCount: item.productId == null
                        ? null
                        : () async {
                            final u = await ref
                                .read(purchaseApiProvider)
                                .productUnits(item.productId!);
                            return ((u['units'] as List?) ?? const []).length;
                          },
                    onTap: () => _changeUnit(context, ref),
                  ),
                ),
              ],
            ),
          ] else ...[
            // Quick (manual) lines keep their single compact row.
            Row(
              children: [
                Expanded(
                  child: _MiniNum(
                    label: AppLocalizations.of(context).translate('saleQty'),
                    value: item.quantity,
                    onChanged: (v) => notifier.updateItem(
                        index, item.copyWith(quantity: v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniNum(
                    label:
                        AppLocalizations.of(context).translate('purBuyPrice'),
                    value: item.unitPrice,
                    money: true,
                    onChanged: (v) {
                      final invCur = ref.read(purchaseDraftProvider).currency;
                      notifier.updateItem(
                          index,
                          item.copyWith(
                              unitPrice: v,
                              priceManual: true,
                              manualPriceCurrency: invCur));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniNum(
                    label: AppLocalizations.of(context).translate('saleValue'),
                    value: item.unitPrice * item.quantity - item.discount,
                    money: true,
                    enabled: false,
                    onChanged: (_) {},
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniNum extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final bool enabled;
  final bool money;
  const _MiniNum(
      {required this.label,
      required this.value,
      required this.onChanged,
      this.enabled = true,
      this.money = false});

  static String fmt(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  @override
  State<_MiniNum> createState() => _MiniNumState();
}

class _MiniNumState extends State<_MiniNum> {
  late final TextEditingController _ctrl = TextEditingController(
      text: widget.money ? fmtNum(widget.value) : _MiniNum.fmt(widget.value));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MiniNum old) {
    super.didUpdateWidget(old);
    // Keep the keyboard and caret: never rewrite the text while the merchant
    // is typing. Only sync from the model when unfocused and truly changed.
    if (!_focus.hasFocus) {
      final current = widget.money
          ? parseFormattedAmount(_ctrl.text)
          : double.tryParse(_ctrl.text.trim());
      if (current == null || (current - widget.value).abs() > 0.0001) {
        _ctrl.text =
            widget.money ? fmtNum(widget.value) : _MiniNum.fmt(widget.value);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BusinessNumberField(
      formField: true,
      controller: _ctrl,
      focusNode: _focus,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: widget.money ? [AmountInputFormatter()] : null,
      style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 12),
          fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onChanged: (v) => widget.onChanged(
          widget.money ? (parseFormattedAmount(v) ?? 0) : (double.tryParse(v.trim()) ?? 0)),
    );
  }
}

/// A read-only, tappable unit field matching `_MiniNum`'s look, opening the
/// product's unit picker (fields are: الوحدة | السعر | الكمية).
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

String _fmtPur(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

/// Plain-language unit line for the purchase picker:
/// «1 باكيت = 8 قطع • 50 USD» (base unit shows just its price).
String _purchaseUnitSubtitle(Map e,
    {required String baseUnit, required String currency}) {
  final name = '${e['name'] ?? ''}';
  final factor = ((e['factor'] ?? 1) as num).toDouble();
  final price = e['purchase_price'];
  final eq = factor == 1 ? name : '1 $name = ${_fmtPur(factor)} $baseUnit';
  if (price == null) return eq;
  final cur = currency.isEmpty ? '' : ' $currency';
  return '$eq • ${fmtNum(price)}$cur';
}
