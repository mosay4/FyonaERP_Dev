import 'dart:io';

import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/shared/widgets/biz_currency_items.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:dio/dio.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/units/custom_units.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/business_selection_sheet.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../../data/inventory_api.dart';
import '../providers/inventory_providers.dart';
import '../widgets/business_product_image.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Units shown in the product form — the same rich list (weights, lengths,
/// services + the merchant's own units) used by quick-add in sale/purchase.
List<UnitDef> _unitsWith(List<String> custom) => <UnitDef>[
      ...defaultUnits,
      for (final c in custom)
        (name: c, en: c, factor: 1.0, weight: false, group: 'count'),
    ];

String _unitSubtitle(AppLocalizations l10n, UnitDef u) => u.weight
    ? l10n.translate('saleWeightUnit')
    : l10n.translate('saleUnitPieces', params: {'n': _clean(u.factor)});

/// The measurement family of a unit (canonical name first, then the stored
/// family of a merchant-defined unit). null = unknown → never blocked.
String? _groupOf(WidgetRef ref, String name) {
  final g = unitGroupOfName(name);
  if (g != null) return g;
  return ref.read(customUnitsProvider.notifier).groupFor(name);
}

/// Whether [unitName] may live on a product whose base unit is [baseGroup].
/// Unknown families are always allowed (legacy/custom safety).
bool _unitAllowed(WidgetRef ref, String unitName, String? baseGroup) {
  if (baseGroup == null) return true;
  final g = _groupOf(ref, unitName);
  return g == null || g == baseGroup;
}

