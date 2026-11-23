import '../../../core/network/api_client.dart';

/// Thin data source for the business purchase-invoice + parties flows.
/// Mirrors [SalesApi] (same envelope tolerance) and reuses the existing
/// backend endpoints; nothing duplicated server-side.
class PurchaseApi {
  final ApiClient _client;

  PurchaseApi(this._client);

  dynamic _data(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) {
      return body['data'];
    }
    return body;
  }

  List<dynamic> _list(dynamic body) {
    final data = _data(body);
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  Map<String, dynamic> _map(dynamic body) {
    final data = _data(body);
    if (data is Map) return Map<String, dynamic>.from(data);
    return {};
  }

  // ── Shared with sales (read-only re-use) ──
  Future<List<dynamic>> bankAccounts() async {

    final r = await _client.get('/business/payment-options');
    return _list(r.data);
  }

  Future<List<dynamic>> searchProducts(String query) async {

    final r = await _client.get(
      '/products',
      queryParameters: {if (query.isNotEmpty) 'search': query, 'per_page': 20},
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> resolveBarcode(String code) async {

    final r = await _client.get(
      '/products/resolve-barcode',
      queryParameters: {'code': code},
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> productUnits(String productId) async {

    final r = await _client.get('/products/$productId/units');
    return _map(r.data);
  }

  Future<List<dynamic>> categories() async {

    final r = await _client.get('/categories');
    return _list(r.data);
  }

  // ── Suppliers ──
  Future<List<dynamic>> searchSuppliers(String query) async {

    final r = await _client.get(
      '/suppliers',
      queryParameters: {if (query.isNotEmpty) 'search': query, 'per_page': 20},
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> createSupplier({
    required String name,
    String? phone,
    String? commandId,
  }) async {

    final r = await _client.post(
      '/suppliers',
      data: {
        'name': name,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> updateSupplier(
    String id, {
    String? name,
    String? phone,
  }) async {

    final r = await _client.put(
      '/suppliers/$id',
      data: {'name': ?name, 'phone': ?phone},
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> supplierBalance(String id) async {

    final r = await _client.get('/suppliers/$id/balance');
    return _map(r.data);
  }

  Future<Map<String, dynamic>> paySupplier(
    String id,
    Map<String, dynamic> body,
  ) async {

    final r = await _client.post('/suppliers/$id/payments', data: body);
    return _map(r.data);
  }

  // ── Customers ──
  Future<List<dynamic>> searchCustomers(String query) async {

    final r = await _client.get(
      '/customers',
      queryParameters: {if (query.isNotEmpty) 'search': query, 'per_page': 20},
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> createCustomer({
    required String name,
    String? phone,
  }) async {

    final r = await _client.post(
      '/customers',
      data: {
        'name': name,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> updateCustomer(
    String id, {
    String? name,
    String? phone,
  }) async {

    final r = await _client.put(
      '/customers/$id',
      data: {'name': ?name, 'phone': ?phone},
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> customerBalance(String id) async {

    final r = await _client.get('/customers/$id/balance');
    return _map(r.data);
  }

  Future<List<dynamic>> customerOperations(String id) async {
    final r = await _client.get('/customers/$id/operations');
    return _list(r.data);
  }

  Future<List<dynamic>> supplierOperations(String id) async {
    final r = await _client.get('/suppliers/$id/operations');
    return _list(r.data);
  }

  Future<Map<String, dynamic>> collectCustomer(
    String id,
    Map<String, dynamic> body,
  ) async {

    final r = await _client.post('/customers/$id/payments', data: body);
    return _map(r.data);
  }

  // ── Purchase invoices ──
  Future<Map<String, dynamic>> issuePurchase(Map<String, dynamic> body) async {

    final r = await _client.post('/invoices/issue-purchase', data: body);
    return _map(r.data);
  }

  Future<List<dynamic>> purchaseInvoices({String? search, int page = 1}) async {

    final r = await _client.get(
      '/invoices',
      queryParameters: {
        'invoice_type': 'purchase',
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'per_page': 20,
      },
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> getInvoice(String id) async {

    final r = await _client.get('/invoices/$id');
    return _map(r.data);
  }
}
