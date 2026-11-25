import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../../data/inventory_api.dart';
import 'business_product_image.dart';
import 'inventory_list_parts.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// One product chosen in the fast picker, with its resolved unit (if any).
class PickedProduct {
  final Map<String, dynamic> product;
  final Map<String, dynamic>? unit;
  double quantity;
  PickedProduct(this.product, {this.unit, this.quantity = 1});
}

/// Fast multi-select product picker: type the first letters, tap several
/// products, tweak quantities, then «إضافة (n)» — all without leaving the
/// sheet. A camera button scans barcodes into the SAME selection so the
/// merchant can add many products by scanning them one after another.
/// With [showQtyStepper] false the sheet becomes a pure check/uncheck
/// multi-chooser (used when assigning products to a category).
/// [checkStock] enforces the available-stock cap — ON for sales (cannot sell
/// what is not in stock), OFF for purchases (buying ADDS stock) and for
/// category assignment (stock is irrelevant there).
/// [showCategories] (the merchant's categories feature) adds the inventory's
/// «بدون تصنيف» / «مع التصنيف» pills: uncategorized products, or category
/// squares that open their products (search + barcode inside). The selection
/// and quantities are kept while switching between these views.
Future<List<PickedProduct>?> showProductMultiPicker(
  BuildContext context, {
  required InventoryApi api,
  required String title,
  String? initialBarcode,
  bool showBarcode = true,
  bool showQtyStepper = true,
  bool checkStock = true,
  bool Function(WidgetRef)? allowed,
  Set<String> excludeIds = const {},
  bool showCategories = false,
}) {
  return showModalBottomSheet<List<PickedProduct>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) {
      final sheet = _MultiPickerSheet(
        api: api,
        title: title,
        initialBarcode: initialBarcode,
        showBarcode: showBarcode,
        showQtyStepper: showQtyStepper,
        checkStock: checkStock,
        excludeIds: excludeIds,
        showCategories: showCategories,
      );
      if (allowed == null) return sheet;
      return Consumer(builder: (context, ref, _) {
        if (allowed(ref)) return sheet;
        return Material(child: ListTile(
          title: Text(AppLocalizations.of(context).translate('unauthorized')),
        ));
      });
    },
  );
}

class _MultiPickerSheet extends StatefulWidget {
  final InventoryApi api;
  final String title;
  final String? initialBarcode;
  final bool showBarcode;
  final bool showQtyStepper;
  final bool checkStock;
  /// Products already where they are going (e.g. in this category).
  final Set<String> excludeIds;
  final bool showCategories;
  const _MultiPickerSheet(
      {required this.api,
      this.showCategories = false,
      this.excludeIds = const {},
      required this.title,
      this.initialBarcode,
      this.showBarcode = true,
      this.showQtyStepper = true,
      this.checkStock = true});
  @override
  State<_MultiPickerSheet> createState() => _MultiPickerSheetState();
}

class _MultiPickerSheetState extends State<_MultiPickerSheet> {
  final _ctrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  final Map<String, PickedProduct> _selected = {}; // productId -> picked
  String _scanMsg = '';
  bool _scanError = false;

  /// Section filter (categories feature only): '' all products, 'none'
  /// uncategorized, 'cats' the category squares / one opened category.
  String _section = '';
  Map<String, dynamic>? _openCategory;
  List<Map<String, dynamic>>? _categories;
  bool _categoriesFailed = false;
  int _searchSeq = 0;

  bool get _showingCategoryGrid =>
      widget.showCategories && _section == 'cats' && _openCategory == null;

  Future<void> _playSfx({required bool ok}) =>
      ok ? ScanSfx.success() : ScanSfx.error();

