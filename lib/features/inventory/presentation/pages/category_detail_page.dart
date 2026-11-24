import 'dart:async';

import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:fyona_flutter/features/auth/presentation/widgets/app_pin_sheet.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../providers/inventory_providers.dart';
import '../widgets/falcon_icon.dart';
import '../widgets/business_product_image.dart';
import '../../data/inventory_api.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../widgets/product_picker.dart';
import '../widgets/inventory_list_parts.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../../../../shared/services/scan_sfx.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:uuid/uuid.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Full category page: picture + full name + its own action buttons, then
/// its products — or a full empty state («لا توجد منتجات في هذا القسم»)
/// when the category has no products. Replaces the old bottom sheet.
class CategoryDetailPage extends ConsumerStatefulWidget {
  final String id;
  final LocalCommerceTarget? localTarget;
  const CategoryDetailPage({super.key, required this.id, this.localTarget});
  @override
  ConsumerState<CategoryDetailPage> createState() =>
      _CategoryDetailPageState();
}

class _CategoryDetailPageState extends ConsumerState<CategoryDetailPage> {
  Map<String, dynamic>? _cat;
  List<Map<String, dynamic>> _products = [];
  bool _loading = true;
  bool _savingLinks = false;
  (String fingerprint, String command)? _pendingLinks;
  Object? _error;
  late final InventoryApi _source;

  bool _canRead(InventoryApi api) {
    if (!identical(_source, api)) return false;
    if (api is! LocalInventoryApi) return widget.localTarget == null;
    final target = widget.localTarget;
    return target != null && target.id == widget.id &&
        target.allows(ref.read(businessLocalLedgerScopeProvider),
            RouteNames.inventoryCategoryDetail);
  }

  bool get _active => mounted && _canRead(ref.read(inventoryApiProvider)) &&
      ref.read(employeeCanProvider('inventory'));
  bool get _canChangeLinks => _active && !BranchScope.readOnly &&
      ref.read(employeeCanProvider('inventory.edit'));

  bool _allowSharedEdit() {
    if (!_active) return false;
    return true;
  }

  /// Multi-remove selection mode (removal only unsets the category).
  bool _selecting = false;
  final Set<String> _selRemove = {};

  @override
  void initState() {
    super.initState();
    _source = ref.read(inventoryApiProvider);
    _load();
  }

