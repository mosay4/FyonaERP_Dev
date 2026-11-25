import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/ai/domain/agent/personal_device_router.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_device_loop.dart';
import 'package:fyona_flutter/features/ai/domain/services/ai_service.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

/// The phone's ledger (no server, no network).
class _Ledger extends PersonalFinanceService {
  _Ledger() : super();
  final accounts = [
    PersonalBankAccount(id: 'a1', bankName: 'بنك الراجحي', balance: 5200.5, currency: 'SAR'),
    PersonalBankAccount(id: 'a2', bankName: 'كاش', balance: 300, currency: 'USD'),
  ];
  final txs = [
    PersonalTransaction(id: 't1', type: 'income', amount: 8000, category: 'salary', description: 'راتب',
        date: DateTime.utc(2026, 11, 1, 6), accountId: 'a1'),
    PersonalTransaction(id: 't2', type: 'expense', amount: 200, category: 'food', description: 'مطعم كبير',
        date: DateTime.utc(2026, 11, 3, 18), accountId: 'a1'),
    PersonalTransaction(id: 't3', type: 'expense', amount: 25.5, category: 'food', description: 'Burger',
        date: DateTime.utc(2026, 11, 6, 13), accountId: 'a2', currency: 'USD'),
    PersonalTransaction(id: 't4', type: 'expense', amount: 60, category: 'food', description: 'مطعم',
        date: DateTime.utc(2026, 10, 10, 10), accountId: 'a1'),
  ];
  int reads = 0;

  @override
  Future<List<PersonalBankAccount>> getBankAccounts() async {
    reads++;
    return accounts;
  }

  @override
  Future<List<PersonalTransaction>> getTransactions({String? accountId, int month = 0, int year = 0}) async => txs;
  @override
  Future<List<SavingsGoal>> getSavingsGoals() async =>
      [SavingsGoal(id: 'g1', name: 'سفر', targetAmount: 10000, currentAmount: 800)];
  @override
  Future<List<PersonalDebt>> getDebts() async =>
      [PersonalDebt(id: 'd1', type: 'payable', personName: 'أحمد', amount: 1000, paid: 350)];
  @override
  Future<List<PersonalBudget>> getAllBudgets() async =>
      [PersonalBudget(id: 'b1', name: 'ميزانية نوفمبر', totalAmount: 2000, totalSpent: 230)];
  @override
  Future<List<RecurringTransaction>> getRecurring() async =>
      [RecurringTransaction(id: 'r1', name: 'نتفليكس', type: 'expense', amount: 45, category: 'اشتراكات')];
  @override
  Future<List<PersonalDebtPayment>> getDebtPayments(String debtId) async =>
      [PersonalDebtPayment(id: 'p1', debtId: debtId, amount: 350, paymentDate: DateTime.utc(2026, 11, 2))];
}

const _bounds = {
  'period': 'this_month', 'start': '2026-10-31T21:00:00+00:00', 'end': '2026-11-30T21:00:00+00:00',
  'prev_start': '2026-10-01T21:00:00+00:00', 'prev_end': '2026-10-31T21:00:00+00:00', 'timezone': 'Asia/Riyadh',
};

Map<String, dynamic> _call(String tool, [Map<String, dynamic> params = const {}]) =>
    {'id': 'c-$tool', 'method': 'TOOL', 'path': tool, 'params': params};

