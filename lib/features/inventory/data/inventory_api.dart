import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Thin data source for the Business inventory screens. Reuses the existing
/// backend endpoints (products, units, barcodes, inventory movements) and only
/// adds the new product-image + stock-adjust calls.
class InventoryApi {
  final ApiClient _client;

  InventoryApi(this._client);

  static dynamic _data(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) {
      return body['data'];
    }
    return body;
  }

  static List<dynamic> _list(dynamic body) {
    final data = _data(body);
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  static Map<String, dynamic> _map(dynamic body) {
    final data = _data(body);
    if (data is Map) return Map<String, dynamic>.from(data);
    return {};
  }

  Future<List<Map<String, dynamic>>> listProducts({
    String search = '',
    String? stockStatus,
    String? expiry,
    int expiryDays = 30,
    String? categoryId,
    bool uncategorized = false,
    int page = 1,
    int perPage = 50,
  }) async {
    final r = await _client.get(
      '/products',
      queryParameters: {
        if (search.isNotEmpty) 'search': search,
        if (stockStatus != null && stockStatus.isNotEmpty)
          'stock_status': stockStatus,
        if (expiry != null && expiry.isNotEmpty) 'expiry': expiry,
        if (expiry != null && expiry.isNotEmpty) 'expiry_days': expiryDays,
        if (categoryId != null && categoryId.isNotEmpty)
          'category_id': categoryId,
        if (uncategorized) 'uncategorized': true,
        'page': page,
        'per_page': perPage,
      },
    );
    return [
      for (final p in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(p),
    ];
  }

  Future<List<Map<String, dynamic>>> branches() async {
    final r = await _client.get('/branches');
    return [
      for (final b in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(b),
    ];
  }

  Future<Map<String, dynamic>> transferStock(Map<String, dynamic> body) async {
    final r = await _client.post('/inventory/transfer', data: body);
    return _map(r.data);
  }

  Future<Map<String, dynamic>> getProduct(String id) async {
    final r = await _client.get('/products/$id');
    return _map(r.data);
  }

  Future<Map<String, dynamic>> createProduct(Map<String, dynamic> body) async {
    final r = await _client.post('/products', data: body);
    return _map(r.data);
  }

  Future<Map<String, dynamic>> updateProduct(
    String id,
    Map<String, dynamic> body,
  ) async {
    final r = await _client.put('/products/$id', data: body);
    return _map(r.data);
  }

  Future<void> deleteProduct(String id) async {
    await _client.delete('/products/$id');
  }

  Future<Map<String, dynamic>> resolveBarcode(String code) async {
    final r = await _client.get(
      '/products/resolve-barcode',
      queryParameters: {'code': code},
    );
    return _map(r.data);
  }

  // ── Units & barcodes ──
  Future<Map<String, dynamic>> productUnits(String id) async {
    final r = await _client.get('/products/$id/units');
    return _map(r.data);
  }

  Future<Map<String, dynamic>> createUnit(
    String id,
    Map<String, dynamic> body,
  ) async {
    final r = await _client.post('/products/$id/units', data: body);
    return _map(r.data);
  }

  Future<void> deleteUnit(String unitId) async {
    await _client.delete('/products/units/$unitId');
  }

  Future<Map<String, dynamic>> addBarcode(
    String id,
    Map<String, dynamic> body,
  ) async {
    final r = await _client.post('/products/$id/barcodes', data: body);
    return _map(r.data);
  }

  Future<void> deleteBarcode(String barcodeId) async {
    await _client.delete('/products/barcodes/$barcodeId');
  }

  // ── Inventory ──
  Future<Map<String, dynamic>> adjustStock(Map<String, dynamic> body) async {

    final r = await _client.post('/inventory/adjust', data: body);
    return _map(r.data);
  }

  Future<List<Map<String, dynamic>>> productMovements(
    String id, {
    int limit = 60,
  }) async {
    final r = await _client.get(
      '/inventory/movements/product/$id',
      queryParameters: {'limit': limit},
    );
    return [
      for (final m in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(m),
    ];
  }

  Future<List<Map<String, dynamic>>> productLots(String id) async {
    final r = await _client.get('/products/$id/lots');
    return [
      for (final l in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(l),
    ];
  }

  Future<Map<String, dynamic>> productStats(
    String id, {
    String? from,
    String? to,
    String? displayCurrency,
  }) async {
    final r = await _client.get(
      '/products/$id/stats',
      queryParameters: {
        if (from != null && from.isNotEmpty) 'date_from': from,
        if (to != null && to.isNotEmpty) 'date_to': to,
        if (displayCurrency != null && displayCurrency.isNotEmpty)
          'display_currency': displayCurrency,
      },
    );
    return _map(r.data);
  }

  Future<void> setWarehouseSettings({
    required bool expiryEnabled,
    required int warnDays,
  }) async {
    await _client.put(
      '/inventory/warehouse-settings',
      data: {'expiry_enabled': expiryEnabled, 'expiry_warn_days': warnDays},
    );
  }

  Future<Map<String, dynamic>> falconAnalyze(
    String scope,
    String? refId, {
    String? reportCurrency,
  }) async {
    final r = await _client.post(
      '/inventory/falcon/analyze',
      data: {
        'scope': scope,
        if (refId != null) 'ref_id': refId,
        if (reportCurrency != null) 'report_currency': reportCurrency,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> falconChat(
    String scope,
    String? refId,
    String question,
    List<Map<String, dynamic>> history, {
    String? reportCurrency,
  }) async {
    final r = await _client.post(
      '/inventory/falcon/chat',
      data: {
        'scope': scope,
        if (refId != null) 'ref_id': refId,
        'question': question,
        'history': history,
        if (reportCurrency != null) 'report_currency': reportCurrency,
      },
    );
    return _map(r.data);
  }

  Future<List<Map<String, dynamic>>> categories() async {
    final r = await _client.get('/categories');
    return [
      for (final c in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(c),
    ];
  }

  Future<Map<String, dynamic>> createCategory(String name) async {
    final r = await _client.post('/categories', data: {'name': name});
    return _map(r.data);
  }

  Future<Map<String, dynamic>> updateCategory(String id, String name) async {
    final r = await _client.put('/categories/$id', data: {'name': name});
    return _map(r.data);
  }

  Future<void> deleteCategory(String id) async {
    await _client.delete('/categories/$id');
  }

  // ── Multi-currency sell prices ──
  Future<List<Map<String, dynamic>>> productPrices(String id) async {
    final r = await _client.get('/products/$id/prices');
    return [
      for (final p in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(p),
    ];
  }

  Future<void> setProductPrices(
    String id,
    List<Map<String, dynamic>> prices,
  ) async {
    await _client.put('/products/$id/prices', data: {'prices': prices});
  }

  // ── Image ──
  /// Phone uploads over mobile data routinely outlive the default 30s
  /// send timeout, and carriers sometimes reset the connection mid-flight
  /// («Connection closed before full header»). Generous per-call timeouts
  /// plus one automatic retry make image changes just work.
  Future<Map<String, dynamic>> _postImage(
    String url,
    String filePath,
    Dio dio,
  ) async {
    Options opts() => Options(
      contentType: 'multipart/form-data',
      sendTimeout: const Duration(seconds: 90),
      receiveTimeout: const Duration(seconds: 90),
    );
    Future<Map<String, dynamic>> once() async {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath),
      });
      final r = await dio.post(url, data: form, options: opts());
      return _map(r.data);
    }

    try {
      return await once();
    } on DioException catch (e) {
      final transient =
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout;
      if (!transient) rethrow;
      await Future.delayed(const Duration(seconds: 2));
      return await once();
    }
  }

  Future<Map<String, dynamic>> uploadImage(
    String id,
    String filePath, {
    required Dio dio,
  }) async {
    return _postImage('/products/$id/image', filePath, dio);
  }

  Future<void> deleteImage(String id) async {
    await _client.delete('/products/$id/image');
  }

  // ── Category image ──
  Future<Map<String, dynamic>> uploadCategoryImage(
    String id,
    String filePath, {
    required Dio dio,
  }) async {
    return _postImage('/categories/$id/image', filePath, dio);
  }

  Future<void> deleteCategoryImage(String id) async {
    await _client.delete('/categories/$id/image');
  }
}
