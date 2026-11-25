import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:convert';
import 'support/personal_ledger_test_support.dart';

/// REPRODUCTION for "tx edit/delete doesn't reach other devices":
/// device-1 stages a transaction UPDATE then DELETE offline (dead Dio),
/// the REAL SyncEngine replays them against a fake server that mimics the
/// real endpoints, and we assert every op leaves the queue (synced).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const userId = 7;
  final serverCalls = <String>[];
  final patchBodies = <Map<String, dynamic>>[];

  Dio makeDeadDio() => Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:9',
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
      ));

  Dio makeFakeServerDio() {
    final dio = Dio(BaseOptions(baseUrl: 'http://fake.local'));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        serverCalls.add('${options.method} ${options.path}');
        if (options.method == 'PATCH' &&
            options.data is Map<String, dynamic>) {
          patchBodies.add(Map<String, dynamic>.from(
              options.data as Map<String, dynamic>));
        }
        if (options.path.contains('sync/pull')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'success': true,
              'data': <String, dynamic>{
                'entities': <dynamic>[],
                'server_time': DateTime.now().toUtc().toIso8601String(),
              },
            },
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{},
        ));
      },
    ));
    return dio;
  }

  PersonalFinanceService makeService() {
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: makeDeadDio()),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(userId);
    return svc;
  }

  Future<(ProviderContainer, SyncEngine)> makeEngine() async {
    final container = ProviderContainer(overrides: [
      apiClientProvider
          .overrideWithValue(ApiClient(dio: makeFakeServerDio())),
      connectivityServiceProvider.overrideWithValue(
        ConnectivityService(debugOnline: true),
      ),
    ]);
    late Ref testRef;
    final probe = Provider((ref) {
      testRef = ref;
      return 0;
    });
    container.read(probe);
    final engine = SyncEngine(testRef, userIdOverride: userId);
    await engine.init();
    return (container, engine);
  }

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache');
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    await (await testLedger()).rawDelete('DELETE FROM sync_operation_log');
    await DatabaseHelper.rawDelete('DELETE FROM sync_cursor');
  }

  Future<List<Map<String, dynamic>>> queueRows() async =>
      (await testLedger()).rawQuery('SELECT * FROM sync_queue ORDER BY id ASC');

  Map<String, dynamic> _decodeOpData(dynamic raw) {
    if (raw == null) return const {};
    if (raw is Map<String, dynamic>) return raw;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw.toString()));
    } catch (_) {
      return const {};
    }
  }

  setUp(() async {
    await cleanDb();
    serverCalls.clear();
    patchBodies.clear();
  });
  tearDown(() async => cleanDb());

  Future<void> seedSyncedTx() async {
    final cache = PersonalCacheRepository();
    await cache.upsertItem(userId, 'personal_bank_account', 'acc-p', {
      'id': 'acc-p',
      'bank_name': 'P',
      'currency': 'SAR',
      'balance': 1000.0,
      'is_active': true,
      '_sync_version': 5,
    });
    await cache.upsertItem(userId, 'personal_transaction', 'tx-p', {
      'id': 'tx-p',
      'tx_type': 'expense',
      'amount': 50.0,
      'currency': 'SAR',
      'category': 'Food',
      'bank_account_id': 'acc-p',
      '_sync_version': 3,
    });
  }

  group('tx edit/delete propagation (device1 -> server)', () {
    test('offline UPDATE replays via PATCH and leaves the queue', () async {
      await seedSyncedTx();
      final svc = makeService();
      await svc.updateTransaction(id: 'tx-p', category: 'Groceries');

      var ops = await queueRows();
      expect(ops.length, 1, reason: 'UPDATE must be staged');
      expect(ops.first['operation'], 'UPDATE');

      final (container, engine) = await makeEngine();
      try {
        await engine.processQueue();
        ops = await queueRows();
        expect(ops, isEmpty,
            reason: 'UPDATE op must sync (else device2 never sees the edit)');
        expect(
          serverCalls.any((c) =>
              c.startsWith('PATCH') && c.contains('transactions/tx-p')),
          isTrue,
          reason: 'server must receive PATCH for the tx, got: $serverCalls',
        );
        // Standard entity road: only the user-touched field is replayed
        // (never a stale full row that could clobber the other device).
        expect(patchBodies.length, 1);
        expect(patchBodies.first.keys.toSet(), {'category'},
            reason:
                'PATCH body must carry only __changed fields, got: ${patchBodies.first.keys}');
        expect(patchBodies.first['category'], 'Groceries');
      } finally {
        engine.dispose();
        container.dispose();
      }
    });

    test('offline DELETE replays via DELETE and leaves the queue', () async {
      await seedSyncedTx();
      final svc = makeService();
      final ok = await svc.deleteTransaction('tx-p');
      expect(ok, isTrue);

      var ops = await queueRows();
      expect(ops.length, 1, reason: 'DELETE must be staged');
      expect(ops.first['operation'], 'DELETE');

      final (container, engine) = await makeEngine();
      try {
        await engine.processQueue();
        ops = await queueRows();
        expect(ops, isEmpty,
            reason: 'DELETE op must sync (else device2 never drops the tx)');
        expect(
          serverCalls.any((c) =>
              c.startsWith('DELETE') && c.contains('transactions/tx-p')),
          isTrue,
          reason: 'server must receive DELETE for the tx, got: $serverCalls',
        );
      } finally {
        engine.dispose();
        container.dispose();
      }
    });
  });

  Future<Map<String, dynamic>?> mirrorRow(String type, String id) async {
    final all = await PersonalCacheRepository().getCollection(userId, type);
    for (final r in all) {
      if ((r['id'] ?? '').toString() == id) return r;
    }
    return null;
  }

  group('tx edit propagation to the sections it moved (local)', () {
    // An edit must move EVERYTHING the original execution moved, offline
    // too: reverse what the old values did, then apply what the new ones do
    // — exactly what the server does with its PATCH delta.
    test('amount edit re-moves bank balance, goal credit and debt paid',
        () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-i', {
        'id': 'acc-i',
        'bank_name': 'P',
        'currency': 'SAR',
        'balance': 1100.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_savings_goal', 'goal-i', {
        'id': 'goal-i',
        'name': 'G',
        'target_amount': 1000.0,
        'current_amount': 300.0,
        'currency': 'SAR',
        '_sync_version': 2,
      });
      await cache.upsertItem(userId, 'personal_debt', 'debt-i', {
        'id': 'debt-i',
        'name': 'D',
        'amount': 100.0,
        'paid': 100.0,
        'remaining': 0.0,
        'is_paid': true,
        'status': 'paid',
        'currency': 'SAR',
        '_sync_version': 4,
      });
      await cache.upsertItem(userId, 'personal_transaction', 'tx-i', {
        'id': 'tx-i',
        'tx_type': 'income',
        'amount': 100.0,
        'currency': 'SAR',
        'category': 'Salary',
        'bank_account_id': 'acc-i',
        'goal_id': 'goal-i',
        'debt_id': 'debt-i',
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(id: 'tx-i', amount: 60.0);

      final acc = await mirrorRow('personal_bank_account', 'acc-i');
      expect(acc!['balance'], 1060.0,
          reason: '1100 - 100 (old income) + 60 (new income)');
      final goal = await mirrorRow('personal_savings_goal', 'goal-i');
      expect(goal!['current_amount'], 260.0,
          reason: '300 - 100 (old credit) + 60 (new credit)');
      final debt = await mirrorRow('personal_debt', 'debt-i');
      expect(debt!['paid'], 60.0, reason: '100 - 100 (old) + 60 (new)');
      expect(debt['remaining'], 40.0,
          reason: 'a debt paid 60 of 100 must show 40 left');
      expect(debt['is_paid'], isFalse,
          reason: 'reversing the full payment must un-pay the debt again');
      expect(debt['status'], 'active');
      expect((await mirrorRow('personal_transaction', 'tx-i'))!['amount'], 60.0);

      // Derived rows are NOT operations: only the tx UPDATE goes to the
      // outbox (the server derives the same effects from its PATCH).
      final ops = await queueRows();
      expect(ops.length, 1, reason: 'exactly one staged UPDATE, got: $ops');
      expect(ops.first['entity_type'], 'personal_transaction');
    });

    test('amount edit re-moves bank balance and budget spent', () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-x', {
        'id': 'acc-x',
        'bank_name': 'P',
        'currency': 'SAR',
        'balance': 900.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_budget', 'bud-x', {
        'id': 'bud-x',
        'name': 'Food',
        'amount': 500.0,
        'spent': 100.0,
        'currency': 'SAR',
        '_sync_version': 2,
      });
      await cache.upsertItem(userId, 'personal_transaction', 'tx-x', {
        'id': 'tx-x',
        'tx_type': 'expense',
        'amount': 100.0,
        'currency': 'SAR',
        'category': 'Food',
        'bank_account_id': 'acc-x',
        'budget_id': 'bud-x',
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(id: 'tx-x', amount: 60.0);

      final acc = await mirrorRow('personal_bank_account', 'acc-x');
      expect(acc!['balance'], 940.0,
          reason: '900 + 100 (old expense reversed) - 60 (new expense)');
      final bud = await mirrorRow('personal_budget', 'bud-x');
      expect(bud!['spent'], 60.0,
          reason: '100 - 100 (old expense) + 60 (new expense)');
      expect((await mirrorRow('personal_transaction', 'tx-x'))!['amount'], 60.0);
    });

    test(
        'goal contribution edit scales the stored same-currency credit '
        'without staging credit fields', () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-g', {
        'id': 'acc-g',
        'bank_name': 'P',
        'currency': 'USD',
        'balance': 1000.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_savings_goal', 'goal-g', {
        'id': 'goal-g',
        'name': 'G',
        'target_amount': 2000.0,
        'current_amount': 500.0,
        'currency': 'USD',
        '_sync_version': 2,
      });
      // Mirror shape of a real contribution: the credit is stored 1:1.
      await cache.upsertItem(userId, 'personal_transaction', 'tx-g', {
        'id': 'tx-g',
        'tx_type': 'expense',
        'amount': 500.0,
        'currency': 'USD',
        'category': 'Savings',
        'bank_account_id': 'acc-g',
        'goal_id': 'goal-g',
        'goal_amount': 500.0,
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(id: 'tx-g', amount: 1000.0);

      final goal = await mirrorRow('personal_savings_goal', 'goal-g');
      expect(goal!['current_amount'], 1000.0,
          reason: '500 - 500 (old credit) + 1000 (new credit)');
      final tx = await mirrorRow('personal_transaction', 'tx-g');
      expect(tx!['goal_amount'], 1000.0,
          reason: 'mirror credit follows the edit for exact future reversals');
      final ops = await queueRows();
      expect(ops.length, 1);
      final staged =
          Map<String, dynamic>.from(_decodeOpData(ops.first['data']));
      final changed = (staged['__changed'] as List?)
              ?.map((e) => e.toString())
              .toSet() ??
          const <String>{};
      expect(changed.contains('goal_amount'), isFalse,
          reason:
              'replay must carry only user fields (server owns credit), got: $changed');
    });

    test('receivable collection edit moves the bank and the debt forward',
        () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-r', {
        'id': 'acc-r',
        'bank_name': 'P',
        'currency': 'USD',
        'balance': 800.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_debt', 'debt-r', {
        'id': 'debt-r',
        'debt_type': 'receivable',
        'person_name': 'A',
        'amount': 1000.0,
        'paid': 500.0,
        'remaining': 500.0,
        'is_paid': false,
        'status': 'active',
        'currency': 'USD',
        '_sync_version': 4,
      });
      await cache.upsertItem(userId, 'personal_transaction', 'tx-r', {
        'id': 'tx-r',
        'tx_type': 'income',
        'amount': 500.0,
        'currency': 'USD',
        'category': 'Collect',
        'bank_account_id': 'acc-r',
        'debt_id': 'debt-r',
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(id: 'tx-r', amount: 1000.0);

      final acc = await mirrorRow('personal_bank_account', 'acc-r');
      expect(acc!['balance'], 1300.0,
          reason: '800 - 500 (old collection reversed) + 1000 (new)');
      final debt = await mirrorRow('personal_debt', 'debt-r');
      expect(debt!['paid'], 1000.0, reason: '500 - 500 + 1000');
      expect(debt['remaining'], 0.0);
      expect(debt['is_paid'], isTrue);
      expect(debt['status'], 'paid');
    });

    test('budget category move keeps the budget and shifts spent by the delta',
        () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-c', {
        'id': 'acc-c',
        'bank_name': 'P',
        'currency': 'SAR',
        'balance': 900.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_budget', 'bud-c', {
        'id': 'bud-c',
        'name': 'Monthly',
        'amount': 500.0,
        'spent': 100.0,
        'currency': 'SAR',
        '_sync_version': 2,
      });
      await cache.upsertItem(userId, 'personal_transaction', 'tx-c', {
        'id': 'tx-c',
        'tx_type': 'expense',
        'amount': 100.0,
        'currency': 'SAR',
        'category': 'Food',
        'bank_account_id': 'acc-c',
        'budget_id': 'bud-c',
        'budget_category_id': 'cat-food',
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(
          id: 'tx-c', amount: 60.0, budgetCategoryId: 'cat-ride');

      final tx = await mirrorRow('personal_transaction', 'tx-c');
      expect(tx!['budget_id'], 'bud-c', reason: 'same budget, never switched');
      expect(tx['budget_category_id'], 'cat-ride');
      final bud = await mirrorRow('personal_budget', 'bud-c');
      expect(bud!['spent'], 60.0, reason: '100 - 100 + 60');
    });

    test('stale server rows never overwrite guarded linked sections',
        () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(userId, 'personal_bank_account', 'acc-s', {
        'id': 'acc-s',
        'bank_name': 'P',
        'currency': 'USD',
        'balance': 1200.0,
        'is_active': true,
        '_sync_version': 5,
      });
      await cache.upsertItem(userId, 'personal_debt', 'debt-s', {
        'id': 'debt-s',
        'debt_type': 'receivable',
        'person_name': 'A',
        'amount': 1000.0,
        'paid': 500.0,
        'remaining': 500.0,
        'is_paid': false,
        'status': 'active',
        'currency': 'USD',
        '_sync_version': 4,
      });
      await cache.upsertItem(userId, 'personal_transaction', 'tx-s', {
        'id': 'tx-s',
        'tx_type': 'income',
        'amount': 500.0,
        'currency': 'USD',
        'category': 'Collect',
        'bank_account_id': 'acc-s',
        'debt_id': 'debt-s',
        '_sync_version': 3,
      });

      final svc = makeService();
      await svc.updateTransaction(id: 'tx-s', amount: 1000.0);

      // A background snapshot that started after the edit still carries the
      // pre-edit server values: the guarded local rows must win.
      final staleDebt = [
        {
          'id': 'debt-s',
          'debt_type': 'receivable',
          'person_name': 'A',
          'amount': 1000.0,
          'paid': 500.0,
          'remaining': 500.0,
          'is_paid': false,
          'status': 'active',
          'currency': 'USD',
        }
      ];
      final merged =
          await cache.mergePendingInto(userId, 'personal_debt', staleDebt);
      expect(merged.length, 1);
      expect(merged.first['paid'], 1000.0,
          reason: 'unconfirmed linked edit is local truth until it confirms');
      final linked =
          await cache.pendingTransactionLinkedIds(userId);
      expect(linked['personal_debt'], contains('debt-s'));
      expect(linked['personal_bank_account'], contains('acc-s'));
    });
  });
}
