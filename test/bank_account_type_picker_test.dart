import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/sales/presentation/widgets/sale_payment_section.dart'
    show openBankCurrencyPicker, AccountCurrencyPick;
import 'package:fyona_flutter/shared/widgets/account_type_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_add_movement_sheet.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';

/// Regression for the bank account pickers:
///  - a currency that exists as BOTH checking (جاري) and savings (توفير)
///    must show BOTH rows, each with its type label and colored bar;
///  - the picked account is exactly the one tapped (not "the first match");
///  - savings = green bar, checking = blue bar.
void main() {
  Map<String, String> acc(String id, String cur, String type, String bal) => {
        'id': id,
        'bank': 'بنك الاختبار',
        'name': 'حساب',
        'balance': bal,
        'currency': cur,
        'type': type,
      };

  Future<AccountCurrencyPick?> open(WidgetTester tester,
      List<Map<String, String>> accounts) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    AccountCurrencyPick? picked;
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                picked = await openBankCurrencyPicker(context, accounts);
              },
              child: const Text('OPEN'),
            ),
          ),
        );
      }),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    // Expand the first (only) bank group.
    await tester.tap(find.text('بنك الاختبار').last);
    await tester.pumpAndSettle();
    return picked;
  }

  test('type colors: checking blue, savings green', () {
    expect(isSavingsType('savings'), true);
    expect(isSavingsType('checking'), false);
    expect(accountTypeBarColor('savings'), kSavingsBar);
    expect(accountTypeBarColor('checking'), kCheckingBar);
    expect(kCheckingBar.toARGB32(), isNot(kSavingsBar.toARGB32()));
  });

  testWidgets(
      'same currency as checking + savings shows BOTH with labels and bars',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    AccountCurrencyPick? picked;
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                picked = await openBankCurrencyPicker(context, [
                  acc('a1', 'USD', 'checking', '100'),
                  acc('a2', 'USD', 'savings', '200'),
                ]);
              },
              child: const Text('OPEN'),
            ),
          ),
        );
      }),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنك الاختبار').last);
    await tester.pumpAndSettle();

    // Both type labels + both bars are present.
    expect(find.text('حساب جاري'), findsOneWidget);
    expect(find.text('حساب توفير'), findsOneWidget);
    final bars = tester.widgetList<AccountTypeBar>(find.byType(AccountTypeBar));
    final types = bars.map((b) => b.type).toSet();
    expect(types, containsAll(<String>['checking', 'savings']));

    // Tapping the SAVINGS row returns exactly the savings account.
    await tester.tap(find.text('حساب توفير'));
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    expect(picked!.accountId, 'a2');
    expect(picked!.currency, 'USD');
  });

  testWidgets('single-type currency keeps one plain row (no duplicate)',
      (tester) async {
    await open(tester, [acc('a1', 'SAR', 'checking', '50')]);
    expect(find.text('ريال سعودي'), findsOneWidget);
    expect(find.text('حساب جاري'), findsOneWidget);
    expect(find.text('حساب توفير'), findsNothing);
  });

  testWidgets(
      'income/expense sheet: picking a bank lists checking AND savings for the '
      'same currency with their type labels', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        businessPaymentAccountsProvider.overrideWith((ref) async => [
              PersonalBankAccount(
                  id: 'a1', bankName: 'بنك الاختبار',
                  balance: 100, currency: 'USD', accountType: 'checking'),
              PersonalBankAccount(
                  id: 'a2', bankName: 'بنك الاختبار',
                  balance: 200, currency: 'USD', accountType: 'savings'),
            ]),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showBusinessAddMovementSheet(context,
                    initialType: 'income'),
                child: const Text('OPEN'),
              ),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    // Choose the bank payment method (toggle), then open the bank dropdown.
    await tester.tap(find.text('حساب بنكي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('يرجى اختيار الحساب أولاً'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنك الاختبار').first);
    await tester.pumpAndSettle();
    // Open the currency picker → BOTH types appear with their labels.
    await tester.tap(find.text('اختر العملة أولاً'));
    await tester.pumpAndSettle();
    expect(find.text('حساب جاري'), findsOneWidget);
    expect(find.text('حساب توفير'), findsOneWidget);
    final bars = tester.widgetList<AccountTypeBar>(find.byType(AccountTypeBar));
    expect(bars.map((b) => b.type).toSet(),
        containsAll(<String>['checking', 'savings']));
  });
}
