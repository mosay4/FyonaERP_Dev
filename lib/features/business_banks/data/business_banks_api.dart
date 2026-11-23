import '../../../core/network/api_client.dart';

/// Direct async client for the org-level `/banking/*` endpoints.
///
/// Unlike Personal (local-first + sync engine), Business banking talks to
/// the server directly — every mutation awaits the response. Lists may be
/// raw arrays or `{data}`/`{data.items}` enveloped; both are tolerated.
class BusinessBanksApi {
  final ApiClient _client;

  BusinessBanksApi(this._client);

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

  Future<List<dynamic>> listAccounts() async {

    final r = await _client.get('/banking/accounts');
    return _list(r.data);
  }

  Future<void> linkAccounts(List<String> ids) async {
    await _client.post('/banking/banks/link', data: {'account_ids': ids});
  }

  Future<void> unlinkAccounts(List<String> ids) async {
    await _client.post('/banking/banks/unlink', data: {'account_ids': ids});
  }

  Future<Map<String, dynamic>> createAccount({
    required String bankName,
    required String accountName,
    required String accountNumber,
    String? iban,
    required String currency,
    String accountType = 'checking',
    double balance = 0,
    String? notes,
  }) async {

    final r = await _client.post(
      '/banking/accounts',
      data: {
        'bank_name': bankName,
        'account_name': accountName,
        'account_number': accountNumber,
        if (iban != null && iban.isNotEmpty) 'iban': iban,
        'currency': currency,
        'account_type': accountType,
        'balance': balance,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> updateAccount(
    String id, {
    String? bankName,
    String? accountName,
    String? accountNumber,
    String? iban,
    String? currency,
    String? accountType,
    double? balance,
    bool? isActive,
  }) async {
    final body = <String, dynamic>{};
    if (bankName != null) body['bank_name'] = bankName;
    if (accountName != null) body['account_name'] = accountName;
    if (accountNumber != null) body['account_number'] = accountNumber;
    if (iban != null) body['iban'] = iban;
    if (currency != null) body['currency'] = currency;
    if (accountType != null) body['account_type'] = accountType;
    if (balance != null) body['balance'] = balance;
    if (isActive != null) body['is_active'] = isActive;

    final r = await _client.put('/banking/accounts/$id', data: body);
    return _map(r.data);
  }

  Future<Map<String, dynamic>> deleteAccount(String id) async {

    await _client.delete('/banking/accounts/$id');
    return {};
  }

  Future<Map<String, dynamic>> transfer({
    required String fromId,
    required String toId,
    required double amount,
    double? toAmount,
    double? rate,
    String? description,
  }) async {

    final r = await _client.post(
      '/banking/transfer',
      data: {
        'from_account_id': fromId,
        'to_account_id': toId,
        'amount': amount,
        if (toAmount != null) 'to_amount': toAmount,
        if (rate != null) 'exchange_rate': rate,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> deposit(
    String id,
    double amount, {
    String? description,
  }) async {

    final r = await _client.post(
      '/banking/accounts/$id/deposit',
      data: {
        'amount': amount,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> withdraw(
    String id,
    double amount, {
    String? description,
  }) async {

    final r = await _client.post(
      '/banking/accounts/$id/withdraw',
      data: {
        'amount': amount,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    return _map(r.data);
  }

  Future<List<dynamic>> transactions(String accountId) async {
    final path = accountId.startsWith('all:')
        ? '/banking/group/${Uri.encodeComponent(Uri.decodeComponent(accountId.substring(4)))}/transactions'
        : '/banking/accounts/$accountId/transactions';
    final items = <dynamic>[];
    var page = 1;
    while (true) {
      final r = await _client.get(
        path,
        queryParameters: {'page': page, 'per_page': 100},
      );
      final rows = _list(r.data);
      items.addAll(rows);
      final data = _data(r.data);
      final pages = data is Map
          ? int.tryParse('${data['total_pages'] ?? 1}') ?? 1
          : 1;
      if (rows.isEmpty || page >= pages) break;
      page++;
    }
    return items;
  }
}
