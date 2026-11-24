import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/ai/domain/agent/business_device_router.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';

final _client = ApiClient(dio: Dio());

class _Purchases extends PurchaseApi {
  _Purchases() : super(_client);
  final calls = <String>[];

  @override
  Future<List<dynamic>> searchCustomers(String query) async {
    calls.add('search:$query');
    return [
      {'id': 'c1', 'name': 'قاسم'},
    ];
  }

  @override
  Future<Map<String, dynamic>> issuePurchase(Map<String, dynamic> body) async {
    if ((body['total'] as num) > 500) throw StateError('الرصيد غير كافٍ');
    calls.add('purchase:${body['total']}');
    return {'id': 'p1'};
  }
}

class _Recon extends ReconciliationApi {
  _Recon() : super(_client);
  List<Map<String, dynamic>>? checked;

  @override
  Future<List<Map<String, dynamic>>> accounts() async => [
    {'id': 'a1', 'bank_name': 'جيب', 'currency': 'YER_OLD', 'balance': 60500},
    {'id': 'a2', 'bank_name': 'كاش', 'currency': 'USD', 'is_cash': true, 'balance': 10},
  ];

  @override
  Future<Map<String, dynamic>> bankCheck({
    required List<Map<String, dynamic>> entries,
    String? notes,
    String? periodStart,
    String? periodEnd,
    String? idempotencyKey,
  }) async {
    checked = entries;
    return {'id': 'r1'};
  }
}

void main() {
  late _Purchases purchases;
  late _Recon recon;
  late ProviderContainer container;
  setUp(() {
    purchases = _Purchases();
    recon = _Recon();
    container = ProviderContainer(overrides: [
      purchaseApiProvider.overrideWithValue(purchases),
      reconciliationApiProvider.overrideWithValue(recon),
    ]);
  });
  tearDown(() => container.dispose());

  Future<Map<String, dynamic>> call(String method, String path,
          {Map<String, dynamic>? params, Map<String, dynamic>? body}) =>
      BusinessDeviceRouter.handle(container.read, method: method, path: path, params: params, body: body);

  test('a read is answered by the same device API the screen uses', () async {
    final r = await call('GET', '/customers', params: {'search': 'قاسم'});
    expect(r['success'], isTrue);
    expect((r['data'] as List).single['name'], 'قاسم');
    expect(purchases.calls, ['search:قاسم']);
    expect((await call('GET', '/customers/c1'))['data'], containsPair('id', 'c1'));
  });

  test('an operation keeps the app rules: a refusal comes back as data', () async {
    expect((await call('POST', '/invoices/issue-purchase', body: {'total': 200}))['success'], isTrue);
    final refused = await call('POST', '/invoices/issue-purchase', body: {'total': 900});
    expect(refused['success'], isFalse);
    expect(refused['message'], contains('الرصيد غير كافٍ'));
    expect(purchases.calls, ['purchase:200']);
    // Collecting a debt has no safe device path yet: Sara offers the screen.
    expect(BusinessDeviceRouter.supports('POST', '/customers/c1/payments'), isFalse);
  });

  test('reconciliation takes actual amounts only; the system side is read here', () async {
    final r = await call('POST', '/reconciliation/bank/check', body: {
      'actuals': [
        {'account_name': 'جيب', 'currency': 'YER_OLD', 'actual': 50000},
        {'account_name': 'كاش', 'actual': 10},
      ],
    });
    expect(r['success'], isTrue);
    expect(recon.checked, [
      {'account_id': 'a1', 'actual': '50000'},
      {'account_id': 'a2', 'actual': '10'},
    ]);
    final ambiguous = await call('POST', '/reconciliation/bank/check', body: {
      'actuals': [{'account_name': 'غير موجود', 'actual': 1}],
    });
    expect(ambiguous['success'], isFalse);
  });

  test('unknown routes are refused and every route is well formed', () async {
    expect((await call('POST', '/admin/everything'))['success'], isFalse);
    final routes = BusinessDeviceRouter.supportedRoutes;
    expect(routes.toSet().length, routes.length, reason: 'no duplicates');
    for (final r in routes) {
      expect(RegExp(r'^(GET|POST|PUT|DELETE) /[a-z0-9\-/{}_]+$').hasMatch(r), isTrue, reason: r);
    }
    expect(BusinessDeviceRouter.supports('GET', '/customers/abc/balance'), isTrue);
    expect(BusinessDeviceRouter.supports('PATCH', '/customers'), isFalse);
  });
}
