import '../../../core/network/api_client.dart';

/// Thin data source for the org-level `/banking/*` endpoints (business section).
///
/// Only the accounts list is used for now — the banks section itself is NOT
/// built yet; the business home just renders the bank cards. The backend
/// guarantees the default non-deletable "كاش" account on this endpoint.
class BusinessFinanceApi {
  final ApiClient _client;

  BusinessFinanceApi(this._client);

  /// Unified business transactions timeline (newest-first). Optional
  /// kind filter, period filter (today/week/month) and a free-text search.
  Future<List<dynamic>> listTransactions({
    String? kind,
    String? period,
    String? search,
    String? dateFrom,
    String? dateTo,
    bool includeDocLegs = false,
  }) async {

    final q = <String, String>{
      'page': '1',
      'per_page': '100',
      if (kind != null && kind.isNotEmpty) 'kind': kind,
      if (period != null && period.isNotEmpty) 'period': period,
      if (search != null && search.isNotEmpty) 'search': search,
      if (dateFrom != null && dateFrom.isNotEmpty) 'date_from': dateFrom,
      if (dateTo != null && dateTo.isNotEmpty) 'date_to': dateTo,
      if (includeDocLegs) 'include_doc_legs': 'true',
    };
    final response = await _client.get(
      '/business/transactions',
      queryParameters: q,
    );
    final body = response.data;
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is Map<String, dynamic> && data['items'] is List) {
        return data['items'] as List;
      }
      if (data is List) return data;
    }
    return const [];
  }

  /// One transaction by its REAL source (details page refresh).
  Future<Map<String, dynamic>?> getTransaction(
    String sourceType,
    String sourceId,
  ) async {

    final response = await _client.get(
      '/business/transactions/$sourceType/$sourceId',
    );
    final body = response.data;
    if (body is Map<String, dynamic> && body['data'] is Map) {
      return Map<String, dynamic>.from(body['data'] as Map);
    }
    return null;
  }

  /// Deposit money INTO a business bank account (income). The backend
  /// updates the balance immediately and writes the matching movement.
  Future<Map<String, dynamic>> deposit(
    String accountId,
    num amount, {
    String? description,
  }) async {

    final response = await _client.post(
      '/banking/accounts/$accountId/deposit',
      data: {
        'amount': amount,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    final body = response.data;
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    return const {};
  }

  /// Withdraw money FROM a business bank account (expense). The backend
  /// checks the balance, deducts it immediately and writes the movement.
  /// When [isExpense] (a categorized Business expense, not a plain move),
  /// the backend ALSO records an Expense row atomically so reports see it.
  Future<Map<String, dynamic>> withdraw(
    String accountId,
    num amount, {
    String? description,
    bool isExpense = false,
    String? category,
  }) async {

    final response = await _client.post(
      '/banking/accounts/$accountId/withdraw',
      data: {
        'amount': amount,
        if (description != null && description.isNotEmpty)
          'description': description,
        if (isExpense) 'is_expense': true,
        if (isExpense && category != null && category.isNotEmpty)
          'category': category,
      },
    );
    final body = response.data;
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    return const {};
  }

  Future<List<dynamic>> listAccounts() async {

    final response = await _client.get('/banking/accounts');
    final body = response.data;
    if (body is List) return body;
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is List) return data;
      final items = body['items'];
      if (items is List) return items;
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> listExpenses() async {

    final response = await _client.get('/expenses');
    return [for (final row in response.data as List) Map<String, dynamic>.from(row as Map)];
  }

}