  @override
  void initState() {
    super.initState();
    _search('');
    if (widget.initialBarcode != null && widget.initialBarcode!.isNotEmpty) {
      _barcodeCtrl.text = widget.initialBarcode!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scanOne());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _barcodeCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  static int get _searchThreshold => 1;

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    setState(() => _loading = true);
    final categoryId = _openCategory?['id']?.toString();
    try {
      final raw = await widget.api.listProducts(
        search: q,
        perPage: (30 + widget.excludeIds.length).clamp(30, 200),
        categoryId: categoryId,
        uncategorized: widget.showCategories && _section == 'none',
      );
      final shown = [
        for (final p in raw)
          if (!widget.excludeIds.contains('${p['id']}')) p,
      ];
      if (mounted && seq == _searchSeq) setState(() => _results = shown);
    } catch (_) {
      if (mounted && seq == _searchSeq) setState(() => _results = []);
    }
    if (mounted && seq == _searchSeq) setState(() => _loading = false);
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    // The category squares filter by name locally (no product search).
    if (_showingCategoryGrid) {
      setState(() {});
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300),
        () => _search(q.trim()));
  }

  void _resetQuery() {
    _debounce?.cancel();
    _ctrl.clear();
  }

  /// «بدون تصنيف»: uncategorized products; tapping again shows all.
  void _toggleUncategorized() {
    _resetQuery();
    setState(() {
      _section = _section == 'none' ? '' : 'none';
      _openCategory = null;
    });
    _search('');
  }

  /// «مع التصنيف»: the category squares; tapping again shows all products.
  void _toggleCategories() {
    _resetQuery();
    final leaving = _section == 'cats';
    setState(() {
      _section = leaving ? '' : 'cats';
      _openCategory = null;
    });
    if (leaving) {
      _search('');
    } else {
      _loadCategories();
    }
  }

  Future<void> _loadCategories() async {
    if (_categories != null && !_categoriesFailed) return;
    setState(() => _categoriesFailed = false);
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _categories = cats);
    } catch (_) {
      if (mounted) {
        setState(() {
          _categories = const [];
          _categoriesFailed = true;
        });
      }
    }
  }

  void _openCategoryProducts(Map<String, dynamic> category) {
    _resetQuery();
    setState(() {
      _openCategory = category;
      _results = [];
    });
    _search('');
  }

  /// Back from one category to the category squares (selection kept).
  void _backToCategories() {
    _resetQuery();
    _searchSeq++;
    setState(() {
      _openCategory = null;
      _loading = false;
    });
  }

  void _toggle(Map<String, dynamic> p) {
    final pid = p['id'].toString();
    if (_selected.containsKey(pid)) {
      setState(() => _selected.remove(pid));
      return;
    }
    final stock = _num(p['stock']);
    final isService = p['is_service'] == true;
    // Sales: a 0-stock product cannot be added (services unlimited).
    // Purchases / category assignment: stock is never a blocker here.
    if (widget.checkStock && !isService && stock <= 0) {
      showFyonaSnack(
          context,
          AppLocalizations.of(context).translate('saleOutOfStock'),
          success: false);
      _playSfx(ok: false);
      return;
    }
    unawaited(ScanSfx.select());
    setState(() => _selected[pid] = PickedProduct(p));
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScanPage()),
    );
    if (mounted && code != null && code.isNotEmpty) {
      _barcodeCtrl.text = code;
      await _scanOne();
    }
  }

  Future<void> _scanOne() async {
    final code = _barcodeCtrl.text.trim();
    if (code.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _scanMsg = '');
    try {
      final res = await widget.api.resolveBarcode(code);
      if (!mounted) return;
      final product = res['product'] as Map?;
      final unit = res['unit'] as Map?;
      if (product == null) throw StateError('no product');
      final pid = product['id'].toString();
      final stock = _num(product['stock']);
      final isService = product['is_service'] == true;
      final already = _selected[pid]?.quantity ?? 0;
      if (widget.checkStock && !isService && already + 1 > stock + 1e-9) {
        setState(() {
          _scanMsg = l10n.translate('saleOutOfStock');
          _scanError = true;
        });
        showFyonaSnack(context, l10n.translate('saleOutOfStock'),
            success: false);
        _playSfx(ok: false);
        _barcodeCtrl.clear();
        return;
      }
      setState(() {
        if (_selected.containsKey(pid)) {
          _selected[pid]!.quantity += 1;
        } else {
          _selected[pid] = PickedProduct(
            Map<String, dynamic>.from(product),
            unit: unit == null ? null : Map<String, dynamic>.from(unit),
          );
        }
        _scanMsg = l10n.translate('invScanned',
            params: {'name': (product['name'] ?? '').toString()});
        _scanError = false;
      });
      _playSfx(ok: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanMsg = l10n.translate('invBarcodeUnknown');
        _scanError = true;
      });
      // Unmistakable solid-red alert for an invalid/unknown code.
      showFyonaSnack(context, l10n.translate('invBarcodeUnknown'),
          success: false);
      _playSfx(ok: false);
    }
    _barcodeCtrl.clear();
  }

  bool _isSelected(String id) => _selected.containsKey(id);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return PopScope(
      // System back inside an opened category returns to the squares first.
      canPop: _openCategory == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _openCategory != null) _backToCategories();
      },
      child: Container(
      // With the keyboard up the sheet may use the full height below the
      // status bar, so the search field, the list and the save button all
      // fit above the keyboard even on small phones.
      constraints: BoxConstraints(
          maxHeight: bottom > 0
              ? MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top
              : MediaQuery.of(context).size.height * 0.9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(widget.title,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FyonaTextField(
              controller: _ctrl,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: l10n.translate('invSearchHint'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: widget.showBarcode
                    ? IconButton(
                        tooltip: l10n.translate('invScanBarcode'),
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: _scan,
                      )
                    : null,
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          if (widget.showCategories) _sectionPills(l10n),
          if (widget.showCategories && _openCategory != null)
            _categoryHeader(l10n),
          if (_scanMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(_scanMsg,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: _scanError
                            ? AppColors.danger
                            : AppColors.success)),
              ),
            ),
          const SizedBox(height: 6),
          // The list gives way (keyboard, small phones, category pills) so
          // the save button below is ALWAYS fully on screen.
          Flexible(
            child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: _showingCategoryGrid
                ? _categoryGrid(l10n)
                : _loading
                 ? widget.api is LocalInventoryApi
                     ? const SizedBox.shrink()
                     : const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Text(l10n.translate('invNoProducts'),
                            style: const TextStyle(fontFamily: 'Cairo')))
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final p = _results[i];
                          final id = p['id'].toString();
                          final sel = _isSelected(id);
                          final stock = _num(p['stock']);
                          final unit = (p['unit'] ?? 'قطعة').toString();
                          final isService = p['is_service'] == true;
                           return Material(
                             color: Colors.transparent,
                             child: ListTile(
                            dense: true,
                            selected: sel,
                            selectedTileColor:
                                AppColors.primary.withAlpha(26),
                            leading: _ProductThumb(
                              image: (p['image'] ?? '').toString(),
                              selected: sel,
                            ),
                            title: Text((p['name'] ?? '').toString(),
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                '${fmtNum(_num(p['price']))} • ${l10n.translate('invQtyNow')}: ${_fmt(stock)} $unit',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontFamily: 'Cairo')),
                            trailing: sel
                                ? (widget.showQtyStepper
                                    ? _qtyStepper(id, stock, isService)
                                    : const Icon(Icons.check_circle,
                                        color: AppColors.primary))
                                : const Icon(Icons.add, size: 20),
                               onTap: () => _toggle(p),
                             ),
                           );
                        },
                      ),
            ),
          ),
          _selectionBar(l10n),
        ],
      ),
      ),
    );
  }

  Widget _sectionPills(AppLocalizations l10n) {
    final inCats = _section == 'cats';
    final openName = (_openCategory?['name'] ?? '').toString();
    return InventoryPillBar(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      pills: [
        InventoryPill(
          key: const ValueKey('picker-section-none'),
          label: l10n.translate('invNoCategory'),
          selected: _section == 'none',
          onTap: _toggleUncategorized,
        ),
        InventoryPill(
          key: const ValueKey('picker-section-cats'),
          icon: Icons.category_outlined,
          label: openName.isNotEmpty
              ? openName
              : l10n.translate('invWithCategory'),
          selected: inCats,
          onTap: _toggleCategories,
        ),
      ],
    );
  }

  /// «‹ التصنيفات · `name`»: returns to the category squares.
  Widget _categoryHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 16, 0),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('picker-back-to-categories'),
            onPressed: _backToCategories,
            style: TextButton.styleFrom(
              foregroundColor: inventoryAccent,
              visualDensity: VisualDensity.compact,
            ),
            icon: const BackButtonIcon(),
            label: Text(l10n.translate('invCategories'),
                style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          ),
          Icon(Icons.circle, size: 4, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text((_openCategory?['name'] ?? '').toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _categoryGrid(AppLocalizations l10n) {
    final all = _categories;
    if (all == null) {
      return widget.api is LocalInventoryApi
          ? const SizedBox.shrink()
          : const Center(child: CircularProgressIndicator());
    }
    final q = _ctrl.text.trim().toLowerCase();
    final cats = [
      for (final c in all)
        if (q.isEmpty || '${c['name'] ?? ''}'.toLowerCase().contains(q)) c,
    ];
    if (cats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              l10n.translate(_categoriesFailed
                  ? 'falconCatLoadFail'
                  : q.isEmpty
                      ? 'invNoCategoriesHint'
                      : 'invNoProducts'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo', color: AppColors.textSecondary)),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.92,
      ),
      itemCount: cats.length,
      itemBuilder: (_, i) {
        final c = cats[i];
        final image = (c['image'] ?? '').toString();
        return InventoryCategoryTile(
          key: ValueKey('picker-category-${c['id']}'),
          name: (c['name'] ?? '').toString(),
          count: c['products_count'] as num?,
          imageUrl: image.isEmpty ? null : image,
          onTap: () => _openCategoryProducts(c),
        );
      },
    );
  }

  Widget _qtyStepper(String id, double stock, bool isService) {
    final q = _selected[id]!.quantity;
    // Sales: 0 stock = truly unavailable; services are open.
    // Purchases: the stepper is never capped — buying grows stock.
    final max = (!widget.checkStock || isService)
        ? double.infinity
        : stock;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() {
            final p = _selected[id]!;
            if (p.quantity > 1) p.quantity -= 1;
          }),
          icon: const Icon(Icons.remove, size: 18),
        ),
        Text(_fmt(q),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () {
            // Never allow MORE than the available stock (services unlimited).
            if (q + 1 > max + 1e-9) {
              showFyonaSnack(
                  context,
                  AppLocalizations.of(context).translate('saleOutOfStock'),
                  success: false);
              _playSfx(ok: false);
              return;
            }
            setState(() => _selected[id]!.quantity += 1);
          },
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
  }

  Widget _selectionBar(AppLocalizations l10n) {
    final count = _selected.length;
    // The home-indicator inset only matters while the keyboard is down (the
    // keyboard already covers it), so the button is never pushed off-screen.
    final mq = MediaQuery.of(context);
    final safeBottom = mq.viewInsets.bottom > 0 ? 0.0 : mq.padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + safeBottom),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
                l10n.translate('invSelectedCount', params: {'n': '$count'}),
                style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: count == 0
                  ? null
                  : () => Navigator.pop(context, _selected.values.toList()),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.check, size: 20),
              label: Text(
                  '${l10n.translate('save')} ($count)',
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

/// Tolerant numeric parse: the API serializes Decimal/Float as a STRING, so a
/// raw `as num?` cast would throw and blank the whole product list.
double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0;
}


/// The product's own picture (from the device catalogue or the server),
/// with a check mark over it once selected.
class _ProductThumb extends StatelessWidget {
  const _ProductThumb({required this.image, required this.selected});
  final String image;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      selected ? Icons.check : Icons.inventory_2_outlined,
      size: 16,
      color: selected ? Colors.white : AppColors.textSecondary,
    );
    return SizedBox(
      width: 40,
      height: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image.isNotEmpty)
              BusinessProductImage(
                url: image,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                placeholder: ColoredBox(
                  color: AppColors.surfaceVariant.withAlpha(120),
                  child: Center(child: icon),
                ),
              )
            else
              ColoredBox(
                color: selected
                    ? AppColors.primary
                    : AppColors.surfaceVariant.withAlpha(120),
                child: Center(child: icon),
              ),
            if (selected && image.isNotEmpty)
              ColoredBox(
                color: AppColors.primary.withAlpha(150),
                child: const Center(
                  child: Icon(Icons.check, size: 18, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
