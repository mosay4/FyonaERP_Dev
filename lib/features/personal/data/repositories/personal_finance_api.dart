import '../../../../core/network/api_client.dart';
import '../../../../core/localization/app_localizations.dart';

/// Thin data source for the `/personal/finance/*` endpoints.
///
/// The backend wraps every response in `{ success, message, data }`. Lists are
/// either a plain array under `data` or, for paginated endpoints, an object
/// with an `items` key. Errors surface as [DioException] via [ApiClient].
class PersonalFinanceApi {
  final ApiClient _client;

  PersonalFinanceApi(this._client);

  Future<List<dynamic>> list(String path, {Map<String, dynamic>? params}) async {
    final response = await _client.get(path, queryParameters: params);
    return _extractList(response.data);
  }

  Future<Map<String, dynamic>> one(String path) async {
    final response = await _client.get(path);
    return _extractMap(response.data);
  }

  Future<Map<String, dynamic>> create(String path, Map<String, dynamic> body) async {
    final response = await _client.post(path, data: body);
    return _extractMap(response.data);
  }

  Future<Map<String, dynamic>> update(String path, Map<String, dynamic> body) async {
    final response = await _client.patch(path, data: body);
    return _extractMap(response.data);
  }

  Future<void> remove(String path) async {
    await _client.delete(path);
  }

  dynamic _extractData(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) {
      return body['data'];
    }
    return body;
  }

  List<dynamic> _extractList(dynamic body) {
    final data = _extractData(body);
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  Map<String, dynamic> _extractMap(dynamic body) {
    final data = _extractData(body);
    if (data is Map) return Map<String, dynamic>.from(data);
    throw FormatException(AppLocalizations.t('apiErrInvalidResponse'));
  }
}
