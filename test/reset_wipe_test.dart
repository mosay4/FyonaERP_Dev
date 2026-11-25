import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

/// Verification for the reset-account wipe (fix 1).
///
/// Root cause it guards: `_performReset` used to compute the wipe namespace
/// as `int.tryParse(userId) ?? userId.hashCode.abs()` — but live data lives
/// under the canonical stable namespace, so the wipe deleted nothing while
/// transactions visibly survived. The wipe below mirrors `_performReset`
/// exactly (stable + FNV namespaces).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const realUserId = 'a47cf941-6376-4df2-81c3-20638e60865b';

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache');
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    await (await testLedger()).rawDelete('DELETE FROM personal_transactions');
    await (await testLedger()).rawDelete('DELETE FROM personal_bank_accounts');
    await (await testLedger()).rawDelete('DELETE FROM savings_goals');
    await DatabaseHelper.rawDelete('DELETE FROM stable_user_ids');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<int> seedLiveData() async {
    final cache = PersonalCacheRepository();
    // Warmed canonical namespace, exactly like production auth boundaries.
    final stableNs = await cache.warmStableId(realUserId);
    await cache.upsertItem(stableNs, 'personal_bank_account', 'bank-w', {
      'id': 'bank-w',
      'bank_name': 'W',
      'balance': 1000.0,
    });
    await cache.upsertItem(stableNs, 'personal_transaction', 'tx-w', {
      'id': 'tx-w',
      'tx_type': 'expense',
      'amount': 50.0,
      'currency': 'SAR',
      'category': 'Food',
    });
    await cache.upsertItem(stableNs, 'personal_savings_goal', 'goal-w', {
      'id': 'goal-w',
      'name': 'G',
      'current_amount': 10.0,
    });
    await (await testLedger()).rawInsert(
      'INSERT INTO personal_transactions '
      '(user_id, tx_type, amount, category) VALUES (?, ?, ?, ?)',
      [stableNs, 'expense', 50.0, 'Food'],
    );
    await SyncOutbox.enqueue(
      tableName: 'personal_transaction',
      entityType: 'personal_transaction',
      entityId: 'tx-w',
      operation: 'UPDATE',
      data: {'id': 'tx-w', 'category': 'Food'},
      userId: stableNs,
    );
    return stableNs;
  }

  /// The wipe exactly as `_performReset` performs it.
  Future<void> performWipe(String userId) async {
    final stableNs = PersonalCacheRepository.stableIdSync(userId);
    final fnvNs = PersonalCacheRepository.fnvNamespace(userId);
    final repo = PersonalRepository();
    await repo.resetAllData(stableNs);
    if (fnvNs != stableNs) {
      await repo.resetAllData(fnvNs);
    }
    await (await testLedger()).rawDelete(
      'DELETE FROM personal_entity_cache WHERE user_id IN (?, ?)',
      [stableNs, fnvNs],
    );
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  Future<int> tableCount(String table, [String? where]) async {
    final rows = await (await testLedger()).rawQuery(
        'SELECT COUNT(*) AS c FROM $table${where == null ? '' : ' WHERE $where'}');
    return ((rows.first['c'] as num?)?.toInt() ?? 0);
  }

  group('reset wipe', () {
    test('old hashCode wipe misses live rows (root cause, documented)',
        () async {
      await seedLiveData();
      final userIdInt =
          int.tryParse(realUserId) ?? realUserId.hashCode.abs();
      await (await testLedger()).rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [userIdInt],
      );
      final left = await tableCount('personal_entity_cache');
      expect(left, 3,
          reason: 'old wipe must miss: proves the reported bug mechanism');
    });

    test('fixed wipe zeroes everything including transactions', () async {
      final stableNs = await seedLiveData();
      expect(await tableCount('personal_entity_cache'), 3);
      expect(await tableCount('personal_transactions'), 1);
      expect(await tableCount('sync_queue'), 1);

      await performWipe(realUserId);

      expect(await tableCount('personal_entity_cache'), 0,
          reason: 'mirror must be empty');
      expect(await tableCount('personal_transactions'), 0,
          reason: 'legacy transactions must be gone');
      expect(await tableCount('personal_bank_accounts'), 0);
      expect(await tableCount('savings_goals'), 0);
      expect(await tableCount('sync_queue'), 0,
          reason: 'staged ops must be cancelled');
      expect(stableNs, greaterThan(0));
    });

    test('service reads empty after wipe (what the UI shows)', () async {
      await seedLiveData();
      await performWipe(realUserId);

      final dio = Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:9',
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
      ));
      final svc = PersonalFinanceService(
        apiClient: ApiClient(dio: dio),
        cache: PersonalCacheRepository(),
      );
      final cache = PersonalCacheRepository();
      final uid = await cache.warmStableId(realUserId);
      svc.setUserId(uid);

      // Empty mirror + dead network: reads return empty, never throw.
      expect(await svc.getTransactions(), isEmpty);
      expect(await svc.getBankAccounts(), isEmpty);
      expect(await svc.getSavingsGoals(), isEmpty);
    });
  });
}
