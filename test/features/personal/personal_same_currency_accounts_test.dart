import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_account_card.dart';
import 'package:fyona_flutter/features/personal/presentation/widgets/personal_account_choice.dart';

/// «الكريمي» holds USD twice (جاري + توفير). Every Personal picker must list
/// both, tag them, and run the operation on exactly the chosen account.
void main() {
  final checking = PersonalBankAccount(
      id: 'kuraimi-usd-chk', bankName: 'الكريمي', currency: 'USD',
      balance: 100, accountType: 'checking');
  final savings = PersonalBankAccount(
      id: 'kuraimi-usd-sav', bankName: 'الكريمي', currency: 'USD',
      balance: 900, accountType: 'savings');
  final yer = PersonalBankAccount(
      id: 'kuraimi-yer', bankName: 'الكريمي', currency: 'YER_OLD',
      balance: 5, accountType: 'checking');
  final other = PersonalBankAccount(
      id: 'tadhamon-usd', bankName: 'التضامن', currency: 'USD', balance: 1);
  final cash1 = PersonalBankAccount(
      id: 'cash-a', bankName: 'كاش', currency: 'USD', accountType: 'cash');
  final cash2 = PersonalBankAccount(
      id: 'cash-b', bankName: 'كاش', currency: 'USD', accountType: 'cash');
  final all = [checking, savings, yer, other, cash1, cash2];

  group('personalBankAccountsOf', () {
    test('lists every account of the bank, never collapsed by currency', () {
      final rows = personalBankAccountsOf(all, 'الكريمي');
      expect(rows.map((a) => a.id),
          ['kuraimi-usd-chk', 'kuraimi-usd-sav', 'kuraimi-yer']);
    });
  });

  group('personalAccountNeedsTypeTag', () {
    test('tags only the same-currency siblings of one bank', () {
      expect(personalAccountNeedsTypeTag(all, checking), isTrue);
      expect(personalAccountNeedsTypeTag(all, savings), isTrue);
      expect(personalAccountNeedsTypeTag(all, yer), isFalse);
      // Same currency in ANOTHER bank is not ambiguous.
      expect(personalAccountNeedsTypeTag(all, other), isFalse);
      // Cash rows are bucketed elsewhere and never tagged.
      expect(personalAccountNeedsTypeTag(all, cash1), isFalse);
    });
  });

  group('resolvePersonalAccount', () {
    test('an explicit id always wins (the savings row stays savings)', () {
      final a = resolvePersonalAccount(all,
          accountId: 'kuraimi-usd-sav', bankName: 'الكريمي', currency: 'USD');
      expect(a?.id, 'kuraimi-usd-sav');
    });

    test('bank + currency is refused when ambiguous (no silent first row)',
        () {
      expect(
          resolvePersonalAccount(all, bankName: 'الكريمي', currency: 'USD'),
          isNull);
    });

    test('bank + currency resolves when unambiguous', () {
      expect(
          resolvePersonalAccount(all,
                  bankName: 'الكريمي', currency: 'yer_old')
              ?.id,
          'kuraimi-yer');
    });

    test('unknown id is not found', () {
      expect(resolvePersonalAccount(all, accountId: 'nope'), isNull);
    });
  });

  group('home card display key', () {
    test('USD جاري and USD توفير are two entries; cash still buckets', () {
      expect(homeAccountLogicalKey(checking),
          isNot(homeAccountLogicalKey(savings)));
      expect(homeAccountLogicalKey(cash1), homeAccountLogicalKey(cash2));
      final cashNew = PersonalBankAccount(
          id: 'c', bankName: 'كاش', currency: 'YER_NEW', accountType: 'cash');
      final cashYer = PersonalBankAccount(
          id: 'd', bankName: 'كاش', currency: 'YER', accountType: 'cash');
      expect(homeAccountLogicalKey(cashNew), homeAccountLogicalKey(cashYer));
    });
  });

  group('PersonalAccountTypeTag', () {
    Future<void> pump(WidgetTester tester, Brightness brightness,
        PersonalBankAccount account) async {
      await tester.runAsync(
          () => AppLocalizations.delegate.load(const Locale('ar')));
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: PersonalAccountTypeTag(accounts: all, account: account),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final b in Brightness.values) {
      testWidgets('shows جاري / توفير for siblings ($b)', (tester) async {
        await pump(tester, b, checking);
        expect(find.text('حساب جاري'), findsOneWidget);
        await pump(tester, b, savings);
        expect(find.text('حساب توفير'), findsOneWidget);
      });
    }

    testWidgets('renders nothing for an unambiguous account', (tester) async {
      await pump(tester, Brightness.light, yer);
      expect(find.text('حساب جاري'), findsNothing);
      expect(find.text('حساب توفير'), findsNothing);
    });
  });
}
