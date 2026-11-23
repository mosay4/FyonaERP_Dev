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
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:uuid/uuid.dart';

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
    if (_source is! LocalInventoryApi) return true;
    showFyonaSnack(context, AppLocalizations.of(context).translate('invSharedCategoryReadOnly'),
      success: false);
    return false;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canRead = ref.watch(employeeCanProvider('inventory')) &&
        _canRead(ref.watch(inventoryApiProvider));
    final c = canRead ? _cat : null;
    final img = (c?['image'] ?? '').toString();
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
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            // Small square showing the whole logo (no crop).
                            Container(
                              width: 120,
                              height: 120,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceVariant.withAlpha(90),
                                borderRadius: BorderRadius.circular(16),
                                border:
                                    Border.all(color: AppColors.border),
                              ),
                              child: img.isNotEmpty
                                   ? BusinessProductImage(
                                      url: img,
                                      width: 120,
                                      height: 120,
                                      fit: BoxFit.contain)
                                  : Icon(Icons.category_outlined,
                                      size: 48,
                                      color: AppColors.textSecondary),
                            ),
                            const SizedBox(height: 10),
                            Text((c['name'] ?? '').toString(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 17,
                                     fontWeight: FontWeight.w800)),
                            if (c['shared_snapshot'] == true)
                              Text(l10n.translate('invSharedCategoryReadOnly'),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceEvenly,
                              children: [
                                if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit'))) IconButton(
                                  tooltip: l10n
                                      .translate('invCategoryImage'),
                                  icon: const Icon(
                                      Icons.add_a_photo_outlined),
                                  onPressed: _changeImage,
                                ),
                                if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit'))) IconButton(
                                  tooltip:
                                      l10n.translate('invManage'),
                                  icon:
                                      const Icon(Icons.edit_outlined),
                                  onPressed: _rename,
                                ),
                                if (ref.watch(employeeCanProvider('falcon')))
                                  IconButton(
                                    tooltip:
                                        l10n.translate('invFalcon'),
                                    icon: const FalconIcon(size: 20),
                                     onPressed: () async {
                                       if (!_active) return;
                                       if (_source is LocalInventoryApi) {
                                         showFyonaSnack(context, l10n.translate('invLocalFalconUnavailable'), success: false);
                                         return;
                                       }
                                       if (!await ensureBusinessOnline(context) ||
                                           !_active) {
                                        return;
                                      }
                                      context.push(
                                          '/inventory/falcon?scope=category&id=${widget.id}');
                                    },
                                  ),
                                if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.delete'))) IconButton(
                                  tooltip: l10n.translate('delete'),
                                  icon: const Icon(
                                      Icons.delete_outline,
                                      color: AppColors.danger),
                                  onPressed: _delete,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                '${l10n.translate('invCategoryProducts')} (${_products.length})',
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800)),
                          ),
                          if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit'))) TextButton(
                            onPressed: _products.isEmpty
                                ? null
                                : () => setState(() {
                                      _selecting = !_selecting;
                                      _selRemove.clear();
                                    }),
                            child: Text(
                                l10n.translate(_selecting
                                    ? 'cancel'
                                    : 'invSelect'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo')),
                          ),
                          if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit')))
                          IconButton(
                            tooltip: _selecting
                                ? l10n.translate('invRemoveCount', params: {'n': '${_selRemove.length}'})
                                : l10n.translate('invAddToCategory'),
                            icon: Icon(_selecting ? Icons.delete_outline : Icons.add_circle_outline,
                                color: _selecting ? AppColors.danger : null),
                            onPressed: _selecting
                                ? (_selRemove.isEmpty ? null : _removeSelected)
                                : _addProducts,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_products.isEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 48),
                          child: Column(
                            children: [
                              Icon(Icons.inventory_2_outlined,
                                  size: 56,
                                  color: AppColors.textSecondary),
                              const SizedBox(height: 12),
                              Text(
                                  l10n.translate(
                                      'invNoProductsInCategory'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 16),
                              if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.edit')))
                              OutlinedButton.icon(
                                onPressed: _addProducts,
                                icon: const Icon(Icons.add, size: 16),
                                label: Text(
                                    l10n.translate(
                                        'invAddProductsToCategory'),
                                    style: const TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.danger,
                                  side: const BorderSide(
                                      color: AppColors.danger,
                                      width: 1.5),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        for (final p in _products)
                          _ProductRow(
                            key: ValueKey(p['id'].toString()),
                            product: p,
                            selecting: _selecting,
                            selected: _selRemove
                                .contains(p['id'].toString()),
                            onToggle: () => setState(() {
                              final pid = p['id'].toString();
                              if (_selRemove.contains(pid)) {
                                _selRemove.remove(pid);
                              } else {
                                _selRemove.add(pid);
                              }
                            }),
                            onEnterSelect: () => setState(() {
                              _selecting = true;
                              _selRemove.add(p['id'].toString());
                            }),
                            onRemove: () =>
                                _removeOne(p['id'].toString()),
                             onOpen: () async {
                               if (!_active) return;
                               await openCommerceRecord(context, RouteNames.inventoryProduct, '${p['id']}',
                                 fromLocal: widget.localTarget?.scope);
                               if (_active) await _load();
                             },
                          ),
                    ],
                  ),
                ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final Map<String, dynamic> product;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onEnterSelect;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  const _ProductRow(
      {super.key, required this.product,
      required this.selecting,
      required this.selected,
      required this.onToggle,
      required this.onEnterSelect,
      required this.onRemove,
      required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final img = (product['image'] ?? '').toString();
    final stock =
        (product['stock'] as num?)?.toDouble() ?? 0;
    final stockTxt = stock == stock.roundToDouble()
        ? stock.round().toString()
        : stock.toStringAsFixed(2);
    return GestureDetector(
      onLongPress: selecting ? null : onEnterSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(AppColors.primary.withAlpha(22), AppColors.surface)
              : AppColors.surface,
          border: Border.all(
              color: selected
                  ? AppColors.primary
                  : AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
          dense: true,
          leading: Container(
            width: 44,
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withAlpha(90),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: img.isNotEmpty
                 ? BusinessProductImage(
                    url: img, width: 44, height: 44, fit: BoxFit.cover)
                : Icon(Icons.inventory_2_outlined,
                    size: 22, color: AppColors.textSecondary),
          ),
          title: Text((product['name'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
          subtitle: Text(
              '${l10n.translate('invQtyNow')}: $stockTxt ${(product['unit'] ?? '').toString()}',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.textSecondary)),
          // Same slot, constraints and button in both modes: only paint
          // and callback change. Selection cannot resize/reflow the row.
          trailing: SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
                  tooltip: l10n.translate(selecting ? 'invSelect' : 'invRemoveFromCategory'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(selecting
                      ? (selected ? Icons.check_circle : Icons.radio_button_unchecked)
                      : Icons.close,
                      size: 20, color: selecting ? AppColors.primary : AppColors.danger),
                  onPressed: selecting ? onToggle : onRemove,
                ),
          ),
          onTap: selecting ? onToggle : onOpen,
          ),
        ),
      ),
    );
  }
}
