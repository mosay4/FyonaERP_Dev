import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/services/notification_service.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../providers/inventory_providers.dart';

import '../widgets/falcon_ambient.dart';
import '../widgets/inventory_list_parts.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../providers/warehouse_settings.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Simple inventory home: search + camera + add + product list with only the
/// three plain filters. Nothing accounting-heavy is shown.
class InventoryHomePage extends ConsumerStatefulWidget {
  const InventoryHomePage({super.key});
  @override
  ConsumerState<InventoryHomePage> createState() => _InventoryHomePageState();
}

class _InventoryHomePageState extends ConsumerState<InventoryHomePage> {
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkExpiry());
  }

  /// Inventory tools sheet (the former 3-dots menu). Falcon entry respects
  /// the Permission Engine: hidden for roles without falcon access
  /// (backend stays authoritative for the page itself).
  Future<void> _openInventoryMenu() async {
    final l10n = AppLocalizations.of(context);
    final ws = ref.read(inventoryWarehouseSettingsProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          8,
          12,
          8,
          8 + MediaQuery.of(ctx).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (ws.categories)
              ListTile(
                dense: true,
                leading: const Icon(Icons.category_outlined),
                title: Text(
                  l10n.translate('invCategories'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                onTap: () => Navigator.pop(ctx, 'categories'),
              ),
            if (ref.watch(employeeCanProvider('inventory.edit'))) ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined),
              title: Text(
                l10n.translate('invSettingsTitle'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              onTap: () => Navigator.pop(ctx, 'settings'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;

    if (picked == 'categories') {
      context.push('/inventory/categories');
    } else if (picked == 'settings') {
      context.push('/inventory/settings');
    }
  }

  /// Expiry alerts with per-product-per-day dedup (never spams daily).
  Future<void> _checkExpiry() async {
    if (!mounted || ref.read(businessLocalLedgerScopeProvider) != null) return;
    // The local branch's dates still appear in its inventory report. Do not
    // put device ledger data into the unscoped system notification tray yet.
    final ws = ref.read(inventoryWarehouseSettingsProvider);
    if (!ws.expiry) return;
    try {
      final products = await ref
          .read(inventoryApiProvider)
          .listProducts(expiry: 'soon', expiryDays: ws.expiryWarnDays);
      if (products.isEmpty || !mounted) return;
      final svc = ref.read(notificationServiceProvider);
      final l10n = AppLocalizations.of(context);
      final today = DateTime.now().toIso8601String().split('T').first;
      for (final p in products) {
        final pid = p['id']?.toString() ?? '';
        final ex = (p['expiry_date'] ?? '').toString();
        final d = ex.isNotEmpty ? DateTime.tryParse(ex) : null;
        final days = d != null ? d.difference(DateTime.now()).inDays : 0;
        final key = 'expiry_${pid}_$today';
        if (await NotificationService.tryClaimTrayKey(key)) {
          await svc.showInventoryExpiry(
            l10n.translate('invExpiryNotifTitle'),
            l10n.translate(
              'invExpiryNotifBody',
              params: {'name': (p['name'] ?? '').toString(), 'days': '$days'},
            ),
          );
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context);
    final source = ref.read(inventoryApiProvider);
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanPage()));
    if (code == null || code.isEmpty || !mounted ||
        !identical(source, ref.read(inventoryApiProvider))) return;
    // The scanned code fills the search (searched across all products, so
    // leave the in-place categories browser).
    _searchCtrl.text = code;
    setState(() => _categoriesView = false);
    ref.read(inventoryCategoryProvider.notifier).state = '';
    ref.read(inventorySearchProvider.notifier).state = code.trim();
    try {
      final res = await source.resolveBarcode(code);
      final product = res['product'] as Map?;
      final id = product?['id']?.toString();
      if (id != null && mounted && identical(source, ref.read(inventoryApiProvider))) {
        // Product found → success beep as the list narrows to it.
        unawaited(ScanSfx.success());
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    // Unknown barcode → alert buzz exactly when the dialog appears.
    unawaited(ScanSfx.error());
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('invNotFoundTitle'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: Text(
          l10n.translate('invCreateWithBarcode', params: {'code': code}),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('cancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('invAddProduct'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    if (create == true &&
        mounted &&
        ref.read(employeeCanProvider('inventory.add'))) {
      context.push('/inventory/product/edit?barcode=$code');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final filter = ref.watch(inventoryFilterProvider);
    final key = (
      filter: filter,
      search: ref.watch(inventorySearchProvider),
      category: ref.watch(inventoryCategoryProvider),
      source: ref.watch(inventoryApiProvider),
    );
    final products = ref.watch(inventoryProductsProvider(key));
    final allowed = ref.watch(employeeCanProvider('inventory'));
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          l10n.translate('bizWarehouse'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          // Falcon: ONE tap from the inventory header (no menu digging).
          if (ws.falcon && ref.watch(employeeCanProvider('falcon')))
            IconButton(
              tooltip: l10n.translate('invFalcon'),
              onPressed: () async {
                if (!await ensureBusinessOnline(context) || !context.mounted) {
                  return;
                }
                context.push(
                  '/inventory/falcon?scope=inventory&title=${l10n.translate('bizWarehouse')}',
                );
              },
              icon: const FalconMark(26),
            ),
          if (!BranchScope.readOnly &&
              ref.watch(employeeCanProvider('inventory.add')))
            IconButton(
              // In «مع التصنيف» the + adds a CATEGORY (products are added
              // from inside a category); elsewhere it adds a product.
              tooltip: _categoriesView
                  ? l10n.translate('invAddCategory')
                  : l10n.translate('invAddProduct'),
              onPressed: _categoriesView
                  ? _addCategory
                  : () => context.push('/inventory/product/edit'),
              icon: const Icon(Icons.add),
            ),
          IconButton(
            tooltip: l10n.translate('invSettingsTitle'),
            // Branded bottom sheet instead of a PopupMenu: identical content
            // on the first and every open (no first-tap black flash), and it
            // matches the app's other selection sheets.
            onPressed: _openInventoryMenu,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: !allowed ? Center(child: Text(l10n.translate('unauthorized'))) : Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: InventorySearchField(
              controller: _searchCtrl,
              onChanged: (v) =>
                  ref.read(inventorySearchProvider.notifier).state = v.trim(),
              onScan: ws.barcode ? _scan : null,
            ),
          ),
          _filtersBar(context, filter, ws),
          Expanded(
            child: (ws.categories && _categoriesView)
                ? _categoriesViewBody(context)
                : _productsList(context, products, key, ws),
          ),
        ],
      ),
    );
  }

  /// Shared products list (main list + browsed-category list).
  Widget _productsList(
    BuildContext context,
    AsyncValue<List<Map<String, dynamic>>> products,
    InventoryListKey key,
    WarehouseSettings ws,
  ) {
    final l10n = AppLocalizations.of(context);
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    return products.when(
      // Device data: keep showing the list while it re-reads (no blank flash).
      skipLoadingOnRefresh: scope != null,
      loading: () => scope != null
          ? const SizedBox.shrink()
          : const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          businessOperationError(l10n, error, fallback: 'invLoadError'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
      ),
      data: (items) => FyonaRefresh(
        onRefresh: () async => ref.invalidate(inventoryProductsProvider(key)),
        child: items.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Text(
                      l10n.translate('invNoProducts'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final p = items[i];
                  return InventoryProductTile(
                    product: p,
                    status: inventoryRowStatus(
                      p,
                      sourceScope: scope,
                      showLow: ws.lowStockAlert,
                      warnDays: scope == null ? 30 : ws.expiryWarnDays,
                    ),
                    showExpiry: ws.expiry,
                    onTap: () => openCommerceRecord(
                      context,
                      RouteNames.inventoryProduct,
                      p['id']?.toString() ?? '',
                      fromLocal: scope,
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// In-place categories browser: shown instead of the products list when
  /// the user taps «مع التصنيف». Tapping a category opens its dedicated
  /// page. No settings shortcut here (management lives in Settings).
  bool _categoriesView = false;

  /// One compact, horizontally scrollable pill row. With categories ON it
  /// starts with the section pills (بدون تصنيف / مع التصنيف); the status
  /// pills are hidden while browsing the category tiles (they appear inside
  /// the opened category instead).
  Widget _filtersBar(BuildContext context, String filter, WarehouseSettings ws) {
    final l10n = AppLocalizations.of(context);
    final showStatus = !(ws.categories && _categoriesView);
    final status = showStatus
        ? inventoryStatusPills(
            l10n,
            current: filter,
            onSelect: (v) => ref.read(inventoryFilterProvider.notifier).state = v,
            lowStock: ws.lowStockAlert,
            expiry: ws.expiry,
          )
        : const <Widget>[];
    return InventoryPillBar(
      pills: [
        if (ws.categories) ..._sectionPills(context),
        if (ws.categories && showStatus) null,
        ...status,
      ],
    );
  }

  List<Widget> _sectionPills(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cats = ref.watch(inventoryCategoriesProvider).asData?.value ?? const [];
    final sel = ref.watch(inventoryCategoryProvider);
    final isCat = sel.isNotEmpty && sel != '__none__';
    String catName = '';
    if (isCat) {
      for (final c in cats) {
        if (c['id'].toString() == sel) catName = (c['name'] ?? '').toString();
      }
    }
    return [
      InventoryPill(
        label: l10n.translate('invNoCategory'),
        selected: sel == '__none__',
        onTap: () {
          // «بدون تصنيف»: exactly one section filter — closes the
          // categories view and shows uncategorized products immediately.
          setState(() => _categoriesView = false);
          ref.read(inventoryCategoryProvider.notifier).state =
              sel == '__none__' ? '' : '__none__';
        },
      ),
      InventoryPill(
        icon: Icons.category_outlined,
        label: isCat ? catName : l10n.translate('invWithCategory'),
        selected: isCat || _categoriesView,
        onTap: () {
          // «مع التصنيف»: exactly one section filter — clears
          // «بدون تصنيف» and browses categories in place (no popup).
          // Tapping again clears back to all products.
          setState(() => _categoriesView = !_categoriesView);
          ref.read(inventoryCategoryProvider.notifier).state = '';
        },
      ),
    ];
  }

  /// Shared empty / failed categories state: respectful message + the
  /// red-outlined «إنشاء أول تصنيف» action (and retry when loading failed).
  Widget _noCategoriesBody(
    BuildContext context,
    AppLocalizations l10n, {
    String? message,
    bool showRetry = false,
  }) {
    return ListView(
      children: [
        const SizedBox(height: 64),
        Icon(Icons.category_outlined, size: 48, color: AppColors.textSecondary),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message ?? l10n.translate('invNoCategoriesHint'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!BranchScope.readOnly && ref.watch(employeeCanProvider('inventory.add')))
          Center(
            child: InventorySmallAction(
              onPressed: _addCategory,
              label: l10n.translate('invCreateFirstCategory'),
            ),
          ),
        if (showRetry) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => ref.invalidate(inventoryCategoriesProvider),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(
              l10n.translate('falconRetry'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ],
    );
  }

  /// Inline category creation (used by the empty-categories state).
  Future<void> _addCategory() async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(inventoryApiProvider);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('invAddCategory'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.translate('invCategoryName'),
          ),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('cancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (mounted && identical(api, ref.read(inventoryApiProvider)) &&
        ok == true && name.isNotEmpty) {
      try {
        await api.createCategory(name);
        if (mounted && identical(api, ref.read(inventoryApiProvider))) {
          ref.invalidate(inventoryCategoriesProvider);
        }
      } catch (e) {
        if (mounted && identical(api, ref.read(inventoryApiProvider))) {
          showFyonaSnack(context, businessOperationError(l10n, e, fallback: 'invActionFailed'),
            success: false);
        }
      }
    }
  }

  /// Categories replace the products list in place. The grid shows
  /// categories only (no «all» tile); tapping one opens its dedicated
  /// page. No settings shortcut here (management lives in Settings).
  Widget _categoriesViewBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final api = ref.watch(inventoryApiProvider);
    final catsAsync = ref.watch(inventoryCategoriesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
               l10n.translate('invTapCategoryHint'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
        Expanded(
           child: catsAsync.when(
              skipLoadingOnRefresh: api is LocalInventoryApi,
             loading: () => api is LocalInventoryApi
                 ? const SizedBox.shrink() : const Center(child: CircularProgressIndicator()),
            // Load failure must NOT read as a dead end: friendly retry plus
            // the create-first-category action (root fix for «مع التصنيف»
            // showing «تعذر التحميل»).
             error: (error, _) => _noCategoriesBody(
               context,
               l10n,
               message: businessOperationError(l10n, error, fallback: 'falconCatLoadFail'),
              showRetry: true,
            ),
            data: (cats) => FyonaRefresh(
              onRefresh: () async =>
                  ref.invalidate(inventoryCategoriesProvider),
              child: cats.isEmpty
                   ? _noCategoriesBody(context, l10n)
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.92,
                          ),
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final c = cats[i];
                        return InventoryCategoryTile(
                          name: (c['name'] ?? '').toString(),
                          count: c['products_count'] as num?,
                          imageUrl: (c['image'] ?? '').toString().isEmpty
                              ? null
                              : (c['image'] ?? '').toString(),
                           onTap: () async {
                              if (!mounted || !identical(api, ref.read(inventoryApiProvider)) ||
                                  !ref.read(employeeCanProvider('inventory'))) return;
                             await openCommerceRecord(context, RouteNames.inventoryCategoryDetail, '${c['id']}');
                             if (mounted) ref.invalidate(inventoryCategoriesProvider);
                          },
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
