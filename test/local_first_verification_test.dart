import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local-First verification for the Personal section (TEST 1-4).
///
/// No real server is used: TEST 1 simulates a slow-but-reachable API to prove
/// writes never await it; TEST 2-4 use an unreachable endpoint (pure offline).
/// SyncEngine replay correctness itself is covered by the existing
/// `sync_delete_version_test.dart` suite (run separately).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final uuidRe = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  PersonalFinanceService makeService({Dio? dioOverride, int userId = 7}) {
    final dio = dioOverride ??
        Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:9',
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(userId);
    return svc;
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<List<Map<String, dynamic>>> outboxOps(
      {String? entityType, int? userId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (entityType != null) {
      where.add('entity_type = ?');
      args.add(entityType);
    }
    if (userId != null) {
      where.add('user_id = ?');
      args.add(userId);
    }
    final sql = where.isEmpty
        ? 'SELECT * FROM sync_queue ORDER BY id ASC'
        : 'SELECT * FROM sync_queue WHERE ${where.join(' AND ')} ORDER BY id ASC';
    return DatabaseHelper.rawQuery(sql, args);
  }

  // ═══════════════════════════════════════════════════════════════════
  // TEST 1 — Online: create appears instantly from Local DB, no API wait.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 1: online create is instant + background-syncable', () {
    test('addTransaction returns before a slow API responds, with zero API calls',
        () async {
      var apiCalls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          apiCalls++;
          // A slow-but-reachable server: Local-First must NOT wait for this.
          await Future<void>.delayed(const Duration(seconds: 5));
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'id': 'srv-1'},
          ));
        },
      ));
      final svc = makeService(dioOverride: dio);
      var syncRequested = false;
      svc.requestSync = () async {
        syncRequested = true;
      };
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-t1', {
        'id': 'acc-t1',
        'bank_name': 'T1Bank',
        'currency': 'SAR',
        'balance': 10000.0,
        'is_active': true,
      });

      final sw = Stopwatch()..start();
      final ok = await svc.addTransaction(
        type: 'expense',
        amount: 100,
        category: 'Food',
        date: DateTime.now(),
        accountId: 'acc-t1',
        currency: 'SAR',
      );
      sw.stop();

      expect(ok, isTrue, reason: 'local commit must succeed');
      expect(sw.elapsedMilliseconds, lessThan(4000),
          reason:
              'must return from Local DB before the 5s API delay (no await API)');
      expect(apiCalls, 0,
          reason: 'service must not call the API synchronously at all');

      // Visible instantly from Local DB.
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1, reason: 'tx must be in Local DB immediately');
      expect((txs.first['amount'] as num).toDouble(), 100.0);

      // Bank effect applied locally.
      final banks = await cache.getCollection(7, 'personal_bank_account');
      final bank = banks.firstWhere((a) => a['id'] == 'acc-t1');
      expect((bank['balance'] as num).toDouble(), 9900.0);

      // A replayable outbox op exists (idempotent).
      final ops = await outboxOps(entityType: 'personal_transaction');
      expect(ops.length, 1, reason: 'exactly one staged INSERT must exist');
      expect(ops.first['operation'], 'INSERT');
      expect(ops.first['status'], 'pending');
      final data =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(data['client_operation_id'], isNotNull,
          reason: 'idempotency key must be staged');
      expect(uuidRe.hasMatch(ops.first['entity_id'].toString()), isTrue,
          reason: 'client UUID must be preserved for sync');

      // Background sync was requested (SyncEngine's turn, not the UI's).
      expect(syncRequested, isTrue,
          reason: 'service must request background sync after local commit');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 2 — Offline create survives an app restart.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 2: offline create survives restart', () {
    test('tx + goal + debt persist in Local DB and outbox after reopen',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-t2', {
        'id': 'acc-t2',
        'bank_name': 'T2Bank',
        'currency': 'SAR',
        'balance': 5000.0,
        'is_active': true,
      });

      await svc.addTransaction(
        type: 'expense',
        amount: 250,
        category: 'Test',
        date: DateTime.now(),
        accountId: 'acc-t2',
        currency: 'SAR',
      );
      await svc.addSavingsGoal(SavingsGoal(
          id: '', name: 'G2', targetAmount: 1000, currency: 'SAR'));
      await svc.addDebt(PersonalDebt(
          id: '', type: 'payable', personName: 'P2', amount: 300));

      // Simulate an app kill + relaunch: drop the open handle, reopen the
      // same file through fresh instances.
      await DatabaseHelper.close();

      final freshCache = PersonalCacheRepository();
      final txs = await freshCache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1, reason: 'tx must survive restart');

      final goals = await freshCache.getCollection(7, 'personal_savings_goal');
      expect(goals.any((g) => g['name'] == 'G2'), isTrue,
          reason: 'goal must survive restart');

      final debts = await freshCache.getCollection(7, 'personal_debt');
      expect(debts.any((d) => d['person_name'] == 'P2'), isTrue,
          reason: 'debt must survive restart');

      final ops = await outboxOps(userId: 7);
      final pending =
          ops.where((o) => o['status'] == 'pending').toList();
      expect(pending.length, 3,
          reason: 'all three ops must still be pending after restart');
      // Every op keeps a unique idempotency identity for retry.
      final opIds = pending.map((o) => o['operation_id'].toString()).toSet();
      expect(opIds.length, 3, reason: 'no duplicate operation ids');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 3 — Two offline devices, same account shape: no loss, no dupes.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 3: multi-device offline ops', () {
    test('devices A+B each do several ops: all preserved, none duplicated',
        () async {
      const deviceA = 101;
      const deviceB = 102;
      final svcA = makeService(userId: deviceA);
      final svcB = makeService(userId: deviceB);
      final cache = PersonalCacheRepository();

      // Device A: bank + 2 txns + bank rename.
      await cache.upsertItem(deviceA, 'personal_bank_account', 'bank-a', {
        'id': 'bank-a',
        'bank_name': 'BankA',
        'currency': 'SAR',
        'balance': 9000.0,
        'is_active': true,
      });
      await svcA.addTransaction(
          type: 'expense',
          amount: 100,
          category: 'A1',
          date: DateTime.now(),
          accountId: 'bank-a',
          currency: 'SAR');
      await svcA.addTransaction(
          type: 'expense',
          amount: 200,
          category: 'A2',
          date: DateTime.now(),
          accountId: 'bank-a',
          currency: 'SAR');
      await svcA.updateBankAccount('bank-a', bankName: 'BankA-Renamed');

      // Device B: bank + 2 txns + goal create + goal rename.
      await cache.upsertItem(deviceB, 'personal_bank_account', 'bank-b', {
        'id': 'bank-b',
        'bank_name': 'BankB',
        'currency': 'SAR',
        'balance': 7000.0,
        'is_active': true,
      });
      await svcB.addTransaction(
          type: 'income',
          amount: 500,
          category: 'B1',
          date: DateTime.now(),
          accountId: 'bank-b',
          currency: 'SAR');
      await svcB.addTransaction(
          type: 'expense',
          amount: 50,
          category: 'B2',
          date: DateTime.now(),
          accountId: 'bank-b',
          currency: 'SAR');
      await svcB.addSavingsGoal(
          SavingsGoal(id: '', name: 'GB', targetAmount: 2000));
      final goalsB = await cache.getCollection(deviceB, 'personal_savings_goal');
      final goalBId = goalsB.first['id'].toString();
      await svcB.updateSavingsGoal(SavingsGoal(
          id: goalBId, name: 'GB-Renamed', targetAmount: 2000));

      // No loss: each device sees exactly its own rows (user isolation).
      final txsA = await cache.getCollection(deviceA, 'personal_transaction');
      final txsB = await cache.getCollection(deviceB, 'personal_transaction');
      expect(txsA.length, 2, reason: 'device A keeps both txns');
      expect(txsB.length, 2, reason: 'device B keeps both txns');

      // No duplication: every staged op has a unique id + op id.
      final allOps = await outboxOps();
      final entityIds = allOps.map((o) => o['entity_id'].toString()).toList();
      final opIds = allOps.map((o) => o['operation_id'].toString()).toList();
      expect(opIds.toSet().length, opIds.length,
          reason: 'operation ids must be unique (idempotent retry safe)');
      // UPDATE ops carry __changed (only-touched-fields replay).
      final updates =
          allOps.where((o) => o['operation'] == 'UPDATE').toList();
      expect(updates.isNotEmpty, isTrue);
      for (final u in updates) {
        final data = jsonDecode(u['data'] as String) as Map<String, dynamic>;
        expect(data['__changed'], isList,
            reason: 'every UPDATE must record __changed');
        expect((data['__changed'] as List).isNotEmpty, isTrue);
      }
      // Spot-check: bank rename only touched bank_name.
      final bankUpd = updates.firstWhere((o) =>
          o['entity_type'] == 'personal_bank_account' &&
          o['entity_id'] == 'bank-a');
      final bankData =
          jsonDecode(bankUpd['data'] as String) as Map<String, dynamic>;
      expect(bankData['__changed'], ['bank_name']);

      // Client-created entities keep server-valid UUIDs (sync replays them
      // as-is). Seeded rows simulate previously-synced server rows, so only
      // INSERT ops are required to carry fresh UUIDs.
      final inserts =
          allOps.where((o) => o['operation'] == 'INSERT').toList();
      expect(inserts.isNotEmpty, isTrue);
      for (final ins in inserts) {
        final e = ins['entity_id'].toString();
        expect(uuidRe.hasMatch(e), isTrue, reason: 'bad entity id: $e');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 4 — Offline-created entity syncs, then update + delete work.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 4: offline-created entity then update/delete', () {
    Future<String> simulateServerSync(
        PersonalCacheRepository cache, String entityType, String name) async {
      final rows = await cache.getCollection(7, entityType);
      final row = rows.firstWhere((r) =>
          (r['bank_name']?.toString() ??
              r['name']?.toString() ??
              r['person_name']?.toString()) ==
          name);
      final id = row['id'].toString();
      // What a successful SyncEngine push + pull leaves behind: a versioned
      // mirror row and no pending ops for the entity.
      await cache.upsertItem(7, entityType, id, {
        ...row,
        '_sync_version': 3,
      });
      await DatabaseHelper.rawDelete(
        'DELETE FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        [entityType, id],
      );
      return id;
    }

    test('bank: create offline, sync, update (versioned), delete (versioned)',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await svc.addBankAccount(
          bankName: 'B4', currency: 'SAR', openingBalance: 5000);
      var id = await simulateServerSync(cache, 'personal_bank_account', 'B4');

      await svc.updateBankAccount(id, bankName: 'B4-Renamed');
      var ops = await outboxOps(entityType: 'personal_bank_account');
      expect(ops.length, 1);
      expect(ops.first['operation'], 'UPDATE');
      expect(ops.first['base_version'], 3,
          reason: 'UPDATE must carry the synced base_version');
      final updData =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(updData['__changed'], ['bank_name']);

      await svc.deleteBankAccount(id);
      ops = await outboxOps(entityType: 'personal_bank_account');
      expect(ops.length, 1, reason: 'UPDATE must be superseded by DELETE');
      expect(ops.first['operation'], 'DELETE');
      expect(ops.first['base_version'], 3);
      final remaining =
          await cache.getCollection(7, 'personal_bank_account');
      expect(remaining.where((a) => a['id'] == id), isEmpty,
          reason: 'mirror row must be gone');
    });

    test('goal + debt: create offline, sync, update, delete', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await svc.addSavingsGoal(
          SavingsGoal(id: '', name: 'G4', targetAmount: 4000));
      await svc.addDebt(PersonalDebt(
          id: '', type: 'payable', personName: 'P4', amount: 900));

      final goalId = await simulateServerSync(cache, 'personal_savings_goal', 'G4');
      final debtId = await simulateServerSync(cache, 'personal_debt', 'P4');

      await svc.updateSavingsGoal(
          SavingsGoal(id: goalId, name: 'G4-Renamed', targetAmount: 4000));
      var goalOps = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_savings_goal', goalId],
      );
      expect(goalOps.length, 1);
      expect(goalOps.first['operation'], 'UPDATE');
      expect(goalOps.first['base_version'], 3);

      await svc.deleteSavingsGoal(goalId);
      goalOps = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_savings_goal', goalId],
      );
      expect(goalOps.length, 1);
      expect(goalOps.first['operation'], 'DELETE');

      await svc.updateDebt(PersonalDebt(
          id: debtId, type: 'payable', personName: 'P4-Renamed', amount: 900));
      var debtOps = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_debt', debtId],
      );
      expect(debtOps.length, 1);
      expect(debtOps.first['operation'], 'UPDATE');

      await svc.deleteDebt(debtId);
      debtOps = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_debt', debtId],
      );
      expect(debtOps.length, 1);
      expect(debtOps.first['operation'], 'DELETE');
    });

    test('transaction: create offline, sync, update, delete', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-t4', {
        'id': 'acc-t4',
        'bank_name': 'T4Bank',
        'currency': 'SAR',
        'balance': 6000.0,
        'is_active': true,
      });
      await svc.addTransaction(
        type: 'expense',
        amount: 400,
        category: 'T4',
        date: DateTime.now(),
        accountId: 'acc-t4',
        currency: 'SAR',
      );
      var txs = await cache.getCollection(7, 'personal_transaction');
      final txId = txs.first['id'].toString();

      // Simulate sync of the INSERT.
      await cache.upsertItem(7, 'personal_transaction', txId, {
        ...txs.first,
        '_sync_version': 2,
      });
      await DatabaseHelper.rawDelete(
        'DELETE FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_transaction', txId],
      );

      await svc.updateTransaction(id: txId, category: 'T4-Edited');
      var ops = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_transaction', txId],
      );
      expect(ops.length, 1);
      expect(ops.first['operation'], 'UPDATE');
      expect(ops.first['base_version'], 2);

      final ok = await svc.deleteTransaction(txId);
      expect(ok, isTrue);
      ops = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE entity_type = ? AND entity_id = ?',
        ['personal_transaction', txId],
      );
      expect(ops.length, 1);
      expect(ops.first['operation'], 'DELETE');
      expect(ops.first['base_version'], 2);
      // Financial reversal applied locally.
      final banks = await cache.getCollection(7, 'personal_bank_account');
      final bank = banks.firstWhere((a) => a['id'] == 'acc-t4');
      expect((bank['balance'] as num).toDouble(), 6000.0,
          reason: 'bank must be restored after delete');
    });
  });
}
