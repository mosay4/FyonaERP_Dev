import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../inventory/presentation/widgets/business_product_image.dart';
import '../../../inventory/presentation/widgets/business_unit_image.dart';
import '../../../inventory/presentation/providers/warehouse_settings.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

enum _InventoryView { individual, categories }

double _number(dynamic value, {double fallback = 0}) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  return parsed != null && parsed.isFinite ? parsed : fallback;
}

class BranchInventoryPickerPage extends ConsumerStatefulWidget {
  const BranchInventoryPickerPage({
    super.key,
    required this.products,
    required this.sourceBranchName,
    required this.targetBranchName,
    this.initialLines = const [],
    this.categories = const [],
    this.l10n,
  });

  final List<Map<String, dynamic>> products;
  final String sourceBranchName;
  final String targetBranchName;
  final List<Map<String, dynamic>> initialLines;
  final List<Map<String, dynamic>> categories;
  final AppLocalizations? l10n;

  @override
  ConsumerState<BranchInventoryPickerPage> createState() =>
      _BranchInventoryPickerPageState();
}

class _PickSelection {
  _PickSelection(this.product, {String? unitId, String? quantity})
    : unitId = unitId ?? _baseUnitId(product),
      controller = TextEditingController(text: quantity ?? '1');

  final Map<String, dynamic> product;
  String? unitId;
  final TextEditingController controller;

  List<Map> get units =>
      (product['units'] as List? ?? const []).whereType<Map>().toList();

  static String? _baseUnitId(Map<String, dynamic> p) {
    final units = (p['units'] as List? ?? const []).whereType<Map>();
    for (final u in units) {
      if (u['is_base'] == true) return '${u['id']}';
    }
    return units.isNotEmpty ? '${units.first['id']}' : null;
  }

  double get factor {
    for (final u in units) {
      if ('${u['id']}' == unitId) {
        final value = _number(u['factor'], fallback: 1);
        return value > 0 ? value : 1;
      }
    }
    return 1;
  }

  String get unitName {
    for (final u in units) {
      if ('${u['id']}' == unitId) return '${u['name'] ?? ''}';
    }
    return '${product['unit'] ?? ''}';
  }

  double get maxQuantity {
    final available = _number(product['available']);
    final f = factor;
    if (f <= 0) return available;
    final value = available / f;
    return (value * 10000).floorToDouble() / 10000;
  }

  double get quantity => _number(controller.text.trim());

  bool get valid => quantity > 0 && quantity <= maxQuantity + 0.00005;

  void dispose() => controller.dispose();
}

