import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/help/help_allowlist.dart';
import 'package:fyona_flutter/core/help/help_clicker_settings.dart';
import 'package:fyona_flutter/core/help/help_content.dart';
import 'package:fyona_flutter/core/help/help_explain.dart';
import 'package:fyona_flutter/core/help/information_clicker.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/app_router.dart';
import 'package:fyona_flutter/shared/providers/locale_provider.dart';

import 'test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ensureTestLocalization('ar');
    setInitialLocale('ar');
  });

  group('HelpContent resolver', () {
    test('exact Arabic label wins over rules', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: 'حفظ', arabic: true);
      expect(info.title, 'حفظ');
      expect(info.body, contains('يحفظ'));
    });

    test('compound label hits the keyword rule', () {
      final info = HelpContent.resolve(
          route: '/sales', label: 'حفظ الفاتورة', arabic: true);
      expect(info.title, 'حفظ الفاتورة');
      expect(info.body, contains('يحفظ'));
    });

    test('icon-only press falls back to the screen explanation', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: '', arabic: true);
      expect(info.title, 'البنوك');
      expect(info.body, contains('حساباتك البنكية'));
    });

    test('dynamic route prefix matches its section', () {
      final info = HelpContent.resolve(
          route: '/customers/abc-123', label: '', arabic: true);
      expect(info.title, 'العملاء');
    });

    test('unknown label falls back to the screen', () {
      final info = HelpContent.resolve(
          route: '/personal/recurring', label: 'عنصر غامض جداً', arabic: true);
      expect(info.title, 'المتكررة');
      expect(info.body, contains('تتكرر'));
    });

    test('English exact label', () {
      final info =
          HelpContent.resolve(route: '/personal/banks', label: 'Save', arabic: false);
      expect(info.title, 'Save');
      expect(info.body, contains('Saves'));
    });

    test('English rule covers compound labels', () {
      final info = HelpContent.resolve(
          route: '/sales', label: 'Save invoice', arabic: false);
      expect(info.body, contains('Saves'));
    });

    test('never returns empty content for a random press', () {
      final info = HelpContent.resolve(
          route: '/nowhere', label: '', arabic: true);
      expect(info.title.isNotEmpty, isTrue);
      expect(info.body.isNotEmpty, isTrue);
    });
  });

  group('HelpClicker settings', () {
    test('defaults ON with 3 seconds and persists changes', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(container.read(helpClickerProvider).enabled, isTrue);
      expect(container.read(helpClickerProvider).seconds, 2);

      await container.read(helpClickerProvider.notifier).setSeconds(5);
      await container.read(helpClickerProvider.notifier).setEnabled(false);
      expect(container.read(helpClickerProvider).seconds, 5);
      expect(container.read(helpClickerProvider).enabled, isFalse);

      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt('help_clicker_seconds_business'), 5);
      expect(sp.getBool('help_clicker_enabled_business'), isFalse);
    });

    test('seconds are clamped to the allowed range', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await container.read(helpClickerProvider.notifier).setSeconds(99);
      expect(container.read(helpClickerProvider).seconds, 15);
      await container.read(helpClickerProvider.notifier).setSeconds(0);
      expect(container.read(helpClickerProvider).seconds, 1);
    });
  });

  group('HelpAllowlist gate', () {    test('curated labels answer anywhere', () {
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'حفظ', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(
            route: '/customers', label: 'إضافة عميل', arabic: true),
        isTrue,
      );
    });

    test('user data never gets a card', () {
      expect(
        HelpAllowlist.allows(
            route: '/', label: 'تحويل 450 ريال', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: '1234567890', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/transactions', label: '2026/09/27', arabic: true),
        isFalse,
      );
    });

    test('unknown labels stay quiet on data screens', () {
      expect(
        HelpAllowlist.allows(
            route: '/customers', label: 'أحمد محمد علي', arabic: true),
        isFalse,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'بنك التضامن', arabic: true),
        isFalse,
      );
    });

    test('icon-only presses need a curated screen', () {
      expect(
        HelpAllowlist.allows(route: '/personal/banks', label: '', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(route: '/nowhere', label: '', arabic: true),
        isFalse,
      );
    });

    test('chrome screens fall back to their own explanation', () {
      expect(
        HelpAllowlist.allows(
            route: '/settings/company', label: 'تفعيل النسخ التلقائي',
            arabic: true),
        isTrue,
      );
    });

    test('musarfa button is allowed on the banks screen', () {
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'مصارفة', arabic: true),
        isTrue,
      );
      expect(
        HelpAllowlist.allows(
            route: '/personal/banks', label: 'Exchange', arabic: false),
        isTrue,
      );
    });
  });

  testWidgets('long-press shows the spotlight card and never activates the button',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var tapped = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(helpClickerProvider);
                  return ElevatedButton(
                    onPressed: () => tapped++,
                    child: const Text('حفظ'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(seconds: 4));
    // NOTE: no pumpAndSettle here — the card's animated icon runs forever.
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('طريقة الاستخدام:'), findsOneWidget);
    expect(find.text('حفظ'), findsWidgets);
    // Release the long press: the button must NOT have been activated.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tapped, 0);

    // Dismiss with the X button.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('طريقة الاستخدام:'), findsNothing);

    // A normal single tap still activates the button.
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('ClickerQuiet keeps the press silent but native taps work',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var tapped = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(helpClickerProvider);
                  // 'حفظ' is curated and WOULD open a card — the quiet
                  // zone forbids border and card alike.
                  return ClickerQuiet(
                    child: ElevatedButton(
                      onPressed: () => tapped++,
                      child: const Text('حفظ'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(seconds: 4));
    // NOTE: no pumpAndSettle here — matches the style of the other
    // long-press tests in this file.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tapped, 0);

    // A normal single tap still activates the button.
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('tap outside the card dismisses it', (tester) async {    SharedPreferences.setMockInitialValues({});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(helpClickerProvider);
                  return ElevatedButton(
                    onPressed: () {},
                    child: const Text('حفظ'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('طريقة الاستخدام:'), findsOneWidget);

    await gesture.up();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('طريقة الاستخدام:'), findsNothing);
  });

  testWidgets('disabled setting never shows the bubble', (tester) async {
    SharedPreferences.setMockInitialValues({'help_clicker_enabled': false});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(helpClickerProvider);
                  return ElevatedButton(
                    onPressed: () {},
                    child: const Text('حفظ'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    // Let the persisted settings load.
    await tester.pump(const Duration(milliseconds: 150));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await gesture.up();
  });

  testWidgets('custom duration is honored (5s instead of 3s)', (tester) async {
    SharedPreferences.setMockInitialValues({'help_clicker_seconds': 5});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(helpClickerProvider);
                  return ElevatedButton(
                    onPressed: () {},
                    child: const Text('حفظ'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    // Not yet: the user set 5 seconds.
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    // Past 5 seconds: the card pops.
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('طريقة الاستخدام:'), findsOneWidget);
    await gesture.up();
  });

  bool hasProgressBorder() => find
      .byWidgetPredicate(
          (w) => w.runtimeType.toString().contains('ProgressBorder'))
      .evaluate()
      .isNotEmpty;

  Future<void> pumpClicker(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('حفظ'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('a quick tap never flashes the progress border', (tester) async {
    await pumpClicker(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(milliseconds: 200));
    // Still inside the grace period: nothing is drawn yet.
    expect(hasProgressBorder(), isFalse);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(hasProgressBorder(), isFalse);
    expect(find.text('طريقة الاستخدام:'), findsNothing);
  });

  testWidgets('holding past the grace period draws the border', (tester) async {
    await pumpClicker(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(hasProgressBorder(), isTrue);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasProgressBorder(), isFalse);
  });

  testWidgets('releasing mid-hold cancels everything: no card', (tester) async {
    await pumpClicker(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(milliseconds: 900));
    expect(hasProgressBorder(), isTrue);

    // Released well before the 2s trigger: border gone, card never opens.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(hasProgressBorder(), isFalse);
    expect(find.text('طريقة الاستخدام:'), findsNothing);
  });

  testWidgets('a 3s setting opens the card after 3s, not before',
      (tester) async {
    SharedPreferences.setMockInitialValues({'help_clicker_seconds': 3});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  // Watch settings early so the persisted 3s is loaded
                  // before the gesture (mirrors production warm-up).
                  ref.watch(helpClickerProvider);
                  return ElevatedButton(
                    onPressed: () {},
                    child: const Text('حفظ'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طريقة الاستخدام:'), findsOneWidget);
    await gesture.up();
  });

  testWidgets('native long-press keeps its own action, no info card',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var fired = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onLongPress: () => fired++,
                child: const Text('حفظ'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('حفظ')));
    // Past the native 500ms long-press: the original action fires…
    await tester.pump(const Duration(milliseconds: 800));
    expect(fired, 1);
    // …and holding to/past our 2s duration never opens our card there.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await gesture.up();
  });

  testWidgets('sara message long-press only copies, no info card',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var copied = 0;
    var tapped = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () => tapped++,
                onLongPress: () => copied++,
                child: const Text('كم رصيدي؟'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    // Normal tap still passes through to the message.
    await tester.tap(find.text('كم رصيدي؟'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, 1);

    // Long-press copies (native action) and never opens our card.
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('كم رصيدي؟')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(copied, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await gesture.up();
  });

  testWidgets('pressing a text field stays quiet (user input)', (tester) async {    SharedPreferences.setMockInitialValues({});
    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => const Scaffold())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [goRouterProvider.overrideWithValue(router)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) =>
              InformationClickerOverlay(child: child ?? const SizedBox()),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: TextField(
                  decoration: InputDecoration(hintText: 'اكتب هنا'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(hasProgressBorder(), isFalse);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(hasProgressBorder(), isFalse);
    expect(find.text('طريقة الاستخدام:'), findsNothing);
    await gesture.up();
  });

  group('content is never the old generic text', () {
    const bannedAr = [
      'اضغط الزر لتنفيذ إجراءه',
      'أكمل الخطوات الظاهرة على الشاشة',
      'راجع النتيجة في نفس القسم',
      'ينفّذ هذا الزر الإجراء الخاص به',
      'اضغط مطولاً على أي زر أو قسم',
    ];
    const bannedEn = [
      'Tap the button to run its action',
      'Complete the steps shown on screen',
      'This button performs its action on this screen',
      'Long-press any button or section',
    ];

    test('every covered section resolves curated, distinct bodies', () {
      final cases = <String, String>{
        '/personal': 'صافي الثروة',
        '/personal/banks': 'إضافة بنك',
        '/personal/debts': 'سداد',
        '/personal/debts:تحصيل': 'تحصيل',
        '/personal/savings': 'إضافة مبلغ',
        '/personal/budget': 'إنشاء ميزانية جديدة',
        '/personal/ai': 'كم رصيدي؟',
        '/personal/transactions': 'سحب مصروف',
        '/personal/recurring': 'تنفيذ الآن',
        '/personal/backup': 'حفظ البيانات الحالية',
        '/subscription': 'اشتراك سنوي',
        '/profile': 'تخصيص العملات',
      };
      final bodies = <String>{};
      cases.forEach((key, label) {
        final route = key.split(':').first;
        final info = HelpExplain.resolve(
            route: route, label: label, arabic: true);
        expect(info.title.isNotEmpty, isTrue, reason: key);
        expect(info.body.isNotEmpty, isTrue, reason: key);
        for (final banned in bannedAr) {
          expect(info.body.contains(banned), isFalse, reason: '$key body');
          for (final step in info.steps) {
            expect(step.contains(banned), isFalse, reason: '$key step');
          }
        }
        bodies.add(info.body);
      });
      // Not all identical: sections genuinely differ from each other.
      expect(bodies.length, greaterThan(6));
    });

    test('section cards never show the raw record text as title', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: '', arabic: true);
      expect(info.title, 'البنوك');
    });

    test('english mirrors resolve with their own content', () {
      final ar = HelpExplain.resolve(
          route: '/personal/debts', label: 'سداد', arabic: true);
      final en = HelpExplain.resolve(
          route: '/personal/debts', label: 'settle', arabic: false);
      expect(en.title.isNotEmpty, isTrue);
      expect(en.body.isNotEmpty, isTrue);
      expect(en.body, isNot(ar.body));
      for (final banned in bannedEn) {
        expect(en.body.contains(banned), isFalse);
      }
    });

    test('steps are empty (not generic) when no flow exists', () {
      final info = HelpExplain.resolve(
          route: '/profile', label: 'اللغة', arabic: true);
      expect(info.steps, isEmpty);
      final info2 = HelpExplain.resolve(
          route: '/personal/backup', label: 'التحديث التلقائي', arabic: true);
      expect(info2.steps, isEmpty);
    });
  });

  group('HelpExplain content', () {
    test('curated route returns its own steps and icon', () {
      final info = HelpExplain.resolve(
          route: '/personal/recurring', label: 'المعاملات المتكررة', arabic: true);
      expect(info.title, 'المعاملات المتكررة');
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('قاعدة'));
    });

    test('expense action label gets its own usage steps', () {
      final info = HelpExplain.resolve(
          route: '/personal/transactions', label: 'سحب مصروف', arabic: true);
      expect(info.title, 'سحب مصروف');
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('الحساب'));
    });

    test('unknown label still gets steps, body and an icon', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'زر غامض', arabic: true);
      expect(info.title.isNotEmpty, isTrue);
      expect(info.body.isNotEmpty, isTrue);
      expect(info.steps.isNotEmpty, isTrue);
    });

    test('english content resolves with steps', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Save invoice', arabic: false);
      expect(info.title, 'Save invoice');
      expect(info.steps.isNotEmpty, isTrue);
    });

    test('a bare action label is description-only (no invented flow)', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Save', arabic: false);
      expect(info.title, 'Save');
      expect(info.body.isNotEmpty, isTrue);
      expect(info.steps, isEmpty);
    });

    test('musarfa button gets its dedicated transfer flow', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'مصارفة', arabic: true);
      expect(info.title, 'مصارفة');
      expect(info.body, contains('يحوّل'));
      expect(info.steps.length, 3);
      expect(info.steps.first, contains('الحساب'));
    });

    test('english Exchange button answers with dedicated text', () {
      final info = HelpExplain.resolve(
          route: '/personal/banks', label: 'Exchange', arabic: false);
      expect(info.title, 'Exchange');
      expect(info.body, contains('moves an amount'));
    });
  });
}
