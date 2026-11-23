import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Recurring EXPENSE withdrawals must be covered by the chosen bank account
/// after converting at the live/offline rate. Insufficient (or unverifiable)
/// balance fails closed with a typed error — never a phantom success.
/// Income is never blocked (it only adds money).
void main() {
  const uid = 88;
  const bankName = 'Balance Bank';

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<CurrencyEngine> engineWith({required Map<String, double> global}) async {
    SharedPreferences.setMockInitialValues({
      'currency_engine_cache_time': DateTime.now().toIso8601String(),
      // The engine only restores an approved (v2) snapshot.
      'currency_engine_cache': jsonEncode({
        'version': 2,
        'approved': true,
        'global_rates': global,
        'yemen_sanaa': <String, dynamic>{},
        'yemen_aden': <String, dynamic>{},
        'last_updated': DateTime.now().toIso8601String(),
        'source': 'test',
        'fetched_at': DateTime.now().toIso8601String(),
      }),
    });
    final engine = CurrencyEngine(apiClient: null);
    await engine.load();
    return engine;
  }

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
        'DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<String> seedAccount(PersonalFinanceService svc,
      {required String currency, required double balance}) async {
    await svc.addBankAccount(
        bankName: bankName, currency: currency, openingBalance: balance);
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(uid, 'personal_bank_account');
    return (all.firstWhere(
                (r) => (r['bank_name']?.toString() ?? '') == bankName)['id']
            ?.toString() ??
        '');
  }

  Future<double> balanceOf() async {
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(uid, 'personal_bank_account');
    final row =
        all.firstWhere((r) => (r['bank_name']?.toString() ?? '') == bankName);
    return double.tryParse(row['balance']?.toString() ?? '0') ?? 0;
  }

  Future<int> txCount() async {
    final cache = PersonalCacheRepository();
    return (await cache.getCollection(uid, 'personal_transaction')).length;
  }

  RecurringTransaction rule({
    required String type,
    required double amount,
    required String currency,
    required String? accountId,
    String execution = 'auto',
  }) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return RecurringTransaction(
      id: '',
      type: type,
      amount: amount,
      category: 'test',
      frequency: 'daily',
      nextDate: today,
      bankAccountId: accountId,
      currency: currency,
      accountType: 'fixed',
      executionType: execution,
      reminderTime: '00:00',
    );
  }

  Future<RecurringTransaction> store(RecurringTransaction r) async {
    final svc = makeService();
    await svc.addRecurring(r);
    return (await svc.getRecurring()).first;
  }

  group('recurring expense balance guard (offline-first)', () {
    test('same currency + insufficient balance -> rejected, nothing staged',
        () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 1000);
      final stored = await store(
          rule(type: 'expense', amount: 1500, currency: 'SAR', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      await expectLater(
        svc.executeRecurringNow(stored, currencyEngine: engine, manual: true),
        throwsA(isA<RecurringExecutionException>()
            .having((e) => e.code, 'code', 'insufficient_balance')),
      );
      expect(await balanceOf(), 1000);
      expect(await txCount(), 0);
      final after = (await svc.getRecurring()).first;
      expect(after.lastExecutedAt, isNull);
    });

    test('same currency + sufficient balance -> executes and debits', () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 1000);
      final stored = await store(
          rule(type: 'expense', amount: 400, currency: 'SAR', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      await svc.executeRecurringNow(stored, currencyEngine: engine, manual: true);
      expect(await balanceOf(), 600);
      expect(await txCount(), 1);
    });

    test('USD expense vs 1000 SAR -> rejected (~259 USD only)', () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 1000);
      final stored = await store(
          rule(type: 'expense', amount: 1000, currency: 'USD', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      await expectLater(
        svc.executeRecurringNow(stored, currencyEngine: engine, manual: true),
        throwsA(isA<RecurringExecutionException>()
            .having((e) => e.code, 'code', 'insufficient_balance')),
      );
      expect(await balanceOf(), 1000);
      expect(await txCount(), 0);
    });

    test('USD expense vs 3857 SAR -> approved, converted debit (SAR)',
        () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 3857);
      final stored = await store(
          rule(type: 'expense', amount: 1000, currency: 'USD', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});
      final expected = engine.convert(1000, 'USD', 'SAR');

      await svc.executeRecurringNow(stored, currencyEngine: engine, manual: true);
      expect(await txCount(), 1);
      expect(await balanceOf(), closeTo(3857 - expected, 0.01));
      final cache = PersonalCacheRepository();
      final txs = await cache.getCollection(uid, 'personal_transaction');
      expect((txs.first['currency'] ?? '').toString().toUpperCase(), 'SAR');
      expect((txs.first['amount'] as num).toDouble(), closeTo(expected, 0.01));
    });

    test('missing FX rate -> fails closed (never relabels the amount)',
        () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 10000);
      final stored = await store(
          rule(type: 'expense', amount: 100, currency: 'EUR', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      await expectLater(
        svc.executeRecurringNow(stored, currencyEngine: engine, manual: true),
        throwsA(isA<RecurringExecutionException>()
            .having((e) => e.code, 'code', 'fx_unavailable')),
      );
      expect(await txCount(), 0);
      expect(await balanceOf(), 10000);
    });

    test('unknown account -> fails closed', () async {
      final svc = makeService();
      final stored = await store(rule(
          type: 'expense', amount: 10, currency: 'SAR', accountId: 'ghost'));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      await expectLater(
        svc.executeRecurringNow(stored, currencyEngine: engine, manual: true),
        throwsA(isA<RecurringExecutionException>()
            .having((e) => e.code, 'code', 'account_unavailable')),
      );
    });

    test('income is never blocked (money only enters)', () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 0);
      final stored = await store(
          rule(type: 'income', amount: 1000, currency: 'USD', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});
      final expected = engine.convert(1000, 'USD', 'SAR');

      await svc.executeRecurringNow(stored, currencyEngine: engine, manual: true);
      expect(await txCount(), 1);
      expect(await balanceOf(), closeTo(expected, 0.01));
    });

    test('auto sweep records the failure and keeps the rule due', () async {
      final svc = makeService();
      final acc = await seedAccount(svc, currency: 'SAR', balance: 100);
      await svc.addRecurring(
          rule(type: 'expense', amount: 900, currency: 'SAR', accountId: acc));
      final engine = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});

      final executed = await svc.processDueRecurring(currencyEngine: engine);
      expect(executed, isEmpty);
      expect(svc.lastRecurringSweepFailures.length, 1);
      expect(svc.lastRecurringSweepFailures.first.type, 'expense');
      expect(await balanceOf(), 100);
      expect(await txCount(), 0);
      final after = (await svc.getRecurring()).first;
      expect(after.lastExecutedAt, isNull);
    });
  });
}
