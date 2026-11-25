import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/help/catalog/help_catalog.dart';
import 'package:fyona_flutter/core/help/catalog/help_entry.dart';
import 'package:fyona_flutter/core/help/help_detector.dart';
import 'package:fyona_flutter/core/help/information_clicker.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

import '../test_utils.dart';

/// Detection accuracy of the Information Clicker: which element the ring
/// wraps, when it must stay silent, and how it coexists with taps and
/// native long presses.

const _save = HelpEntry(
  id: 't.save',
  keys: ['save'],
  icon: Icons.save_rounded,
  ar: 'يحفظ اللي كتبته.',
  en: 'Saves what you entered.',
);
const _card = HelpEntry(
  id: 't.card',
  texts: ['بطاقة الحساب', 'Account card'],
  icon: Icons.credit_card_rounded,
  ar: 'يفتح تفاصيل الحساب.',
  en: 'Opens the account details.',
  arHow: ['اضغط على البطاقة', 'شوف الحركات'],
  enHow: ['Tap the card', 'See the moves'],
);
const _inner = HelpEntry(
  id: 't.inner',
  texts: ['تعديل داخلي'],
  icon: Icons.edit_rounded,
  ar: 'يعدّل البطاقة.',
  en: 'Edits the card.',
);
const _gear = HelpEntry(
  id: 't.gear',
  icons: [Icons.settings],
  scopes: ['/demo'],
  icon: Icons.settings_rounded,
  arTitle: 'الإعدادات',
  enTitle: 'Settings',
  ar: 'يفتح الإعدادات.',
  en: 'Opens settings.',
);
const _tip = HelpEntry(
  id: 't.tip',
  texts: ['تلميح الزر'],
  icon: Icons.info_rounded,
  ar: 'زر عليه تلميح.',
  en: 'A button with a tooltip.',
);
const _row = HelpEntry(
  id: 't.row',
  row: true,
  scopes: ['/demo'],
  icon: Icons.person_rounded,
  arTitle: 'عميل',
  enTitle: 'Customer',
  ar: 'اضغط على العميل عشان تفتح ملفه.',
  en: 'Tap a customer to open their file.',
);
const _explicit = HelpEntry(
  id: 't.explicit',
  ids: ['demo.stat'],
  icon: Icons.bar_chart_rounded,
  arTitle: 'ملخص',
  enTitle: 'Summary',
  ar: 'ملخص سريع.',
  en: 'A quick summary.',
);
const _menuItem = HelpEntry(
  id: 't.menu',
  texts: ['أرشفة'],
  icon: Icons.archive_rounded,
  ar: 'يرسل العنصر للأرشيف.',
  en: 'Archives the item.',
);

final _catalog = HelpCatalog(
    const [_save, _card, _inner, _gear, _tip, _row, _explicit, _menuItem]);

