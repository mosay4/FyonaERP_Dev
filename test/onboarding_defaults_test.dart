import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart';
import 'package:fyona_flutter/core/utils/country_phone_data.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'support/personal_ledger_test_support.dart';

/// First-run onboarding defaults: per-country phone examples + currencies.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  group('per-country phone examples', () {
    test('spot-check leading digits per country', () {
      expect(phoneExampleForCountry('YE'), '7xxxxxxxx');
      expect(phoneExampleForCountry('SA'), '5xxxxxxxx');
      expect(phoneExampleForCountry('EG'), '1xxxxxxxxx');
      expect(phoneExampleForCountry('IQ'), '7xxxxxxxxx');
      expect(phoneExampleForCountry('US'), 'xxxxxxxxxx');
      expect(phoneExampleForCountry('ye'), '7xxxxxxxx',
          reason: 'lookup is case-insensitive');
      expect(phoneExampleForCountry('XX'), 'xxxxxxxx',
          reason: 'unknown ISO falls back to generic mask');
    });

    test('every country has a well-formed mask', () {
      expect(kPhoneCountries.length, greaterThan(70));
      final isos = <String>{};
      for (final c in kPhoneCountries) {
        expect(c.iso.length, 2, reason: 'bad ISO: ${c.iso}');
        expect(c.cc.startsWith('+'), isTrue);
        expect(c.example.isNotEmpty, isTrue, reason: 'empty mask: ${c.iso}');
        expect(
          RegExp(r'^[0-9x]+$').hasMatch(c.example),
          isTrue,
          reason: 'mask must be digits+x only: ${c.iso}=${c.example}',
        );
        expect(c.example.length, greaterThanOrEqualTo(7),
            reason: 'too short: ${c.iso}');
        expect(c.example.length, lessThanOrEqualTo(11),
            reason: 'too long: ${c.iso}');
        expect(isos.add(c.iso), isTrue, reason: 'duplicate ISO: ${c.iso}');
      }
    });
  });

  group('per-country default currencies', () {    test('contract examples from the request', () {
      expect(
        defaultCurrenciesForCountry('YE'),
        ['USD', 'SAR', 'YER_OLD', 'YER_NEW'],
      );
      expect(defaultCurrenciesForCountry('SA'), ['USD', 'SAR']);
    });

    test('unknown country falls back to global defaults', () {
      expect(defaultCurrenciesForCountry('XX'), defaultEnabledCurrencies);
    });

    test('ensureCountryDefaults saves once and never overrides', () async {      const uid = 'onboarding-test-user';
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('enabled_currencies_$uid');

      await ensureCountryDefaults('SA', uid);
      expect(
        prefs.getStringList('enabled_currencies_$uid'),
        ['USD', 'SAR'],
      );

      // User customizes afterwards...
      await saveEnabledCurrencies({'EUR', 'USD'}, uid);
      // ...a later phone save must NOT clobber the customization.
      await ensureCountryDefaults('YE', uid);
      expect(
        prefs.getStringList('enabled_currencies_$uid')!.toSet(),
        {'EUR', 'USD'},
      );
      await prefs.remove('enabled_currencies_$uid');
    });
  });

  group('cash accounts follow customization', () {
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

    Future<void> cleanCash() async {
      await (await testLedger()).rawDelete(
          "DELETE FROM personal_entity_cache WHERE entity_type = 'personal_bank_account'");
      await (await testLedger()).rawDelete(
          "DELETE FROM personal_entity_cache WHERE entity_type = 'personal_transaction'");
      await (await testLedger()).rawDelete('DELETE FROM sync_queue');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cash_vault_7');
    }

    Future<List<Map<String, dynamic>>> cashAccounts() async {
      final cache = PersonalCacheRepository();
      final all = await cache.getCollection(7, 'personal_bank_account');
      return all
          .where((a) => (a['bank_name']?.toString() ?? '') == 'كاش')
          .toList();
    }

    setUp(() async => cleanCash());

    test('ensure creates one cash per currency, skips existing', () async {
      final svc = makeService();
      await svc.ensureCashAccounts(['SAR', 'USD']);
      var cash = await cashAccounts();
      expect(cash.map((a) => a['currency']).toSet(), {'SAR', 'USD'});

      await svc.ensureCashAccounts(['SAR', 'USD', 'YER']);
      cash = await cashAccounts();
      expect(cash.length, 3, reason: 'no duplicates for existing');
      // Bare YER is stored under its canonical code (Aden, YER_NEW).
      expect(cash.map((a) => a['currency']).toSet(),
          {'SAR', 'USD', 'YER_NEW'});
    });

    test('remove deletes account + txs, restore brings back balance',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await svc.ensureCashAccounts(['SAR']);

      // Simulate activity: balance + a transaction on SAR cash.
      var cash = await cashAccounts();
      final sarId = cash.first['id'].toString();
      await cache.upsertItem(7, 'personal_bank_account', sarId, {
        ...cash.first,
        'balance': 350.0,
      });
      await svc.addTransaction(
        type: 'expense',
        amount: 50,
        category: 'Food',
        date: DateTime.now(),
        accountId: sarId,
        currency: 'SAR',
      );

      await svc.removeCashCurrency('SAR');

      cash = await cashAccounts();
      expect(
        cash.where((a) => a['currency'] == 'SAR'),
        isEmpty,
        reason: 'SAR cash must be gone even with past operations',
      );
      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(
        txs.where((t) => t['bank_account_id'] == sarId),
        isEmpty,
        reason: 'its transactions must be gone too',
      );

      // Re-enable restores the same balance.
      await svc.ensureCashAccounts(['SAR']);
      cash = await cashAccounts();
      final restored = cash.firstWhere((a) => a['currency'] == 'SAR');
      expect((restored['balance'] as num).toDouble(), 300.0);
    });
  });

  group('display default currency (USD-if-enabled)', () {
    test('USD when enabled, else first enabled code, stable order', () async {
      const uid = 'display-default-user';
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('enabled_currencies_$uid');

      // Fresh account (defaults include USD) -> USD.
      expect(await resolveDefaultCurrency(uid), 'USD');

      // Customized without USD -> deterministic enabled fallback.
      await saveEnabledCurrencies({'EUR', 'SAR'}, uid);
      expect(await resolveDefaultCurrency(uid), 'EUR');

      await saveEnabledCurrencies({'YER'}, uid);
      expect(await resolveDefaultCurrency(uid), 'YER');

      await prefs.remove('enabled_currencies_$uid');
    });
  });
}
