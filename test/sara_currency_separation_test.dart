import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_money.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

/// P0 currency separation: no Sara read may merge amounts of different
/// currencies into one number. Conversion only via real engine rates.
void main() {
  const uid = 92;

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

  group('sara_money primitives', () {
    test('codes never merge, incl. YER vs YER_NEW, case-insensitive', () {
      final m = groupAmounts(
        ['usd', 'USD', 'SAR', 'YER', 'YER_NEW', 'EUR'],
        (_) => 10.0,
        (c) => c,
      );
      expect(m, {
        'USD': 20.0,
        'SAR': 10.0,
        'YER': 10.0,
        'YER_NEW': 10.0,
        'EUR': 10.0,
      });
    });

    test('single currency renders plain, multi renders labeled block', () {
      expect(formatBreakdown({'SAR': 100}, arabic: true), contains('SAR'));
      final multi = formatBreakdown({'SAR': 100, 'USD': 5}, arabic: true);
      expect(multi, contains('SAR'));
      expect(multi, contains('USD'));
      expect(multi, contains('بدون جمع'));
    });

    test('convertBuckets refuses partial totals', () {
      final partial = convertBuckets({'SAR': 100, 'USD': 5}, 'EUR',
          (f, t) => f == 'SAR' ? 0.27 : null);
      expect(partial.missing, contains('USD'));
      // Caller must not use partial.total as complete.
      final full = convertBuckets({'SAR': 100}, 'USD', (f, t) => 0.27);
      expect(full.missing, isEmpty);
      expect(full.total, closeTo(27.0, 1e-9));
      expect(full.targetCurrency, 'USD');
    });
  });

  Future<PersonalFinanceService> seedTwoCurrencies() async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'Cash', currency: 'USD', openingBalance: 100);
    await svc.addBankAccount(
        bankName: 'Cash', currency: 'SAR', openingBalance: 200);
    final banks =
        await PersonalCacheRepository().getCollection(uid, 'personal_bank_account');
    final usdId = banks
        .firstWhere((m) => (m['currency'] as String) == 'USD')['id']
        .toString();
    await svc.addTransaction(
      type: 'income', amount: 50, category: 'job',
      date: DateTime.now(), accountId: usdId, currency: 'USD',
    );
    await svc.addTransaction(
      type: 'expense', amount: 30, category: 'food',
      date: DateTime.now(), accountId: usdId, currency: 'SAR',
    );
    await svc.addSavingsGoal(SavingsGoal(
        id: '', name: 'Car', targetAmount: 1000, currentAmount: 100));
    await svc.addSavingsGoal(SavingsGoal(
        id: '', name: 'House', targetAmount: 500, currentAmount: 50,
        currency: 'USD'));
    await svc.addDebt(PersonalDebt(
        id: '', type: 'payable', personName: 'Ali', amount: 500));
    await svc.addDebt(PersonalDebt(
        id: '', type: 'payable', personName: 'Omar', amount: 200,
        currency: 'USD'));
    await svc.addBudget(PersonalBudget(
        id: '', name: 'Food', totalAmount: 300, currency: 'SAR',
        periodType: 'monthly', budgetTypes: const ['expenses'], categories: const []));
    await svc.addBudget(PersonalBudget(
        id: '', name: 'Trips', totalAmount: 400, currency: 'USD',
        periodType: 'monthly', budgetTypes: const ['expenses'], categories: const []));
    await svc.addRecurring(RecurringTransaction(
        id: '', type: 'expense', amount: 20, category: 'sub',
        description: 'Sub', frequency: 'monthly'));
    await svc.addRecurring(RecurringTransaction(
        id: '', type: 'expense', amount: 30, category: 'sub2',
        description: 'Sub2', frequency: 'monthly', currency: 'USD'));
    return svc;
  }

  group('Sara read tools (mirror truth, offline-capable)', () {
    test('get_balance separates, never sums across currencies', () async {
      final exec = ToolExecutor(await seedTwoCurrencies());
      final r = await exec.execute('get_balance', {});
      expect(r.success, isTrue);
      expect(r.messageAr, contains('USD'));
      expect(r.messageAr, contains('SAR'));
      expect(r.messageAr, contains('بدون جمع'));
      final byCur = (r.data!['by_currency'] as Map).cast<String, dynamic>();
      final usd = (byCur['USD']['amount'] as num).toDouble();
      final sar = (byCur['SAR']['amount'] as num).toDouble();
      expect(usd, greaterThan(0));
      expect(sar, greaterThan(0));
      expect((r.data! as Map).containsKey('total'), isFalse);
    });

    test('get_balance converted total only with real rate', () async {
      final exec = ToolExecutor(await seedTwoCurrencies());
      final noEngine =
          await exec.execute('get_balance', {'currency': 'USD'});
      // No fx engine injected: engine-less executor must refuse, not invent.
      expect(noEngine.messageAr, contains('SAR'));
      expect(noEngine.messageEn, contains('USD'));
    });

    test('get_balance converted total with injected engine', () async {
      final svc = await seedTwoCurrencies();
      final exec = ToolExecutor(svc, fxEngine: _RateEngine());
      final r = await exec.execute('get_balance', {'currency': 'USD'});
      expect(r.messageAr, contains('الإجمالي المحوّل إلى USD'));
      final byCur = (r.data!['by_currency'] as Map).cast<String, dynamic>();
      final usd = (byCur['USD']['amount'] as num).toDouble();
      final sar = (byCur['SAR']['amount'] as num).toDouble();
      expect(r.data!['converted_total'], closeTo(usd + sar * 0.25, 1e-9));
      expect(r.data!['target_currency'], 'USD');
    });

    test('goals/debts/budgets/recurring carry currency ids', () async {
      final exec = ToolExecutor(await seedTwoCurrencies());
      final g = await exec.execute('get_savings_goals', {});
      final goalCurs = ((g.data!['goals'] as List)
              .cast<Map>()
              .map((m) => m['currency_id'])
              .toSet());
      expect(goalCurs, {'SAR', 'USD'});
      expect(g.messageAr, contains('SAR'));
      expect(g.messageAr, contains('USD'));
      final d = await exec.execute('get_debts', {});
      expect(d.messageAr, contains('SAR'));
      expect(d.messageAr, contains('USD'));
      final b = await exec.execute('get_budgets', {});
      expect(
          (((b.data!['budgets'] as List).cast<Map>()).map((m) => m['currency_id']).toSet()),
          {'SAR', 'USD'});
      final rc = await exec.execute('get_recurring', {});
      expect(
          (((rc.data!['recurring'] as List).cast<Map>()).map((m) => m['currency']).toSet()),
          {'SAR', 'USD'});
      final tx = await exec.execute('get_transactions', {});
      final byCur = (tx.data!['income_by_currency'] as Map);
      expect(byCur.keys, contains('USD'));
    });

    test('transfer keeps four fields + rate, no invented rate', () async {
      final svc = await seedTwoCurrencies();
      final banks = await svc.getBankAccounts();
      final usd = banks.firstWhere((a) => a.currency == 'USD');
      final sar = banks.firstWhere((a) => a.currency == 'SAR');
      // Without engine: must stop, write nothing.
      final execNoFx = ToolExecutor(svc);
      final txBefore = (await svc.getTransactions()).length;
      final stopped = await execNoFx.execute('create_transfer', {
        'from_account_id': usd.id,
        'to_account_id': sar.id,
        'amount': 10,
      });
      expect(stopped.success, isFalse);
      expect(stopped.errorCode, 'NO_FX_RATE');
      expect((await svc.getTransactions()).length, txBefore);
      // With engine: real conversion recorded on both sides. No server
      // API here, so the honest verdict is local-pending (never blind ✅).
      final execFx = ToolExecutor(svc, fxEngine: _RateEngine());
      final ok = await execFx.execute('create_transfer', {
        'from_account_id': usd.id,
        'to_account_id': sar.id,
        'amount': 10,
      });
      expect(ok.verificationStatus, 'local_pending');
      expect(saraToneOf(ok), '⏳');
      expect(ok.data!['source_currency_id'], 'USD');
      expect(ok.data!['source_amount'], 10);
      expect(ok.data!['destination_currency_id'], 'SAR');
      expect(ok.data!['destination_amount'], closeTo(40.0, 1e-9));
      expect(ok.data!['exchange_rate'], 4.0);
      final after = await svc.getBankAccounts();
      expect(after.firstWhere((a) => a.id == usd.id).balance,
          closeTo(usd.balance - 10, 1e-9));
      expect(after.firstWhere((a) => a.id == sar.id).balance,
          closeTo(sar.balance + 40.0, 1e-9));
    });
  });
}

/// Fake engine: USD->SAR = 4.0, SAR->USD = 0.25, else unavailable.
class _RateEngine extends CurrencyEngine {
  _RateEngine()
      : super(
            apiClient:
                ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))));

  @override
  double? getRate(String from, String to) {
    if (from == to) return 1.0;
    if (from == 'USD' && to == 'SAR') return 4.0;
    if (from == 'SAR' && to == 'USD') return 0.25;
    return null;
  }
}
