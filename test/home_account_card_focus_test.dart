import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_account_card.dart';

/// After a branch switch (or a reload that passes through the empty card),
/// the focused bank card must be full size and fully opaque at once.
void main() {
  List<PersonalBankAccount> banks(List<String> names) => [
        for (final (i, name) in names.indexed)
          PersonalBankAccount(
              id: '$name$i', bankName: name, balance: 10, currency: 'USD', accountType: 'checking'),
      ];

  Widget app(List<PersonalBankAccount> accounts) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ar'),
        home: Scaffold(body: HomeAccountCard(accounts: accounts, distinctAccountTypes: true)),
      );

  double opacityOf(WidgetTester tester, String bank) => tester
      .widget<AnimatedOpacity>(find
          .ancestor(of: find.text(bank).first, matching: find.byType(AnimatedOpacity))
          .first)
      .opacity;

  double scaleOf(WidgetTester tester, String bank) => tester
      .widget<Transform>(find
          .ancestor(of: find.text(bank).first, matching: find.byType(Transform))
          .last)
      .transform
      .entry(0, 0);

  Future<void> swipeTo(WidgetTester tester, int page) async {
    tester.widget<PageView>(find.byType(PageView)).controller!.animateToPage(page,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    await tester.pumpAndSettle();
  }

  testWidgets('the focused card is full size after a branch switch and a reload',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(app(banks(['بنك أ', 'بنك ب', 'بنك ج'])));
    await tester.pumpAndSettle();
    // Focus the third bank of branch 1 (swipe to the next).
    await swipeTo(tester, 2);
    expect(opacityOf(tester, 'بنك ج'), 1.0);

    // Switch branch: loading (empty card), then the other branch's banks.
    await tester.pumpWidget(app(const []));
    await tester.pump();
    await tester.pumpWidget(app(banks(['الراجحي', 'الأهلي'])));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'الراجحي'), 1.0);
    expect(scaleOf(tester, 'الراجحي'), closeTo(1.0, 1e-9));
    expect(opacityOf(tester, 'الأهلي'), lessThan(1.0));

    // Focus the second bank, then a data reload of the same branch keeps it
    // focused at full size.
    await swipeTo(tester, 1);
    expect(opacityOf(tester, 'الأهلي'), 1.0);
    await tester.pumpWidget(app(const []));
    await tester.pump();
    await tester.pumpWidget(app(banks(['الراجحي', 'الأهلي'])));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'الأهلي'), 1.0);
    expect(scaleOf(tester, 'الأهلي'), closeTo(1.0, 1e-9));
    expect(tester.takeException(), isNull);
  });
}
