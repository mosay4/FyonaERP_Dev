import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Goal completion flag must follow the REAL state in both directions:
/// contribute-to-complete sets it, and reversing (deleting) the
/// contribution that completed the goal must un-complete it again.
/// Amounts/conversion/contribution logic is untouched — only the flag.
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
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<String> seedAccount(PersonalFinanceService svc,
      {required String name, required double balance}) async {
    await svc.addBankAccount(
        bankName: name, currency: 'SAR', openingBalance: balance);
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_bank_account');
    return (all
            .firstWhere((r) => (r['bank_name']?.toString() ?? '') == name)['id']
            ?.toString() ??
        '');
  }

  Future<String> seedGoal(PersonalFinanceService svc,
      {required String name, required double target}) async {
    await svc.addSavingsGoal(SavingsGoal(
        id: '', name: name, targetAmount: target, currency: 'SAR'));
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_savings_goal');
    return (all
            .firstWhere((r) => (r['name']?.toString() ?? '') == name)['id']
            ?.toString() ??
        '');
  }

  Future<Map<String, dynamic>> mirrorGoal(String id) async {
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_savings_goal');
    return Map<String, dynamic>.from(
        all.firstWhere((r) => (r['id']?.toString() ?? '') == id));
  }

  Future<String> txIdForGoal(String goalId) async {
    final txs =
        await PersonalCacheRepository().getCollection(7, 'personal_transaction');
    return (txs
            .firstWhere((t) => (t['goal_id']?.toString() ?? '') == goalId)['id']
            ?.toString() ??
        '');
  }

  group('goal is_completed follows reality', () {
    test('complete then reverse returns to incomplete', () async {
      final svc = makeService();
      final accId = await seedAccount(svc, name: 'CashG', balance: 5000);
      final goalId =
          await seedGoal(svc, name: 'Car', target: 1000);

      await svc.contributeToGoal(goalId, 1000,
          currency: 'SAR', bankAccountId: accId);
      var goal = await mirrorGoal(goalId);
      expect(((goal['current_amount'] as num?)?.toDouble() ?? -1), 1000.0);
      expect(goal['is_completed'], isTrue);

      final txId = await txIdForGoal(goalId);
      expect(txId, isNotEmpty);
      expect(await svc.deleteTransaction(txId), isTrue);

      goal = await mirrorGoal(goalId);
      expect(((goal['current_amount'] as num?)?.toDouble() ?? -1), 0.0);
      expect(goal['is_completed'], isFalse,
          reason: 'reversing the completing contribution must un-complete');
    });

    test('partial contribution never completes, delete stays incomplete',
        () async {
      final svc = makeService();
      final accId = await seedAccount(svc, name: 'CashP', balance: 5000);
      final goalId =
          await seedGoal(svc, name: 'Trip', target: 1000);

      await svc.contributeToGoal(goalId, 400,
          currency: 'SAR', bankAccountId: accId);
      var goal = await mirrorGoal(goalId);
      expect(((goal['current_amount'] as num?)?.toDouble() ?? -1), 400.0);
      expect(goal['is_completed'], isFalse);

      final txId = await txIdForGoal(goalId);
      expect(await svc.deleteTransaction(txId), isTrue);
      goal = await mirrorGoal(goalId);
      expect(((goal['current_amount'] as num?)?.toDouble() ?? -1), 0.0);
      expect(goal['is_completed'], isFalse);
    });
  });
}