Future<void> _pump(
  WidgetTester tester,
  Widget body, {
  bool arabic = true,
  String route = '/demo',
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: Locale(arabic ? 'ar' : 'en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => InformationClickerOverlay(
          catalog: _catalog,
          routeOf: () => route,
          arabicOf: () => arabic,
          child: child ?? const SizedBox(),
        ),
        home: body,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
}

/// Probe as the overlay does, without the hold.
HelpProbe? _probe(WidgetTester tester, Offset at) {
  final view = tester.view;
  return HelpDetector.probeAt(at,
          viewId: view.viewId,
          screen: view.physicalSize / view.devicePixelRatio)
      .probe;
}

HelpMatch? _resolve(WidgetTester tester, Offset at,
    {bool arabic = true, String route = '/demo'}) {
  final p = _probe(tester, at);
  if (p == null) return null;
  return _catalog.resolve(p, route: route, arabic: arabic);
}

Rect _rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

void _expectRect(Rect actual, Rect expected) {
  expect((actual.left - expected.left).abs(), lessThan(0.5),
      reason: 'left $actual vs $expected');
  expect((actual.top - expected.top).abs(), lessThan(0.5),
      reason: 'top $actual vs $expected');
  expect((actual.width - expected.width).abs(), lessThan(0.5),
      reason: 'width $actual vs $expected');
  expect((actual.height - expected.height).abs(), lessThan(0.5),
      reason: 'height $actual vs $expected');
}

/// Holds [at] for the full duration and returns whether the card opened.
Future<bool> _hold(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(at);
  await tester.pump(const Duration(milliseconds: 2100));
  await tester.pumpAndSettle();
  final shown = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_SpotCard')
      .evaluate()
      .isNotEmpty;
  await g.up();
  await tester.pumpAndSettle();
  return shown;
}

Future<void> _closeCard(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await ensureTestLocalization('ar');
    await ensureTestLocalization('en');
  });

  testWidgets('ring wraps exactly the visible button (not its tap padding)',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(
              key: const Key('b'), onPressed: () {}, child: const Text('حفظ')),
        ),
      ),
    );
    final at = tester.getCenter(find.text('حفظ'));
    final p = _probe(tester, at)!;
    // ElevatedButton's Material is the visible surface.
    final material = find.descendant(
        of: find.byKey(const Key('b')), matching: find.byType(Material));
    _expectRect(p.rect, _rectOf(tester, material.first));
    final m = _resolve(tester, at)!;
    expect(m.entry.id, 't.save');
    expect(m.title, 'حفظ');
    expect(m.via, 'key');
  });

  testWidgets('disabled button: still the visible bounds', (tester) async {
    await _pump(
      tester,
      const Scaffold(
        body: Center(
          child: ElevatedButton(
              key: Key('b'), onPressed: null, child: Text('حفظ')),
        ),
      ),
    );
    final p = _probe(tester, tester.getCenter(find.text('حفظ')))!;
    final material = find.descendant(
        of: find.byKey(const Key('b')), matching: find.byType(Material));
    _expectRect(p.rect, _rectOf(tester, material.first));
  });

  testWidgets('English label resolves through the same ARB key',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: TextButton(onPressed: () {}, child: const Text('Save')),
        ),
      ),
      arabic: false,
    );
    final m = _resolve(tester, tester.getCenter(find.text('Save')),
        arabic: false)!;
    expect(m.entry.id, 't.save');
    expect(m.body, 'Saves what you entered.');
  });

  testWidgets('background and decorative content never trigger',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        appBar: AppBar(title: const Text('حفظ')),
        body: const Column(
          children: [
            Text('حفظ'), // plain text with a known label, but not a button
            SizedBox(height: 300),
          ],
        ),
      ),
    );
    expect(_probe(tester, const Offset(200, 500)), isNull);
    expect(_probe(tester, tester.getCenter(find.text('حفظ').last)), isNull);
    expect(await _hold(tester, const Offset(200, 500)), isFalse);
    expect(await _hold(tester, tester.getCenter(find.text('حفظ').last)),
        isFalse);
  });

  testWidgets('a button without curated help stays silent', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(
              onPressed: () {}, child: const Text('زر لا يعرفه أحد')),
        ),
      ),
    );
    final at = tester.getCenter(find.text('زر لا يعرفه أحد'));
    expect(_probe(tester, at), isNotNull);
    expect(_resolve(tester, at), isNull);
    expect(await _hold(tester, at), isFalse);
  });

  testWidgets('nested: the inner button wins over its card', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: Card(
              child: InkWell(
                key: const Key('card'),
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('بطاقة الحساب'),
                      const SizedBox(height: 20),
                      TextButton(
                        key: const Key('inner'),
                        onPressed: () {},
                        child: const Text('تعديل داخلي'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final inner = _resolve(tester, tester.getCenter(find.text('تعديل داخلي')))!;
    expect(inner.entry.id, 't.inner');
    final innerProbe =
        _probe(tester, tester.getCenter(find.text('تعديل داخلي')))!;
    final innerMat = find.descendant(
        of: find.byKey(const Key('inner')), matching: find.byType(Material));
    _expectRect(innerProbe.rect, tester.getRect(innerMat.first));

    // Pressing the card body: the card, and its label never borrows the
    // inner button's text.
    final cardAt = tester.getCenter(find.text('بطاقة الحساب'));
    final card = _resolve(tester, cardAt)!;
    expect(card.entry.id, 't.card');
    final cardProbe = _probe(tester, cardAt)!;
    expect(cardProbe.texts, isNot(contains('تعديل داخلي')));
    _expectRect(cardProbe.rect, tester.getRect(find.byKey(const Key('card'))));
  });

  testWidgets('icon-only button matches its icon on its own screen only',
      (tester) async {
    Widget page() => Scaffold(
          appBar: AppBar(actions: [
            IconButton(
                key: const Key('gear'),
                onPressed: () {},
                icon: const Icon(Icons.settings)),
          ]),
        );
    await _pump(tester, page());
    final at = tester.getCenter(find.byKey(const Key('gear')));
    final m = _resolve(tester, at)!;
    expect(m.entry.id, 't.gear');
    expect(m.title, 'الإعدادات');
    expect(_resolve(tester, at, route: '/other'), isNull);
  });

  testWidgets('tooltip button: hold still opens help, tap still works',
      (tester) async {
    var taps = 0;
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: IconButton(
            tooltip: 'تلميح الزر',
            onPressed: () => taps++,
            icon: const Icon(Icons.star),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byIcon(Icons.star));
    expect(_resolve(tester, at)!.entry.id, 't.tip');
    expect(await _hold(tester, at), isTrue);
    expect(taps, 0, reason: 'the hold must not press the button');
    await _closeCard(tester);
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('long hold opens the card and never presses the button',
      (tester) async {
    var taps = 0;
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(
              onPressed: () => taps++, child: const Text('حفظ')),
        ),
      ),
    );
    final at = tester.getCenter(find.text('حفظ'));
    expect(await _hold(tester, at), isTrue);
    expect(taps, 0);
    await _closeCard(tester);
    // A quick tap afterwards behaves normally and shows nothing.
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SpotCard'),
        findsNothing);
  });

  testWidgets('quick taps never draw the ring', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(onPressed: () {}, child: const Text('حفظ')),
        ),
      ),
    );
    final g = await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ProgressBorder'),
        findsNothing);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('native long-press keeps its action and the clicker is silent',
      (tester) async {
    var longs = 0;
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () {},
            onLongPress: () => longs++,
            child: const Text('حفظ'),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.text('حفظ'));
    expect(_probe(tester, at), isNull);
    expect(await _hold(tester, at), isFalse);
    expect(longs, 1);
  });

  testWidgets('text fields and ClickerQuiet zones stay silent',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Column(
          children: [
            const TextField(key: Key('f')),
            ClickerQuiet(
              child: ElevatedButton(
                  onPressed: () {}, child: const Text('حفظ')),
            ),
          ],
        ),
      ),
    );
    expect(_probe(tester, tester.getCenter(find.byKey(const Key('f')))),
        isNull);
    expect(_probe(tester, tester.getCenter(find.text('حفظ'))), isNull);
  });

  testWidgets('scrolled list: ring follows the row actually under the finger',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 30; i++)
              ListTile(
                key: Key('row$i'),
                title: Text(i == 17 ? 'بطاقة الحساب' : 'سطر رقم $i'),
                onTap: () {},
              ),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('row17'));
    expect(row, findsOneWidget);
    final at = tester.getCenter(row);
    final p = _probe(tester, at)!;
    _expectRect(p.rect, tester.getRect(row));
    expect(_resolve(tester, at)!.entry.id, 't.card');
    expect(await _hold(tester, at), isTrue);
  });

  testWidgets('record rows fall back to the section row help', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            ListTile(title: const Text('أحمد محمد'), onTap: () {}),
          ],
        ),
      ),
    );
    final at = tester.getCenter(find.text('أحمد محمد'));
    final m = _resolve(tester, at)!;
    expect(m.entry.id, 't.row');
    expect(m.title, 'عميل', reason: 'never the raw record text');
    expect(_resolve(tester, at, route: '/elsewhere'), isNull);
  });

  testWidgets('bottom sheet and dialog buttons are detected exactly',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: FilledButton(
                        key: const Key('sheetBtn'),
                        onPressed: () {},
                        child: const Text('حفظ')),
                  ),
                ),
                child: const Text('open sheet'),
              ),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    actions: [
                      TextButton(
                          key: const Key('dlgBtn'),
                          onPressed: () {},
                          child: const Text('حفظ')),
                    ],
                  ),
                ),
                child: const Text('open dialog'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    final sheetBtn = find.byKey(const Key('sheetBtn'));
    final p = _probe(tester, tester.getCenter(sheetBtn))!;
    _expectRect(
        p.rect,
        tester.getRect(find
            .descendant(of: sheetBtn, matching: find.byType(Material))
            .first));
    expect(_resolve(tester, tester.getCenter(sheetBtn))!.entry.id, 't.save');
    // The sheet background is not a target.
    expect(
        _resolve(tester,
            tester.getTopLeft(find.byType(BottomSheet)) + const Offset(6, 6)),
        isNull);
    Navigator.of(tester.element(sheetBtn)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    final dlgBtn = find.byKey(const Key('dlgBtn'));
    final d = _probe(tester, tester.getCenter(dlgBtn))!;
    _expectRect(
        d.rect,
        tester.getRect(find
            .descendant(of: dlgBtn, matching: find.byType(Material))
            .first));
    // Barrier (outside the dialog) is never a target.
    expect(_probe(tester, const Offset(5, 300)), isNull);
  });

  testWidgets('popup menu items, chips and tabs are their own targets',
      (tester) async {
    await _pump(
      tester,
      DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            bottom: const TabBar(tabs: [Tab(text: 'حفظ'), Tab(text: 'ب')]),
            actions: [
              PopupMenuButton<int>(
                key: const Key('menu'),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1, child: Text('أرشفة')),
                ],
              ),
            ],
          ),
          body: Center(
            child: ActionChip(
                key: const Key('chip'),
                label: const Text('أرشفة'),
                onPressed: () {}),
          ),
        ),
      ),
    );
    final tab = _probe(tester, tester.getCenter(find.text('حفظ')))!;
    final tabRect = tester.getRect(find.ancestor(
        of: find.text('حفظ'), matching: find.byType(InkWell)).first);
    _expectRect(tab.rect, tabRect);
    expect(_resolve(tester, tester.getCenter(find.text('حفظ')))!.entry.id,
        't.save');
    expect(_resolve(tester, tester.getCenter(find.byKey(const Key('chip'))))!
        .entry
        .id, 't.menu');
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    final item = find.text('أرشفة').last;
    final m = _resolve(tester, tester.getCenter(item))!;
    expect(m.entry.id, 't.menu');
    final itemProbe = _probe(tester, tester.getCenter(item))!;
    final ink = find.ancestor(of: item, matching: find.byType(InkWell)).first;
    _expectRect(itemProbe.rect, tester.getRect(ink));
  });

  testWidgets('FAB and bottom navigation items are detected', (tester) async {
    await _pump(
      tester,
      Scaffold(
        floatingActionButton: FloatingActionButton(
            key: const Key('fab'),
            onPressed: () {},
            child: const Icon(Icons.settings)),
        bottomNavigationBar: BottomNavigationBar(
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: 'حفظ'),
            BottomNavigationBarItem(icon: Icon(Icons.list), label: 'ب'),
          ],
        ),
      ),
    );
    final fab = find.byKey(const Key('fab'));
    final p = _probe(tester, tester.getCenter(fab))!;
    _expectRect(p.rect, tester.getRect(fab));
    expect(_resolve(tester, tester.getCenter(fab))!.entry.id, 't.gear');
    final nav = _resolve(tester, tester.getCenter(find.text('حفظ')));
    expect(nav?.entry.id, 't.save');
  });

  testWidgets('RTL and LTR give the same exact bounds', (tester) async {
    for (final rtl in [true, false]) {
      await _pump(
        tester,
        Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            body: Row(
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 40),
                  child: OutlinedButton(
                      key: const Key('o'),
                      onPressed: () {},
                      child: const Text('حفظ')),
                ),
              ],
            ),
          ),
        ),
        arabic: rtl,
      );
      final at = tester.getCenter(find.text('حفظ'));
      final p = _probe(tester, at)!;
      final mat = find
          .descendant(of: find.byKey(const Key('o')), matching: find.byType(Material))
          .first;
      _expectRect(p.rect, tester.getRect(mat));
    }
  });

  testWidgets('a bare switch is explained by its row label, ring on the switch',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            Row(
              children: [
                const Expanded(child: Text('بطاقة الحساب')),
                Switch(key: const Key('sw'), value: true, onChanged: (_) {}),
              ],
            ),
          ],
        ),
      ),
    );
    final sw = find.byKey(const Key('sw'));
    final at = tester.getCenter(sw);
    final p = _probe(tester, at)!;
    expect(p.rect.width, lessThan(tester.getRect(sw).width + 0.5));
    expect(_resolve(tester, at)!.entry.id, 't.card');
  });

  testWidgets('explicit HelpTarget registers a non-button element',
      (tester) async {
    await _pump(
      tester,
      const Scaffold(
        body: Center(
          child: HelpTarget(
            id: 'demo.stat',
            child: SizedBox(
                key: Key('stat'), width: 160, height: 90, child: Text('١٢')),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byKey(const Key('stat')));
    final m = _resolve(tester, at)!;
    expect(m.entry.id, 't.explicit');
    _expectRect(_probe(tester, at)!.rect,
        tester.getRect(find.byKey(const Key('stat'))));
  });

  testWidgets('card shows icon, idea and only real steps; settles (finite)',
      (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: InkWell(
                onTap: () {},
                child: const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('بطاقة الحساب'),
                )),
          ),
        ),
      ),
    );
    final g =
        await tester.startGesture(tester.getCenter(find.text('بطاقة الحساب')));
    await tester.pump(const Duration(milliseconds: 2100));
    // pumpAndSettle completes: no infinite animation anywhere in the card.
    await tester.pumpAndSettle();
    expect(find.text('يفتح تفاصيل الحساب.'), findsOneWidget);
    expect(find.text('طريقة الاستخدام'), findsOneWidget);
    expect(find.text('شوف الحركات'), findsOneWidget);
    expect(find.byIcon(Icons.credit_card_rounded), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    await _closeCard(tester);
    expect(find.text('يفتح تفاصيل الحساب.'), findsNothing);
  });
}
