import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fix 1 — reset keeps the cash currency set:
/// snapshot → wipe → re-ensure recreates the same currencies at zero,
/// while a manually removed currency stays deleted.
/// Fix 2 — accounts paint instantly: bankAccounts are published as soon as
/// THEIR OWN fetch resolves, never gated on txs/goals/debts (an empty
/// mirror in any of those stalls on a network fetch online yet fails fast
/// offline — the reported asymmetry).
void main() {
  const uid = 84;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
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
    svc.setUserId(uid);
    return svc;
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<void> seedCash(PersonalFinanceService svc) async {
    await svc.addBankAccount(bankName: 'كاش', currency: 'USD', openingBalance: 100);
    await svc.addBankAccount(bankName: 'كاش', currency: 'SAR', openingBalance: 200);
    await svc.addBankAccount(bankName: 'كاش', currency: 'YER_NEW', openingBalance: 300);
  }

  group('reset preserves cash currencies', () {
    test('snapshot sees all cash, recreate restores them at zero', () async {
      final svc = makeService();
      await seedCash(svc);

      final snap = await svc.snapshotCashCurrencies();
      expect(snap, {'USD', 'SAR', 'YER_NEW'});

      // Simulate the reset wipe (server rows + local mirror gone).
      await cleanDb();

      // Recreate exactly the snapshot, as _performReset does.
      await svc.clearCashVault();
      await svc.ensureCashAccounts(snap.toList(), enabled: snap);

      final after = await svc.getBankAccounts();
      final cash = after.where((a) => isCashAccount(a.bankName)).toList();
      expect(cash.map((a) => a.currency).toSet(), {'USD', 'SAR', 'YER_NEW'});
      expect(cash.fold<double>(0, (s, a) => s + a.balance), 0);
    });

    test('manually removed currency stays deleted across reset', () async {
      final svc = makeService();
      await seedCash(svc);
      await svc.removeCashCurrency('SAR');

      // Stash holds the removed balance until vault is cleared by reset.
      expect(await svc.takeStashedCashBalance('SAR'), isNotNull);

      final snap = await svc.snapshotCashCurrencies();
      expect(snap, {'USD', 'YER_NEW'});

      await cleanDb();
      await svc.clearCashVault();
      expect(await svc.takeStashedCashBalance('SAR'), isNull);
      await svc.ensureCashAccounts(snap.toList(), enabled: snap);

      final after = await svc.getBankAccounts();
      final codes =
          after.where((a) => isCashAccount(a.bankName)).map((a) => a.currency).toSet();
      expect(codes, {'USD', 'YER_NEW'});
      expect(codes.contains('SAR'), isFalse);
    });
  });

  group('instant banks paint', () {
    test('accounts publish without waiting for slow goals/debts', () async {
      final svc = _SlowGoalsService(
        apiClient: ApiClient(dio: Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:9',
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ))),
        cache: PersonalCacheRepository(),
      );
      svc.setUserId(uid);
      // Mirror has accounts (+txs); goals/debts mirrors are empty but their
      // fetch is artificially slow (slow online backend), not failing.
      await svc.addBankAccount(bankName: 'كاش', currency: 'USD', openingBalance: 500);

      final container = ProviderContainer(overrides: [
        personalFinanceServiceProvider.overrideWithValue(svc),
      ]);
      addTearDown(container.dispose);
      final fut = container.read(personalFinanceProvider.notifier).load();
      await Future.delayed(const Duration(milliseconds: 800));
      final mid = container.read(personalFinanceProvider);
      expect(mid.isLoading, isFalse);
      expect(mid.bankAccounts.length, 1,
          reason: 'cards must paint before the slow goals/debts fetch resolves');
      expect(mid.totalBalance, 500);
      await fut;
      final st = container.read(personalFinanceProvider);
      expect(st.bankAccounts.length, 1);
      expect(st.isLoading, isFalse);
    });
  });
}

/// Service whose goals/debts fetches hang (slow online backend) instead of
/// failing fast — reproduces the reported online delay deterministically.
class _SlowGoalsService extends PersonalFinanceService {
  _SlowGoalsService({required ApiClient apiClient, required PersonalCacheRepository cache})
      : super(apiClient: apiClient, cache: cache);

  @override
  Future<List<SavingsGoal>> getSavingsGoals() async {
    await Future.delayed(const Duration(seconds: 6));
    return [];
  }

  @override
  Future<List<PersonalDebt>> getDebts() async {
    await Future.delayed(const Duration(seconds: 6));
    return [];
  }
}
