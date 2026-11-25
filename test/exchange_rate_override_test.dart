import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_banks_page.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_debts_page.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/savings_goals_page.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/exchange_rate_override.dart';

/// Manual exchange rate (pencil beside the auto-filled rate): the shared
/// widget, and every Personal flow storing the manual rate's conversion.

class _Engine extends CurrencyEngine {
  _Engine(this.rates);
  final Map<String, double> rates; // 'FROM>TO' → 1 FROM = r TO

  @override
  double? getRate(String from, String to) {
    from = from.toUpperCase();
    to = to.toUpperCase();
    if (from == to) return 1;
    final direct = rates['$from>$to'];
    if (direct != null) return direct;
    final inverse = rates['$to>$from'];
    return inverse == null ? null : 1 / inverse;
  }
}

class _Finance extends PersonalFinanceNotifier {
  _Finance(super.ref, PersonalFinanceState initial) {
    state = initial;
  }

  final calls = <Map<String, Object?>>[];

  @override
  Future<void> load() async {}

  @override
  Future<void> contributeToGoal(
    String id,
    double amount, {
    double? goalAmount,
    String? currency,
    String? bankAccountId,
    String? paymentMethod,
    String? category,
    String? description,
    String? clientOperationId,
  }) async {
    calls.add({
      'op': 'goal',
      'amount': amount,
      'goalAmount': goalAmount,
      'currency': currency,
    });
  }

