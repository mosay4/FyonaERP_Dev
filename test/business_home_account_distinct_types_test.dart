import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_account_card.dart';

/// The Business home card must keep a currency that exists as BOTH جاري and
/// توفير as two independent entries (issue #4). Personal behavior (default)
/// stays collapsed to one row per currency.
void main() {
  List<PersonalBankAccount> twoTypes() => [
        PersonalBankAccount(
            id: '1',
            bankName: 'جيب',
            balance: 99,
            currency: 'USD',
            accountType: 'checking'),
        PersonalBankAccount(
            id: '2',
            bankName: 'جيب',
            balance: 99,
            currency: 'USD',
            accountType: 'savings'),
      ];

  Future<void> pump(WidgetTester tester,
      {required bool distinct}) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ar'),
      home: Scaffold(
        body: HomeAccountCard(
            accounts: twoTypes(), distinctAccountTypes: distinct),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('business: same currency جاري + توفير → 2 independent entries',
      (tester) async {
    await pump(tester, distinct: true);
    // Two accounts in the group → the multi-count badge «2 عملات».
    expect(find.text('2 عملات'), findsOneWidget);
    // The active currency wheel exposes the real type label.
    expect(find.text('حساب جاري'), findsOneWidget);
  });

  testWidgets('personal default: same currency collapses to one entry',
      (tester) async {
    await pump(tester, distinct: false);
    expect(find.text('2 عملات'), findsNothing);
    expect(find.text('حساب جاري'), findsOneWidget);
  });
}
