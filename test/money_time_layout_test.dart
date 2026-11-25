import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/time_format.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/widgets/product_picker.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/net_worth_frame.dart';
import 'package:fyona_flutter/shared/widgets/bank_detail/bank_detail_view.dart';
import 'package:fyona_flutter/shared/widgets/money_text.dart';

/// Owner reports: amounts + currency never cut/ellipsized/overlapping, the
/// wealth-card arrow never moves, times follow the phone's 12/24h setting,
/// and the product picker's save button is always fully visible.
void main() {
  Widget host(Widget child, {TextDirection dir = TextDirection.rtl}) =>
      MaterialApp(
        home: Directionality(
          textDirection: dir,
          child: Scaffold(body: child),
        ),
      );

  void noEllipsis(WidgetTester tester) {
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      expect(t.overflow, isNot(TextOverflow.ellipsis),
          reason: 'ellipsized: ${t.data}');
    }
  }

  group('MoneyText', () {
    tearDown(() => setCurrentLocale('ar'));

    for (final lang in ['ar', 'en']) {
      for (final width in [90.0, 160.0, 320.0]) {
        testWidgets('long number + currency fits $width px ($lang)',
            (tester) async {
          setCurrentLocale(lang);
          await tester.pumpWidget(host(Center(
            child: SizedBox(
              width: width,
              child: MoneyText(
                amount: fmtNum(12345678901234567890.0),
                currency: currencySymbol('YER_OLD'),
                style: const TextStyle(fontSize: 26),
              ),
            ),
          ), dir: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr));
          expect(tester.takeException(), isNull);
          noEllipsis(tester);
          // Whole pair stays inside the given width.
          final box = tester.getSize(find.byType(MoneyText));
          expect(box.width, lessThanOrEqualTo(width + .01));
          // Both parts are rendered in full (no truncation of the strings).
          expect(find.text(currencySymbol('YER_OLD')), findsOneWidget);
          final number = tester.widget<Text>(find.textContaining('1,234'));
          final cur = tester.widget<Text>(find.text(currencySymbol('YER_OLD')));
          expect(cur.style!.fontSize!, lessThan(number.style!.fontSize!));
        });
      }
    }

    testWidgets('number and currency never overlap (RTL)', (tester) async {
      setCurrentLocale('ar');
      await tester.pumpWidget(host(Center(
        child: SizedBox(
          width: 120,
          child: MoneyText(
              amount: '13,500',
              currency: currencySymbol('YER_OLD'),
              style: const TextStyle(fontSize: 15)),
        ),
      )));
      final n = tester.getRect(find.text('13,500'));
      final c = tester.getRect(find.text('ريال يمني قديم'));
      expect(n.overlaps(c), isFalse);
      // RTL: the number reads first (on the right), the currency after it.
      expect(c.right, lessThanOrEqualTo(n.left + .01));
    });

    test('splitMoney separates leading/trailing numbers', () {
      expect(MoneyText.splitMoney('1,250.5 ريال يمني قديم'),
          ('1,250.5', 'ريال يمني قديم'));
      expect(MoneyText.splitMoney('-300 USD'), ('-300', 'USD'));
      expect(MoneyText.splitMoney('USD 42'), ('42', 'USD'));
      expect(MoneyText.splitMoney('—'), ('—', ''));
    });
  });

  testWidgets('bank accounts list: long names and 20-digit balances fit',
      (tester) async {
    setCurrentLocale('ar');
    addTearDown(() => setCurrentLocale('ar'));
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: BankDetailView(
          bankName: 'بنك الكريمي للتمويل الأصغر الإسلامي',
          accounts: const [
            BankDetailAccount(
                id: '1',
                currency: 'USD',
                typeLabel: 'حساب جاري',
                balance: 12345678901234567890.0),
            BankDetailAccount(
                id: '2',
                currency: 'YER_OLD',
                typeLabel: 'حساب توفير',
                balance: 180000),
          ],
          movements: const [],
          walletCurrency: 'USD',
          initialCurrency: kBankAllCurrencies,
          toWallet: (a, _) => a,
          onRefresh: () async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 12 && !tester.any(find.text('حساب توفير')); i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.ensureVisible(find.text('حساب توفير'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    // Name and type are separate, complete texts — no «— د…» truncation.
    final type = find.text('حساب توفير');
    final tile = find.ancestor(of: type, matching: find.byType(Row)).first;
    // Full currency name on the name side + the small tag beside the amount.
    expect(
        find.descendant(
            of: tile, matching: find.text(currencyName('YER_OLD'))),
        findsNWidgets(2));
    final money = find.descendant(of: tile, matching: find.byType(MoneyText));
    expect(money, findsOneWidget);
    final amountRect = tester.getRect(money);
    expect(amountRect.overlaps(tester.getRect(type)), isFalse);
    for (final t in tester.widgetList<Text>(
        find.descendant(of: tile, matching: find.byType(Text)))) {
      expect(t.overflow, isNot(TextOverflow.ellipsis), reason: t.data);
    }
  });

  group('time format follows the phone 12/24h setting', () {
    final t = DateTime(2026, 11, 25, 15, 5);
    final morning = DateTime(2026, 11, 25, 9, 7);

    test('12-hour', () {
      expect(formatClock(t, use24h: false, locale: 'en'), '3:05 PM');
      expect(formatClock(morning, use24h: false, locale: 'en'), '9:07 AM');
      expect(formatClock(t, use24h: false, locale: 'ar'), '3:05 م');
      expect(formatClock(morning, use24h: false, locale: 'ar'), '9:07 ص');
    });

    test('24-hour', () {
      expect(formatClock(t, use24h: true, locale: 'en'), '15:05');
      expect(formatClock(morning, use24h: true, locale: 'ar'), '09:07');
    });

    test('date-time and stored clocks', () {
      expect(formatDateTimeDisplay(t, use24h: false, locale: 'ar'),
          '2026/11/25 3:05 م');
      expect(formatDateTimeDisplay(t, use24h: true, locale: 'en'),
          '2026/11/25 15:05');
      expect(formatStoredClock('21:30', use24h: false, locale: 'en'),
          '9:30 PM');
      expect(formatStoredClock('bad', use24h: false), 'bad');
      expect(formatTimeOfDay(const TimeOfDay(hour: 0, minute: 0),
          use24h: false, locale: 'en'), '12:00 AM');
    });

    for (final h24 in [false, true]) {
      testWidgets('reads MediaQuery.alwaysUse24HourFormat=$h24',
          (tester) async {
        late String out;
        await tester.pumpWidget(MaterialApp(
          locale: const Locale('en'),
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: h24),
            child: Builder(builder: (c) {
              out = formatClock(t, context: c);
              return Text(out);
            }),
          ),
        ));
        expect(out, h24 ? '15:05' : '3:05 PM');
      });
    }
  });

  group('wealth card arrow is pinned top-left', () {
    for (final dir in TextDirection.values) {
      testWidgets('same place in both states ($dir)', (tester) async {
        var expanded = true;
        await tester.pumpWidget(host(
          Padding(
            padding: const EdgeInsets.all(20),
            child: StatefulBuilder(
              builder: (c, set) => Align(
                alignment: Alignment.topCenter,
                child: NetWorthFrame(
                  expanded: expanded,
                  onToggle: () => set(() => expanded = !expanded),
                  expandedChild: const SizedBox(
                      key: ValueKey('card'), height: 180, width: 320),
                  collapsedChild: const SizedBox(
                      key: ValueKey('pill'), height: 52, width: 320),
                ),
              ),
            ),
          ),
          dir: dir,
        ));
        final arrow = find.byKey(const ValueKey('netWorthToggleArrow'));
        final frame = find.byType(NetWorthFrame);
        final open = tester.getRect(arrow);
        final frameRect = tester.getRect(frame);
        // Physical top-left corner of the card.
        expect(open.left - frameRect.left, kNetWorthArrowInset);
        expect(open.top - frameRect.top, kNetWorthArrowInset);

        await tester.tap(arrow);
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.getRect(arrow).topLeft, open.topLeft,
            reason: 'arrow moved mid-animation');
        await tester.pumpAndSettle();
        expect(expanded, isFalse);
        expect(tester.getRect(arrow).topLeft, open.topLeft);

        await tester.tap(arrow);
        await tester.pumpAndSettle();
        expect(expanded, isTrue);
        expect(tester.getRect(arrow).topLeft, open.topLeft);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('product picker save button fully visible on a small screen',
      (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'data': [
            for (var i = 0; i < 12; i++)
              {
                'id': '$i',
                'name': 'منتج $i',
                'stock': 5,
                'price': '10',
                'unit': 'قطعة',
                'is_service': false,
              }
          ]
        }));
      }));
    final api = InventoryApi(ApiClient(dio: dio));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showProductMultiPicker(context,
                  api: api, title: 'بحث وتحديد منتجات', showCategories: true),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final save = find.ancestor(
        of: find.byIcon(Icons.check),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(save, findsWidgets);
    final rect = tester.getRect(save.last);
    expect(rect.bottom, lessThanOrEqualTo(568 - 34 + .01),
        reason: 'save button hidden behind the bottom inset');
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.height, greaterThanOrEqualTo(48));

    // Keyboard up: the button stays above it.
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final up = tester.getRect(save.last);
    expect(up.bottom, lessThanOrEqualTo(568 - 260 + .01));
    expect(up.top, greaterThanOrEqualTo(0));
  });
}