void main() {
  late _Ledger ledger;
  late PersonalDeviceRouter router;
  setUp(() {
    ledger = _Ledger();
    router = PersonalDeviceRouter(ledger, now: () => DateTime.utc(2026, 11, 20, 12));
  });

  test('accounts come from the phone in the server shape', () async {
    final r = await router.handle(_call('get_bank_accounts'));
    expect(r['success'], isTrue);
    expect(r['data']['accounts'], [
      {'id': 'a1', 'name': 'بنك الراجحي', 'currency': 'SAR', 'balance': '5200.50', 'type': 'bank'},
      {'id': 'a2', 'name': 'كاش', 'currency': 'USD', 'balance': '300.00', 'type': 'bank'},
    ]);
  });

  test('period reads use the server window and never mix currencies', () async {
    final s = await router.handle(_call('get_financial_summary', {'bounds': _bounds}));
    expect(s['data'], {
      'period': 'this_month',
      'by_currency': [
        {'currency_id': 'SAR', 'currency': 'SAR', 'income': '8000.00', 'expense': '200.00', 'net': '7800.00'},
        {'currency_id': 'USD', 'currency': 'USD', 'income': '0', 'expense': '25.50', 'net': '-25.50'},
      ],
    });
    final e = await router.handle(_call('get_expenses_data', {'bounds': _bounds, 'category': 'food', 'limit': 1}));
    expect(e['data']['by_currency'], [
      {'currency_id': 'SAR', 'currency': 'SAR', 'total': '200.00'},
      {'currency_id': 'USD', 'currency': 'USD', 'total': '25.50'},
    ]);
    expect((e['data']['expenses'] as List).single['description'], 'Burger'); // newest first
    expect(e['data']['expenses_coverage'], {'shown': 1, 'total': 2});
  });

  test('search, entity lookups and analytics answer from the ledger', () async {
    final found = await router.handle(_call('search_all_transactions', {'query': 'مطعم', 'from_date': '2026-11-01'}));
    expect((found['data']['transactions'] as List).single['amount'], '200.00');
    final matches = await router.handle(_call('search_entity', {'query': 'سفر'}));
    expect(matches['data']['matches'], [
      {'entity_type': 'goal', 'id': 'g1', 'name': 'سفر', 'target_amount': '10000.00',
       'current_amount': '800.00', 'currency': 'SAR'},
    ]);
    final detail = await router.handle(_call('get_entity_detail', {'entity_type': 'debt', 'entity_id': 'd1'}));
    expect(detail['data']['entity']['paid'], '350.00');
    final missing = await router.handle(_call('get_entity_detail', {'entity_type': 'debt', 'entity_id': 'x'}));
    expect(missing['success'], isFalse);
    final analytics = await router.handle(_call('get_financial_analytics', {'bounds': _bounds}));
    final data = analytics['data'] as Map;
    expect(data['meta']['source'], 'device');
    expect(data['facts']['money_by_currency'][0]['income'], '8000.00');
    expect(data['facts']['debts'][0]['paid'], '350.00');
    expect(data['conversion'], {'status': 'not_requested'});
  });

  test('flutter-owned reads use the existing ToolExecutor read cases', () async {
    final r = await router.handle(_call('get_debt_payments', {'debt_id': 'd1'}));
    expect(r['success'], isTrue);
    expect((r['data']['payments'] as List).single['amount'], 350);
  });

  test('unknown or non-read calls are refused as data', () async {
    for (final call in [_call('create_debt'), {'id': 'x', 'method': 'GET', 'path': 'get_debts'}]) {
      final r = await router.handle(call);
      expect(r['success'], isFalse);
      expect(r['message'], isNotEmpty);
    }
  });

  test('the shared loop answers every call and resumes until Sara replies', () async {
    final sent = <List<Map<String, dynamic>>>[];
    final first = AiAgentResponse(text: '', state: const {'phase': 'context'}, deviceCalls: [
      {'id': 'ctx:banking', 'method': 'TOOL', 'path': 'get_bank_accounts', 'params': {}},
      {'id': 'ctx:financial', 'method': 'TOOL', 'path': 'get_financial_summary', 'params': {'bounds': _bounds}},
    ]);
    final reply = await SaraDeviceLoop.run(first, handle: router.handle, resume: (state, results) async {
      sent.add(results);
      if (sent.length == 1) {
        return const AiAgentResponse(text: '', state: {'phase': 'loop'}, deviceCalls: [
          {'id': 't1', 'method': 'TOOL', 'path': 'get_debts', 'params': {}},
        ]);
      }
      return const AiAgentResponse(text: 'عليك 650 لأحمد.');
    });
    expect(reply!.text, 'عليك 650 لأحمد.');
    expect(sent.first.map((r) => r['id']), ['ctx:banking', 'ctx:financial']);
    expect((sent.last.single['result'] as Map)['data']['debts'][0]['remaining'], '650.00');
  });

  test('large answers are trimmed under the server limit', () async {
    ledger.txs
      ..clear()
      ..addAll([
        for (var i = 0; i < 3000; i++)
          PersonalTransaction(id: 'x$i', type: 'expense', amount: 1, category: 'c',
              description: 'وصف طويل ' * 20, date: DateTime.utc(2026, 11, 2)),
      ]);
    final r = await router.handle(_call('search_all_transactions', {'limit': 500}));
    expect((r['data']['transactions'] as List).length, 50);
    expect(jsonEncode(SaraDeviceLoop.compact(r)).length, lessThanOrEqualTo(SaraDeviceLoop.resultLimit));
  });

  test('the Personal chat path sends the device header and runs the loop', () async {
    final seen = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        seen.add(o);
        final data = o.path.endsWith('/ai/continue')
            ? {'text': 'رصيدك 5200.50 ريال.', 'actions': []}
            : {'text': '', 'user_query': 'كم رصيدي', 'state': {'phase': 'context', 'sig': 's'},
               'device_calls': [{'id': 'ctx:banking', 'method': 'TOOL', 'path': 'get_bank_accounts', 'params': {}}]};
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {'success': true, 'data': data}));
      }));
    final ai = AiService(apiClient: ApiClient(dio: dio));
    final reply = await ai.askQuestion('كم رصيدي', language: 'ar', personalDevice: router.handle);
    expect(reply.text, 'رصيدك 5200.50 ريال.');
    expect(reply.userQuery, 'كم رصيدي');
    expect(seen.map((o) => o.path.split('/').last), ['query', 'continue']);
    for (final o in seen) {
      expect(o.headers['x-fyona-device-sara'], 'personal');
    }
    final body = seen.last.data as Map;
    expect(body['state'], {'phase': 'context', 'sig': 's'});
    final result = (body['results'] as List).single as Map;
    expect(result['id'], 'ctx:banking');
    expect((result['result'] as Map)['data']['accounts'][0]['balance'], '5200.50');

    // Old behaviour without a device handler: no header, no loop.
    seen.clear();
    await ai.askQuestion('كم رصيدي');
    expect(seen.single.headers.containsKey('x-fyona-device-sara'), isFalse);
  });
}
