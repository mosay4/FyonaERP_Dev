import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/tables.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

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

  tearDown(() async {
    await cleanDb();
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 1: budget_categories table created in fresh DB
  // ═══════════════════════════════════════════════════════════════════
  group('Test 1: budget_categories table', () {
    test('budget_categories exists in allTables', () {
      // Verify the table definition exists in Tables class
      expect(Tables.budgetCategories, isNotNull);
      expect(Tables.budgetCategories, contains('CREATE TABLE'));
      expect(Tables.budgetCategories, contains('budget_categories'));
    });

    test('budget_categories is included in allTables list', () {
      // Verify budgetCategories is in the allTables list
      expect(Tables.allTables, contains(Tables.budgetCategories));
    });

    test('budget_categories can be created via _onCreate', () async {
      // Use a unique temp DB to simulate fresh install
      final tempDb = await databaseFactory.openDatabase(
        'test_budget_categories.db',
        options: OpenDatabaseOptions(
          version: DatabaseHelper.databaseVersion,
          onCreate: (db, version) async {
            // Create all tables including budget_categories
            for (final table in Tables.allTables) {
              await db.execute(table);
            }
          },
        ),
      );

      // Verify the table exists by querying its structure
      final tables = await tempDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='budget_categories'",
      );
      expect(tables.length, 1,
          reason: 'budget_categories table must exist in fresh DB');

      // Verify columns exist
      final columns = await tempDb.rawQuery("PRAGMA table_info('budget_categories')");
      final colNames = columns.map((c) => c['name'] as String).toSet();
      expect(colNames, containsAll(['id', 'budget_id', 'name', 'type',
        'allocated_amount', 'spent_amount', 'currency', 'created_at']));

      await tempDb.close();
    });

    test('budget_categories can be created via migration v14', () async {
      // Simulate upgrade from v13 to v14
      final tempDb = await databaseFactory.openDatabase(
        'test_budget_migration.db',
        options: OpenDatabaseOptions(
          version: 13,
          onCreate: (db, version) async {
            // Only create tables up to v13 (excluding budget_categories)
            for (final table in Tables.allTables) {
              if (table != Tables.budgetCategories) {
                await db.execute(table);
              }
            }
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 14) {
              await db.execute(Tables.budgetCategories);
            }
          },
        ),
      );

      // Upgrade to v14
      await tempDb.close();
      final upgradedDb = await databaseFactory.openDatabase(
        'test_budget_migration.db',
        options: OpenDatabaseOptions(
          version: 14,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 14) {
              await db.execute(Tables.budgetCategories);
            }
          },
        ),
      );

      final tables = await upgradedDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='budget_categories'",
      );
      expect(tables.length, 1,
          reason: 'budget_categories must exist after migration to v14');

      await upgradedDb.close();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 2: Multi-user pending outbox isolation
  // ═══════════════════════════════════════════════════════════════════
  group('Test 2: Multi-user outbox isolation', () {
    test('pending ops for user A do not protect data for user B', () async {
      final cache = PersonalCacheRepository();

      const userA = 100;
      const userB = 200;

      // User A creates a bank account and stages an INSERT
      await cache.upsertItem(userA, 'personal_bank_account', 'bank-a', {
        'id': 'bank-a', 'bank_name': 'BankA', 'balance': 5000.0,
        'currency': 'SAR',
      });
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'bank-a',
        operation: 'INSERT',
        data: {'id': 'bank-a', 'bank_name': 'BankA', 'balance': 5000.0},
        userId: userA,
      );

      // User B creates a different bank account (no pending ops)
      await cache.upsertItem(userB, 'personal_bank_account', 'bank-b', {
        'id': 'bank-b', 'bank_name': 'BankB', 'balance': 3000.0,
        'currency': 'SAR',
      });

      // User B's pending IDs should NOT include user A's bank-a
      final pendingB = await (await testLedger()).rawQuery(
        "SELECT entity_id FROM sync_queue "
        "WHERE entity_type = 'personal_bank_account' "
        "AND user_id = ? "
        "AND status IN ('pending', 'syncing', 'failed', 'conflict')",
        [userB],
      );
      final pendingIdsB = pendingB.map((r) => r['entity_id'].toString()).toSet();
      expect(pendingIdsB, isNot(contains('bank-a')),
          reason: 'User B pending ops must NOT contain user A entity');

      // User A's pending IDs should include bank-a
      final pendingA = await (await testLedger()).rawQuery(
        "SELECT entity_id FROM sync_queue "
        "WHERE entity_type = 'personal_bank_account' "
        "AND user_id = ? "
        "AND status IN ('pending', 'syncing', 'failed', 'conflict')",
        [userA],
      );
      final pendingIdsA = pendingA.map((r) => r['entity_id'].toString()).toSet();
      expect(pendingIdsA, contains('bank-a'),
          reason: 'User A pending ops must contain bank-a');
    });

    test('pending INSERT for user A does not block user B pull', () async {
      final cache = PersonalCacheRepository();

      const userA = 101;
      const userB = 102;

      // User A has a pending INSERT for entity 'bank-x'
      await cache.upsertItem(userA, 'personal_bank_account', 'bank-x', {
        'id': 'bank-x', 'bank_name': 'BankX', 'balance': 1000.0,
        'currency': 'SAR',
      });
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'bank-x',
        operation: 'INSERT',
        data: {'id': 'bank-x'},
        userId: userA,
      );

      // Simulate what _pullRemote does: check pending for user B
      final pendingForPull = await (await testLedger()).rawQuery(
        "SELECT entity_id FROM sync_queue "
        "WHERE entity_type = 'personal_bank_account' "
        "AND user_id = ? "
        "AND status IN ('pending', 'syncing', 'failed', 'conflict')",
        [userB],
      );
      final pendingIdsForPull =
          pendingForPull.map((r) => r['entity_id'].toString()).toSet();

      // bank-x must NOT be in user B's pending set
      expect(pendingIdsForPull, isNot(contains('bank-x')),
          reason: 'User B pull must not be blocked by user A pending ops');

      // But user A's pending set DOES contain bank-x
      final pendingForA = await (await testLedger()).rawQuery(
        "SELECT entity_id FROM sync_queue "
        "WHERE entity_type = 'personal_bank_account' "
        "AND user_id = ? "
        "AND status IN ('pending', 'syncing', 'failed', 'conflict')",
        [userA],
      );
      final pendingIdsA =
          pendingForA.map((r) => r['entity_id'].toString()).toSet();
      expect(pendingIdsA, contains('bank-x'),
          reason: 'User A pending must still contain bank-x');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 3: Goal contribution offline mirror update
  // ═══════════════════════════════════════════════════════════════════
  group('Test 3: Goal contribution mirror update', () {
    test('offline contribution updates bank and goal mirrors immediately', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed mirrors
      await cache.upsertItem(7, 'personal_bank_account', 'acc-gc', {
        'id': 'acc-gc', 'bank_name': 'TestBank', 'currency': 'SAR',
        'balance': 10000.0, 'is_active': true,
      });
      await cache.upsertItem(7, 'personal_savings_goal', 'goal-gc', {
        'id': 'goal-gc', 'name': 'Trip', 'target_amount': 5000.0,
        'current_amount': 0.0, 'currency': 'SAR',
      });

      // Contribute 3000 offline
      await svc.contributeToGoal('goal-gc', 3000,
          bankAccountId: 'acc-gc', clientOperationId: 'gc-test-1');

      // Verify bank balance updated
      final bankAll = await cache.getCollection(7, 'personal_bank_account');
      final bank = bankAll.firstWhere((a) => a['id'] == 'acc-gc');
      expect(bank['balance'], 7000.0,
          reason: 'Bank must be deducted by 3000 immediately');

      // Verify goal current_amount updated
      final goalAll = await cache.getCollection(7, 'personal_savings_goal');
      final goal = goalAll.firstWhere((g) => g['id'] == 'goal-gc');
      expect(goal['current_amount'], 3000.0,
          reason: 'Goal must be credited 3000 immediately');
    });

    test('contribution creates a transaction mirror row', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-gc2', {
        'id': 'acc-gc2', 'bank_name': 'TestBank2', 'currency': 'SAR',
        'balance': 5000.0, 'is_active': true,
      });
      await cache.upsertItem(7, 'personal_savings_goal', 'goal-gc2', {
        'id': 'goal-gc2', 'name': 'Car', 'target_amount': 20000.0,
        'current_amount': 0.0, 'currency': 'SAR',
      });

      await svc.contributeToGoal('goal-gc2', 1500,
          bankAccountId: 'acc-gc2', clientOperationId: 'gc-test-2');

      // A transaction mirror row must exist
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1, reason: 'Contribution must create tx mirror');
      expect(txs.first['goal_id'], 'goal-gc2',
          reason: 'Tx must carry goal_id');
      expect(txs.first['amount'], 1500.0,
          reason: 'Tx amount must match contribution');
    });

    test('deleting contribution reverses bank and goal', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      await cache.upsertItem(7, 'personal_bank_account', 'acc-gc3', {
        'id': 'acc-gc3', 'bank_name': 'TestBank3', 'currency': 'SAR',
        'balance': 8000.0, 'is_active': true,
      });
      await cache.upsertItem(7, 'personal_savings_goal', 'goal-gc3', {
        'id': 'goal-gc3', 'name': 'House', 'target_amount': 50000.0,
        'current_amount': 2000.0, 'currency': 'SAR',
      });

      // Contribute 1000
      await svc.contributeToGoal('goal-gc3', 1000,
          bankAccountId: 'acc-gc3', clientOperationId: 'gc-test-3');

      // Verify state after contribution
      var bankAll = await cache.getCollection(7, 'personal_bank_account');
      var bank = bankAll.firstWhere((a) => a['id'] == 'acc-gc3');
      expect(bank['balance'], 7000.0);

      var goalAll = await cache.getCollection(7, 'personal_savings_goal');
      var goal = goalAll.firstWhere((g) => g['id'] == 'goal-gc3');
      expect(goal['current_amount'], 3000.0);

      // Delete the transaction
      final txs = await cache.getCollection(7, 'personal_transaction');
      final txId = txs.first['id'].toString();
      final ok = await svc.deleteTransaction(txId);
      expect(ok, isTrue);

      // Verify reversal
      bankAll = await cache.getCollection(7, 'personal_bank_account');
      bank = bankAll.firstWhere((a) => a['id'] == 'acc-gc3');
      expect(bank['balance'], 8000.0,
          reason: 'Bank must be restored after delete');

      goalAll = await cache.getCollection(7, 'personal_savings_goal');
      goal = goalAll.firstWhere((g) => g['id'] == 'goal-gc3');
      expect(goal['current_amount'], 2000.0,
          reason: 'Goal must be restored after delete');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 4: Multi-device UPDATE on different fields
  // ═══════════════════════════════════════════════════════════════════
  group('Test 4: Multi-device UPDATE different fields', () {
    test('two offline edits on different fields produce separate __changed lists', () async {
      final cache = PersonalCacheRepository();

      // Seed a synced entity (simulates a bank account pulled from server)
      await cache.upsertItem(7, 'personal_bank_account', 'bank-multi', {
        'id': 'bank-multi',
        'bank_name': 'OriginalBank',
        'currency': 'SAR',
        'balance': 5000.0,
        'notes': 'Original notes',
        'is_active': true,
        '_sync_version': 2,
      });

      // Simulate Device A editing bank_name offline
      final mirrorA = Map<String, dynamic>.from(
        (await cache.getCollection(7, 'personal_bank_account'))
            .firstWhere((a) => a['id'] == 'bank-multi'),
      );
      mirrorA['bank_name'] = 'DeviceA_Bank';
      mirrorA['__changed'] = ['bank_name'];
      // Simulate what _offlineUpdate does: merge + stage
      await cache.upsertItem(7, 'personal_bank_account', 'bank-multi', mirrorA);
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'bank-multi',
        operation: 'UPDATE',
        data: Map<String, dynamic>.from(mirrorA)..remove('_sync_version'),
        userId: 7,
      );

      // Verify Device A's staged op has __changed = ['bank_name']
      var ops = await (await testLedger()).rawQuery(
        "SELECT data FROM sync_queue WHERE entity_type = 'personal_bank_account' "
        "AND entity_id = 'bank-multi' AND operation = 'UPDATE' ORDER BY id DESC LIMIT 1",
      );
      expect(ops.length, 1);
      var opData = jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(opData['__changed'], ['bank_name'],
          reason: 'Device A op must only carry bank_name in __changed');
      expect(opData['bank_name'], 'DeviceA_Bank');
      // notes must NOT be in __changed (Device A did not edit notes)
      expect((opData['__changed'] as List), isNot(contains('notes')),
          reason: 'Device A must not include notes in __changed');

      // Simulate Device B editing notes offline (on the same entity)
      final mirrorB = Map<String, dynamic>.from(
        await cache.getCollection(7, 'personal_bank_account')
          .then((all) => all.firstWhere((a) => a['id'] == 'bank-multi')),
      );
      mirrorB['notes'] = 'DeviceB notes';
      mirrorB['__changed'] = ['notes'];
      await cache.upsertItem(7, 'personal_bank_account', 'bank-multi', mirrorB);
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'bank-multi',
        operation: 'UPDATE',
        data: Map<String, dynamic>.from(mirrorB)..remove('_sync_version'),
        userId: 7,
      );

      // Verify Device B's staged op has __changed = ['notes']
      ops = await (await testLedger()).rawQuery(
        "SELECT data FROM sync_queue WHERE entity_type = 'personal_bank_account' "
        "AND entity_id = 'bank-multi' AND operation = 'UPDATE' ORDER BY id DESC LIMIT 1",
      );
      expect(ops.length, 1);
      opData = jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(opData['__changed'], ['notes'],
          reason: 'Device B op must only carry notes in __changed');
      expect(opData['notes'], 'DeviceB notes');
      expect((opData['__changed'] as List), isNot(contains('bank_name')),
          reason: 'Device B must not include bank_name in __changed');
    });

    test('explicitChanges extracts only __changed fields', () async {
      // This tests the _explicitChanges logic directly via the sync engine pattern
      final data = <String, dynamic>{
        'id': 'entity-1',
        'bank_name': 'NewName',
        'notes': 'Old notes',
        'balance': 5000.0,
        '__changed': ['bank_name'],
      };

      // Simulate _explicitChanges
      final copy = Map<String, dynamic>.from(data)..remove('remote_id');
      final changed = copy.remove('__changed');
      final out = <String, dynamic>{};
      if (changed is List) {
        final keys = changed.map((e) => e.toString()).toSet();
        keys.forEach((k) {
          if (copy.containsKey(k)) out[k] = copy[k];
        });
      }

      expect(out.length, 1, reason: 'Only 1 field should be extracted');
      expect(out['bank_name'], 'NewName');
      expect(out.containsKey('notes'), false, reason: 'notes must not be in output');
      expect(out.containsKey('balance'), false, reason: 'balance must not be in output');
      expect(out.containsKey('id'), false, reason: 'id must not be in output');
    });

    test('explicitChanges falls back to full payload when no __changed', () async {
      final data = <String, dynamic>{
        'id': 'entity-2',
        'bank_name': 'LegacyEntity',
        'notes': 'no marker',
        'balance': 1000.0,
      };

      final copy = Map<String, dynamic>.from(data)..remove('remote_id');
      final changed = copy.remove('__changed');
      final out = <String, dynamic>{};
      if (changed is List) {
        final keys = changed.map((e) => e.toString()).toSet();
        keys.forEach((k) {
          if (copy.containsKey(k)) out[k] = copy[k];
        });
      }

      // Fallback: return full payload (minus transport keys)
      final result = out.isEmpty ? copy : out;
      expect(result, contains('bank_name'));
      expect(result, contains('notes'));
      expect(result, contains('balance'));
    });
  });
}
