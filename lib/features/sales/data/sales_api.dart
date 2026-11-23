import '../../../core/network/api_client.dart';

/// Thin data source for the business sale-invoice flow.
///
/// Endpoints used (all pre-existing backend systems, no duplicates):
/// customers, products (+units/barcodes), invoices (issue/returns),
/// banking accounts, customer balance. Responses may be enveloped
/// `{success,message,data}` or raw lists (banking) — both tolerated.
class SalesApi {
  final ApiClient _client;

  SalesApi(this._client);

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
    String? commandId,
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

  Future<Map<String, dynamic>> customerBalance(String customerId) async {

    final r = await _client.get('/customers/$customerId/balance');
    return _map(r.data);
  }

  // ── Products ──
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

  // ── Bank accounts (receiving) ──
  Future<List<dynamic>> bankAccounts() async {

    final r = await _client.get('/business/payment-options');
    return _list(r.data);
  }

  // ── Invoices ──
  Future<Map<String, dynamic>> issueSale(Map<String, dynamic> body) async {

    final r = await _client.post('/invoices/issue-sale', data: body);
    return _map(r.data);
  }

  Future<List<dynamic>> saleInvoices({String? search, int page = 1}) async {

    final r = await _client.get(
      '/invoices',
      queryParameters: {
        'invoice_type': 'sale',
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
