import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/all_branches_commerce.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_database.dart'
    show BusinessWarehouseExpiry;
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/inventory_api.dart';

import 'warehouse_settings.dart';

final inventoryApiProvider = Provider<InventoryApi>((ref) {
  // «جميع الفروع»: the products of every branch, read-only.
  final all = ref.watch(allBranchesCommerceProvider);
  if (all != null) return AllBranchesInventoryApi(all);
  return localCommerceApi<InventoryApi>(
    InventoryApi.new,
    LocalInventoryApi.new,
    ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  );
});

/// Currently selected inventory filter: all | low | out.
final inventoryFilterProvider = StateProvider<String>((ref) => 'all');

/// Search query for the inventory list.
final inventorySearchProvider = StateProvider<String>((ref) => '');

/// Selected category filter: '' = all, '__none__' = uncategorized, else id.
final inventoryCategoryProvider = StateProvider<String>((ref) {
  ref.watch(inventoryApiProvider);
  return '';
});

final inventoryCategoriesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(inventoryApiProvider);
  if (!ref.watch(employeeCanProvider('inventory')))
    throw const DirectoryAccessDenied();
  return api.categories();
});

final deviceWarehouseExpiryProvider = FutureProvider<BusinessWarehouseExpiry?>((
  ref,
) async {
  final api = ref.watch(inventoryApiProvider);
  if (!ref.watch(employeeCanProvider('inventory'))) return null;
  return api is LocalInventoryApi ? api.warehouseExpiry() : null;
});

final inventoryWarehouseSettingsProvider = Provider<WarehouseSettings>((ref) {
  final preferences = ref.watch(warehouseSettingsProvider);
  if (ref.watch(inventoryApiProvider) is! LocalInventoryApi) return preferences;
  final expiry = ref.watch(deviceWarehouseExpiryProvider);
  final saved = expiry is AsyncData ? expiry.value : null;
  return preferences.copyWith(
    expiry: saved?.enabled,
    expiryWarnDays: saved?.warnDays ?? 60,
  );
});

typedef InventoryListKey = ({
  String filter,
  String search,
  String category,
  InventoryApi source,
});

/// A cached list key cannot resolve a different source after switching branches.
final inventoryProductsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, InventoryListKey>((ref, key) async {
      final (filter: filter, search: search, category: category, source: _) =
          key;
      final api = ref.watch(inventoryApiProvider);
      if (!identical(api, key.source) ||
          !ref.watch(employeeCanProvider('inventory'))) {
        throw const DirectoryAccessDenied();
      }
      if (api is LocalInventoryApi)
        ref.watch(employeeCanProvider('inventory_cost.read'));
      final status = filter == 'low'
          ? 'low'
          : filter == 'out'
          ? 'out'
          : null;
      final expiry = filter == 'expiring'
          ? 'soon'
          : filter == 'expired'
          ? 'expired'
          : null;
      final warnDays = api is LocalInventoryApi
          ? 60
          : ref.watch(warehouseSettingsProvider).expiryWarnDays;
      return api.listProducts(
        search: search,
        stockStatus: status,
        expiry: expiry,
        expiryDays: warnDays,
        categoryId: (category.isEmpty || category == '__none__')
            ? null
            : category,
        uncategorized: category == '__none__',
      );
    });

typedef InventoryProductKey = ({String id, LocalCommerceTarget? target});
typedef InventoryStatsKey = ({
  InventoryProductKey product,
  String from,
  String to,
  String? currency,
});

InventoryApi _recordSource(Ref ref, InventoryProductKey key) {
  final target = key.target;
  // Invalidation on a branch switch can rerun a provider before the router
  // has removed the previous page. Do not let it resolve to connected REST.
  if (target != null &&
      (target.id != key.id ||
          !target.allows(
            ref.watch(businessLocalLedgerScopeProvider),
            target.path,
          ))) {
    throw const DirectoryAccessDenied();
  }
  final source = ref.watch(inventoryApiProvider);
  if (target != null && source is! LocalInventoryApi) {
    throw const DirectoryAccessDenied();
  }
  return source;
}

/// Single product — autoDispose: the details page refetches the authoritative
/// authoritative stock on EVERY open (no stale snapshot between the list
/// and the details after sales/purchases/adjustments).
final productDetailProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, InventoryProductKey>((ref, key) async {
      return _recordSource(ref, key).getProduct(key.id);
    });

final productMovementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, InventoryProductKey>((ref, key) async {
      return _recordSource(ref, key).productMovements(key.id);
    });

final productUnitsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, InventoryProductKey>((ref, key) async {
      return _recordSource(ref, key).productUnits(key.id);
    });

final productPricesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, InventoryProductKey>((ref, key) async {
      return _recordSource(ref, key).productPrices(key.id);
    });

final productLotsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, InventoryProductKey>((ref, key) async {
      return _recordSource(ref, key).productLots(key.id);
    });

/// The range is in ISO dates or empty. The display
/// currency is part of the key so switching currencies recomputes — and the
/// provider is autoDispose so reopening the page ALWAYS refetches the live
/// stock/stats (no stale cache between screens).
final productStatsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, InventoryStatsKey>((ref, key) async {
      if (key.product.target != null) {
        ref.watch(employeeCanProvider('inventory'));
        ref.watch(employeeCanProvider('inventory_cost.read'));
        ref.watch(employeeCanProvider('inventory_profit.read'));
      }
      return _recordSource(ref, key.product).productStats(
        key.product.id,
        from: key.from.isEmpty ? null : key.from,
        to: key.to.isEmpty ? null : key.to,
        displayCurrency: key.currency,
      );
    });

/// Organization branches (empty when the project uses no branches).
final branchesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  return ref.watch(inventoryApiProvider).branches();
});