/// Dialog for a merchant-defined unit: a name AND a measurement group (the
/// group is what keeps incompatible units apart). Returns null on cancel.
Future<({String name, String group})?> _promptCustomUnit(
    BuildContext context, String initial) async {
  final l10n = AppLocalizations.of(context);
  final isAr = Localizations.localeOf(context).languageCode == 'ar';
  final tc = TextEditingController(text: initial);
  String group = 'count';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        title: Text(l10n.translate('invCustomUnit'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FyonaTextField(
                controller: tc,
                autofocus: true,
                decoration:
                    InputDecoration(labelText: l10n.translate('invUnitName')),
                style: const TextStyle(fontFamily: 'Cairo')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: group,
              isExpanded: true,
              decoration:
                  InputDecoration(labelText: l10n.translate('invMeasureGroup')),
              items: [
                for (final g in unitGroups)
                  DropdownMenuItem(
                      value: g,
                      child: Text(unitGroupLabel(g, isAr: isAr),
                          style: const TextStyle(fontFamily: 'Cairo'))),
              ],
              onChanged: (v) => setSt(() => group = v ?? 'count'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('save'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    ),
  );
  if (ok == true && tc.text.trim().isNotEmpty) {
    final out = (name: tc.text.trim(), group: group);
    tc.dispose();
    return out;
  }
  tc.dispose();
  return null;
}

/// Very simple add/edit product form. Only the essentials are visible; extra
/// units / barcodes / category live under a collapsed «خيارات إضافية».
class ProductFormPage extends ConsumerStatefulWidget {
  final String? id; // null = create
  final String? initialBarcode;
  final LocalCommerceTarget? localTarget;
  const ProductFormPage({super.key, this.id, this.initialBarcode, this.localTarget});
  @override
  ConsumerState<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends ConsumerState<ProductFormPage> {
  final _name = TextEditingController();
  final _unit = TextEditingController(text: 'قطعة');
  final _stock = TextEditingController(text: '0');
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _barcode = TextEditingController();
  final _minStock = TextEditingController();
  /// One row per currency: buy + sell prices, side by side.
  final List<_PriceEntry> _prices = [];
  String? _categoryId;
  String? _originalCategoryId;
  String? _categoryName;
  DateTime? _expiry;
  String? _image;
  XFile? _picked;
  bool _loading = false;
  bool _initialized = false;
  Object? _loadError;
  bool _imageRemoved = false;
  String? _commandId;
  late InventoryApi _source;
  late final (String?, String?, bool) _selection;

  /// A background refresh (sync, branch access, auth reload) may hand an
  /// equivalent API for the very same workspace/branch: keep editing with it.
  /// Only a real change (other branch/organization, all-branches, another
  /// kind of source) closes the form.
  bool _sameSource(InventoryApi next) {
    if (identical(next, _source)) return true;
    if (next.runtimeType != _source.runtimeType ||
        _selection != (BranchScope.organizationId, BranchScope.branchId, BranchScope.allMode)) {
      return false;
    }
    _source = next;
    return true;
  }

  bool get isEdit => widget.id != null;

  bool _allows(LocalCommerceTarget? target) {
    if (target == null) return _source is! LocalInventoryApi || !isEdit;
    return _source is LocalInventoryApi && target.id == widget.id &&
        target.allows(ref.read(businessLocalLedgerScopeProvider), RouteNames.inventoryProductEdit);
  }

  String get _writePermission => isEdit ? 'inventory.edit' : 'inventory.add';

  bool get _active => mounted && _allows(widget.localTarget) &&
      _sameSource(ref.read(inventoryApiProvider)) &&
      ref.read(employeeCanProvider('inventory')) &&
      ref.read(employeeCanProvider(_writePermission));

  @override
  void initState() {
    super.initState();
    _source = ref.read(inventoryApiProvider);
    _selection = (BranchScope.organizationId, BranchScope.branchId, BranchScope.allMode);
    if (widget.initialBarcode != null) _barcode.text = widget.initialBarcode!;
    if (isEdit && _active) _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _stock.dispose();
    _price.dispose();
    _cost.dispose();
    _barcode.dispose();
    _minStock.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final p = await _source.getProduct(widget.id!);
      if (!_active) return;
      if (p.isEmpty) throw StateError('Product not found');
      _name.text = (p['name'] ?? '').toString();
      _unit.text = (p['unit'] ?? 'قطعة').toString();
      _stock.text = (p['stock'] ?? 0).toString();
      _barcode.text = (p['barcode'] ?? '').toString();
      final minStock = asDoubleValue(p['min_stock']);
      _minStock.text = minStock == 0 ? '' : _clean(minStock);
      _prices.clear();
      final prices = (p['prices'] as List?)?.whereType<Map>().toList() ?? [];
      for (final e in prices) {
        _prices.add(_PriceEntry(
          (e['currency'] ?? '').toString(),
          buyText: e['buy_price'] == null ? '' : fmtNum(e['buy_price']),
          sellText: fmtNum(e['price']),
        ));
      }
      if (_prices.isEmpty &&
          (p['price'] != null || p['cost_price'] != null)) {
        _prices.add(_PriceEntry(
          (p['cost_currency'] ?? 'SAR').toString(),
          buyText: p['cost_price'] == null ? '' : fmtNum(p['cost_price']),
          sellText: fmtNum(p['price']),
        ));
      }
      _categoryId = p['category_id']?.toString();
      _originalCategoryId = _categoryId;
      _categoryName = p['category_name']?.toString();
      final ex = p['expiry_date']?.toString();
      _expiry = (ex != null && ex.isNotEmpty) ? DateTime.tryParse(ex) : null;
      _image = p['image']?.toString();
      _initialized = true;
    } catch (error) {
      if (_active) _loadError = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      // Kept small on purpose: big phone photos stall slow mobile uploads
      // (send timeouts) and the server re-encodes anyway.
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 70,
      );
      if (mounted && file != null) {
        setState(() {
          _picked = file;
          _imageRemoved = false;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).translate('invImageFail'),
                style: const TextStyle(fontFamily: 'Cairo'))));
      }
    }
  }

  Future<void> _chooseImage() async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.translate('invFromCamera'),
                style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () {
              Navigator.pop(ctx);
              _pickImage(ImageSource.camera);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.translate('invFromGallery'),
                style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () {
              Navigator.pop(ctx);
              _pickImage(ImageSource.gallery);
            },
          ),
          if (_image != null || _picked != null)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text(l10n.translate('invRemoveImage'),
                  style: const TextStyle(fontFamily: 'Cairo')),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                   _picked = null;
                   _image = null;
                   _imageRemoved = true;
                });
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _pickCategory() async {
    if (!_active || _loading) return;
    final l10n = AppLocalizations.of(context);
    List<Map<String, dynamic>> cats;
    try {
      cats = await _source.categories();
    } catch (e) {
      if (_active) {
        showFyonaSnack(context, businessOperationError(l10n, e, fallback: 'invActionFailed'),
            success: false);
      }
      return;
    }
    if (!_active) return;
    final picked = await showBusinessSelectionSheet<Map<String, dynamic>>(
      context: context,
      title: l10n.translate('invCategory'),
      guard: (_, sheet) => Consumer(builder: (context, ref, _) {
        if (!_sameSource(ref.watch(inventoryApiProvider)) ||
            !ref.watch(employeeCanProvider('inventory')) ||
            !ref.watch(employeeCanProvider(_writePermission))) {
          return Material(child: ListTile(title: Text(l10n.translate('unauthorized'))));
        }
        return sheet;
      }),
      items: [
        for (final c in cats)
          BizSheetItem(
            value: c,
            title: (c['name'] ?? '').toString(),
            icon: Icons.category_outlined,
          ),
      ],
    );
    if (picked != null && _active) {
      setState(() {
        _categoryId = picked['id']?.toString();
        _categoryName = (picked['name'] ?? '').toString();
      });
    }
  }

  Future<void> _save() async {
    if (_loading || !_active || BranchScope.readOnly ||
        (isEdit && !_initialized)) return;
    final l10n = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('invNameRequired'),
              style: const TextStyle(fontFamily: 'Cairo'))));
      return;
    }
    setState(() => _loading = true);
    final api = _source;
    final first = _prices.isNotEmpty ? _prices.first : null;
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'unit': _unit.text.trim().isEmpty ? 'قطعة' : _unit.text.trim(),
      'price': first?.sellValue ?? 0,
      'cost_price': first?.buyValue ?? 0,
      'cost_currency': first?.currency ?? 'SAR',
      'barcode': _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      'min_stock': double.tryParse(_minStock.text.trim()) ?? 0,
      'category_id': _categoryId,
      if (_expiry != null)
        'expiry_date': _expiry!.toIso8601String().split('T').first,
    };
    try {
      final prices = [
        for (final e in _prices)
          {'currency': e.currency, 'price': e.sellValue, 'buy_price': e.buyValue},
      ];
      if (api is LocalInventoryApi) {
        if (isEdit) {
          if (_originalCategoryId != _categoryId) {
            body['expected_category_id'] = _originalCategoryId;
          } else {
            body.remove('category_id');
          }
        }
        body['cost_price'] = first == null || first.buy.text.trim().isEmpty
            ? null : first.buyValue;
        final picked = _picked;
        if (picked != null) {
          try {
            body['image'] = await readBusinessProductImage(picked.path);
          } on Exception {
            if (_active) {
              showFyonaSnack(context, l10n.translate('invImageSaveFailed'), success: false);
            }
            return;
          }
        } else if (_imageRemoved) {
          body['image'] = null;
        }
        if (!_active) return;
        body['prices'] = [
          for (final e in _prices)
            {
              'currency': e.currency,
              'price': e.sellValue,
              'buy_price': e.buy.text.trim().isEmpty ? null : e.buyValue,
            },
        ];
        body['command_id'] = _commandId ??= const Uuid().v4();
        if (!isEdit) body['stock'] = double.tryParse(_stock.text.trim()) ?? 0;
        final saved = isEdit
            ? await api.updateProduct(widget.id!, body)
            : await api.createProduct(body);
        if (!_active) return;
        if (picked != null) {
          showFyonaSnack(context, l10n.translate('invImageSaved'), success: true);
        }
        _showSaved('${saved['id']}');
        return;
      }
      String id;
      if (isEdit) {
        id = widget.id!;
        try {
          await api.updateProduct(id, body);
        } on DioException catch (e) {
          if (!await _moveConflictingCode(e, api)) rethrow;
          await api.updateProduct(id, body);
        }
      } else {
        body['stock'] = double.tryParse(_stock.text.trim()) ?? 0;
        Map<String, dynamic> created;
        try {
          created = await api.createProduct(body);
        } on DioException catch (e) {
          if (!await _moveConflictingCode(e, api)) rethrow;
          created = await api.createProduct(body);
        }
        id = created['id'].toString();
      }
      // Independent per-currency BUY + SELL prices. Never converted.
      await api.setProductPrices(id, prices);
      // Image handling (upload new / remove existing).
      if (_picked != null) {
        try {
          await api.uploadImage(id, _picked!.path, dio: ref.read(dioProvider));
        } catch (_) {
          if (!mounted) return;
          setState(() => _loading = false);
          showFyonaSnack(context, l10n.translate('invImageSaveFailed'),
              success: false);
          return;
        }
        if (!mounted) return;
        showFyonaSnack(context, l10n.translate('invImageSaved'),
            success: true);
      } else if (isEdit && _imageRemoved) {
        try {
          await api.deleteImage(id);
        } catch (_) {
          if (!mounted) return;
          setState(() => _loading = false);
          showFyonaSnack(context, l10n.translate('invImageSaveFailed'),
              success: false);
          return;
        }
      }
      if (!mounted || !_sameSource(ref.read(inventoryApiProvider))) return;
      _showSaved(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e),
                style: const TextStyle(fontFamily: 'Cairo'))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSaved(String id) {
    ref.invalidate(inventoryCategoriesProvider);
    ref.invalidate(inventoryProductsProvider);
    ref.invalidate(productDetailProvider);
    ref.invalidate(productPricesProvider);
    if (isEdit) {
      context.pop(true);
    } else {
      openCommerceRecord(context, RouteNames.inventoryProduct, id, replace: true);
    }
  }

  String _friendlyError(Object e) {
    return businessOperationError(AppLocalizations.of(context), e, fallback: 'invActionFailed');
  }

  Future<bool> _moveConflictingCode(
      DioException e, InventoryApi api) async {
    final data = e.response?.data;
    final payload = data is Map ? (data['detail'] ?? data['message']) : null;
    if (payload is! Map || payload['code'] != 'product_code_conflict') {
      return false;
    }
    final conflictId = '${payload['product_id'] ?? ''}';
    final name = '${payload['product_name'] ?? ''}';
    final field = '${payload['field'] ?? 'barcode'}';
    if (conflictId.isEmpty || !mounted) return false;
    final l10n = AppLocalizations.of(context);
    final move = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('invCodeConflictTitle'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(
            l10n.translate('invCodeConflictBody', params: {'name': name}),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('invCodeMove'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (move != true || !mounted) return false;
    try {
      await api.updateProduct(conflictId, {
        if (field == 'sku') 'sku': null else 'barcode': null,
      });
      return true;
    } catch (err) {
      if (mounted) {
        showFyonaSnack(context, _friendlyError(err), success: false);
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!_sameSource(ref.watch(inventoryApiProvider)) || !_allows(widget.localTarget) ||
        !ref.watch(employeeCanProvider('inventory')) ||
        !ref.watch(employeeCanProvider(_writePermission))) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
            l10n.translate(isEdit ? 'invEditProduct' : 'invAddProduct'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
      ),
      body: isEdit && _loading && !_initialized
          ? (_source is LocalInventoryApi ? const SizedBox.shrink()
              : const Center(child: CircularProgressIndicator()))
           : _loadError != null
           ? Center(child: Text(businessOperationError(l10n, _loadError!, fallback: 'invLoadError')))
           : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (ws.productImages) ...[
                  Center(child: _imagePicker()),
                  const SizedBox(height: 16),
                ],
                _field(_name, 'invName'),
                const SizedBox(height: 10),
                _unitSelector(_unit),
                const SizedBox(height: 10),
                if (!isEdit) ...[
                  _field(_stock, 'invQtyNow', number: true),
                  const SizedBox(height: 10),
                ],
                for (final e in _prices) _priceEntryRow(e),
                if (ws.multiCurrency || _prices.isEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _addPriceRow,
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(l10n.translate('invAddPrice'),
                          style: const TextStyle(
                              fontFamily: 'Cairo', fontSize: 12)),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (ws.barcode) ...[
                  _field(_barcode, 'invBarcode', camera: true),
                  const SizedBox(height: 10),
                ],
                if (ws.lowStockAlert) ...[
                  _field(_minStock, 'invMinQty',
                      number: true, hint: l10n.translate('invQtyHint')),
                  const SizedBox(height: 8),
                ],
                if (ws.categories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.translate('invCategory'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13))),
                    subtitle: Text(_categoryName ?? l10n.translate('invNone'),
                        style: const TextStyle(fontFamily: 'Cairo')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_categoryId != null)
                        IconButton(
                          tooltip: l10n.translate('invRemoveFromCategory'),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close,
                              size: 16, color: AppColors.danger),
                          onPressed: () => setState(() {
                            _categoryId = null;
                            _categoryName = null;
                          }),
                        ),
                      const Icon(Icons.chevron_left),
                    ]),
                    onTap: _pickCategory,
                  ),
                if (ws.expiry)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.translate('invProductExpiry'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13))),
                    subtitle: Text(
                        _expiry == null
                            ? l10n.translate('invNone')
                            : _expiry!.toIso8601String().split('T').first,
                        style: const TextStyle(fontFamily: 'Cairo')),
                    trailing: const Icon(Icons.event_outlined),
                    onTap: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _expiry ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 15),
                      );
                      if (picked != null) setState(() => _expiry = picked);
                    },
                  ),
                if (ws.extraOptions)
                  Card(
                  color: AppColors.surface,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      side: BorderSide(color: AppColors.border),
                      borderRadius: BorderRadius.circular(12)),
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(l10n.translate('invAdvanced'),
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    children: [
                      if (isEdit)
                         _UnitsSection(
                             productId: widget.id!, baseUnit: _unit.text, source: _source)
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(l10n.translate('invSaveFirstForUnits'),
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _loading && _source is! LocalInventoryApi
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(l10n.translate('save'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 15),
                                fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _imagePicker() {
    final l10n = AppLocalizations.of(context);
    Widget child;
    if (_picked != null) {
      child = Image.file(File(_picked!.path), fit: BoxFit.cover);
    } else if (_image != null && _image!.isNotEmpty) {
      child = BusinessProductImage(url: _image, fit: BoxFit.cover);
    } else {
      child =
          Icon(Icons.add_a_photo_outlined, color: AppColors.textSecondary);
    }
    return GestureDetector(
      onTap: _chooseImage,
      child: Column(
        children: [
          Container(
            width: 110,
            height: 110,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withAlpha(90),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: child,
          ),
          const SizedBox(height: 6),
          Text(l10n.translate('invImageOptional'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _unitSelector(TextEditingController ctrl) {
    final l10n = AppLocalizations.of(context);
    final name = ctrl.text.trim().isEmpty ? 'قطعة' : ctrl.text.trim();
    String? desc;
    for (final u in _unitsWith(ref.watch(customUnitsProvider))) {
      if (u.name == name) desc = _unitSubtitle(l10n, u);
    }
    return GestureDetector(
      onTap: () => _pickUnit(ctrl),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.translate('invBaseUnit'),
          suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name,
                style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
            if (desc != null)
              Text(desc,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickUnit(TextEditingController ctrl,
      {bool allowCustom = true}) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('invUnitPick'),
      items: [
        for (final u in _unitsWith(ref.read(customUnitsProvider)))
          BizSheetItem(
            value: u.name,
            title: u.name,
            subtitle: _unitSubtitle(l10n, u),
            icon: Icons.straighten_outlined,
          ),
        if (allowCustom)
          BizSheetItem(
            value: '__custom__',
            title: l10n.translate('invCustomUnit'),
            icon: Icons.edit_outlined,
          ),
      ],
    );
    if (picked == null) return;
    if (picked == '__custom__') {
      final cu = await _promptCustomUnit(context, ctrl.text);
      if (cu != null && mounted) {
        ref.read(customUnitsProvider.notifier).add(cu.name, group: cu.group);
        setState(() => ctrl.text = cu.name);
      }
      return;
    }
    setState(() => ctrl.text = picked);
  }

  Widget _priceRow(TextEditingController ctrl, String labelKey,
      String currency, ValueChanged<String> onCurrency) {
    final l10n = AppLocalizations.of(context);
    final unit = _unit.text.trim().isEmpty ? 'قطعة' : _unit.text.trim();
    final label = l10n.translate(labelKey).replaceAll('{u}', unit);
    return BusinessNumberField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: GestureDetector(
          onTap: () async {
            final c = await _pickCurrency(currency);
            if (c != null) onCurrency(c);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            child: Text(currency,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
          ),
        ),
      ),
      style: const TextStyle(fontFamily: 'Cairo'),
    );
  }

  Future<String?> _pickCurrency(String current) async {
    final l10n = AppLocalizations.of(context);
    // Exactly the Business currencies enabled in profile settings.
    final codes = await readBizCurrencies(ref);
    if (!mounted) return null;
    return showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('invCurrency'),
      selected: current,
      items: bizCurrencySheetItems(codes),
    );
  }

  Future<void> _addPriceRow() async {
    final l10n = AppLocalizations.of(context);
    final used = {for (final e in _prices) e.currency};
    final available = (await readBizCurrencies(ref))
        .where((c) => !used.contains(c))
        .toList();
    if (available.isEmpty || !mounted) return;
    final c = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('invCurrency'),
      items: bizCurrencySheetItems(available),
    );
    if (c == null || !mounted) return;
    setState(() => _prices.add(_PriceEntry(c)));
  }

  /// One currency row: [ purchase price | currency | sell price ] (side by side).
  Widget _priceEntryRow(_PriceEntry e) {
    final l10n = AppLocalizations.of(context);
    final unit = _unit.text.trim().isEmpty ? 'قطعة' : _unit.text.trim();
    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.primary.withAlpha(90)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.monetization_on_outlined,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(currencyName(e.currency),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ]),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16, color: AppColors.danger),
            onPressed: () => setState(() {
              e.dispose();
              _prices.remove(e);
            }),
          ),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(
            child: BusinessNumberField(
              controller: e.buy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AmountInputFormatter()],
              decoration: deco(
                  l10n.translate('invBuyPriceOf').replaceAll('{u}', unit)),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: BusinessNumberField(
              controller: e.sell,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AmountInputFormatter()],
              decoration: deco(
                  l10n.translate('invSellPriceOf').replaceAll('{u}', unit)),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _field(TextEditingController ctrl, String key,
      {bool number = false, bool camera = false, String? hint}) {
    final l10n = AppLocalizations.of(context);
    return BusinessNumberField(
      controller: ctrl,
      keyboardType:
          number ? const TextInputType.numberWithOptions(decimal: true) : null,
      decoration: InputDecoration(
        labelText: l10n.translate(key),
        hintText: hint,
        suffixIcon: camera
            ? IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: () async {
                  final code = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => const BarcodeScanPage()),
                  );
                  if (code != null && code.isNotEmpty) ctrl.text = code;
                },
              )
            : null,
      ),
      style: const TextStyle(fontFamily: 'Cairo'),
    );
  }
}

/// Extra units + barcodes for an existing product (reuses existing endpoints).
class _UnitsSection extends ConsumerStatefulWidget {
  final String productId;
  final String baseUnit;
  final InventoryApi source;
  const _UnitsSection({required this.productId, required this.baseUnit, required this.source});
  @override
  ConsumerState<_UnitsSection> createState() => _UnitsSectionState();
}

class _UnitsSectionState extends ConsumerState<_UnitsSection> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  bool get _isCurrent => mounted && identical(widget.source, ref.read(inventoryApiProvider));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_isCurrent) return;
    setState(() => _loading = true);
    try {
      final d = await widget.source.productUnits(widget.productId);
      if (_isCurrent) setState(() => _data = d);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addUnit() async {
    final l10n = AppLocalizations.of(context);
    final name = TextEditingController();
    final factor = TextEditingController();
    final buy = TextEditingController();
    final sale = TextEditingController();
    final bc = TextEditingController();
    String desc = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.translate('invExtraUnit'),
              style: const TextStyle(fontFamily: 'Cairo')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Pick from a ready list; the meaning shows under the name.
              GestureDetector(
                onTap: () async {
                  final baseGroup = _groupOf(ref, widget.baseUnit);
                  final picked =
                      await showBusinessSelectionSheet<String>(
                    context: ctx,
                    title: l10n.translate('invUnitPick'),
                    items: [
                      // Only units from the SAME measure group as the product's
                      // base unit (a «لتر» can never attach to a «قطعة»).
                      for (final u in _unitsWith(ref.read(customUnitsProvider)))
                        if (_unitAllowed(ref, u.name, baseGroup))
                          BizSheetItem(
                            value: u.name,
                            title: u.name,
                            subtitle: _unitSubtitle(l10n, u),
                            icon: Icons.straighten_outlined,
                          ),
                      BizSheetItem(
                        value: '__custom__',
                        title: l10n.translate('invCustomUnit'),
                        icon: Icons.edit_outlined,
                      ),
                    ],
                  );
                  if (picked == null) return;
                  if (picked == '__custom__') {
                    final cu = await _promptCustomUnit(ctx, name.text);
                    if (cu == null) return;
                    if (!_unitAllowed(ref, cu.name, baseGroup)) {
                      showFyonaSnack(ctx,
                          l10n.translate('invUnitIncompatible'),
                          success: false);
                      return;
                    }
                    ref.read(customUnitsProvider.notifier).add(cu.name,
                        group: cu.group);
                    setSt(() {
                      name.text = cu.name;
                      desc = '';
                    });
                    return;
                  }
                  setSt(() {
                    name.text = picked;
                    desc = '';
                    for (final u in _unitsWith(ref.read(customUnitsProvider))) {
                      if (u.name == picked) desc = _unitSubtitle(l10n, u);
                    }
                  });
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.translate('invUnitType'),
                    suffixIcon:
                        const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name.text,
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w700)),
                      if (desc.isNotEmpty)
                        Text(desc,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              BusinessNumberField(
                  controller: factor,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: name.text.trim().isEmpty
                          ? l10n.translate('invUnitQtyLabel')
                          : l10n
                              .translate('invUnitFactorQ2')
                              .replaceAll('{x}', name.text)
                              .replaceAll('{b}', widget.baseUnit)),
                  style: const TextStyle(fontFamily: 'Cairo')),
              const SizedBox(height: 8),
              FyonaTextField(
                  controller: bc,
                  decoration: InputDecoration(
                    labelText: l10n.translate('invBarcode'),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      onPressed: () async {
                        final code = await Navigator.of(ctx).push<String>(
                          MaterialPageRoute(
                              builder: (_) => const BarcodeScanPage()),
                        );
                        if (code != null && code.isNotEmpty) {
                          setSt(() => bc.text = code);
                        }
                      },
                    ),
                  ),
                  style: const TextStyle(fontFamily: 'Cairo')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: BusinessNumberField(
                      controller: buy,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [AmountInputFormatter()],
                      decoration: InputDecoration(
                          labelText: l10n.translate('invBuyPrice')),
                      style: const TextStyle(fontFamily: 'Cairo')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: BusinessNumberField(
                      controller: sale,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [AmountInputFormatter()],
                      decoration: InputDecoration(
                          labelText: l10n.translate('invSellPrice')),
                      style: const TextStyle(fontFamily: 'Cairo')),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.translate('cancel'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.translate('save'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
          ],
        ),
      ),
    );
    if (ok == true && _isCurrent && name.text.trim().isNotEmpty) {
      // Prices are typed with thousands separators («1,500»): parse them the
      // way the field formats them, never drop them.
      final salePrice = parseFormattedAmount(sale.text);
      final buyPrice = parseFormattedAmount(buy.text);
      try {
        await widget.source.createUnit(widget.productId, {
          'name': name.text.trim(),
          'factor': parseFormattedAmount(factor.text) ?? 1,
          if (_groupOf(ref, name.text.trim()) != null)
            'group': _groupOf(ref, name.text.trim()),
          'sale_price': ?salePrice,
          'purchase_price': ?buyPrice,
          if (bc.text.trim().isNotEmpty) 'barcode': bc.text.trim(),
        });
        // Every open view of this product re-reads its units at once.
        ref.invalidate(productUnitsProvider);
        ref.invalidate(productDetailProvider);
        await _load();
      } catch (e) {
        if (mounted) {
          showFyonaSnack(context,
              businessOperationError(l10n, e, fallback: 'invActionFailed'),
              success: false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final units = (_data?['units'] as List?)?.whereType<Map>() ?? const [];
    final barcodes =
        (_data?['barcodes'] as List?)?.whereType<Map>() ?? const [];
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(8),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(l10n.translate('invUnitsBarcodes'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: _addUnit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.translate('invExtraUnit'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            ),
          ],
        ),
        for (final u in units)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
                '1 ${u['name']} = ${_clean(u['factor'])} ${widget.baseUnit}',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
            subtitle: (u['barcode']?.toString().isNotEmpty ?? false)
                ? Text('${l10n.translate('invBarcode')}: ${u['barcode']}',
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 11))
                : null,
            trailing: (u['is_base'] == true)
                ? null
                : IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.translate('invDeleteUnit'),
                    icon: const Icon(Icons.delete_outline,
                        size: 16, color: AppColors.danger),
                     onPressed: () async {
                       if (!_isCurrent) return;
                       try {
                         await widget.source.deleteUnit(u['id'].toString());
                      } catch (_) {}
                      ref.invalidate(productUnitsProvider);
                      ref.invalidate(productDetailProvider);
                      await _load();
                    },
                  ),
          ),
        for (final b in barcodes)
          if ((b['unit_id'] ?? '') == null || '${b['unit_id']}'.isEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${l10n.translate('invExtraBarcode')}: ${b['barcode']}',
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
            ),
      ],
    );
  }
}

