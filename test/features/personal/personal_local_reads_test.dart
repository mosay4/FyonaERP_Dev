import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_store.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/budget_aggregation.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/personal_ledger_test_support.dart';

/// Records every request; reads fail (they must not be needed any more),
/// the bulk reset endpoint is missing (old server) so per-row deletes run.
class _Recorder extends ApiClient {
  _Recorder() : super(dio: Dio());
  final calls = <String>[];

  Never _fail(String path) => throw DioException(
    requestOptions: RequestOptions(path: path),
    response: Response(requestOptions: RequestOptions(path: path), statusCode: 404),
    type: DioExceptionType.badResponse,
  );

  @override
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) {
    calls.add('GET $path');
    _fail(path);
  }

  @override
  Future<Response<T>> post<T>(String path,
      {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) {
    calls.add('POST $path');
    _fail(path);
  }

  @override
  Future<Response<T>> delete<T>(String path,
      {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) {
    calls.add('DELETE $path');
    if (path.endsWith('/reset')) _fail(path);
    return Future.value(Response<T>(requestOptions: RequestOptions(path: path), statusCode: 204));
  }
}

const _ns = 7;

Map<String, dynamic> _tx(String id, String type, double amount, String? date,
        {String? budget, String? goal, String? debt, String? cat}) =>
    {
      'id': id,
      'tx_type': type,
      'amount': amount,
      'currency': 'SAR',
      'category': 'Food',
      'date': date,
      'budget_id': budget,
      'goal_id': goal,
      'debt_id': debt,
      'budget_category_id': cat,
    };

final _budget = <String, dynamic>{
  'id': 'b1',
  'name': 'November',
  'total_amount': 1000.0,
  'currency': 'SAR',
  'start_date': '2026-11-01T00:00:00',
  'end_date': '2026-11-30T23:59:59',
  'categories': [
    {'id': 'c1', 'budget_id': 'b1', 'name': 'Food', 'type': 'expense', 'allocated_amount': 300.0},
  ],
};

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    await resetPersonalLedger();
    PersonalRelayConfig.enabled = true;
  });
  tearDown(() => PersonalRelayConfig.enabled = PersonalRelayConfig.build);

  group('budget aggregation = the server rules (parity)', () {
    final goals = [
      {'id': 'g1', 'name': 'Car', 'target_amount': 900.0, 'current_amount': 50.0, 'currency': 'SAR', 'budget_id': 'b1'},
      {'id': 'g2', 'name': 'Trip', 'target_amount': 10.0, 'current_amount': 0.0, 'currency': 'SAR', 'budget_id': 'other'},
    ];
    final debts = [
      {'id': 'd1', 'person_name': 'Ali', 'amount': 200.0, 'currency': 'SAR', 'budget_id': 'b1'},
    ];
    final txs = [
      _tx('t1', 'expense', 100, '2026-11-05T09:00:00', budget: 'b1', cat: 'c1'),
      _tx('t1', 'expense', 100, '2026-11-05T09:00:00', budget: 'b1', cat: 'c1'), // dup id
      _tx('t2', 'expense', 50, '2026-11-06T10:00:00Z', goal: 'g1'),
      _tx('t3', 'expense', 70, '2026-11-07T12:00:00+00:00', debt: 'd1'),
      _tx('t4', 'income', 500, '2026-11-08T09:00:00', budget: 'b1'),
      _tx('t5', 'expense', 40, '2026-10-31T23:00:00', budget: 'b1'), // before
      _tx('t6', 'expense', 25, '2026-11-09T09:00:00', goal: 'g2'), // other budget
      _tx('t7', 'expense', 33.333, '2026-11-30T23:59:59', budget: 'b1'), // end incl.
      _tx('t8', 'expense', 11, null, budget: 'b1'), // no date: never counted
    ];

    test('membership by ids, period, dedup, rounding, order', () {
      final json = computeBudgetAggregation(budget: _budget, transactions: txs, goals: goals, debts: debts);
      // Expected values computed by hand with the rules of
      // backend personal_finance.py budget_aggregation.
      expect(json['total_amount'], 1000.0);
      expect(json['total_used'], 253.33);
      expect(json['remaining'], 746.67);
      expect(json['progress'], 0.2533);
      expect(json['operations_count'], 4);
      expect([for (final o in json['operations'] as List) o['id']], ['t7', 't3', 't2', 't1']);
      final cat = (json['categories'] as List).single as Map;
      expect(cat['used'], 100.0);
      expect(cat['remaining'], 200.0);
      expect(cat['currency'], 'SAR');
      final goal = (json['goals'] as List).single as Map;
      expect(goal['id'], 'g1');
      expect(goal['contributed_in_period'], 50.0);
      final debt = (json['debts'] as List).single as Map;
      expect(debt['paid_in_period'], 70.0);
      final agg = BudgetAggregation.fromJson(json);
      expect(agg.budget.id, 'b1');
      expect(agg.operationsCount, 4);
      expect(agg.categories.single.used, 100.0);
    });

    test('open ends and the amount fallback', () {
      final json = computeBudgetAggregation(
        budget: {..._budget, 'total_amount': 0, 'amount': 400.0, 'start_date': null, 'end_date': null},
        transactions: txs,
        goals: goals,
        debts: debts,
      );
      expect(json['total_amount'], 400.0);
      expect(json['total_used'], 293.33); // t5 counts without a start
      expect(json['progress'], 0.7333);
    });
  });

  Future<(PersonalFinanceService, _Recorder)> service() async {
    final cache = PersonalCacheRepository();
    final api = _Recorder();
    final svc = PersonalFinanceService(apiClient: api, cache: cache)..setUserId(_ns);
    return (svc, api);
  }

  Future<void> seed(String type, Map<String, dynamic> row) =>
      PersonalCacheRepository().upsertItem(_ns, type, '${row['id']}', row);

  test('aggregation, debt payments and categories need no server', () async {
    final (svc, api) = await service();
    await seed('personal_budget', _budget);
    await seed('personal_bank_account', {'id': 'bank-1', 'bank_name': 'Main', 'balance': 1000.0, 'currency': 'SAR'});
    await seed('personal_debt', {'id': 'd1', 'debt_type': 'payable', 'person_name': 'Ali', 'amount': 200.0, 'paid': 0.0, 'currency': 'SAR', 'budget_id': 'b1'});
    await seed('personal_transaction', _tx('t1', 'expense', 100, '2026-11-05T09:00:00', budget: 'b1', cat: 'c1'));
    await svc.payDebt('d1', 30, DateTime(2026, 11, 10), method: 'bank', bankAccountId: 'bank-1', notes: 'first');
    await svc.payDebt('d1', 20, DateTime(2026, 11, 12), method: 'bank', bankAccountId: 'bank-1');
    final calls = api.calls.length;

    final agg = await svc.getBudgetAggregation('b1');
    expect(agg.totalUsed, 150.0); // t1 + both payments (debt linked to the budget)
    expect(agg.debts.single.paidInPeriod, 50.0);
    await expectLater(svc.getBudgetAggregation('nope'), throwsException);

    final payments = await svc.getDebtPayments('d1');
    expect([for (final p in payments) p.amount], [20.0, 30.0]); // newest first
    expect(payments.last.notes, 'first');
    expect(payments.first.currency, 'SAR');
    await expectLater(svc.getDebtPayments('nope'), throwsException);

    await svc.addCategory(SpendingCategory(id: '', name: 'Zakat', nameAr: 'زكاة'));
    final cats = await svc.getCategories();
    expect(cats.first.name, 'Zakat'); // stored first, then derived names
    expect(cats.map((c) => c.name), containsAll(['Food', 'سداد دين']));
    expect(api.calls.length, calls, reason: 'no server read: ${api.calls}');
  });

  test('ensureCashAccounts: ledger check only; nothing while a copy is awaited', () async {
    final (svc, api) = await service();
    final store = PersonalRelayStore(await PersonalLedger.active());
    await store.setResync('waiting');
    Future<List<Map<String, dynamic>>> banks() =>
        PersonalCacheRepository().getCollection(_ns, 'personal_bank_account');
    await svc.ensureCashAccounts(['SAR']);
    expect(await banks(), isEmpty);
    await store.setResync('');
    await svc.ensureCashAccounts(['SAR']);
    await svc.ensureCashAccounts(['SAR']);
    final cash = (await banks()).where((a) => a['bank_name'] == 'كاش');
    expect(cash, hasLength(1));
    expect(api.calls.where((c) => c.startsWith('GET')), isEmpty);
  });

  test('duplicate cash heals to the same survivor on every device', () async {
    final (svc, _) = await service();
    for (final id in ['cash-b', 'cash-a']) {
      await seed('personal_bank_account', {'id': id, 'bank_name': 'كاش', 'balance': 0.0, 'currency': 'SAR'});
    }
    await svc.sweepDuplicateCashAccounts();
    final left = await svc.getBankAccounts();
    expect([for (final a in left) a.id], ['cash-a']); // smallest id, not insertion order
  });

  test('resetAccount (old server): what to delete comes from the ledger', () async {
    // A server that still keeps Personal data (not device-only Personal).
    PersonalLocalMode.serverDeclined = true;
    addTearDown(() => PersonalLocalMode.serverDeclined = false);
    final (svc, api) = await service();
    await seed('personal_bank_account', {'id': 'bank-9', 'bank_name': 'Main', 'balance': 1.0, 'currency': 'SAR'});
    await seed('personal_savings_goal', {'id': 'goal-9', 'name': 'G', 'target_amount': 1.0, 'current_amount': 0.0});
    await svc.resetAccount();
    expect(api.calls.where((c) => c.startsWith('GET')), isEmpty);
    expect(api.calls, contains(predicate<String>((c) => c.startsWith('DELETE') && c.contains('bank-9'))));
    expect(api.calls, contains(predicate<String>((c) => c.startsWith('DELETE') && c.contains('goal-9'))));
  });
}
