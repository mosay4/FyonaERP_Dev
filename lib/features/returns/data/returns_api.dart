import '../../../core/network/api_client.dart';

/// Thin data source for the Business «المرتجعات» (returns) feature.
///
/// Every return is created through the ONE invoice-return endpoint; the backend
/// dispatches to the sale or purchase path by the invoice type. Reads come from
/// the unified `/returns` timeline.
class ReturnsApi {
  final ApiClient _client;

  ReturnsApi(this._client);

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

  /// Unified previous-returns list. [kind] = 'sale_return' | 'purchase_return'.
  Future<List<dynamic>> list({
    String? kind,
    String? search,
    String? invoiceId,
    int page = 1,
  }) async {

    final r = await _client.get(
      '/returns',
      queryParameters: {
        if (kind != null && kind.isNotEmpty) 'kind': kind,
        if (search != null && search.isNotEmpty) 'search': search,
        if (invoiceId != null && invoiceId.isNotEmpty) 'invoice_id': invoiceId,
        'page': page,
        'per_page': 100,
      },
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> detail(String kind, String id) async {

    final r = await _client.get('/returns/$kind/$id');
    return _map(r.data);
  }

  /// Confirms a return against the original invoice (sale OR purchase).
  Future<Map<String, dynamic>> create(
    String invoiceId,
    Map<String, dynamic> body,
  ) async {

    final r = await _client.post('/invoices/$invoiceId/returns',
        data: Map<String, dynamic>.of(body)..remove('command_id'));
    return _map(r.data);
  }

  Future<List<dynamic>> searchInvoices(
    String invoiceType,
    String search,
  ) async {

    final r = await _client.get(
      '/invoices',
      queryParameters: {
        'invoice_type': invoiceType,
        if (search.isNotEmpty) 'search': search,
        'per_page': 20,
        'number_only': 'true',
        // Hide fully-returned invoices: only invoices with a returnable line
        // remain, so a fully-returned invoice never appears in the picker.
        'returnable_only': 'true',
      },
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> getInvoice(String id) async {

    final r = await _client.get(
      '/invoices/$id',
      queryParameters: {'returnable_only': 'true'},
    );
    return _map(r.data);
  }

  Future<List<dynamic>> bankAccounts() async {

    final r = await _client.get('/business/payment-options');
    return _list(r.data);
  }
}