class _BranchInventoryPickerPageState
    extends ConsumerState<BranchInventoryPickerPage> {
  final _search = TextEditingController();
  final Map<String, _PickSelection> _selected = {};
  // «منتجات فردية» (every product, one by one) is the default view.
  _InventoryView _view = _InventoryView.individual;
  String? _categoryFilter;
  String _query = '';
  String? _errorProduct;

  AppLocalizations get l10n => widget.l10n ?? AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    for (final line in widget.initialLines) {
      final p = line['product'];
      if (p is Map) {
        final product = Map<String, dynamic>.from(p);
        final key = '${product['id']}';
        _selected[key] = _PickSelection(
          product,
          unitId: line['unitId']?.toString(),
          quantity: line['quantity']?.toString(),
        );
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    for (final s in _selected.values) {
      s.dispose();
    }
    super.dispose();
  }

  String _categoryLabel(Map c) {
    if (l10n.locale.languageCode != 'ar') {
      final name = '${c['name'] ?? ''}'.trim();
      if (name.isNotEmpty) return name;
    }
    final ar = '${c['name_ar'] ?? ''}'.trim();
    if (ar.isNotEmpty) return ar;
    return '${c['name'] ?? ''}'.trim();
  }

  String _categoryLabelById(List<Map<String, dynamic>> categories, String id) {
    for (final c in categories) {
      if ('${c['id']}' == id) return _categoryLabel(c);
    }
    return '';
  }

  bool _matches(Map<String, dynamic> p) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return '${p['name'] ?? ''}'.toLowerCase().contains(q) ||
        '${p['name_ar'] ?? ''}'.toLowerCase().contains(q) ||
        '${p['barcode'] ?? ''}'.toLowerCase().contains(q) ||
        '${p['sku'] ?? ''}'.toLowerCase().contains(q);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanPage()));
    if (code == null || code.trim().isEmpty) return;
    _search.text = code.trim();
    _search.selection = TextSelection.fromPosition(
      TextPosition(offset: _search.text.length),
    );
    setState(() => _query = code.trim());
  }

  @override
  Widget build(BuildContext context) {
    final showBarcode = ref.watch(warehouseSettingsProvider).barcode;
    final products = widget.products.where(_matches).toList();
    final categories = <Map<String, dynamic>>[];
    if (widget.categories.isNotEmpty) {
      for (final c in widget.categories) {
        final map = Map<String, dynamic>.from(c);
        if ('${map['id'] ?? ''}'.isNotEmpty) categories.add(map);
      }
    } else {
      final seen = <String>{};
      for (final p in widget.products) {
        final id = '${p['category_id'] ?? ''}';
        if (id.isEmpty || !seen.add(id)) continue;
        categories.add({
          'id': id,
          'name': '${p['category_name'] ?? ''}',
          'name_ar': '${p['category_name_ar'] ?? ''}',
        });
      }
    }
    // The categories filter follows the warehouse «التصانيف» setting and
    // the sending branch actually having categories.
    if (!ref.watch(warehouseSettingsProvider).categories) categories.clear();
    final categoryIds = categories.map((c) => '${c['id']}').toSet();
    final visible = products.where((p) {
      final id = '${p['category_id'] ?? ''}';
      // Individual products: ALL products, each on its own (also the ones
      // inside a category).
      if (_view != _InventoryView.categories) return true;
      return _categoryFilter != null && id == _categoryFilter;
    }).toList();
    final selectedCategory = categoryIds.contains(_categoryFilter)
        ? _categoryFilter
        : null;
    final browseCategories =
        _view == _InventoryView.categories && selectedCategory == null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          l10n.translate('inventoryPickerTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      // Everything above the products scrolls too. Fixed-height header/footer
      // Rows previously consumed the whole product viewport on real phones
      // with larger text, making a populated list appear completely white.
      bottomNavigationBar: _bottomBar(),
      body: CustomScrollView(
        key: const ValueKey('branch-inventory-content'),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(children: [
                          Flexible(
                              child: Text(widget.sourceBranchName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.primary))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.arrow_forward_rounded,
                                size: 14, color: AppColors.primary),
                          ),
                          Flexible(
                              child: Text(widget.targetBranchName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.primary))),
                        ]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.translate('inventoryPickerHint'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10.5,
                          height: 1.45,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FyonaTextField(
                    controller: _search,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: l10n.translate('inventorySearchHint'),
                      hintStyle: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11.5,
                        color: AppColors.textTertiary,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: showBarcode
                          ? IconButton(
                              tooltip: l10n.translate('purScanBarcode'),
                              onPressed: _scan,
                              icon: const Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 20,
                              ),
                            )
                          : null,
                      filled: true,
                      fillColor: AppColors.surface,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _filter(
                        l10n.translate('inventoryIndividual'),
                        _InventoryView.individual,
                      ),
                      if (categories.isNotEmpty)
                        _filter(
                          l10n.translate('invCategories'),
                          _InventoryView.categories,
                        ),
                    ],
                  ),
                ),
                if (_view == _InventoryView.categories &&
                    selectedCategory != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _categoryFilter = null),
                          icon: const Icon(Icons.arrow_back_rounded, size: 17),
                          label: Text(
                            l10n.translate('invCategories'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            _categoryLabelById(categories, selectedCategory),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (browseCategories)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverGrid(
                // Two category squares per row, like the inventory screen.
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisExtent:
                      124 +
                      (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(
                            0,
                            32,
                          ) *
                          5,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _categoryCard(categories[index]),
                  childCount: categories.length,
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 40,
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 48,
                      color: AppColors.primary.withAlpha(100),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.translate('inventoryNoProducts'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _productCard(visible[index]),
                  childCount: visible.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filter(String label, _InventoryView view) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        key: ValueKey('inventory-filter-${view.name}'),
        selected: _view == view,
        label: Text(
          label,
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
        ),
        onSelected: (_) => setState(() {
          _view = view;
          _categoryFilter = null;
        }),
      ),
    );
  }

  Widget _categoryCard(Map<String, dynamic> category) {
    final id = '${category['id']}';
    final count = widget.products
        .where((p) => '${p['category_id'] ?? ''}' == id)
        .length;
    final image = '${category['image'] ?? ''}';
    return Padding(
      padding: EdgeInsets.zero,
      child: InkWell(
        key: ValueKey('inventory-category-$id'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _categoryFilter = id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withAlpha(90),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: image.trim().isNotEmpty
                    ? BusinessProductImage(
                        url: image,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      )
                    : Icon(
                        Icons.category_outlined,
                        size: 24,
                        color: AppColors.primary,
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                _categoryLabel(category),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                l10n.translate(
                  'branchProductCount',
                  params: {'count': '$count'},
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _productCard(Map<String, dynamic> product) {
    final id = '${product['id']}';
    final selection = _selected[id];
    final selected = selection != null;
    final image = '${product['image'] ?? ''}';
    final available = _number(product['available']);
    return AnimatedContainer(
      key: ValueKey('inventory-product-$id'),
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary.withAlpha(9) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? AppColors.primary.withAlpha(90) : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: image.isNotEmpty
                      ? BusinessProductImage(url: image, width: 56, height: 56)
                      : Container(
                          width: 56,
                          height: 56,
                          color: AppColors.primary.withAlpha(16),
                          child: const Icon(
                            Icons.inventory_2_outlined,
                            color: AppColors.primary,
                            size: 25,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${product['name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if ('${product['barcode'] ?? ''}'.trim().isNotEmpty)
                      Text(
                        '${product['barcode']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9.5,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    Text(
                      '${l10n.translate('inventoryAvailable')}: ${_fmt(available)} ${product['unit'] ?? ''}',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (available <= 0)
                      Text(
                        l10n.translate('inventoryOutOfStock'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10,
                          color: AppColors.danger,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('inventory-select-$id'),
                tooltip: available <= 0
                    ? l10n.translate('inventoryOutOfStock')
                    : l10n.translate('inventoryChooseProducts'),
                onPressed: available <= 0 ? null : () => _toggle(product),
                icon: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline,
                  color: available <= 0
                      ? AppColors.textTertiary
                      : AppColors.primary,
                ),
              ),
            ],
          ),
          if (selection != null) ...[
            const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                key: ValueKey('inventory-decrease-$id'),
                tooltip: l10n.translate('inventoryDecreaseQuantity'),
                visualDensity: VisualDensity.compact,
                onPressed: selection.quantity <= 0
                    ? null : () => _stepQuantity(selection, -1),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Expanded(
                  child: BusinessNumberField(
                    key: ValueKey('inventory-quantity-$id'),
                    controller: selection.controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.translate('branchLineQuantity'),
                      labelStyle: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                      ),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                    ),
                    onChanged: (_) => setState(() => _errorProduct = null),
                  ),
                ),
              IconButton(
                key: ValueKey('inventory-increase-$id'),
                tooltip: l10n.translate('inventoryIncreaseQuantity'),
                visualDensity: VisualDensity.compact,
                onPressed: selection.quantity >= selection.maxQuantity
                    ? null : () => _stepQuantity(selection, 1),
                icon: const Icon(Icons.add_circle_outline),
              ),
              const SizedBox(width: 8),
                if (selection.units.length > 1)
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: selection.unitId,
                      isExpanded: true,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.translate('branchUnit'),
                        labelStyle: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10,
                        ),
                        filled: true,
                        fillColor: AppColors.background,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(11),
                          borderSide: BorderSide(color: AppColors.border),
                        ),
                      ),
                      items: selection.units
                          .map(
                            (u) => DropdownMenuItem(
                              value: '${u['id']}',
                              child: Row(children: [
                                if (businessUnitDisplayImage(u,
                                        product: selection.product) !=
                                    null) ...[
                                  BusinessUnitImage(
                                      image: businessUnitDisplayImage(u,
                                          product: selection.product),
                                      size: 22,
                                      radius: 6),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    '${u['name']}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 10.5,
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        selection.unitId = v;
                        final q = selection.quantity;
                        if (q > selection.maxQuantity) {
                          selection.controller.text = _fmt(
                            selection.maxQuantity,
                          );
                        }
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.translate(
                    'inventoryMax',
                    params: {
                      'max':
                          '${_fmt(selection.maxQuantity)} ${selection.unitName}',
                    },
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9.5,
                    color: _errorProduct == id
                        ? AppColors.danger
                        : AppColors.textTertiary,
                  ),
                ),
                if (_errorProduct == id)
                  Text(
                    l10n.translate('branchQuantityExceeded'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 9.5,
                      color: AppColors.danger,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _toggle(Map<String, dynamic> product) {
    final available = _number(product['available']);
    if (available <= 0) return;
    final id = '${product['id']}';
    setState(() {
      if (_selected.containsKey(id)) {
        _selected.remove(id)?.dispose();
      } else {
        _selected[id] = _PickSelection(product);
        _errorProduct = null;
      }
    });
  }

  void _stepQuantity(_PickSelection selection, int delta) {
    final next = (selection.quantity + delta)
        .clamp(0.0, selection.maxQuantity);
    final text = _fmt(next);
    setState(() {
      _errorProduct = null;
      selection.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length));
    });
  }

  Widget _bottomBar() {
    final validCount = _selected.values.where((s) => s.valid).length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.translate(
                'inventorySelectedCount',
                params: {'count': '$validCount'},
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            FilledButton(
              key: const ValueKey('inventory-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              onPressed: _confirm,
              child: Text(
                l10n.translate('inventoryApply'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirm() {
    String? bad;
    for (final s in _selected.values) {
      if (!s.valid) {
        bad = '${s.product['id']}';
        break;
      }
    }
    if (bad != null) {
      setState(() => _errorProduct = bad);
      return;
    }
    final lines = <Map<String, dynamic>>[];
    for (final s in _selected.values) {
      if (!s.valid) continue;
      lines.add({
        'product': s.product,
        'quantity': s.quantity,
        'unitId': s.unitId,
        'unitName': s.unitName,
        'available': s.maxQuantity,
      });
    }
    Navigator.pop(context, lines);
  }
}

String _fmt(double value) {
  if ((value - value.roundToDouble()).abs() < 0.00005) {
    return value.toInt().toString();
  }
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
