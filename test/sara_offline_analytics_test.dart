import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/offline/offline_sara.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'support/personal_ledger_test_support.dart';

/// P1 offline analytics: OfflineSara answers analytical queries from LOCAL
/// data only (same services the UI uses) — per-currency, real names, and an
/// honest insufficient-data message when empty. Never server-confirmed.
void main() {
  const uid = 93;

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
    await (await testLedger()).rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  final probeProvider = Provider<Ref>((ref) => ref);

  Future<String?> ask(PersonalFinanceService svc, String q) async {
    final container = ProviderContainer(overrides: [
      personalFinanceServiceProvider.overrideWithValue(svc),
    ]);
    addTearDown(container.dispose);
    final ref = container.read(probeProvider);
    return OfflineSara.answer(ref: ref, query: q);
  }

  Future<PersonalFinanceService> seedAnalytics() async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'الراجحي', currency: 'SAR', openingBalance: 10000);
    final banks = await svc.getBankAccounts();
    final accId = banks.firstWhere((b) => b.currency == 'SAR').id;
    final now = DateTime.now();
    await svc.addTransaction(
        type: 'income', amount: 8000, category: 'راتب',
        description: 'راتب مايو', date: now, accountId: accId, currency: 'SAR');
    await svc.addTransaction(
        type: 'expense', amount: 400, category: 'طعام',
        description: 'عشاء عائلي', date: now, accountId: accId, currency: 'SAR');
    await svc.addTransaction(
        type: 'expense', amount: 200, category: 'طعام',
        description: 'غداء عمل', date: now, accountId: accId, currency: 'SAR');
    await svc.addTransaction(
        type: 'expense', amount: 50, category: 'food',
        description: 'coffee', date: now, accountId: accId, currency: 'USD');
    await svc.addSavingsGoal(SavingsGoal(
        id: 'goal-1', name: 'سيارة جديدة', targetAmount: 100000,
        currentAmount: 25000, currency: 'SAR'));
    await svc.addDebt(PersonalDebt(
        id: 'debt-1', type: 'payable', personName: 'سلفة أخي',
        amount: 10000, paid: 3000, currency: 'SAR'));
    return svc;
  }

  test('analytical query returns local month analysis with real names', () async {
    final svc = await seedAnalytics();
    final out = await ask(svc, 'عطني تحليل مصروفاتي');
    expect(out, isNotNull);
    expect(out!, contains('SAR'));
    expect(out, contains('USD')); // two currencies stay separate
    expect(out, contains('طعام')); // real category name
    expect(out, contains('سيارة جديدة')); // real goal name
    expect(out, contains('سلفة أخي')); // real debt name
    expect(out, contains('المحلية')); // marked as local data
  });

  test('report keyword also resolves to local analytics', () async {
    final svc = await seedAnalytics();
    final out = await ask(svc, 'تقرير هذا الشهر');
    expect(out, isNotNull);
    expect(out!, contains('8,000'));
  });

  test('empty data answers honestly instead of inventing', () async {
    final svc = makeService();
    final out = await ask(svc, 'حللي وضعي المالي');
    expect(out, isNotNull);
    expect(out!, contains('لا توجد معاملات'));
  });

  test('existing offline answers are unchanged', () async {
    final svc = await seedAnalytics();
    final balance = await ask(svc, 'كم رصيدي');
    expect(balance, isNotNull);
    expect(balance!, contains('SAR'));
    final txs = await ask(svc, 'آخر العمليات');
    expect(txs, isNotNull);
  });
}