  Future<void> _load() async {
    if (!_active) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cats = await _source.categories();
      if (!_active) return;
      final found = cats.where((c) => c['id'].toString() == widget.id).firstOrNull;
      final products = <Map<String, dynamic>>[];
      if (found != null) {
        const pageSize = 50;
        for (var page = 1; ; page++) {
          final chunk = await _source.listProducts(categoryId: widget.id,
            page: page, perPage: pageSize);
          if (!_active) return;
          products.addAll(chunk);
          if (_source is! LocalInventoryApi || chunk.length < pageSize) break;
        }
      }
      if (_active) {
        setState(() {
          _cat = found;
          _products = products;
        });
      }
    } catch (e) {
      if (_active) setState(() {
        _error = e;
        _cat = null;
        _products = [];
      });
    }
    if (_active) setState(() => _loading = false);
  }

  /// Add several products into this category at once (compact check
  /// list with a «save (n)» bar provided by the shared multi picker).
  Future<void> _addProducts() async {
    if (!_canChangeLinks || _savingLinks) return;
    final l10n = AppLocalizations.of(context);
    final api = _source;
    final list = await showProductMultiPicker(
      context,
      api: api,
      title: l10n.translate('invAddToCategory'),
      showQtyStepper: false,
      allowed: (ref) => identical(api, ref.watch(inventoryApiProvider)) &&
          ref.watch(employeeCanProvider('inventory')) &&
          ref.watch(employeeCanProvider('inventory.edit')) && !BranchScope.readOnly,
      // Categorizing has nothing to do with stock — never block 0-stock items.
      checkStock: false,
      // A product already in this category is not offered again.
      excludeIds: {for (final p in _products) '${p['id']}'},
    );
    if (list == null || list.isEmpty || !_canChangeLinks) return;
    if (api is LocalInventoryApi) {
      await _localLinks(api, [for (final pk in list) pk.product['id'].toString()], remove: false);
      return;
    }
    var done = 0;
    for (final pk in list) {
      if (!_active) return;
      try {
        await api.updateProduct(pk.product['id'].toString(),
            {'category_id': widget.id});
        done++;
      } catch (_) {}
    }
    if (!_active) return;
    ref.invalidate(inventoryCategoriesProvider);
    await _load();
    if (mounted) {
      showFyonaSnack(
          context,
          done > 0
              ? l10n.translate('invAddedToCategory')
              : l10n.translate('invActionFailed'),
          success: done > 0);
    }
  }

  /// Removing from a category only unsets the link — the product itself
  /// stays. Always gated by fingerprint / app PIN.
  Future<void> _removeOne(String pid) async {
    if (!_canChangeLinks || _savingLinks) return;
    final l10n = AppLocalizations.of(context);
    final ok = await verifySensitiveAction(context, ref,
        reason: l10n.translate('invRemoveFromCategory'));
    if (!ok || !_canChangeLinks) return;
    final api = _source;
    if (api is LocalInventoryApi) {
      await _localLinks(api, [pid], remove: true);
      return;
    }
    try {
      await api.updateProduct(pid, {'category_id': null});
      await _load();
      if (mounted) {
        showFyonaSnack(context,
            l10n.translate('invRemovedFromCategory'), success: true);
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('invActionFailed'),
            success: false);
      }
    }
  }

  Future<void> _removeSelected() async {
    if (!_canChangeLinks || _savingLinks || _selRemove.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final ok = await verifySensitiveAction(context, ref,
        reason: l10n.translate('invRemoveFromCategory'));
    if (!ok || !_canChangeLinks) return;
    var done = 0;
    final api = _source;
    if (api is LocalInventoryApi) {
      await _localLinks(api, _selRemove.toList(), remove: true);
      return;
    }
    for (final pid in _selRemove.toList()) {
      if (!_active) return;
      try {
        await api.updateProduct(pid, {'category_id': null});
        done++;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _selecting = false;
        _selRemove.clear();
      });
      await _load();
      showFyonaSnack(
          context,
          done > 0
              ? l10n.translate('invRemovedFromCategory')
              : l10n.translate('invActionFailed'),
          success: done > 0);
    }
  }

  Future<void> _localLinks(LocalInventoryApi api, List<String> ids, {required bool remove}) async {
    if (!_canChangeLinks || _savingLinks) return;
    _savingLinks = true;
    final l10n = AppLocalizations.of(context);
    final ordered = ids.toList()..sort();
    final fingerprint = '$remove:${ordered.join(',')}';
    final (prior, _) = _pendingLinks ?? ('', '');
    if (prior != fingerprint) _pendingLinks = (fingerprint, const Uuid().v4());
    final command = _pendingLinks!.$2;
    try {
      await api.classifyProducts(ordered,
        commandId: command,
        categoryId: remove ? null : widget.id,
        removingFrom: remove ? widget.id : null,
      );
      if (!_active) return;
      _pendingLinks = null;
      setState(() { _selecting = false; _selRemove.clear(); });
      ref.invalidate(inventoryCategoriesProvider);
      ref.invalidate(inventoryProductsProvider);
      await _load();
      if (_active) showFyonaSnack(context,
        l10n.translate(remove ? 'invRemovedFromCategory' : 'invAddedToCategory'), success: true);
    } catch (e) {
      if (_active) showFyonaSnack(context,
        businessOperationError(l10n, e, fallback: 'invActionFailed'), success: false);
    } finally {
      _savingLinks = false;
    }
  }

  Future<void> _rename() async {
    if (!_allowSharedEdit()) return;
    final c = _cat;
    if (c == null) return;
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: (c['name'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('invCategories'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: FyonaTextField(
            controller: ctrl,
            autofocus: true,
            decoration:
                InputDecoration(labelText: l10n.translate('invCategoryName')),
            style: const TextStyle(fontFamily: 'Cairo')),
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
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (_active && ok == true && name.isNotEmpty) {
      try {
        await _source.updateCategory(widget.id, name);
        if (!_active) return;
        ref.invalidate(inventoryCategoriesProvider);
        await _load();
      } catch (e) {
        if (_active) showFyonaSnack(context,
          businessOperationError(l10n, e, fallback: 'invActionFailed'), success: false);
      }
    }
  }

  Future<void> _changeImage() async {
    if (!_allowSharedEdit()) return;
    final c = _cat;
    if (c == null) return;
    final l10n = AppLocalizations.of(context);
    final hasImage = ((c['image'] ?? '').toString().isNotEmpty);
    final source = await showModalBottomSheet<dynamic>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.translate('invFromCamera'),
                  style: const TextStyle(fontFamily: 'Cairo')),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.translate('invFromGallery'),
                  style: const TextStyle(fontFamily: 'Cairo')),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            if (hasImage)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: AppColors.danger),
                title: Text(l10n.translate('delete'),
                    style: const TextStyle(fontFamily: 'Cairo')),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!_active) return;
    try {
      if (source == 'delete') {
        if (hasImage) {
          final okv = await verifySensitiveAction(context, ref,
              reason: l10n.translate('delete'));
          if (!okv || !_active) return;
          await _source.deleteCategoryImage(widget.id);
          if (!_active) return;
          ref.invalidate(inventoryCategoriesProvider);
          await _load();
          if (mounted) {
            showFyonaSnack(context, l10n.translate('invImageSaved'),
                success: true);
          }
        }
        return;
      }
      if (source is! ImageSource) return;
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 70,
      );
      if (file == null || !_active) return;
      await _source.uploadCategoryImage(widget.id, file.path, dio: ref.read(dioProvider));
      if (!_active) return;
      ref.invalidate(inventoryCategoriesProvider);
      await _load();
      if (mounted) {
        showFyonaSnack(context, l10n.translate('invImageSaved'),
            success: true);
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('invImageSaveFailed'),
            success: false);
      }
    }
  }

  Future<void> _delete() async {
    if (!_allowSharedEdit()) return;
    final l10n = AppLocalizations.of(context);
    final okc = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text((_cat?['name'] ?? '').toString(),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: Text(l10n.translate('invDeleteConfirm'),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('delete'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (okc == true && _active) {
      final ok = await verifySensitiveAction(context, ref,
          reason: l10n.translate('delete'));
      if (!ok || !_active) return;
      try {
        await _source.deleteCategory(widget.id);
        if (!_active) return;
        ref.invalidate(inventoryCategoriesProvider);
        ref.invalidate(inventoryProductsProvider);
        if (!mounted) return;
        showFyonaSnack(context, l10n.translate('invCategoryDeleted'), success: true);
        context.pop(true);
      } catch (_) {
        if (mounted) {
          showFyonaSnack(context, l10n.translate('invActionFailed'), success: false);
        }
      }
    }
  }

  /// Category-local search + status filter (client-side over the rows
  /// already loaded above — no extra reads, no spinner).
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _filter = 'all';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (!_active) return;
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanPage()));
    if (code == null || code.isEmpty || !_active) return;
    _searchCtrl.text = code;
    setState(() => _query = code.trim());
    final hit = _products.any((p) => _matches(p, code.trim().toLowerCase()));
    unawaited(hit ? ScanSfx.success() : ScanSfx.error());
  }

  bool _matches(Map<String, dynamic> p, String q) {
    if (q.isEmpty) return true;
    for (final k in const ['name', 'barcode', 'sku']) {
      if ('${p[k] ?? ''}'.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  bool _passesStatus(InventoryRowStatus st) => switch (_filter) {
    'low' => st.low,
    'out' => st.out,
    'expiring' => st.soon,
    'expired' => st.expired,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canRead = ref.watch(employeeCanProvider('inventory')) &&
        _canRead(ref.watch(inventoryApiProvider));
    final c = canRead ? _cat : null;
    final canEdit = !BranchScope.readOnly &&
        ref.watch(employeeCanProvider('inventory.edit'));
    final canDelete = !BranchScope.readOnly &&
        ref.watch(employeeCanProvider('inventory.delete'));
    final canFalcon = ref.watch(employeeCanProvider('falcon'));
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    final scope = widget.localTarget?.scope;
    final warnDays = scope == null ? 30 : ws.expiryWarnDays;
    final filter = inventoryStatusAvailable(_filter,
            lowStock: ws.lowStockAlert, expiry: ws.expiry)
        ? _filter
        : 'all';
    final q = _query.toLowerCase();
    final rows = <(Map<String, dynamic>, InventoryRowStatus)>[
      for (final p in _products)
        if (_matches(p, q))
          (p, inventoryRowStatus(p, sourceScope: scope,
              showLow: ws.lowStockAlert, warnDays: warnDays)),
    ].where((r) => filter == 'all' || _passesStatus(r.$2)).toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
            _loading ? '' : (c?['name'] ?? '').toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
      ),
      body: !canRead
          ? Center(child: Text(l10n.translate('unauthorized')))
          : _loading
          ? _source is LocalInventoryApi ? const SizedBox.shrink()
            : const Center(child: CircularProgressIndicator())
          : c == null
              ? Center(
                   child: Text(_error == null ? l10n.translate('invLoadError')
                       : businessOperationError(l10n, _error!, fallback: 'invLoadError'),
                      style: const TextStyle(fontFamily: 'Cairo')))
              : FyonaRefresh(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _header(context, c,
                          canEdit: canEdit,
                          canDelete: canDelete,
                          canFalcon: canFalcon),
                      if (_products.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        InventorySearchField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v.trim()),
                          onScan: ws.barcode ? _scan : null,
                        ),
                        // Status pills filter only this category's products.
                        InventoryPillBar(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          pills: inventoryStatusPills(
                            l10n,
                            current: filter,
                            onSelect: (v) => setState(() => _filter = v),
                            lowStock: ws.lowStockAlert,
                            expiry: ws.expiry,
                          ),
                        ),
                      ] else
                        const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                '${l10n.translate('invCategoryProducts')} (${rows.length})',
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w800)),
                          ),
                          if (canEdit && _products.isNotEmpty) TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              foregroundColor: inventoryAccent,
                            ),
                            onPressed: () => setState(() {
                              _selecting = !_selecting;
                              _selRemove.clear();
                            }),
                            child: Text(
                                l10n.translate(_selecting
                                    ? 'cancel'
                                    : 'invSelect'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.w700)),
                          ),
                          if (canEdit) ...[
                            const SizedBox(width: 4),
                            IconButton.filledTonal(
                              tooltip: _selecting
                                  ? l10n.translate('invRemoveCount', params: {'n': '${_selRemove.length}'})
                                  : l10n.translate('invAddToCategory'),
                              visualDensity: VisualDensity.compact,
                              style: IconButton.styleFrom(
                                backgroundColor: _selecting
                                    ? AppColors.danger.withAlpha(26)
                                    : inventoryAccentTint,
                                foregroundColor: _selecting
                                    ? AppColors.danger
                                    : inventoryAccent,
                              ),
                              icon: Icon(
                                  _selecting ? Icons.delete_outline : Icons.add,
                                  size: 20),
                              onPressed: _selecting
                                  ? (_selRemove.isEmpty ? null : _removeSelected)
                                  : _addProducts,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_products.isEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 40),
                          child: Column(
                            children: [
                              Icon(Icons.inventory_2_outlined,
                                  size: 48,
                                  color: AppColors.textSecondary),
                              const SizedBox(height: 10),
                              Text(
                                  l10n.translate(
                                      'invNoProductsInCategory'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 14),
                              if (canEdit)
                                InventorySmallAction(
                                  onPressed: _addProducts,
                                  label: l10n.translate(
                                      'invAddProductsToCategory'),
                                ),
                            ],
                          ),
                        )
                      else if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Text(
                            l10n.translate('invNoMatchingProducts'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      else
                        for (final (p, st) in rows)
                          Padding(
                            key: ValueKey(p['id'].toString()),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _productRow(p, st, ws.expiry),
                          ),
                    ],
                  ),
                ),
    );
  }

  Widget _productRow(
      Map<String, dynamic> p, InventoryRowStatus st, bool showExpiry) {
    final l10n = AppLocalizations.of(context);
    final pid = p['id'].toString();
    final selected = _selRemove.contains(pid);
    void toggle() => setState(() {
          if (!_selRemove.remove(pid)) _selRemove.add(pid);
        });
    final canEdit = !BranchScope.readOnly &&
        ref.watch(employeeCanProvider('inventory.edit'));
    return InventoryProductTile(
      product: p,
      status: st,
      showExpiry: showExpiry,
      selected: _selecting && selected,
      onLongPress: _selecting || !canEdit
          ? null
          : () => setState(() {
                _selecting = true;
                _selRemove.add(pid);
              }),
      onTap: _selecting
          ? toggle
          : () async {
              if (!_active) return;
              await openCommerceRecord(context, RouteNames.inventoryProduct, pid,
                  fromLocal: widget.localTarget?.scope);
              if (_active) await _load();
            },
      // Same slot, constraints and button in both modes: only paint
      // and callback change. Selection cannot resize/reflow the row.
      trailing: !canEdit
          ? null
          : IconButton(
              tooltip: l10n.translate(
                  _selecting ? 'invSelect' : 'invRemoveFromCategory'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                  _selecting
                      ? (selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked)
                      : Icons.close,
                  size: 20,
                  color: _selecting
                      ? inventoryAccent
                      : AppColors.textSecondary),
              onPressed: _selecting ? toggle : () => _removeOne(pid),
            ),
    );
  }

  Widget _header(BuildContext context, Map<String, dynamic> c,
      {required bool canEdit,
      required bool canDelete,
      required bool canFalcon}) {
    final l10n = AppLocalizations.of(context);
    final img = (c['image'] ?? '').toString();
    final actions = <Widget>[
      if (canEdit)
        _HeaderAction(
          icon: Icons.edit_outlined,
          label: l10n.translate('edit'),
          tooltip: l10n.translate('invManage'),
          onTap: _rename,
        ),
      if (canEdit)
        _HeaderAction(
          icon: Icons.add_a_photo_outlined,
          label: l10n.translate('invCatActionImage'),
          tooltip: l10n.translate('invCategoryImage'),
          onTap: _changeImage,
        ),
      if (canFalcon)
        _HeaderAction(
          iconWidget: const FalconIcon(size: 18),
          label: l10n.translate('invCatActionFalcon'),
          tooltip: l10n.translate('invFalcon'),
          onTap: () async {
            if (!_active) return;
            if (!await ensureBusinessOnline(context) || !_active) {
              return;
            }
            context.push('/inventory/falcon?scope=category&id=${widget.id}');
          },
        ),
      if (canDelete)
        _HeaderAction(
          icon: Icons.delete_outline,
          label: l10n.translate('delete'),
          tooltip: l10n.translate('delete'),
          color: AppColors.danger,
          onTap: _delete,
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Small square showing the whole logo (no crop).
              Container(
                width: 60,
                height: 60,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: inventoryAccentTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: img.isNotEmpty
                    ? BusinessProductImage(
                        url: img, width: 60, height: 60, fit: BoxFit.contain)
                    : Icon(Icons.category_outlined,
                        size: 28, color: inventoryAccent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((c['name'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            height: 1.3,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                        l10n.translate('invCatProductsCount',
                            params: {'n': '${_products.length}'}),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Equal-size labeled action of the category header.
class _HeaderAction extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final String tooltip;
  final Color? color;
  final VoidCallback onTap;
  const _HeaderAction({
    this.icon,
    this.iconWidget,
    required this.label,
    required this.tooltip,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? AppColors.textPrimary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color != null ? color!.withAlpha(20) : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 54,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconWidget ?? Icon(icon, size: 19, color: fg),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
