import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_count_page.dart';

/// Linked inventory counting: ONE real entry per product, the rest are locked
/// equivalents. The زبادي scenario (832 قطع = 104 باكيت ×8).
void main() {
  String textOf(WidgetTester tester, String label) =>
      tester
          .widget<TextField>(find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == label))
          .controller
          ?.text
          .replaceAll('\u200F', '') ??
      '';

  Map<String, dynamic> record({bool withCarton = false, bool empty = false}) => {
        'id': 'r1',
        'scope': empty ? 'category' : 'product',
        'lines': empty ? [] : [
          {
            'product_id': 'p1',
            'name': 'زبادي',
            'unit': 'قطعة',
            'image': null,
          },
        ],
        'units': {
          'p1': [
            {'unit_id': 'u1', 'name': 'باكيت', 'factor': 8},
            if (withCarton)
              {'unit_id': 'u2', 'name': 'كرتون', 'factor': 64},
          ],
        },
      };

  Finder boxField(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);

  Future<void> pump(WidgetTester tester,
      {bool withCarton = false, bool empty = false}) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ReconInventoryCountPage(
            record: record(withCarton: withCarton, empty: empty)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('50 قطع shows 6 باكيت + 2 قطعة + base total 50',
      (tester) async {
    await pump(tester);
    await tester.enterText(boxField('قطعة'), '50');
    await tester.pumpAndSettle();
    // The باكيت field locks and shows the whole+remainder equivalent
    // (never a bare «6.25 باكيت»).
    expect(find.text('6 باكيت + 2 قطعة'), findsOneWidget);
    // Single converted base total.
    expect(find.textContaining('50'), findsWidgets);
    expect(find.textContaining('الإجمالي'), findsOneWidget);
  });


  testWidgets('99 قطع shows 12 باكيت + 3 قطعة', (tester) async {
    await pump(tester);
    await tester.enterText(boxField('قطعة'), '99');
    await tester.pumpAndSettle();
    expect(find.text('12 باكيت + 3 قطعة'), findsOneWidget);
  });

  testWidgets('6 باكيت shows 48 قطع', (tester) async {
    await pump(tester);
    await tester.enterText(boxField('باكيت (×8)'), '6');
    await tester.pumpAndSettle();
    expect(find.text('48 قطعة'), findsOneWidget);
  });

  testWidgets('18 قطع shows 2 باكيت + 2 قطعة (never 2.25)', (tester) async {
    await pump(tester);
    await tester.enterText(boxField('قطعة'), '18');
    await tester.pumpAndSettle();
    expect(find.text('2 باكيت + 2 قطعة'), findsOneWidget);
  });

  testWidgets('99 قطع with carton+pack+piece cascades exactly',
      (tester) async {
    await pump(tester, withCarton: true);
    await tester.enterText(boxField('قطعة'), '99');
    await tester.pumpAndSettle();
    expect(find.text('12 باكيت + 3 قطعة'), findsOneWidget);
    expect(find.text('1 كرتون + 4 باكيت + 3 قطعة'), findsWidgets);
    expect(find.textContaining('= 1 كرتون + 4 باكيت + 3 قطعة'),
        findsOneWidget);
  });

  testWidgets('clearing reopens all fields with no stale value', (tester) async {
    await pump(tester);
    await tester.enterText(boxField('قطعة'), '50');
    await tester.pumpAndSettle();
    // Clear the active box fully.
    await tester.enterText(boxField('قطعة'), '');
    await tester.pumpAndSettle();
    final piece = tester.widget<TextField>(boxField('قطعة'));
    final pack = tester.widget<TextField>(boxField('باكيت (×8)'));
    expect(textOf(tester, 'قطعة'), isEmpty);
    expect(textOf(tester, 'باكيت (×8)'), isEmpty);
    expect(piece.readOnly, isFalse);
    expect(pack.readOnly, isFalse);
  });

  testWidgets('empty category shows a calm centered message and blocks run',
      (tester) async {
    await pump(tester, empty: true);
    expect(find.text('هذا التصنيف لا يحتوي على أي منتج'), findsOneWidget);
    final run = tester.widget<FilledButton>(
        find.ancestor(of: find.text('تنفيذ المطابقة'), matching: find.byType(FilledButton)));
    expect(run.onPressed, isNull);
  });
}
