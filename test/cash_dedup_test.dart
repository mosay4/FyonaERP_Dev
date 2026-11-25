import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

/// Cash uniqueness rule: the same currency is NEVER created twice in the
/// same account — unless the account TYPE differs (checking vs savings).
/// Regression test for the same-name duplicates: the check must consult
/// the server too, because a fresh/unsynced mirror alone recreates what
/// already exists remotely.
void main() {
  const uid = 78;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService({Dio? dio}) {
    final d = dio ??
        Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:9',
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: d),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(uid);
    return svc;
  }

  /// Dio that answers the accounts list with canned server rows.
  Dio stubServer(List<Map<String, dynamic>> rows) {
    final d = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    d.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {'success': true, 'data': rows},
      ));
    }));
    return d;
  }

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<List<Map<String, dynamic>>> cashRows() async {
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(uid, 'personal_bank_account');
    return all
        .where((r) => (r['bank_name']?.toString() ?? '') == 'كاش')
        .toList();
  }

  test('existing checking cash is not recreated (mirror hit)', () async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'كاش', currency: 'USD', openingBalance: 50);
    await svc.ensureCashAccounts(['USD', 'SAR']);
    final cash = await cashRows();
    expect(cash.where((r) => r['currency'] == 'USD').length, 1);
    expect(cash.where((r) => r['currency'] == 'SAR').length, 1);
  });

  test('same currency with a different type IS allowed', () async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'كاش',
        currency: 'USD',
        openingBalance: 50,
        accountType: 'savings');
    await svc.ensureCashAccounts(['USD']);
    final usd =
        (await cashRows()).where((r) => r['currency'] == 'USD').toList();
    expect(usd.length, 2);
    expect(usd.map((r) => r['account_type']).toSet(), {'savings', 'checking'});
  });

  test('empty mirror + existing server cash creates nothing (relay off)', () async {
    // Without the Personal device relay the server is still consulted; with
    // it the ledger is the truth (see personal_local_reads_test.dart).
    PersonalRelayConfig.enabled = false;
    addTearDown(() => PersonalRelayConfig.enabled = PersonalRelayConfig.build);
    final svc = makeService(
        dio: stubServer([
      {'id': 'srv-usd', 'bank_name': 'كاش', 'currency': 'USD', 'balance': 10},
    ]));
    expect(await cashRows(), isEmpty);
    await svc.ensureCashAccounts(['USD']);
    // Skipped via the server check — no local duplicate born.
    expect(await cashRows(), isEmpty);
  });

  test('empty mirror + empty server creates the cash', () async {
    final svc = makeService(dio: stubServer([]));
    await svc.ensureCashAccounts(['USD']);
    final cash = await cashRows();
    expect(cash.where((r) => r['currency'] == 'USD').length, 1);
  });

  test('enabled set blocks resurrecting a deleted currency', () async {
    final svc = makeService(dio: stubServer([]));
    // The user removed USD from the enabled set: triggers must not bring
    // it back, while SAR is still created.
    await svc.ensureCashAccounts(['USD', 'SAR'], enabled: {'SAR'});
    final cash = await cashRows();
    expect(cash.where((r) => r['currency'] == 'USD'), isEmpty);
    expect(cash.where((r) => r['currency'] == 'SAR').length, 1);
  });

  test('bare YER is canonicalized to YER_NEW on creation', () async {
    final svc = makeService(dio: stubServer([]));
    await svc.ensureCashAccounts(['YER']);
    final cash = await cashRows();
    expect(cash.where((r) => r['currency'] == 'YER'), isEmpty);
    expect(cash.where((r) => r['currency'] == 'YER_NEW').length, 1);
    // …and YER_NEW is then skipped as the same money.
    await svc.ensureCashAccounts(['YER_NEW']);
    expect((await cashRows()).where((r) => r['currency'] == 'YER_NEW').length, 1);
  });

  test('manual cash type counts as checking for the rule', () async {
    final svc = makeService(dio: stubServer([]));
    await svc.addBankAccount(
        bankName: 'كاش',
        currency: 'USD',
        openingBalance: 0,
        accountType: 'cash');
    await svc.ensureCashAccounts(['USD']);
    expect((await cashRows()).where((r) => r['currency'] == 'USD').length, 1);
  });

  group('sweepDuplicateCashAccounts (phantom-zero healing)', () {
    Future<void> seedCashRow(String id, String currency, double balance,
        {String type = 'checking'}) async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(uid, 'personal_bank_account', id, {
        'id': id,
        'bank_name': 'كاش',
        'currency': currency,
        'balance': balance,
        'account_type': type,
        'is_active': true,
      });
    }

    Future<List<Map<String, dynamic>>> queueOps() async =>
        (await testLedger()).rawQuery('SELECT * FROM sync_queue ORDER BY id ASC');

    test('unreferenced zero stub beside the live row is removed', () async {
      await seedCashRow('cash-live', 'USD', 500);
      await seedCashRow('cash-stub', 'USD', 0);
      final svc = makeService();
      await svc.sweepDuplicateCashAccounts();

      final cash = await cashRows();
      expect(cash.length, 1);
      expect(cash.single['id'], 'cash-live');
      expect(cash.single['balance'], 500);
      // The absorbed id is staged as DELETE so the server converges too.
      final ops = await queueOps();
      final dels = ops.where((o) =>
          o['entity_id'] == 'cash-stub' && o['operation'] == 'DELETE');
      expect(dels.length, 1);
    });

    test('referenced zero stub is kept (money links stay intact)', () async {
      await seedCashRow('cash-live', 'USD', 500);
      await seedCashRow('cash-stub', 'USD', 0);
      final cache = PersonalCacheRepository();
      await cache.upsertItem(uid, 'personal_transaction', 'tx-ref', {
        'id': 'tx-ref',
        'tx_type': 'expense',
        'amount': 10,
        'currency': 'USD',
        'category': 'Food',
        'bank_account_id': 'cash-stub',
      });
      final svc = makeService();
      await svc.sweepDuplicateCashAccounts();

      expect((await cashRows()).length, 2,
          reason: 'a row pointed at by history must never be swept');
      expect(await queueOps(), isEmpty);
    });

    test('non-zero duplicates are never merged by the sweep', () async {
      await seedCashRow('cash-a', 'USD', 200);
      await seedCashRow('cash-b', 'USD', 300);
      final svc = makeService();
      await svc.sweepDuplicateCashAccounts();

      final cash = await cashRows();
      expect(cash.length, 2);
      expect(
          cash.fold<double>(0, (s, r) => s + (r['balance'] as num).toDouble()),
          500);
      expect(await queueOps(), isEmpty);
    });
  });

  group('canonicalCashAccounts (one row per bucket)', () {
    PersonalBankAccount row(String id, String cur, double bal) =>
        PersonalBankAccount(
            id: id, bankName: 'كاش', currency: cur, balance: bal);

    test('sums duplicates and keeps the funded row identity', () {
      final out = PersonalFinanceService.canonicalCashAccounts([
        row('stub', 'USD', 0),
        row('live', 'USD', 500),
        row('sar', 'SAR', 100),
      ]);
      expect(out.length, 2);
      final usd = out.firstWhere((a) => a.currency == 'USD');
      expect(usd.id, 'live');
      expect(usd.balance, 500);
    });

    test('YER and YER_NEW share one bucket, YER_OLD stays distinct', () {
      final out = PersonalFinanceService.canonicalCashAccounts([
        row('y1', 'YER', 10),
        row('y2', 'YER_NEW', 20),
        row('yo', 'YER_OLD', 30),
      ]);
      expect(out.length, 2);
      final yer = out.firstWhere(
          (a) => a.currency == 'YER' || a.currency == 'YER_NEW');
      expect(yer.balance, 30);
      expect(out.any((a) => a.currency == 'YER_OLD'), isTrue);
    });
  });
}