/// Per-currency SELL prices. Each value is stored exactly as entered and is
/// never auto-converted when exchange rates change.
class _PricesSection extends ConsumerStatefulWidget {
  final String productId;
  const _PricesSection({required this.productId});
  @override
  ConsumerState<_PricesSection> createState() => _PricesSectionState();
}

class _PricesSectionState extends ConsumerState<_PricesSection> {
  List<Map<String, dynamic>> _prices = [];
  bool _loading = true;

  static const _currencies = ['SAR', 'USD', 'YER_NEW', 'YER_OLD'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await ref.read(inventoryApiProvider).productPrices(widget.productId);
      if (mounted) setState(() => _prices = d);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      await ref.read(inventoryApiProvider).setProductPrices(widget.productId, [
        for (final p in _prices)
          {'currency': p['currency'], 'price': p['price']}
      ]);
      ref.invalidate(productPricesProvider);
    } catch (_) {}
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context);
    final used = {for (final p in _prices) p['currency']};
    final available =
        _currencies.where((c) => !used.contains(c)).toList();
    if (available.isEmpty) return;
    String cur = available.first;
    final price = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.translate('invPrices'),
              style: const TextStyle(fontFamily: 'Cairo')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: cur,
              items: [
                for (final c in available)
                  DropdownMenuItem(value: c, child: Text(c))
              ],
              onChanged: (v) => setSt(() => cur = v ?? cur),
              decoration: InputDecoration(
                  labelText: l10n.translate('invCurrency')),
            ),
            const SizedBox(height: 8),
            BusinessNumberField(
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AmountInputFormatter()],
              decoration: InputDecoration(
                  labelText: l10n.translate('invSellPrice')),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.translate('cancel'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.translate('save'),
                    style: const TextStyle(fontFamily: 'Cairo'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() => _prices = [
            ..._prices,
            {
              'currency': cur,
              'price': parseFormattedAmount(price.text) ?? 0,
            }
          ]);
      await _save();
    }
    price.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(8),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(l10n.translate('invPrices'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.translate('invAddPrice'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            ),
          ],
        ),
        for (final p in _prices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('${currencySymbol((p['currency'] ?? '').toString())}: ${p['price']}',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
            trailing: IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16, color: AppColors.danger),
              onPressed: () async {
                setState(() => _prices =
                    _prices.where((e) => e['currency'] != p['currency']).toList());
                await _save();
              },
            ),
          ),
      ],
    );
  }
}

/// One currency's price row (buy + sell), each with its own controller.
class _PriceEntry {
  final String currency;
  final TextEditingController buy;
  final TextEditingController sell;
  _PriceEntry(this.currency, {String buyText = '', String sellText = ''})
      : buy = TextEditingController(text: buyText),
        sell = TextEditingController(text: sellText);
  double get buyValue => parseFormattedAmount(buy.text) ?? 0;
  double get sellValue => parseFormattedAmount(sell.text) ?? 0;
  void dispose() {
    buy.dispose();
    sell.dispose();
  }
}

/// Number text without a trailing ".0" (1.0 -> 1, 1.5 -> 1.5).
String _clean(dynamic v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
}
