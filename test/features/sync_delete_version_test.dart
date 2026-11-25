import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:dio/dio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/personal_ledger_test_support.dart';

/// Tests that offline DELETE ops carry the correct base_version from
/// the mirror row's _sync_version, preventing version conflicts that
/// caused "resurrected" transactions on the next pull.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  PersonalFinanceService makeService() {
    final dio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:9',
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(7);
    return svc;
  }

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache');
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  group('DELETE ops carry correct baseVersion', () {
    test('deleteTransaction offline uses _sync_version from mirror', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed a mirror row as if it was pulled from the server with version=3
      // (e.g. the tx was created then updated twice via CRUD).
      await cache.upsertItem(7, 'personal_transaction', 'tx-synced-v3', {
        'id': 'tx-synced-v3',
        'tx_type': 'expense',
        'amount': 50.0,
        'currency': 'SAR',
        'category': 'Test',
        'bank_account_id': 'acc-1',
        '_sync_version': 3,
      });

      // Seed a bank account so the reversal can update it.
      await cache.upsertItem(7, 'personal_bank_account', 'acc-1', {
        'id': 'acc-1',
        'bank_name': 'TestBank',
        'currency': 'SAR',
        'balance': 1000.0,
        'is_active': true,
        '_sync_version': 5,
      });

      // Offline delete of the transaction.
      final ok = await svc.deleteTransaction('tx-synced-v3');
      expect(ok, isTrue);

      // Verify the tx mirror is gone.
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.where((t) => t['id'] == 'tx-synced-v3'), isEmpty);

      // Verify a DELETE op was staged with baseVersion = 3 (from _sync_version).
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND entity_id = 'tx-synced-v3' AND operation = 'DELETE'",
      );
      expect(ops.length, 1,
          reason: 'DELETE op must be staged for the synced transaction');
      expect(ops.first['base_version'], 3,
          reason: 'baseVersion must match the mirror _sync_version (3)');

      // The bank balance must NOT be staged as an absolute fragment: the
      // server applies balances by replaying the transaction DELETE (or any
      // other exact endpoint) atomically through the operation journal.
      final bankOps = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_bank_account' "
        "AND entity_id = 'acc-1' ORDER BY id DESC LIMIT 1",
      );
      expect(bankOps, isEmpty,
          reason: 'no absolute balance fragment may be staged');
    });

    test('deleteTransaction offline uses baseVersion=0 when no _sync_version', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed a mirror row WITHOUT _sync_version (old data before the fix).
      await cache.upsertItem(7, 'personal_transaction', 'tx-old', {
        'id': 'tx-old',
        'tx_type': 'expense',
        'amount': 25.0,
        'currency': 'SAR',
        'category': 'Old',
      });

      final ok = await svc.deleteTransaction('tx-old');
      expect(ok, isTrue);

      // DELETE op should have baseVersion=0 (fallback).
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND entity_id = 'tx-old' AND operation = 'DELETE'",
      );
      expect(ops.length, 1);
      expect(ops.first['base_version'], 0,
          reason: 'baseVersion must be 0 when _sync_version is absent');
    });

    test('personal_transaction INSERT cancelled by delete, no INSERT left', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed a mirror row that was created offline (INSERT staged, never synced).
      await cache.upsertItem(7, 'personal_transaction', 'tx-offline', {
        'id': 'tx-offline',
        'tx_type': 'expense',
        'amount': 10.0,
        'currency': 'SAR',
        'category': 'Offline',
      });
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: 'tx-offline',
        operation: 'INSERT',
        data: {'tx_type': 'expense', 'amount': 10.0, 'currency': 'SAR'},
        userId: 7,
      );

      // Verify INSERT is staged.
      var insertOps = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_id = 'tx-offline' AND operation = 'INSERT'",
      );
      expect(insertOps.length, 1);

      // Delete the offline transaction.
      final ok = await svc.deleteTransaction('tx-offline');
      expect(ok, isTrue);

      // INSERT should be cancelled, and NO DELETE should be staged
      // (was never synced → nothing to delete server-side).
      final allOps = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_id = 'tx-offline'",
      );
      expect(allOps, isEmpty,
          reason: 'INSERT cancelled and no DELETE staged for never-synced tx');
    });

    test('_purgeLocalTx does not interfere with concurrent DELETE staging', () async {      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed a synced transaction with _sync_version=2.
      await cache.upsertItem(7, 'personal_transaction', 'tx-purge-test', {
        'id': 'tx-purge-test',
        'tx_type': 'income',
        'amount': 100.0,
        'currency': 'SAR',
        'category': 'Salary',
        'bank_account_id': 'acc-2',
        '_sync_version': 2,
      });
      await cache.upsertItem(7, 'personal_bank_account', 'acc-2', {
        'id': 'acc-2',
        'bank_name': 'Bank2',
        'currency': 'SAR',
        'balance': 500.0,
        'is_active': true,
        '_sync_version': 4,
      });

      // Stage an unrelated UPDATE for the same entity (simulates a stale op).
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: 'tx-purge-test',
        operation: 'UPDATE',
        data: {'category': 'StaleUpdate'},
        userId: 7,
      );

      // Delete → _purgeLocalTx cancels the stale UPDATE, then stages DELETE.
      final ok = await svc.deleteTransaction('tx-purge-test');
      expect(ok, isTrue);

      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_id = 'tx-purge-test'",
      );
      // Should have only the DELETE, not the stale UPDATE.
      final deletes = ops.where((o) => o['operation'] == 'DELETE').toList();
      final updates = ops.where((o) => o['operation'] == 'UPDATE').toList();
      expect(deletes.length, 1, reason: 'DELETE must be staged');
      expect(updates, isEmpty, reason: 'stale UPDATE must be cancelled');
      expect(deletes.first['base_version'], 2,
          reason: 'DELETE baseVersion must be 2 from _sync_version');
    });

    test('offline update preserves _sync_version and stages versioned UPDATE',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed a synced transaction with _sync_version=4 (updated via CRUD twice).
      await cache.upsertItem(7, 'personal_transaction', 'tx-edit-v4', {
        'id': 'tx-edit-v4',
        'tx_type': 'expense',
        'amount': 30.0,
        'currency': 'SAR',
        'category': 'Food',
        '_sync_version': 4,
      });

      // Offline edit (API unreachable → _offlineUpdate path).
      await svc.updateTransaction(id: 'tx-edit-v4', category: 'Groceries');

      // Mirror must keep the version and show the edit.
      final txs = await cache.getCollection(7, 'personal_transaction');
      final row =
          txs.firstWhere((t) => t['id'] == 'tx-edit-v4');
      expect(row['category'], 'Groceries');
      expect(row['_sync_version'], 4,
          reason: 'offline edit must preserve _sync_version');

      // UPDATE op must carry baseVersion=4 (server will see version=5).
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND entity_id = 'tx-edit-v4' AND operation = 'UPDATE'",
      );
      expect(ops.length, 1, reason: 'UPDATE op must be staged');
      expect(ops.first['base_version'], 4,
          reason: 'UPDATE baseVersion must match _sync_version (4)');
    });

    test('offline edit then offline delete keeps version chain', () async {      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_transaction', 'tx-chain', {
        'id': 'tx-chain',
        'tx_type': 'expense',
        'amount': 20.0,
        'currency': 'SAR',
        'category': 'A',
        '_sync_version': 6,
      });

      // Edit offline, then delete offline before any sync.
      await svc.updateTransaction(id: 'tx-chain', category: 'B');
      final ok = await svc.deleteTransaction('tx-chain');
      expect(ok, isTrue);

      // The staged UPDATE is purged; DELETE carries version 6.
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_id = 'tx-chain'",
      );
      final deletes = ops.where((o) => o['operation'] == 'DELETE').toList();
      expect(deletes.length, 1);
      expect(deletes.first['base_version'], 6,
          reason: 'DELETE must carry the pre-edit _sync_version (6)');
    });

    test('offline partial update merges mirror and stages complete data',
        () async {      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Full synced row.
      await cache.upsertItem(7, 'personal_bank_account', 'acc-merge', {
        'id': 'acc-merge',
        'bank_name': 'MergeBank',
        'currency': 'SAR',
        'balance': 1000.0,
        'notes': 'keep me',
        'is_active': true,
        '_sync_version': 2,
      });

      // Partial offline edit (name only).
      await svc.updateBankAccount('acc-merge', bankName: 'Renamed');

      // Mirror must keep every other column.
      final all = await cache.getCollection(7, 'personal_bank_account');
      final row = all.firstWhere((a) => a['id'] == 'acc-merge');
      expect(row['bank_name'], 'Renamed');
      expect((row['balance'] as num).toDouble(), 1000.0,
          reason: 'merge must not wipe untouched columns');
      expect(row['notes'], 'keep me');
      expect(row['_sync_version'], 2);

      // Staged op must carry the complete row so the server upsert cannot
      // blank missing fields with defaults.
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_bank_account' "
        "AND entity_id = 'acc-merge' AND operation = 'UPDATE'",
      );
      expect(ops.length, 1);
      expect(ops.first['base_version'], 2);
    });
  });

  group('cross-currency goal contribution arithmetic (offline)', () {
    Future<double> bankBalance(PersonalCacheRepository cache) async {
      final all = await cache.getCollection(7, 'personal_bank_account');
      return (all.firstWhere((a) => a['id'] == 'acc-fx')['balance'] as num)
          .toDouble();
    }

    Future<double> goalCurrent(PersonalCacheRepository cache) async {
      final all = await cache.getCollection(7, 'personal_savings_goal');
      return (all.firstWhere((g) => g['id'] == 'goal-fx')['current_amount']
              as num)
          .toDouble();
    }

    setUp(() async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(7, 'personal_bank_account', 'acc-fx', {
        'id': 'acc-fx',
        'bank_name': 'AlKarimi',
        'currency': 'SAR',
        'balance': 10000.0,
        'is_active': true,
      });
      await cache.upsertItem(7, 'personal_savings_goal', 'goal-fx', {
        'id': 'goal-fx',
        'name': 'Car',
        'target_amount': 5000.0,
        'current_amount': 0.0,
        'currency': 'USD',
      });
    });

    test('bank deducts SOURCE amount, goal credited CONVERTED amount',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // 3000 SAR -> 800 USD (offline).
      await svc.contributeToGoal('goal-fx', 3000,
          goalAmount: 800, currency: 'SAR', bankAccountId: 'acc-fx');

      expect(await bankBalance(cache), 7000.0,
          reason: 'bank must deduct exactly 3000 SAR, not 800');
      expect(await goalCurrent(cache), 800.0,
          reason: 'goal must be credited 800 USD');

      // Staged tx must keep both legs for an exact reversal later.
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1);
      expect((txs.first['amount'] as num).toDouble(), 3000.0);
      expect((txs.first['goal_amount'] as num).toDouble(), 800.0);
    });

    test('deleting the contribution reverses stored originals exactly',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await svc.contributeToGoal('goal-fx', 3000,
          goalAmount: 800, currency: 'SAR', bankAccountId: 'acc-fx');
      final txs = await cache.getCollection(7, 'personal_transaction');
      final txId = txs.first['id'].toString();

      final ok = await svc.deleteTransaction(txId);
      expect(ok, isTrue);
      expect(await bankBalance(cache), 10000.0,
          reason: 'bank must return to exactly 10000');
      expect(await goalCurrent(cache), 0.0,
          reason: 'goal credit must be removed exactly');
    });

    test('re-contribution after delete deducts source amount again', () async {      final svc = makeService();
      final cache = PersonalCacheRepository();

      await svc.contributeToGoal('goal-fx', 3000,
          goalAmount: 800, currency: 'SAR', bankAccountId: 'acc-fx');
      var txs = await cache.getCollection(7, 'personal_transaction');
      await svc.deleteTransaction(txs.first['id'].toString());

      // 5000 SAR -> 1333.33 USD at a new rate.
      await svc.contributeToGoal('goal-fx', 5000,
          goalAmount: 1333.33, currency: 'SAR', bankAccountId: 'acc-fx');

      expect(await bankBalance(cache), closeTo(5000.0, 0.001),
          reason: '10000 - 5000 must hold regardless of FX rate');
      expect(await goalCurrent(cache), closeTo(1333.33, 0.001));
    });

    test('staged contribution op carries goal_id for server linkage', () async {
      final svc = makeService();

      await svc.contributeToGoal('goal-fx', 3000,
          goalAmount: 800, currency: 'SAR', bankAccountId: 'acc-fx');

      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND operation = 'INSERT'",
      );
      expect(ops.length, 1);
      final data =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(
        data['goal_id'],
        'goal-fx',
        reason:
            'sync payload must link the goal or delete cannot reverse it',
      );
      expect((data['amount'] as num).toDouble(), 3000.0);
      expect((data['goal_amount'] as num).toDouble(), 800.0);
    });
  });

    group('offline entity ids are server-valid UUIDs', () {    final uuidRe = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

    test('offline-created transaction id parses as UUID', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-uuid', {
        'id': 'acc-uuid',
        'bank_name': 'U',
        'currency': 'SAR',
        'balance': 5000.0,
        'is_active': true,
      });
      await svc.contributeToGoal('goal-uuid-x', 100,
          currency: 'SAR', bankAccountId: 'acc-uuid');

      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1);
      final id = txs.first['id'].toString();
      expect(uuidRe.hasMatch(id), isTrue,
          reason: 'offline id must be a valid UUID, got: $id');
      expect(id.replaceAll('-', '').length, 32);

      // The staged INSERT must reference the same valid id.
      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND operation = 'INSERT'",
      );
      expect(ops.length, 1);
      expect(ops.first['entity_id'].toString(), id);
    });

    test('v12 sanitize remaps malformed ids incl. JSON references', () async {
      const badAcc = '01a08c6d1e96-0000-4000-8000-1a12ce17388';
      const badTx = '02b08c6d1e96-0000-4000-8000-2b12ce17388';
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', badAcc, {
        'id': badAcc,
        'bank_name': 'Old',
        'currency': 'SAR',
        'balance': 100.0,
        'is_active': true,
      });
      await cache.upsertItem(7, 'personal_transaction', badTx, {
        'id': badTx,
        'tx_type': 'expense',
        'amount': 10.0,
        'currency': 'SAR',
        'bank_account_id': badAcc,
      });
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: badTx,
        operation: 'INSERT',
        data: {'amount': 10.0, 'bank_account_id': badAcc},
        userId: 7,
      );

      await DatabaseHelper.sanitizeMalformedEntityIds();

      final accs = await cache.getCollection(7, 'personal_bank_account');
      expect(accs.any((a) => a['id'] == badAcc), isFalse);
      final newAccId = accs.first['id'].toString();
      expect(uuidRe.hasMatch(newAccId), isTrue);

      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.any((t) => t['id'] == badTx), isFalse);
      final tx = txs.first;
      expect(uuidRe.hasMatch(tx['id'].toString()), isTrue);
      expect(tx['bank_account_id'].toString(), newAccId,
          reason: 'embedded FK reference must follow the remap');

      final ops = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction'",
      );
      expect(ops.length, 1);
      expect(ops.first['entity_id'].toString(), tx['id'].toString());
    });
  });

  group('recurring auto-execution sweep (offline)', () {
    Future<void> seedBank(PersonalCacheRepository cache) async {
      await cache.upsertItem(7, 'personal_bank_account', 'acc-recur', {
        'id': 'acc-recur',
        'bank_name': 'SweepBank',
        'currency': 'SAR',
        'balance': 1000.0,
        'is_active': true,
      });
    }

    Map<String, dynamic> dueRule(String id, DateTime nextDate) => {
          'id': id,
          'name': 'Rent',
          'tx_type': 'expense',
          'amount': 100.0,
          'currency': 'SAR',
          'category': 'إيجار',
          'frequency': 'monthly',
          'interval_value': 1,
          'next_run_date': nextDate.toIso8601String(),
          'account_type': 'fixed',
          'bank_account_id': 'acc-recur',
          'execution_type': 'auto',
          'is_active': true,
        };

    test('due fixed auto rule executes, stages tx and advances date',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await seedBank(cache);
      final yesterday =
          DateTime.now().subtract(const Duration(days: 1));
      await cache.upsertItem(
          7, 'personal_recurring_transaction', 'rt-due', dueRule('rt-due', yesterday));

      final executed = await svc.processDueRecurring();

      expect(executed.length, 1);
      expect(executed.first.id, 'rt-due');

      // Money moved locally.
      final accs = await cache.getCollection(7, 'personal_bank_account');
      final bal = (accs.firstWhere((a) => a['id'] == 'acc-recur')['balance'] as num)
          .toDouble();
      expect(bal, 900.0);

      // A transaction was staged.
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1);
      expect((txs.first['amount'] as num).toDouble(), 100.0);

      // Next occurrence advanced past yesterday.
      final rts =
          await cache.getCollection(7, 'personal_recurring_transaction');
      final next = DateTime.parse(
          rts.firstWhere((r) => r['id'] == 'rt-due')['next_run_date'].toString());
      expect(next.isAfter(yesterday), isTrue);
    });

    test('same-day re-sweep does not execute twice', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await seedBank(cache);
      final yesterday =
          DateTime.now().subtract(const Duration(days: 1));
      await cache.upsertItem(
          7, 'personal_recurring_transaction', 'rt-due', dueRule('rt-due', yesterday));

      expect((await svc.processDueRecurring()).length, 1);
      // Second sweep same day: lastExecutedAt guard stops a duplicate.
      expect(await svc.processDueRecurring(), isEmpty);

      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1, reason: 'no duplicate transaction staged');
    });

    test('future and inactive rules are left alone', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await seedBank(cache);
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await cache.upsertItem(7, 'personal_recurring_transaction', 'rt-future',
          dueRule('rt-future', tomorrow));
      final off = dueRule('rt-off', DateTime.now().subtract(const Duration(days: 2)));
      off['is_active'] = false;
      await cache.upsertItem(7, 'personal_recurring_transaction', 'rt-off', off);

      expect(await svc.processDueRecurring(), isEmpty);
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs, isEmpty);
    });
  });
}