  @override
  Future<bool> transferBetweenAccounts({
    required String fromId,
    required String toId,
    required double amount,
    required String fromCurrency,
    required String toCurrency,
    required double rate,
  }) async {
    calls.add({'op': 'transfer', 'amount': amount, 'rate': rate});
    return true;
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLocalizations.preload('ar');
  });

  Widget app(Widget child, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: child),
        ),
      );

  String converted(WidgetTester tester) =>
      tester
          .widget<Text>(find.byKey(ExchangeRateOverrideLine.convertedKey))
          .data!;

  Future<void> typeRate(WidgetTester tester, String value) async {
    await tester.tap(find.byKey(ExchangeRateOverrideLine.editKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(ExchangeRateOverrideLine.fieldKey), value);
    await tester.tap(find.byKey(ExchangeRateOverrideLine.saveKey));
    await tester.pumpAndSettle();
  }

  group('ExchangeRateOverrideLine', () {
    Widget line({required String from, required String to, double? auto}) {
      double? manual;
      return StatefulBuilder(
        builder: (_, setState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            ExchangeRateOverrideLine(
              fromCurrency: from,
              toCurrency: to,
              autoRate: auto,
              manualRate: manual,
              amount: 100,
              onManualRateChanged: (r) => setState(() => manual = r),
            ),
            Text('manual=${manual ?? '-'}', key: const Key('probe')),
          ]),
        ),
      );
    }

    String probe(WidgetTester t) =>
        t.widget<Text>(find.byKey(const Key('probe'))).data!;

    testWidgets('shows the auto rate, edits it, validates > 0 and resets',
        (tester) async {
      await tester.pumpWidget(app(line(from: 'USD', to: 'SAR', auto: 3.75)));
      await tester.pumpAndSettle();
      expect(find.text(formatCurrencyRateLine('USD', 3.75, 'SAR')),
          findsOneWidget);
      expect(converted(tester), contains(fmtNum(375)));
      expect(find.text('يدوي'), findsNothing);

      // Invalid (0) keeps the sheet open with the validation message.
      await typeRate(tester, '0');
      expect(find.text('أدخل سعر صرف أكبر من صفر'), findsOneWidget);
      expect(probe(tester), 'manual=-');
      await tester.enterText(
          find.byKey(ExchangeRateOverrideLine.fieldKey), '4');
      await tester.tap(find.byKey(ExchangeRateOverrideLine.saveKey));
      await tester.pumpAndSettle();
      expect(probe(tester), 'manual=4.0');
      expect(find.text(formatCurrencyRateLine('USD', 4, 'SAR')),
          findsOneWidget);
      expect(find.text('يدوي'), findsOneWidget);
      expect(converted(tester), contains(fmtNum(400)),
          reason: 'converted preview follows the manual rate live');

      // «استخدام السعر التلقائي» drops the manual rate.
      await tester.tap(find.byKey(ExchangeRateOverrideLine.editKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('استخدام السعر التلقائي'));
      await tester.pumpAndSettle();
      expect(probe(tester), 'manual=-');
      expect(converted(tester), contains(fmtNum(375)));
    });

    testWidgets('YER-style rates are shown and typed in the ≥ 1 direction',
        (tester) async {
      await tester.pumpWidget(
          app(line(from: 'YER_OLD', to: 'USD', auto: 1 / 535)));
      await tester.pumpAndSettle();
      expect(find.text(formatCurrencyRateLine('USD', 535, 'YER_OLD')),
          findsOneWidget);
      await typeRate(tester, '600');
      expect(probe(tester), 'manual=${1 / 600}',
          reason: 'stored rate stays from→to (YER_OLD→USD)');
      expect(find.text(formatCurrencyRateLine('USD', 600, 'YER_OLD')),
          findsOneWidget);
    });

    testWidgets('no automatic rate: pencil still lets the user type one',
        (tester) async {
      await tester.pumpWidget(app(line(from: 'USD', to: 'SAR')));
      await tester.pumpAndSettle();
      expect(find.text('غير متوفر'), findsOneWidget);
      expect(find.byKey(ExchangeRateOverrideLine.convertedKey), findsNothing);
      await tester.tap(find.byKey(ExchangeRateOverrideLine.editKey));
      await tester.pumpAndSettle();
      expect(find.text('استخدام السعر التلقائي'), findsNothing);
      await tester.enterText(
          find.byKey(ExchangeRateOverrideLine.fieldKey), '3.5');
      await tester.tap(find.byKey(ExchangeRateOverrideLine.saveKey));
      await tester.pumpAndSettle();
      expect(probe(tester), 'manual=3.5');
      expect(converted(tester), contains(fmtNum(350)));
    });

    test('effective rate and per-pair override', () {
      expect(effectiveExchangeRate(3.75, null), 3.75);
      expect(effectiveExchangeRate(3.75, 0), 3.75);
      expect(effectiveExchangeRate(null, 4), 4);
      final o = ManualRateOverride()..set('usd', 'SAR', 4);
      expect(o.rateFor('USD', 'sar'), 4);
      expect(o.rateFor('USD', 'EUR'), isNull,
          reason: 'another pair falls back to the automatic rate');
      o.clear();
      expect(o.rateFor('USD', 'SAR'), isNull);
    });
  });

  group('Personal flows use the manual rate', () {
    late _Finance finance;

    List<Override> overrides(PersonalFinanceState st) => [
          currencyEngineProvider
              .overrideWithValue(_Engine({'USD>SAR': 3.75})),
          personalFinanceServiceProvider
              .overrideWithValue(PersonalFinanceService()),
          personalFinanceProvider
              .overrideWith((ref) => finance = _Finance(ref, st)),
        ];

    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('savings goal contribution from another currency',
        (tester) async {
      tall(tester);
      final st = PersonalFinanceState(
        bankAccounts: [
          PersonalBankAccount(
              id: 'c1', bankName: 'كاش', currency: 'USD', balance: 1000,
              accountType: 'cash'),
        ],
        savingsGoals: [
          SavingsGoal(id: 'g1', name: 'سيارة', targetAmount: 10000,
              currency: 'SAR'),
        ],
      );
      await tester.pumpWidget(
          app(const SavingsGoalsPage(), overrides: overrides(st)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة مبلغ').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '100');
      await tester.pump();
      expect(converted(tester), contains(fmtNum(375)));

      await typeRate(tester, '4');
      expect(converted(tester), contains(fmtNum(400)));
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(finance.calls.single['amount'], 100);
      expect(finance.calls.single['goalAmount'], closeTo(400, 1e-9),
          reason: 'the goal is credited at the manual rate');
      expect(finance.calls.single['currency'], 'USD');
    });

    testWidgets('exchange between accounts of different currencies',
        (tester) async {
      tall(tester);
      final st = PersonalFinanceState(bankAccounts: [
        PersonalBankAccount(
            id: 'a', bankName: 'بنك الدولار', currency: 'USD', balance: 1000),
        PersonalBankAccount(
            id: 'b', bankName: 'بنك الريال', currency: 'SAR', balance: 0),
      ]);
      await tester.pumpWidget(app(const PersonalBanksPage(openTransfer: true),
          overrides: overrides(st)));
      await tester.pumpAndSettle();
      Future<void> choose(String field, String bank) async {
        await tester.tap(find.text(field));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(
            of: find.byType(BottomSheet), matching: find.text(bank)));
        await tester.pumpAndSettle();
      }

      await choose('من حساب', 'بنك الدولار');
      await choose('إلى حساب', 'بنك الريال');
      await tester.enterText(find.byType(EditableText).last, '100');
      await tester.pumpAndSettle();
      expect(find.text(fmtNum(375)),
          findsWidgets);

      await typeRate(tester, '3.9');
      expect(find.text(fmtNum(390)),
          findsWidgets,
          reason: 'the received-amount preview follows the manual rate');
      await tester.tap(find.text('تحويل').last);
      await tester.pumpAndSettle();
      expect(finance.calls.single['rate'], 3.9);
      expect(finance.calls.single['amount'], 100);
    });

    Future<List<double>> paySheet(
      WidgetTester tester,
      PersonalDebt debt,
      List<PersonalBankAccount> accounts,
      String typed,
      String manual,
    ) async {
      tall(tester);
      final paid = <double>[];
      await tester.pumpWidget(app(
        debugDebtPaySheet(
          debt: debt,
          onPay: (amount, method, bankId, notes, opId, currency,
                  debtAmount) async =>
              paid..addAll([amount, debtAmount]),
        ),
        overrides: overrides(PersonalFinanceState(bankAccounts: accounts)),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, typed);
      await tester.pump();
      // Cash bucket chip (single currency) selects the paying account.
      await tester.tap(find.textContaining('USD ·'));
      await tester.pumpAndSettle();
      await typeRate(tester, manual);
      await tester.tap(find.byType(ElevatedButton).last);
      await tester.pumpAndSettle();
      return paid;
    }

    final usdCash = [
      PersonalBankAccount(
          id: 'c1', bankName: 'كاش', currency: 'USD', balance: 1000,
          accountType: 'cash'),
    ];

    testWidgets('debt payment (I owe SAR) from a USD account',
        (tester) async {
      final paid = await paySheet(
        tester,
        PersonalDebt(id: 'd1', type: 'payable', personName: 'سالم',
            amount: 1000, currency: 'SAR'),
        usdCash,
        '100',
        '3.9',
      );
      expect(paid, [100, closeTo(390, 1e-9)],
          reason: '100 USD leave the account, 390 SAR settle the debt');
    });

    testWidgets('debt collection (owed SAR) into a USD account',
        (tester) async {
      final paid = await paySheet(
        tester,
        PersonalDebt(id: 'd2', type: 'receivable', personName: 'سالم',
            amount: 1000, currency: 'SAR'),
        usdCash,
        '390',
        '4',
      );
      // Typed in debt currency: 390 SAR at 1 USD = 4 SAR → 97.5 USD.
      expect(paid[0], closeTo(97.5, 1e-9));
      expect(paid[1], 390);
    });
  });
}
