import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Reproduces the reported bug end-to-end against the REAL service code:
/// offline goal contribution → offline delete of that transaction.
/// Expected: bank restored, goal credit removed, tx mirror gone, staged
/// INSERT cancelled, goal/bank UPDATEs staged with reverted values.
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
    // NOTE: never open/close the file directly — sqflite caches open DBs by
    // path, so closing our own handle would kill DatabaseHelper's handle too.
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  Future<List<Map<String, dynamic>>> queueOps() async {
    return DatabaseHelper.rawQuery('SELECT * FROM sync_queue ORDER BY id ASC');
  }

  setUp(() async => cleanDb());
  tearDown(() async {
    await cleanDb();
  });

  group('offline goal contribution then delete', () {    test('reverses goal + bank, purges tx mirror and cancels INSERT', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();

      // Seed mirrors as if previously pulled from the server.
      await cache.upsertItem(7, 'personal_bank_account', 'acc-1', {
        'id': 'acc-1', 'bank_name': 'TestBank', 'currency': 'SAR',
        'balance': 1000.0, 'is_active': true,
      });
      await cache.upsertItem(7, 'personal_savings_goal', 'goal-1', {
        'id': 'goal-1', 'name': 'G', 'target_amount': 5000.0,
        'current_amount': 500.0, 'currency': 'SAR',
      });

      // 1) Offline contribution of 100.
      await svc.contributeToGoal('goal-1', 100,
          bankAccountId: 'acc-1', clientOperationId: 'op-test-1');

      Future<Map<String, dynamic>> bank() =>
          _row(cache, 7, 'personal_bank_account', 'acc-1');
      Future<Map<String, dynamic>> goal() =>
          _row(cache, 7, 'personal_savings_goal', 'goal-1');
      expect((await bank())['balance'], 900.0);
      expect((await goal())['current_amount'], 600.0);

      // Find the staged tx id like the UI does (refresh from mirror).
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1);
      final txId = txs.first['id'].toString();

      var ops = await queueOps();
      final insertOps = ops
          .where((o) =>
              o['entity_type'] == 'personal_transaction' &&
              o['entity_id'] == txId &&
              o['operation'] == 'INSERT')
          .toList();
      expect(insertOps.length, 1, reason: 'contribution INSERT must be staged');

      // 2) Offline delete of that transaction.
      final ok = await svc.deleteTransaction(txId);
      expect(ok, isTrue);

      expect((await bank())['balance'], 1000.0,
          reason: 'bank balance must be restored');
      expect((await goal())['current_amount'], 500.0,
          reason: 'goal credit must be removed');
      final txsAfter = await cache.getCollection(7, 'personal_transaction');
      expect(txsAfter, isEmpty, reason: 'tx mirror must be gone');

      ops = await queueOps();
      final txOpsLeft = ops
          .where((o) =>
              o['entity_type'] == 'personal_transaction' &&
              o['entity_id'] == txId)
          .toList();
      expect(txOpsLeft, isEmpty,
          reason: 'staged INSERT must be cancelled so sync never replays it');

      // No absolute goal/bank balance fragments may be staged: when the
      // contribution had already synced, the server reverses the exact effects
      // from the DELETE operation replay; when it had NOT synced (this case)
      // the INSERT is cancelled and the server never saw the contribution at
      // all. Either way the derived state is never shipped as a frozen blob.
      final goalUpdates = ops
          .where((o) =>
              o['entity_type'] == 'personal_savings_goal' &&
              o['operation'] == 'UPDATE')
          .toList();
      expect(goalUpdates, isEmpty,
          reason: 'derived balances must be replayed, never staged as fragments');
    });

    test('namespace never flips mid-session and warm migrates FNV rows', () async {
      const realUser = 'ns-test-user-uuid-1234';
      final cache = PersonalCacheRepository();

      // Pre-warm fallback namespace (what a fresh provider uses).
      final fnv = PersonalCacheRepository.fnvNamespace(realUser);
      expect(fnv, isNot(0));

      // Write rows under the FNV namespace (simulates writes made before
      // the stable mapping resolved).
      await cache.upsertItem(fnv, 'personal_savings_goal', 'goal-ns', {
        'id': 'goal-ns', 'name': 'G', 'current_amount': 10.0,
      });

      // Warm (auth boundary): resolves stable id, migrates, caches.
      final stable = await cache.warmStableId(realUser);
      expect(stable, greaterThan(0));
      expect(PersonalCacheRepository.stableIdSync(realUser), stable,
          reason: 'after warm, sync reads must use the stable namespace');

      // FNV rows migrated into the stable namespace.
      final goals = await cache.getCollection(stable, 'personal_savings_goal');
      expect(goals.any((g) => g['id'] == 'goal-ns'), isTrue,
          reason: 'pre-warm FNV rows must move to the stable namespace');

      // A second "provider rebuild" sees the SAME namespace (no flip-flop).
      expect(PersonalCacheRepository.stableIdSync(realUser), stable);
      expect(PersonalCacheRepository.stableIdSync(realUser), stable);
    });
  });
}

Future<Map<String, dynamic>> _row(
    PersonalCacheRepository cache, int uid, String type, String id) async {
  final all = await cache.getCollection(uid, type);
  return Map<String, dynamic>.from(
      all.firstWhere((r) => (r['id']?.toString() ?? '') == id));
}
