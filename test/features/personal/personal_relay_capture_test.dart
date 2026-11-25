import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/account_type_store.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_store.dart';
import 'package:fyona_flutter/features/personal/data/models/financial_tree_models.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/data/repositories/financial_tree_storage.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/personal_ledger_test_support.dart';

/// Every request fails like a device without Internet.
class _Offline extends ApiClient {
  _Offline() : super(dio: Dio());

  Never _fail(String path) => throw DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.connectionError,
    message: 'SocketException: offline',
  );

  @override
  Future<Response<T>> get<T>(String path,
          {Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _fail(path);

  @override
  Future<Response<T>> post<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _fail(path);

  @override
  Future<Response<T>> delete<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _fail(path);
}

const _ns = 7;

/// The relay operations recorded so far: each is the list of its changes.
Future<List<List<Map<String, dynamic>>>> _ops() async {
  final db = await PersonalLedger.active();
  return [
    for (final r in await db.rawQuery(
      'SELECT payload FROM personal_relay_outbox ORDER BY created_us',
    ))
      [
        for (final c in (jsonDecode(r['payload'] as String) as Map)['c'] as List)
          Map<String, dynamic>.from(c as Map),
      ],
  ];
}

Map<String, dynamic> _change(List<Map<String, dynamic>> op, String type, [String? id]) =>
    op.firstWhere((c) => c['t'] == type && (id == null || c['id'] == id));

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

  Future<(PersonalFinanceService, PersonalCacheRepository)> seeded() async {
    final cache = PersonalCacheRepository();
    // Server-mirror rows (what a pull stores): never sent to other devices.
    await cache.upsertItem(_ns, 'personal_bank_account', 'bank-1', {
      'id': 'bank-1',
      'bank_name': 'Main',
      'balance': 1000.0,
      'currency': 'SAR',
      '_sync_version': 4,
    });
    await cache.replaceCollection(_ns, 'personal_debt', [
      {'id': 'debt-1', 'debt_type': 'payable', 'person_name': 'Ali', 'amount': 500.0, 'paid': 0.0, 'currency': 'SAR'},
      {'id': 'debt-2', 'debt_type': 'payable', 'person_name': 'Sara', 'amount': 90.0, 'paid': 0.0, 'currency': 'SAR'},
    ]);
    final svc = PersonalFinanceService(apiClient: _Offline(), cache: cache, repo: PersonalRepository())
      ..setUserId(_ns);
    return (svc, cache);
  }

  test('server-mirror writes record nothing; relay off records nothing', () async {
    final (svc, _) = await seeded();
    expect(await _ops(), isEmpty);
    PersonalRelayConfig.enabled = false;
    await svc.updateBankAccount('bank-1', bankName: 'Quiet');
    expect(await _ops(), isEmpty);
  });

  test('commitOfflineWrite: one op with the row, its effects and counter deltas', () async {
    final (svc, _) = await seeded();
    await svc.payDebt('debt-1', 200, DateTime(2026, 9, 8), method: 'bank', bankAccountId: 'bank-1');
    final ops = await _ops();
    expect(ops, hasLength(1));
    final op = ops.single;
    final tx = _change(op, 'personal_transaction');
    expect(tx['k'], 'i');
    expect(tx['data']['debt_id'], 'debt-1');
    final bank = _change(op, 'personal_bank_account', 'bank-1');
    expect(bank['k'], 'u');
    expect(bank['d'], {'balance': -200.0});
    expect((bank['data'] as Map).containsKey('_sync_version'), isFalse);
    final debt = _change(op, 'personal_debt', 'debt-1');
    expect(debt['d'], {'paid': 200.0});
    // A counter-only change claims no field of the account.
    expect(bank['f'], isNot(contains('bank_name')));
  });

  test('update / delete / never-synced delete (commitMirrorOnly) / transfer', () async {
    final (svc, cache) = await seeded();
    await svc.updateBankAccount('bank-1', bankName: 'Renamed');
    final rename = (await _ops()).last.single;
    expect(rename['k'], 'u');
    expect(rename['f'], contains('bank_name'));
    expect(rename.containsKey('d'), isFalse);

    await svc.addTransaction(type: 'income', amount: 50, category: 'Gift', date: DateTime(2026, 9, 1), accountId: 'bank-1', currency: 'SAR');
    final txId = _change((await _ops()).last, 'personal_transaction')['id'] as String;
    // Never reached the server: the cancel is mirror-only, but it still
    // reaches the other devices (which may already have the row).
    await svc.deleteTransaction(txId);
    final cancel = (await _ops()).last;
    expect(_change(cancel, 'personal_transaction', txId)['k'], 'd');
    expect(_change(cancel, 'personal_bank_account')['d'], {'balance': -50.0});

    await svc.addBankAccount(bankName: 'Second', currency: 'SAR', openingBalance: 10);
    final second = (await _ops()).last.single;
    expect(second['k'], 'i');
    final before = (await _ops()).length;
    await svc.transferBetweenAccounts(
      fromId: 'bank-1', toId: second['id'] as String, amount: 100,
      fromCurrency: 'SAR', toCurrency: 'SAR', rate: 1,
    );
    final ops = await _ops();
    expect(ops.length, before + 1);
    final transfer = ops.last;
    expect(transfer.where((c) => c['t'] == 'personal_transaction'), hasLength(2));
    expect(_change(transfer, 'personal_bank_account', 'bank-1')['d'], {'balance': -100.0});
    expect(_change(transfer, 'personal_bank_account', second['id'] as String)['d'], {'balance': 100.0});

    await svc.deleteDebt('debt-2');
    expect((await _ops()).last.single, {'t': 'personal_debt', 'id': 'debt-2', 'k': 'd'});
    final tomb = await (await PersonalLedger.active()).rawQuery(
      "SELECT deleted FROM personal_relay_rows WHERE id = 'debt-2'",
    );
    expect(tomb.single['deleted'], 1);
    expect(cache, isNotNull);
  });

  test('categories, trees, account types and rates: one op each', () async {
    final (svc, cache) = await seeded();
    final cat = await svc.addCategory(SpendingCategory(id: '', name: 'Food', nameAr: 'طعام'));
    expect(_change((await _ops()).last, 'personal_category')['k'], 'i');
    await svc.deleteCategory(cat.id);
    expect(_change((await _ops()).last, 'personal_category')['k'], 'd');

    await FinancialTreeStorage().saveTree(FinancialTree(id: 't1', name: 'Home', rootNodeId: 'n1', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    final tree = (await _ops()).last.single;
    expect(tree['t'], '_kv');
    expect(tree['id'], 'financial_trees_v1');

    PersonalAccountTypeStore.now = () => 77;
    await PersonalAccountTypeStore.save('bank-1', 'savings');
    expect((await _ops()).last, [
      {'t': '_acct', 'id': 'bank-1', 'k': 'u', 'data': {'t': 'savings', 'at': 77}},
    ]);

    await svc.addExchangeRate(fromCurrency: 'USD', toCurrency: 'SAR', rate: 3.75);
    await svc.addExchangeRate(fromCurrency: 'USD', toCurrency: 'SAR', rate: 3.8);
    final rates = (await _ops()).reversed.take(2).toList();
    expect(rates[0].single['data'], {'from': 'USD', 'to': 'SAR', 'rate': 3.8});
    expect(rates[1].single['data'], {'from': 'USD', 'to': 'SAR', 'rate': 3.75});
    expect(cache, isNotNull);
  });

  test('reset: one op deleting every row; a failed commit records nothing', () async {
    final (_, cache) = await seeded();
    await cache.wipeNamespaces([_ns]);
    final reset = (await _ops()).single;
    expect(reset.map((c) => '${c['t']}/${c['id']}/${c['k']}').toSet(), {
      'personal_bank_account/bank-1/d',
      'personal_debt/debt-1/d',
      'personal_debt/debt-2/d',
    });
    // Atomic with the write: a rolled back transaction leaves no op.
    final db = await PersonalLedger.active();
    final cap = PersonalRelayCapture.begin()!;
    await expectLater(
      db.transaction((tx) async {
        await cap.put(tx, 'personal_budget', 'b1', {'id': 'b1'});
        await cap.seal(tx);
        throw StateError('disk full');
      }),
      throwsStateError,
    );
    expect(await _ops(), hasLength(1));
  });
}
