import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';

/// Stock mutations (sale/purchase/adjust/return/transfer) must reflect in
/// EVERY stock-reading surface instantly: the list, the details page, the
/// statistics, the lots and the movement timeline. One call invalidates the
/// whole graph (family providers invalidate all keys).
void invalidateInventoryData(WidgetRef ref) {
  ref.invalidate(inventoryProductsProvider);
  ref.invalidate(productDetailProvider);
  ref.invalidate(productStatsProvider);
  ref.invalidate(productLotsProvider);
  ref.invalidate(productMovementsProvider);
}
