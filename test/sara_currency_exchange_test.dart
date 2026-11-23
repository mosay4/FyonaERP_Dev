import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

Map<String, dynamic> _loadContract() {
  final file = File('backend/app/domain/services/sara_tool_contract.v1.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  const uid = 96;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService({CurrencyEngine? engine}) {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9', connectTimeout: const Duration(seconds: 2)));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
      repo: PersonalRepository(),
    );
    svc.setUserId(uid);
    return svc;
  }

  Future<void> clean() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM personal_exchange_rates WHERE user_id = ?', [uid]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
    // Clear enabled currencies for this user
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('enabled_currencies_$uid');
    await prefs.remove('enabled_currencies_global');
  }

  setUp(() async => clean());
  tearDown(() async => clean());

  group('currencies: read / YER separation / add / duplicate / delete', () {
    test('read currencies returns enabled + account distinct, YER≠YER_NEW', () async {
      final svc = makeService();
      // Ensure both YER variants enabled separately
      await saveEnabledCurrencies({'SAR', 'YER', 'YER_NEW', 'USD'}, uid.toString());
      await svc.addBankAccount(bankName: 'Cash YER', currency: 'YER', openingBalance: 100);
      await svc.addBankAccount(bankName: 'Cash YER_NEW', currency: 'YER_NEW', openingBalance: 200);
      final exec = ToolExecutor(svc);
      final r = await exec.execute('get_currencies', {});
      expect(r.success, isTrue);
      final list = (r.data!['currencies'] as List).map((e) => (e as Map)['currency_code'] as String).toSet();
      expect(list, contains('YER'));
      expect(list, contains('YER_NEW'));
      expect(list, contains('SAR'));
      // Ensure YER and YER_NEW are separate entries, not merged
      expect(list.where((c) => c == 'YER').length, 1);
      expect(list.where((c) => c == 'YER_NEW').length, 1);
    });

    test('add currency enables and is idempotent', () async {
      final svc = makeService();
      await saveEnabledCurrencies({'SAR'}, uid.toString());
      final exec = ToolExecutor(svc);
      final a1 = await exec.execute('add_currency', {'currency_code': 'USD'});
      expect(a1.success, isTrue);
      expect(a1.verificationStatus, anyOf('confirmed', 'local_pending'));
      final after = await loadEnabledCurrencies(uid.toString());
      expect(after, contains('USD'));
      // Duplicate add should be idempotent — still success, no duplicate error
      final a2 = await exec.execute('add_currency', {'currency_code': 'USD'});
      expect(a2.success, isTrue);
      final after2 = await loadEnabledCurrencies(uid.toString());
      expect(after2.where((c) => c == 'USD').length, 1);
    });

    test('add duplicate YER vs YER_NEW are distinct', () async {
      final svc = makeService();
      await saveEnabledCurrencies({'SAR'}, uid.toString());
      final exec = ToolExecutor(svc);
      final r1 = await exec.execute('add_currency', {'currency_code': 'YER'});
      final r2 = await exec.execute('add_currency', {'currency_code': 'YER_NEW'});
      expect(r1.success, isTrue);
      expect(r2.success, isTrue);
      final set = await loadEnabledCurrencies(uid.toString());
      expect(set, contains('YER'));
      expect(set, contains('YER_NEW'));
    });

    test('delete currency disables without deleting financial data', () async {
      final svc = makeService();
      await saveEnabledCurrencies({'SAR', 'USD'}, uid.toString());
      await svc.addBankAccount(bankName: 'ToKeep', currency: 'USD', openingBalance: 500);
      final exec = ToolExecutor(svc);
      final r = await exec.execute('delete_currency', {'currency_code': 'USD'});
      expect(r.success, isTrue);
      final after = await loadEnabledCurrencies(uid.toString());
      expect(after, isNot(contains('USD')));
      // Financial data (bank account) should still exist — we only disabled
      final banks = await svc.getBankAccounts();
      expect(banks.any((b) => b.currency == 'USD'), isTrue);
    });

    test('reject invalid currency codes', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r1 = await exec.execute('add_currency', {'currency_code': 'INVALID!!!'});
      expect(r1.success, isFalse);
      expect(r1.errorCode, 'INVALID_CURRENCY');
      final r2 = await exec.execute('add_currency', {'currency_code': ''});
      expect(r2.success, isFalse);
    });

    test('missing currency_code does not partially execute', () async {
      final def = AgentToolRegistry.findByName('add_currency')!;
      final check = def.params.where((p) => p.required).map((p) => p.name).toSet();
      expect(check, contains('currency_code'));
      // Simulate empty params — should be caught as missing, not executed
      final exec = ToolExecutor(makeService());
      final r = await exec.execute('add_currency', {});
      expect(r.success, isFalse);
    });
  });

  group('exchange rates: real engine, no invention, add/update, validation', () {
    test('USD→SAR requires a stored rate and never invents a fixed fallback', () async {
      final engine = CurrencyEngine();
      await engine.load();
      final svc = makeService(engine: engine);
      final exec = ToolExecutor(svc, fxEngine: engine);
      final r = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'SAR'});
      expect(r.success, isTrue);
      expect(r.data!['available'], isFalse);
      await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'SAR', 'rate': 3.75});
      final stored = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'SAR'});
      expect(stored.data!['available'], isTrue);
      expect(stored.data!['rate'], closeTo(3.75, 0.001));
    });

    test('no rate returns available false, never invented', () async {
      final engine = CurrencyEngine();
      await engine.load();
      final svc = makeService(engine: engine);
      final exec = ToolExecutor(svc, fxEngine: engine);
      // Use obscure pair that engine has no rate for and no personal rate
      final r = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'XYZ'});
      expect(r.success, isTrue);
      expect(r.data!['available'], isFalse);
      expect(r.data!['rate'], isNull);
    });

    test('YER and YER_NEW rates are distinct', () async {
      final engine = CurrencyEngine();
      await engine.load();
      final svc = makeService(engine: engine);
      final exec = ToolExecutor(svc, fxEngine: engine);
      final r1 = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'YER'});
      final r2 = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'YER_NEW'});
      // Both may be available or not, but they are queried separately — codes not merged
      expect(r1.data!['from_currency'], 'USD');
      expect(r2.data!['from_currency'], 'USD');
      expect(r1.data!['to_currency'], 'YER');
      expect(r2.data!['to_currency'], 'YER_NEW');
    });

    test('add exchange rate stores and is readable', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'EUR', 'rate': 0.92});
      expect(r.success, isTrue);
      expect(r.verificationStatus, anyOf('confirmed', 'local_pending'));
      final check = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'EUR'});
      // Personal rate should be found (source personal)
      expect(check.success, isTrue);
      // If engine has fallback 0.92, personal 0.92 also 0.92 — but we verify via personal repo directly
      final rates = await svc.getExchangeRates();
      final found = rates.where((e) => e.fromCurrency == 'USD' && e.toCurrency == 'EUR').toList();
      expect(found.length, 1);
      expect(found.first.rate, closeTo(0.92, 0.001));
    });

    test('update exchange rate modifies existing', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'JPY', 'rate': 150.0});
      final upd = await exec.execute('update_exchange_rate', {'from_currency': 'USD', 'to_currency': 'JPY', 'rate': 160.0});
      expect(upd.success, isTrue);
      final rates = await svc.getExchangeRates();
      final found = rates.firstWhere((e) => e.fromCurrency == 'USD' && e.toCurrency == 'JPY');
      expect(found.rate, closeTo(160.0, 0.001));
    });

    test('reject rate <=0', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r1 = await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'EUR', 'rate': 0});
      expect(r1.success, isFalse);
      expect(r1.errorCode, 'INVALID_RATE');
      final r2 = await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'EUR', 'rate': -5});
      expect(r2.success, isFalse);
    });

    test('reject invalid currency ids for rate', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('add_exchange_rate', {'from_currency': 'BAD!', 'to_currency': 'EUR', 'rate': 1.5});
      expect(r.success, isFalse);
      expect(r.errorCode, 'INVALID_CURRENCY');
      final r2 = await exec.execute('get_exchange_rate', {'from_currency': 'USD', 'to_currency': 'BAD!'});
      expect(r2.success, isFalse);
    });

    test('reject same from/to', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'USD', 'rate': 1});
      expect(r.success, isFalse);
    });

    test('verification failure does not give success', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      // Try to add with missing params via direct exec (bypassing collector) — should fail
      final r = await exec.execute('add_exchange_rate', {'from_currency': 'USD', 'to_currency': 'EUR'});
      expect(r.success, isFalse);
      expect(r.verified, isFalse);
    });

    test('concurrent duplicate add does not create duplicates', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final results = await Future.wait([
        exec.execute('add_currency', {'currency_code': 'EUR'}),
        exec.execute('add_currency', {'currency_code': 'EUR'}),
      ]);
      expect(results[0].success, isTrue);
      expect(results[1].success, isTrue);
      final set = await loadEnabledCurrencies(uid.toString());
      expect(set.where((c) => c == 'EUR').length, 1);
      // Also for rates
      final r1 = exec.execute('add_exchange_rate', {'from_currency': 'GBP', 'to_currency': 'USD', 'rate': 1.25});
      final r2 = exec.execute('add_exchange_rate', {'from_currency': 'GBP', 'to_currency': 'USD', 'rate': 1.25});
      final rr = await Future.wait([r1, r2]);
      expect(rr[0].success, isTrue);
      expect(rr[1].success, isTrue);
      final rates = await svc.getExchangeRates();
      final matches = rates.where((e) => e.fromCurrency == 'GBP' && e.toCurrency == 'USD').toList();
      expect(matches.length, 1);
    });
  });

  test('contract contains new currency tools', () {
    final c = _loadContract();
    final ids = (c['tools'] as List).map((t) => (t as Map)['tool_id'] as String).toSet();
    expect(ids, contains('get_currencies'));
    expect(ids, contains('add_currency'));
    expect(ids, contains('delete_currency'));
    expect(ids, contains('get_exchange_rate'));
    expect(ids, contains('add_exchange_rate'));
    expect(ids, contains('update_exchange_rate'));
    expect(c['contract_version'], '1.5.0');
  });

  test('a transfer quote cannot be reused after an account currency changes', () async {
    final svc = makeService();
    await svc.addBankAccount(bankName: 'Source', currency: 'USD', openingBalance: 100);
    await svc.addBankAccount(bankName: 'Target', currency: 'SAR', openingBalance: 0);
    final banks = await svc.getBankAccounts();
    final from = banks.firstWhere((b) => b.bankName == 'Source');
    final to = banks.firstWhere((b) => b.bankName == 'Target');
    final result = await ToolExecutor(svc).execute('create_transfer', {
      'from_account_id': from.id, 'to_account_id': to.id, 'amount': 10,
      'from_currency': 'SAR', 'to_currency': 'SAR', 'exchange_rate': 1,
    });
    expect(result.success, isFalse);
    expect(result.errorCode, 'QUOTE_CURRENCY_CHANGED');
    expect((await svc.getBankAccounts()).firstWhere((b) => b.id == from.id).balance, 100);
  });
}
