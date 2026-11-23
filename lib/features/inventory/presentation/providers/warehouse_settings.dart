import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-organization warehouse feature flags (Business only). Disabling a
/// feature only HIDES its UI — it never deletes stored data.
class WarehouseSettings {
  final bool productImages;
  final bool lowStockAlert;
  final bool showCost;
  final bool showProfit;
  final bool barcode;
  final bool falcon;
  final bool expiry;
  final bool multiCurrency;
  final bool extraOptions;
  final bool categories;
  final int expiryWarnDays;

  const WarehouseSettings({
    this.productImages = true,
    this.lowStockAlert = true,
    this.showCost = true,
    this.showProfit = true,
    this.barcode = true,
    this.falcon = true,
    this.expiry = false,
    this.multiCurrency = false,
    this.extraOptions = false,
    this.categories = false,
    this.expiryWarnDays = 60,
  });

  WarehouseSettings copyWith({
    bool? productImages,
    bool? lowStockAlert,
    bool? showCost,
    bool? showProfit,
    bool? barcode,
    bool? falcon,
    bool? expiry,
    bool? multiCurrency,
    bool? extraOptions,
    bool? categories,
    int? expiryWarnDays,
  }) =>
      WarehouseSettings(
        productImages: productImages ?? this.productImages,
        lowStockAlert: lowStockAlert ?? this.lowStockAlert,
        showCost: showCost ?? this.showCost,
        showProfit: showProfit ?? this.showProfit,
        barcode: barcode ?? this.barcode,
        falcon: falcon ?? this.falcon,
        expiry: expiry ?? this.expiry,
        multiCurrency: multiCurrency ?? this.multiCurrency,
        extraOptions: extraOptions ?? this.extraOptions,
        categories: categories ?? this.categories,
        expiryWarnDays: expiryWarnDays ?? this.expiryWarnDays,
      );
}

class WarehouseSettingsNotifier extends StateNotifier<WarehouseSettings> {
  WarehouseSettingsNotifier() : super(const WarehouseSettings());

  static const _k = 'wh_';

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = WarehouseSettings(
        productImages: p.getBool('${_k}images') ?? true,
        lowStockAlert: p.getBool('${_k}low') ?? true,
        showCost: p.getBool('${_k}cost') ?? true,
        showProfit: p.getBool('${_k}profit') ?? true,
        barcode: p.getBool('${_k}barcode') ?? true,
        falcon: p.getBool('${_k}falcon') ?? true,
        expiry: p.getBool('${_k}expiry') ?? false,
        multiCurrency: p.getBool('${_k}multi') ?? false,
        extraOptions: p.getBool('${_k}extra') ?? false,
        categories: p.getBool('${_k}cats') ?? false,
        expiryWarnDays: p.getInt('${_k}expiryDays') ?? 60,
      );
    } catch (_) {}
  }

  Future<void> _save(String key, Object v) async {
    final p = await SharedPreferences.getInstance();
    if (v is bool) await p.setBool('$_k$key', v);
    if (v is int) await p.setInt('$_k$key', v);
  }

  void setProductImages(bool v) {
    state = state.copyWith(productImages: v);
    _save('images', v);
  }

  void setLowStock(bool v) {
    state = state.copyWith(lowStockAlert: v);
    _save('low', v);
  }

  void setShowCost(bool v) {
    state = state.copyWith(showCost: v);
    _save('cost', v);
  }

  void setShowProfit(bool v) {
    state = state.copyWith(showProfit: v);
    _save('profit', v);
  }

  void setBarcode(bool v) {
    state = state.copyWith(barcode: v);
    _save('barcode', v);
  }

  void setFalcon(bool v) {
    state = state.copyWith(falcon: v);
    _save('falcon', v);
  }

  void setExpiry(bool v) {
    state = state.copyWith(expiry: v);
    _save('expiry', v);
  }

  void setMultiCurrency(bool v) {
    state = state.copyWith(multiCurrency: v);
    _save('multi', v);
  }

  void setExtraOptions(bool v) {
    state = state.copyWith(extraOptions: v);
    _save('extra', v);
  }

  void setCategories(bool v) {
    state = state.copyWith(categories: v);
    _save('cats', v);
  }

  void setExpiryWarnDays(int v) {
    state = state.copyWith(expiryWarnDays: v);
    _save('expiryDays', v);
  }
}

final warehouseSettingsProvider =
    StateNotifierProvider<WarehouseSettingsNotifier, WarehouseSettings>((ref) {
  return WarehouseSettingsNotifier()..load();
});
