import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_utils.dart';

/// Service wrapper that delays exactly ONE transactions read: it models a
/// slow load() started on a slow network whose snapshot resolves with
/// PRE-ADD data after the user already added (and saw) the new income.
class _SlowFirstTxReadService extends PersonalFinanceService {
  bool slowNextTxRead = false;

  _SlowFirstTxReadService(
      {required super.apiClient, required super.cache});

  @override
  Future<List<PersonalTransaction>> getTransactions(
      {String? accountId, int month = 0, int year = 0}) {
    if (slowNextTxRead) {
      slowNextTxRead = false;
      return Future.delayed(
        const Duration(seconds: 2),
        () => super.getTransactions(
            accountId: accountId, month: month, year: year),
      );
    }
    return super.getTransactions(
        accountId: accountId, month: month, year: year);
  }
}

/// Regression test for the reported bug: an income added while ONLINE
/// vanished right after adding ("suddenly deleted") and only reappeared
/// after manual refreshes. Root cause: a slow in-flight load() (slowed by
/// network fetches that only happen online) published its pre-add snapshot
/// AFTER the fresh Phase-2 publish — last-write-wins with stale data.
/// The generation guard must drop the stale publish.
void main() {
  const uid = 99;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await ensureTestLocalization('ar');
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> cleanNs() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await DatabaseHelper.rawDelete(
        'DELETE FROM sync_queue WHERE user_id = ?', [uid.toString()]);
  }

  setUp(() async => cleanNs());
  tearDown(() async => cleanNs());

  test('stale in-flight load cannot wipe a fresh income publish', () async {
    final dio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:9',
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    final svc = _SlowFirstTxReadService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(uid);
    final container = ProviderContainer(overrides: [
      personalFinanceServiceProvider.overrideWithValue(svc),
      currencyEngineProvider.overrideWithValue(
        CurrencyEngine(apiClient: null),
      ),
    ]);
    addTearDown(container.dispose);

    await svc.addBankAccount(
        bankName: 'RaceBank', currency: 'SAR', openingBalance: 1000);
    final bank = (await svc.getBankAccounts())
        .firstWhere((x) => x.bankName == 'RaceBank');
    // Seed every collection the load() fans out to, so all sub-reads stay
    // on the instant local path (no network attempts at all in this test).
    await svc.addDebt(PersonalDebt(
      id: '',
      type: 'payable',
      personName: 'Ali',
      amount: 300,
      currency: 'SAR',
    ));
    await svc.addSavingsGoal(SavingsGoal(
        id: '', name: 'Car', targetAmount: 5000, currency: 'SAR'));
    await svc.addBudget(PersonalBudget(
        id: '',
        name: 'Monthly',
        periodType: 'monthly',
        totalAmount: 1000,
        currency: 'SAR'));

    final notifier = container.read(personalFinanceProvider.notifier);

    // A slow load starts first (page opened on a slow network): its
    // transactions read resolves with PRE-ADD data, 2s later.
    svc.slowNextTxRead = true;
    final slowLoad = notifier.load();
    await Future.delayed(const Duration(milliseconds: 200));

    // The user adds an income while the old load is still in flight.
    final err = await notifier.addTransaction(
      type: 'income',
      amount: 250,
      category: 'Salary',
      accountId: bank.id,
      currency: 'SAR',
      date: DateTime.now(),
    );
    expect(err, isNull);
    // Fresh publish already shows it (read-your-write).
    expect(
      notifier.state.transactions
          .any((t) => t.amount == 250 && t.type == 'income'),
      isTrue,
    );

    // The stale load lands afterwards — it must NOT wipe the fresh publish.
    await slowLoad;
    expect(
      notifier.state.transactions
          .any((t) => t.amount == 250 && t.type == 'income'),
      isTrue,
      reason: 'stale load must not overwrite fresh add',
    );
  });
}
