import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/services/notification_service.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../providers/inventory_providers.dart';

import '../widgets/falcon_ambient.dart';
import '../widgets/business_product_image.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../providers/warehouse_settings.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Simple inventory home: search + camera + add + product list with only the
/// three plain filters. Nothing accounting-heavy is shown.
class InventoryHomePage extends ConsumerStatefulWidget {
  const InventoryHomePage({super.key});
  @override
  ConsumerState<InventoryHomePage> createState() => _InventoryHomePageState();
}

class _InventoryHomePageState extends ConsumerState<InventoryHomePage> {
  final _searchCtrl = TextEditingController();
  bool _filtersOpen = false;

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
    final ws = ref.read(warehouseSettingsProvider);
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
            if (ws.barcode)
              ListTile(
                dense: true,
                leading: const Icon(Icons.qr_code_scanner),
                title: Text(
                  l10n.translate('invScanBarcode'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                onTap: () => Navigator.pop(ctx, 'scan'),
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

    if (picked == 'scan') {
      _scan();
    } else if (picked == 'categories') {
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
    try {
      final res = await source.resolveBarcode(code);
      final product = res['product'] as Map?;
      final id = product?['id']?.toString();
      if (id != null && mounted && identical(source, ref.read(inventoryApiProvider))) {
        // Product found → success beep in sync with the navigation.
        unawaited(ScanSfx.success());
        openCommerceRecord(context, RouteNames.inventoryProduct, id);
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
    final role = ref.watch(currentUserRoleProvider);
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    final canSeeCost = role != 'employee' && role != 'staff' && ws.showCost;
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
              tooltip: l10n.translate('invAddProduct'),
              onPressed: () => context.push('/inventory/product/edit'),
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
            child: FyonaTextField(
              controller: _searchCtrl,
              onChanged: (v) =>
                  ref.read(inventorySearchProvider.notifier).state = v.trim(),
              decoration: InputDecoration(
                hintText: l10n.translate('invSearchHint'),
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          if (ws.categories)
            _filtersPanel(context, filter)
          else
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                children: [
                  _statusAllChip(context, filter, _filtersExpanded(filter)),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    alignment: AlignmentDirectional.centerStart,
                    child: _filtersExpanded(filter)
                        ? ClipRect(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (ws.lowStockAlert) ...[
                                  const SizedBox(width: 8),
                                  _filterChip(
                                    'low',
                                    l10n.translate('invFilterLow'),
                                    filter,
                                  ),
                                ],
                                const SizedBox(width: 8),
                                _filterChip(
                                  'out',
                                  l10n.translate('invFilterOut'),
                                  filter,
                                ),
                                if (ws.expiry) ...[
                                  const SizedBox(width: 8),
                                  _filterChip(
                                    'expiring',
                                    l10n.translate('invExpiringSoon'),
                                    filter,
                                  ),
                                  const SizedBox(width: 8),
                                  _filterChip(
                                    'expired',
                                    l10n.translate('invExpired'),
                                    filter,
                                  ),
                                ],
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          Expanded(
            child: (ws.categories && _categoriesView)
                ? _categoriesViewBody(context, canSeeCost, ws)
                : _productsList(context, products, key, canSeeCost, ws),
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
    bool canSeeCost,
    dynamic ws,
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
      data: (items) => RefreshIndicator(
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _ProductCard(
                  product: items[i],
                  sourceScope: scope,
                  showCost: canSeeCost,
                  showLow: ws.lowStockAlert,
                   showExpiry: ws.expiry,
                   warnDays: scope == null ? 30 : ws.expiryWarnDays,
                ),
              ),
      ),
    );
  }

  /// Whether the bordered filters panel is expanded (categories mode).
  bool _filtersPanelOpen = true;

  /// In-place categories browser: shown instead of the products list when
  /// the user taps «مع التصنيف». Tapping a category opens its dedicated
  /// page. No settings shortcut here (management lives in Settings).
  bool _categoriesView = false;

  /// Bordered filters panel (categories mode): the section row plus the
  /// full status strip, collapsible upward into a single «عرض الفلاتر»
  /// button to free list space. Smooth AnimatedSize both ways.
  Widget _filtersPanel(BuildContext context, String filter) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: _filtersPanelOpen
            ? Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.primary, width: 1.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(child: _categoriesBar(context)),
                        IconButton(
                          tooltip: l10n.translate('invHideFilters'),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                          onPressed: () =>
                              setState(() => _filtersPanelOpen = false),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                    _statusStripFull(context, filter),
                  ],
                ),
              )
            : SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _filtersPanelOpen = true),
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  label: Text(
                    l10n.translate('invShowFilters'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    backgroundColor: AppColors.primary.withAlpha(14),
                    side: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
      ),
    );
  }

  /// Full status strip (no collapsing): shown under the category row when
  /// the categories feature is ON. Filters the chosen section in place.
  Widget _statusStripFull(BuildContext context, String filter) {
    final l10n = AppLocalizations.of(context);
    final ws = ref.watch(inventoryWarehouseSettingsProvider);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _filterChip('all', l10n.translate('invFilterAll'), filter),
          if (ws.lowStockAlert) ...[
            const SizedBox(width: 8),
            _filterChip('low', l10n.translate('invFilterLow'), filter),
          ],
          const SizedBox(width: 8),
          _filterChip('out', l10n.translate('invFilterOut'), filter),
          if (ws.expiry) ...[
            const SizedBox(width: 8),
            _filterChip('expiring', l10n.translate('invExpiringSoon'), filter),
            const SizedBox(width: 8),
            _filterChip('expired', l10n.translate('invExpired'), filter),
          ],
        ],
      ),
    );
  }

  Widget _categoriesBar(BuildContext context) {
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
    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 12,
            color: selected ? Colors.white : AppColors.textPrimary,
          ),
        ),
        selected: selected,
        selectedColor: AppColors.primary,
        backgroundColor: AppColors.surface,
        side: BorderSide(color: AppColors.border),
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          chip(l10n.translate('invNoCategory'), sel == '__none__', () {
            // «بدون تصنيف»: exactly one section filter — closes the
            // categories view and shows uncategorized products immediately.
            setState(() => _categoriesView = false);
            ref.read(inventoryCategoryProvider.notifier).state =
                sel == '__none__' ? '' : '__none__';
          }),
          chip(
            isCat ? catName : l10n.translate('invWithCategory'),
            isCat || _categoriesView,
            () {
              // «مع التصنيف»: exactly one section filter — clears
              // «بدون تصنيف» and browses categories in place (no popup).
              // Tapping again clears back to all products.
              final catProv = ref.read(inventoryCategoryProvider.notifier);
              if (_categoriesView) {
                setState(() => _categoriesView = false);
                catProv.state = '';
              } else {
                setState(() => _categoriesView = true);
                catProv.state = '';
              }
            },
          ),
        ],
      ),
    );
  }

  /// The extra status filters stay visible while expanded OR while a
  /// non-"all" filter is active (so the active choice is never hidden).
  bool _filtersExpanded(String current) => _filtersOpen || current != 'all';

  Widget _statusAllChip(BuildContext context, String current, bool expanded) {
    final l10n = AppLocalizations.of(context);
    final selected = current == 'all';
    final c = selected ? Colors.white : AppColors.textPrimary;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.translate('invFilterAll'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: c,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: () => setState(() => _filtersOpen = !_filtersOpen),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: Icon(Icons.chevron_right, size: 18, color: c),
              ),
            ),
          ),
        ],
      ),
      selected: selected,
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: AppColors.border),
      showCheckmark: false,
      onSelected: (_) =>
          ref.read(inventoryFilterProvider.notifier).state = 'all',
    );
  }

  Widget _filterChip(String value, String label, String current) {
    final selected = value == current;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? Colors.white : AppColors.textPrimary,
        ),
      ),
      selected: selected,
      onSelected: (_) =>
          ref.read(inventoryFilterProvider.notifier).state = value,
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: AppColors.border),
      showCheckmark: false,
    );
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
        Icon(Icons.category_outlined, size: 56, color: AppColors.textSecondary),
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
            child: OutlinedButton.icon(
              onPressed: _addCategory,
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                l10n.translate('invCreateFirstCategory'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 11,
                ),
              ),
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
  Widget _categoriesViewBody(
    BuildContext context,
    bool canSeeCost,
    dynamic ws,
  ) {
    final l10n = AppLocalizations.of(context);
    final api = ref.watch(inventoryApiProvider);
    final catsAsync = ref.watch(inventoryCategoriesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
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
            data: (cats) => RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(inventoryCategoriesProvider),
              child: cats.isEmpty
                   ? _noCategoriesBody(context, l10n)
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 1.35,
                          ),
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final c = cats[i];
                        return _CategoryTile(
                          name: (c['name'] ?? '').toString(),
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

class _CategoryTile extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final VoidCallback onTap;
  const _CategoryTile({required this.name, this.imageUrl, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
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
              child: (imageUrl != null && imageUrl!.isNotEmpty)
                  ? BusinessProductImage(
                      url: imageUrl,
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
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends ConsumerWidget {
  final Map<String, dynamic> product;
  final DirectoryAccess? sourceScope;
  final bool showCost;
  final bool showLow;
  final bool showExpiry;
  final int warnDays;
  const _ProductCard({
    required this.product,
    required this.sourceScope,
    required this.showCost,
    this.showLow = true,
    this.showExpiry = false,
    this.warnDays = 30,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final id = product['id']?.toString() ?? '';
    final stock = (product['stock'] as num?)?.toDouble() ?? 0;
    final minStock = (product['min_stock'] as num?)?.toDouble() ?? 0;
    final isService = product['is_service'] == true;
    final low = showLow && !isService && stock > 0 && stock <= minStock;
    final exStr = (product['expiry_date'] ?? '').toString();
    final exd = exStr.isNotEmpty ? DateTime.tryParse(exStr) : null;
    final now = DateTime.now();
    final day = sourceScope == null ? now : DateTime(now.year, now.month, now.day);
    final expired = exd != null && exd.isBefore(day);
    final soon =
        exd != null && !expired && exd.difference(day).inDays <= warnDays;
    final out = !isService && stock <= 0;
    final price = product['price'];
    final cost = product['cost_price'];
    final costCur = (product['cost_currency'] ?? '').toString();
    final prices =
        (product['prices'] as List?)?.whereType<Map>().toList() ?? const [];
    final sellCur = prices.isNotEmpty
        ? (prices.first['currency'] ?? '').toString()
        : costCur;
    return GestureDetector(
      onTap: () => openCommerceRecord(context, RouteNames.inventoryProduct, id,
          fromLocal: sourceScope),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            _Thumb(url: product['image']?.toString()),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          (product['name'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (low)
                        _badge(l10n.translate('invLow'), AppColors.warning),
                      if (out)
                        _badge(l10n.translate('invOut'), AppColors.danger),
                      if (showExpiry)
                        if (expired)
                          _badge(l10n.translate('invExpired'), AppColors.danger)
                        else if (soon)
                          _badge(
                            l10n.translate('invExpiringSoon'),
                            AppColors.warning,
                          ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${l10n.translate('invQtyNow')}: ${_fmt(stock)} ${product['unit'] ?? ''}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      Text(
                        '${l10n.translate('invSellPrice')}: ${fmtNum(price)} ${_sym(sellCur)}',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (showCost)
                        Text(
                          '${l10n.translate('invLastPurchase')}: ${fmtNum(cost)} ${_sym(costCur)}',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_left, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
    margin: const EdgeInsetsDirectional.only(start: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(28),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

class _Thumb extends StatelessWidget {
  final String? url;
  const _Thumb({this.url});
  @override
  Widget build(BuildContext context) {
    final hasImage = url != null && url!.isNotEmpty;
    return Container(
      width: 48,
      height: 48,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(90),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: hasImage
          ? BusinessProductImage(url: url, width: 48, height: 48, fit: BoxFit.cover)
          : Icon(
              Icons.inventory_2_outlined,
              size: 22,
              color: AppColors.textSecondary,
            ),
    );
  }
}

String _sym(String code) =>
    code.isEmpty ? '' : currencySymbol(code.toUpperCase());

String _fmt(dynamic v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
}
