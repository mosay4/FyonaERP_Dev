import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/reports/personal_report_data.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/reports/personal_report_sections.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/reports/personal_report_widgets.dart';

/// Owner rule for the Personal report KPI tiles: the title and the amount
/// (or percentage) only — no descriptions or side stats. The report
/// currency picker is ONE list of exactly the enabled currencies.
void main() {
  Widget app(Widget Function(BuildContext) body) => MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (c) => SingleChildScrollView(child: body(c))),
        ),
      );

  final now = DateTime(2026, 11, 20);
  final data = PersonalReportData.build(
    currency: 'YER_OLD',
    window: PersonalReportWindow(
        'month', DateTime(2026, 11, 1), DateTime(2026, 12, 1)),
    rate: (a, b) => 1,
    transactions: const [],
    now: now,
  );

  testWidgets('KPI tiles show only title + amount / percentage',
      (tester) async {
    late AppLocalizations l10n;
    await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('ar')));
    await tester.pumpWidget(app((c) {
      l10n = AppLocalizations.of(c);
      return PersonalReportSections(c, data).kpiGrid();
    }));
    await tester.pumpAndSettle();

    expect(find.byType(PrKpi), findsNWidgets(4));
    expect(find.text(l10n.translate('prepSavingsRate')), findsOneWidget);
    expect(find.text(l10n.translate('prepNet')), findsOneWidget);
    // No descriptions / side stats under any tile.
    for (final k in ['prepAvgDaily', 'prepToGoals']) {
      expect(find.textContaining(l10n.translate(k)), findsNothing, reason: k);
    }
    expect(
        find.textContaining(
            l10n.translate('prepOps', params: {'n': '0'}).replaceAll('0', '').trim()),
        findsNothing);
    expect(find.byType(PrChange), findsNothing);
  });

  testWidgets('net-worth hero has no description line', (tester) async {
    late AppLocalizations l10n;
    await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('ar')));
    await tester.pumpWidget(app((c) {
      l10n = AppLocalizations.of(c);
      return PersonalReportSections(c, data).netWorth();
    }));
    await tester.pumpAndSettle();
    expect(find.text(l10n.translate('prepNetWorthHint')), findsNothing);
  });

  testWidgets('currency picker: one list, no headers, only enabled',
      (tester) async {
    const enabled = ['USD', 'YER_OLD', 'SAR'];
    late AppLocalizations l10n;
    await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('ar')));
    await tester.pumpWidget(app((c) {
      l10n = AppLocalizations.of(c);
      return TextButton(
        onPressed: () => showPersonalReportCurrencyPicker(c,
            currencies: enabled, current: 'USD'),
        child: const Text('open'),
      );
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(enabled.length));
    expect(find.text(l10n.translate('prepCurrencyMine')), findsNothing);
    expect(find.text(l10n.translate('prepCurrencyAll')), findsNothing);
    // Short list → no search field either.
    expect(find.byType(TextField), findsNothing);
    // Every row has a flag/marker leading.
    expect(find.text('¤'), findsNothing);
  });
}
