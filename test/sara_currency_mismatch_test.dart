import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/ai/domain/agent/currency_mismatch.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';

/// Generic account/currency binding: a write explicitly naming an account in
/// a currency the account does not support must be REFUSED with real,
/// numbered options — never written, never converted, never re-targeted.
/// Cases are parametrized over arbitrary pairs (the reported USD/OMR case is
/// just one row) plus synthetic names/codes to prove nothing is hardcoded.
void main() {
  const uid = 97;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService() {
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
  }

  setUp(() async => clean());
  tearDown(() async => clean());

  MismatchOptions fakeOptions() => const MismatchOptions(
        accountId: 'a1',
        accountName: 'AlphaVault',
        accountCurrency: 'QQQ',
        requestedCurrency: 'ZZZ',
        amount: 200,
        fxOptions: [
          MismatchFxOption(currency: 'QQQ', accountId: 'a1', accountName: 'AlphaVault', rate: 2.0, converted: 400),
        ],
        siblings: [
          MismatchSibling(accountId: 'b2', accountName: 'BetaPocket', currency: 'ZZZ'),
        ],
      );

  group('mismatch helper: pure, generic, never guesses', () {
    test('question lists only the passed-in real names/currencies', () {
      final qAr = buildMismatchQuestion(fakeOptions(), arabic: true);
      final qEn = buildMismatchQuestion(fakeOptions(), arabic: false);
      for (final q in [qAr, qEn]) {
        expect(q, contains('AlphaVault'));
        expect(q, contains('BetaPocket'));
        expect(q, contains('QQQ'));
        expect(q, contains('ZZZ'));
        expect(q, contains('200'));
      }
    });

    test('numbered + ordinal + code + name choices resolve', () {
      final o = fakeOptions();
      expect(parseMismatchChoice('1', o).kind, 'fx');
      expect(parseMismatchChoice('2', o).kind, 'account');
      expect(parseMismatchChoice('الثاني', o).kind, 'account');
      expect(parseMismatchChoice('second', o).kind, 'account');
      final byCode = parseMismatchChoice('ZZZ', o);
      expect(byCode.kind, 'account');
      expect(byCode.sibling!.accountId, 'b2');
      final byName = parseMismatchChoice('BetaPocket', o);
      expect(byName.kind, 'account');
      expect(byName.sibling!.accountId, 'b2');
    });

    test('cancel words cancel; bare yes/thanks/empty never execute', () {
      final o = fakeOptions();
      expect(parseMismatchChoice('إلغاء', o).kind, 'cancel');
      expect(parseMismatchChoice('cancel', o).kind, 'cancel');
      // A bare yes must NOT pick an option — the caller re-asks.
      expect(parseMismatchChoice('نعم', o).kind, 'unknown');
      expect(parseMismatchChoice('تمام', o).kind, 'unknown');
      expect(parseMismatchChoice('شكرا', o).kind, 'unknown');
      expect(parseMismatchChoice('', o).kind, 'unknown');
      expect(parseMismatchChoice('7', o).kind, 'unknown');
    });
  });

  group('executor: single-currency bank auto-converts at stored rate', () {
    // [bankCurrency, requestedCurrency] — the reported USD case is one row;
    // every other pair proves the rule is generic, not hardcoded.
    final pairs = [
      ['EUR', 'GBP'],
      ['SAR', 'USD'],
      ['USD', 'OMR'],
      ['KWD', 'SAR'],
    ];
    for (final pair in pairs) {
      test('converts ${pair[1]} into ${pair[0]}-only bank and writes converted', () async {
        final svc = makeService();
        final engine = CurrencyEngine();
        await engine.load();
        await svc.addBankAccount(bankName: 'SoloBank', currency: pair[0], openingBalance: 1000);
        final banks = await svc.getBankAccounts();
        final target = banks.firstWhere((b) => b.currency == pair[0]);
        final rate = engine.getRate(pair[1], pair[0])!;
        expect(rate > 0 && rate.isFinite, isTrue);
        final before = await svc.getTransactions();
        final exec = ToolExecutor(svc, fxEngine: engine);
        final r = await exec.execute('create_transaction', {
          'type': 'expense',
          'amount': 200,
          'currency': pair[1],
          'account_id': target.id,
          'category': 'test',
        });
        // Converted, not refused — and NOT written in the requested currency.
        expect(r.errorCode, isNot('CURRENCY_MISMATCH'));
        expect(r.verificationStatus, 'local_pending');
        final conv = r.data!['conversion'] as Map;
        expect(conv['from_currency'], pair[1]);
        expect(conv['to_currency'], pair[0]);
        expect((conv['rate'] as num).toDouble(), closeTo(rate, 1e-9));
        final after = await svc.getTransactions();
        expect(after.length, before.length + 1);
        final written = after.firstWhere((t) => t.category == 'test');
        expect(written.currency, pair[0]);
        expect(written.amount, closeTo(200 * rate, 0.01));
        // The message discloses the conversion (both sides + rate).
        expect(r.messageAr, contains(pair[0]));
        expect(r.messageAr, contains(pair[1]));
      });
    }

    test('multi-currency bank refuses with sibling options, writes nothing', () async {
      final svc = makeService();
      final engine = CurrencyEngine();
      await engine.load();
      await svc.addBankAccount(bankName: 'DuoBank', currency: 'SAR', openingBalance: 500);
      await svc.addBankAccount(bankName: 'DuoBank', currency: 'USD', openingBalance: 500);
      final banks = await svc.getBankAccounts();
      final sarRow = banks.firstWhere((b) => b.bankName == 'DuoBank' && b.currency == 'SAR');
      final usdRow = banks.firstWhere((b) => b.bankName == 'DuoBank' && b.currency == 'USD');
      final before = await svc.getTransactions();
      final exec = ToolExecutor(svc, fxEngine: engine);
      final r = await exec.execute('create_transaction', {
        'type': 'expense',
        'amount': 100,
        'currency': 'USD',
        'account_id': sarRow.id,
        'category': 'test',
      });
      expect(r.errorCode, 'CURRENCY_MISMATCH');
      expect(r.data!['account_id'], sarRow.id);
      final sibs = r.data!['sibling_accounts'] as List;
      expect(sibs.any((s) => (s as Map)['account_id'] == usdRow.id), isTrue);
      final after = await svc.getTransactions();
      expect(after.length, before.length);
    });

    test('matching currency writes normally (control)', () async {
      final svc = makeService();
      final engine = CurrencyEngine();
      await engine.load();
      await svc.addBankAccount(bankName: 'CtrlBank', currency: 'SAR', openingBalance: 500);
      final banks = await svc.getBankAccounts();
      final before = await svc.getTransactions();
      final exec = ToolExecutor(svc, fxEngine: engine);
      final r = await exec.execute('create_transaction', {
        'type': 'expense',
        'amount': 50,
        'currency': 'SAR',
        'account_id': banks.first.id,
        'category': 'test',
      });
      // Honest gateway semantics: accepted locally, pending sync — and crucially NOT a mismatch.
      expect(r.errorCode, isNot('CURRENCY_MISMATCH'));
      expect(r.verificationStatus, 'local_pending');
      final after = await svc.getTransactions();
      expect(after.length, before.length + 1);
    });

    test('missing currency keeps legacy behavior (no mismatch)', () async {
      final svc = makeService();
      await svc.addBankAccount(bankName: 'LegacyBank', currency: 'EUR', openingBalance: 500);
      final banks = await svc.getBankAccounts();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('create_transaction', {
        'type': 'expense',
        'amount': 10,
        'account_id': banks.first.id,
        'category': 'test',
      });
      expect(r.errorCode, isNot('CURRENCY_MISMATCH'));
    });

    test('missing account keeps legacy behavior (no mismatch)', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('create_transaction', {
        'type': 'expense',
        'amount': 10,
        'currency': 'USD',
        'category': 'test',
      });
      expect(r.errorCode, isNot('CURRENCY_MISMATCH'));
    });

    test('unavailable FX pair invents no rate', () async {
      final svc = makeService();
      final engine = CurrencyEngine();
      await engine.load();
      await svc.addBankAccount(bankName: 'NoFxBank', currency: 'SAR', openingBalance: 500);
      final banks = await svc.getBankAccounts();
      final exec = ToolExecutor(svc, fxEngine: engine);
      final r = await exec.execute('create_transaction', {
        'type': 'expense',
        'amount': 10,
        'currency': 'XYZ',
        'account_id': banks.first.id,
        'category': 'test',
      });
      expect(r.errorCode, 'CURRENCY_MISMATCH');
      expect((r.data!['fx_options'] as List), isEmpty);
      expect((r.data!['sibling_accounts'] as List), isEmpty);
    });
  });

  group('analytics is data, not a screen', () {
    test('open_screen no longer accepts analytics', () {
      final def = AgentToolRegistry.findByName('open_screen')!;
      final screen = def.params.firstWhere((p) => p.name == 'screen');
      expect(screen.allowedValues, isNotNull);
      expect(screen.allowedValues, isNot(contains('analytics')));
      // Real screens still accepted (control).
      expect(screen.allowedValues, contains('banks'));
      expect(screen.allowedValues, contains('reports'));
    });

    test('dispatcher no longer resolves analytics to a route', () {
      expect(SaraActionDispatcher.resolveRoute('analytics'), isNull);
      expect(SaraActionDispatcher.resolveRoute('Analytics'), isNull);
      expect(SaraActionDispatcher.resolveRoute('التحليلات'), isNull);
      expect(
        SaraActionDispatcher.resolveRouteFromActions([
          const SaraAction(type: SaraActionType.openScreen, params: {'screen': 'analytics'}),
        ]),
        isNull,
      );
      // Real screens still resolve (control).
      expect(SaraActionDispatcher.resolveRoute('Banks'), isNotNull);
    });
  });
}
