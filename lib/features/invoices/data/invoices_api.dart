import '../../../core/network/api_client.dart';

/// Generic business invoices data source for the unified «الفواتير» center
/// (sale + purchase). Reuses the existing `/invoices` endpoints only.
class InvoicesApi {
  final ApiClient _client;

  InvoicesApi(this._client);

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

  /// [type] = 'sale' | 'purchase'. [search] matches invoice number / party
  /// name / party phone / barcode. [perPage] high so client-side date
  /// filtering stays accurate.
  Future<List<dynamic>> list({
    String? type,
    String? search,
    int perPage = 100,
  }) async {

    final r = await _client.get(
      '/invoices',
      queryParameters: {
        if (type != null && type.isNotEmpty) 'invoice_type': type,
        if (search != null && search.isNotEmpty) 'search': search,
        'page': 1,
        'per_page': perPage,
      },
    );
    return _list(r.data);
  }

  Future<Map<String, dynamic>> getInvoice(String id) async {

    final r = await _client.get('/invoices/$id');
    return _map(r.data);
  }
}
