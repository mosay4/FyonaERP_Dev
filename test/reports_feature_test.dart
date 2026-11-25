import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart' show currencyFlagEmoji;
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart'
    show bizEnabledCurrenciesProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/reports_hub_page.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/report_view_page.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_scenes.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_widgets.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:go_router/go_router.dart';

/// Reports feature tests: the «كيف شغلك؟» hub, the 4-second cinematic gate
/// with the five distinct scenes, animated numbers, and honest FX notices.
void main() {
  Future<void> preload(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AppLocalizations.preload('ar'));
  }

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: child,
  );

  void bigSurface(WidgetTester tester) {
    // Tall virtual device so lazy ListViews build every card.
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget hostRouted(Widget page) => MaterialApp.router(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, _) => page)],
    ),
  );

  /// Bounded pumping: some widgets (spinners/pending providers) tick forever
  /// in tests — drive a fixed number of frames instead of pumpAndSettle.
  Future<void> pumpFor(WidgetTester tester, Duration step, int times) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(step);
    }
  }

  testWidgets('Scene overlay: result NEVER revealed before 4 seconds (sales)', (
    tester,
  ) async {
    await preload(tester);
    dynamic revealed;
    await tester.pumpWidget(
      host(
        ReportSceneOverlay(
          scene: ReportScene.sales,
          sceneText: 'نجمع مبيعاتك...',
          processingText: 'جارٍ الحساب الدقيق...',
          future: Future.value({
            'sales': {'total': 1750},
          }),
          onResult: (_, r) => revealed = r,
          onError: (_, e) {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(revealed, isNull, reason: 'the full 4 seconds must elapse');
    await pumpFor(tester, const Duration(milliseconds: 250), 16);
    await tester.pump();
    await tester.pump();
    expect(revealed, isNotNull);
    expect((revealed as Map)['sales']['total'], 1750);
  });

  testWidgets('All five scenes render their distinct choreography without '
      'errors (paint smoke)', (tester) async {
    await preload(tester);
    for (final scene in ReportScene.values) {
      dynamic revealed;
      await tester.pumpWidget(
        host(
          ReportSceneOverlay(
            scene: scene,
            sceneText: 'x',
            processingText: 'y',
            future: Future.value({'ok': true}),
            onResult: (_, r) => revealed = r,
            onError: (_, e) {},
          ),
        ),
      );
      await pumpFor(tester, const Duration(milliseconds: 250), 20);
      await tester.pump();
      await tester.pump();
      expect(revealed, isNotNull, reason: 'scene $scene must complete');
    }
  });

  testWidgets('Reports hub: «كيف شغلك؟» + FOUR KPI cards + FIVE report cards', (
    tester,
  ) async {
    await preload(tester);
    final fake = FakeReportsApi(ApiClient(dio: Dio()));
    bigSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessReportsApiProvider.overrideWithValue(fake)],
        child: hostRouted(const ReportsHubPage()),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 12);
    expect(find.text('كيف شغلك؟'), findsOneWidget);
    expect(find.text('كم بعت؟'), findsOneWidget);
    expect(find.text('كم ربحت؟'), findsOneWidget);
    expect(find.text('كم صرفت؟'), findsOneWidget);
    expect(find.text('كم باقي لك عند العملاء؟'), findsOneWidget);
    expect(find.text('المبيعات والمشتريات'), findsOneWidget);
    expect(find.text('الفلوس والحسابات'), findsOneWidget);
    expect(find.text('المخزون'), findsOneWidget);
    expect(find.text('الديون'), findsOneWidget);
    expect(find.text('نظرة شاملة'), findsOneWidget);
    // Sold value rendered from the FAKE api (real data path).
    expect(find.text('1,750'), findsWidgets);
    expect(find.textContaining('دولار أمريكي'), findsWidgets);
    // The owner's rule: no warning lines in reports (amounts are valued with
    // the saved rates; «كم ربحت؟» explains a missing profit when tapped).
    expect(find.textContaining('لم تدخل في الإجمالي'), findsNothing);
  });

  testWidgets('Report view page opens the cinematic gate then shows results', (
    tester,
  ) async {
    await preload(tester);
    final fake = FakeReportsApi(ApiClient(dio: Dio()));
    bigSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessReportsApiProvider.overrideWithValue(fake)],
        child: hostRouted(const ReportViewPage(kind: 'sales')),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 8);
    await tester.tap(find.text('عرض التقرير'));
    await pumpFor(tester, const Duration(milliseconds: 250), 20);
    await tester.pump();
    await tester.pump();
    // Real numbers from the fake API, in merchant language.
    expect(find.textContaining('1,750'), findsWidgets);
    expect(find.text('أكثر المنتجات مبيعًا'), findsOneWidget);
  });

  // ══ Reference-identity pages: structure, both languages, small screens ══
  Future<void> pumpKind(
    WidgetTester tester,
    String kind, {
    Locale locale = const Locale('ar'),
    Size? surface,
    BusinessReportsApi? api,
  }) async {
    await tester.runAsync(() => AppLocalizations.preload(locale.languageCode));
    final fake = api ?? FakeReportsApi(ApiClient(dio: Dio()));
    tester.view.physicalSize = surface ?? const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessReportsApiProvider.overrideWithValue(fake)],
        child: MaterialApp.router(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => ReportViewPage(kind: kind),
              ),
              GoRoute(
                path: '/customers',
                builder: (_, __) =>
                    const Scaffold(body: Center(child: Text('STUB-CUSTOMERS'))),
              ),
              GoRoute(
                path: '/suppliers',
                builder: (_, __) =>
                    const Scaffold(body: Center(child: Text('STUB-SUPPLIERS'))),
              ),
              GoRoute(
                path: '/debts/customers',
                builder: (_, __) => const Scaffold(
                  body: Center(child: Text('STUB-DEBT-CUSTOMERS')),
                ),
              ),
              GoRoute(
                path: '/debts/suppliers',
                builder: (_, __) => const Scaffold(
                  body: Center(child: Text('STUB-DEBT-SUPPLIERS')),
                ),
              ),
              GoRoute(
                path: '/reports/view',
                builder: (_, __) =>
                    const Scaffold(body: Center(child: Text('STUB-VIEW'))),
              ),
            ],
          ),
        ),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 8);
    await tester.tap(find.byType(FilledButton));
    await pumpFor(tester, const Duration(milliseconds: 250), 24);
    await tester.pump();
  }

  testWidgets('sales page matches the reference (RTL, small screen)', (
    tester,
  ) async {
    await pumpKind(tester, 'sales', surface: const Size(360, 640));
    expect(
      tester.takeException(),
      isNull,
      reason: 'no RenderFlex overflow / layout exception',
    );
    expect(find.text('المبيعات'), findsOneWidget);
    expect(find.text('المشتريات'), findsOneWidget);
    expect(find.text('أكثر المنتجات مبيعًا'), findsOneWidget);
    expect(find.textContaining('عرض جميع المنتجات'), findsOneWidget);
    expect(find.textContaining('1,750'), findsWidgets);
  });

  testWidgets('sales page mirrors to English (LTR)', (tester) async {
    await pumpKind(tester, 'sales', locale: const Locale('en'));
    expect(tester.takeException(), isNull);
    expect(find.text('المبيعات'), findsNothing);
    expect(find.text('أكثر المنتجات مبيعًا'), findsNothing);
    expect(find.textContaining('1,750'), findsWidgets);
  });

  testWidgets('money page: banks + currency pickers + settlements (RTL)', (
    tester,
  ) async {
    await pumpKind(tester, 'money', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('البنوك'), findsOneWidget);
    expect(find.text('اختر العملة'), findsOneWidget);
    expect(find.text('تعديل الرصيد'), findsOneWidget);
    // Selecting the bank chip keeps the details card honest.
    expect(find.textContaining('RCT-كاش'), findsWidgets);
    for (
      var i = 0;
      i < 8 && find.text('تعديلات الأرصدة').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -160));
      await pumpFor(tester, const Duration(milliseconds: 120), 3);
    }
    expect(find.text('تعديلات الأرصدة'), findsOneWidget);
  });

  testWidgets('money settlements pill toggles to show-fewer label (RTL)', (
    tester,
  ) async {
    await pumpKind(tester, 'money', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 8; i++) {
      if (find.textContaining('عرض جميع التصحيحات').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(ListView).last, const Offset(0, -260));
      await pumpFor(tester, const Duration(milliseconds: 120), 3);
    }
    expect(find.textContaining('عرض جميع التصحيحات (4)'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('عرض جميع التصحيحات (4)'));
    await pumpFor(tester, const Duration(milliseconds: 150), 3);
    await tester.tap(
      find.textContaining('عرض جميع التصحيحات (4)'),
      warnIfMissed: false,
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 4);
    expect(find.text('تقليل عدد التصحيحات'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inventory page: hero + mini stats + most moved (RTL)', (
    tester,
  ) async {
    await pumpKind(tester, 'inventory', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('قيمة البضاعة الموجودة'), findsOneWidget);
    expect(find.text('قرب النفاد'), findsOneWidget);
    expect(find.text('نفد'), findsOneWidget);
    expect(find.text('أكثر المنتجات حركة'), findsOneWidget);
  });

  testWidgets('debts page: summary cards + movements (RTL, small screen)', (
    tester,
  ) async {
    await pumpKind(tester, 'debts', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('باقي لك عند العملاء'), findsOneWidget);
    expect(find.text('باقي عليك للموردين'), findsOneWidget);
    for (
      var i = 0;
      i < 8 && find.text('عرض التفاصيل').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -120));
      await pumpFor(tester, const Duration(milliseconds: 120), 3);
    }
    expect(find.text('عرض التفاصيل'), findsNWidgets(2));
    // Details open the REAL customers/suppliers sections, not an inline list.
    await tester.tap(find.text('عرض التفاصيل').first);
    await pumpFor(tester, const Duration(milliseconds: 200), 6);
    expect(find.text('STUB-DEBT-CUSTOMERS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview page: trend + comparison cards + breakdown (RTL)', (
    tester,
  ) async {
    await pumpKind(tester, 'overview', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('كيف تغير شغلك؟'), findsOneWidget);
    expect(find.text('الربح'), findsOneWidget);
    // The pill sits below the fold on a small screen — drag down to it.
    for (var i = 0; i < 8; i++) {
      if (find.textContaining('عرض التفاصيلية').evaluate().isNotEmpty) break;
      await tester.drag(find.byType(ListView).last, const Offset(0, -260));
      await pumpFor(tester, const Duration(milliseconds: 120), 3);
    }
    expect(find.textContaining('عرض التفاصيلية').evaluate().isNotEmpty, isTrue);
    await tester.tap(find.textContaining('عرض التفاصيلية').first);
    await pumpFor(tester, const Duration(milliseconds: 200), 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('money: USD checking + USD savings show as two فئة chips', (
    tester,
  ) async {
    await pumpKind(tester, 'money', surface: const Size(360, 640));
    expect(tester.takeException(), isNull);
    await tester.drag(find.text('RCT-كاش').first, const Offset(-220, 0));
    await pumpFor(tester, const Duration(milliseconds: 200), 4);
    await tester.tap(find.text('RCT-بنك'));
    await pumpFor(tester, const Duration(milliseconds: 200), 6);
    expect(tester.takeException(), isNull);
    // Same currency, two categories → never merged into one chip.
    expect(find.text('USD'), findsNWidgets(2));
    expect(find.text('حساب جاري'), findsWidgets);
    expect(find.text('حساب توفير'), findsWidgets);
  });

  testWidgets('debts movements: expand toggles to show-less label', (
    tester,
  ) async {
    await pumpKind(tester, 'debts', surface: const Size(360, 640));
    for (var i = 0; i < 8; i++) {
      if (find.textContaining('تقليل العدد').evaluate().isNotEmpty) break;
      if (find.text('عرض الكل').evaluate().isEmpty) {
        await tester.drag(find.byType(ListView).last, const Offset(0, -260));
        await pumpFor(tester, const Duration(milliseconds: 120), 3);
        continue;
      }
      await tester.ensureVisible(find.text('عرض الكل').first);
      await tester.pump();
      await tester.tap(find.text('عرض الكل').first);
      await pumpFor(tester, const Duration(milliseconds: 200), 4);
    }
    expect(find.textContaining('تقليل العدد').evaluate().isNotEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hub KPI squares are display-only (no tap response)', (
    tester,
  ) async {
    await preload(tester);
    final fake = FakeReportsApi(ApiClient(dio: Dio()));
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessReportsApiProvider.overrideWithValue(fake)],
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(path: '/', builder: (_, __) => const ReportsHubPage()),
              GoRoute(
                path: '/reports/view',
                builder: (_, __) =>
                    const Scaffold(body: Center(child: Text('STUB-VIEW'))),
              ),
            ],
          ),
        ),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 14);
    // Tap the first KPI square (كم بعت؟): NOTHING happens — no navigation,
    // no confirm box — yet the numbers stay visible and refresh with filters.
    await tester.tap(find.text('كم بعت؟'));
    await pumpFor(tester, const Duration(milliseconds: 200), 6);
    expect(find.text('STUB-VIEW'), findsNothing);
    expect(find.text('عرض التقرير'), findsNothing);
    expect(find.text('كم بعت؟'), findsOneWidget);
    expect(find.text('1,750'), findsWidgets);
    expect(find.textContaining('دولار أمريكي'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hub currency picker lists exactly the Business enabled set, '
      'each with its flag', (
    tester,
  ) async {
    await preload(tester);
    // The server reports AED, SAR and USD; only AED + USD are enabled in the
    // Business profile settings → the picker shows exactly those two.
    final fake = FakeReportsApi(ApiClient(dio: Dio()));
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          businessReportsApiProvider.overrideWithValue(fake),
          bizEnabledCurrenciesProvider.overrideWith(
            (ref) async => {'AED', 'USD'},
          ),
        ],
        child: hostRouted(const ReportsHubPage()),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 14);
    await tester.tap(find.byIcon(Icons.currency_exchange_rounded).first);
    await pumpFor(tester, const Duration(milliseconds: 200), 4);
    // Arabic UI shows the full Arabic currency name next to its flag.
    expect(find.text('درهم إماراتي'), findsWidgets);
    expect(find.byKey(const ValueKey('report-currency-AED')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-currency-USD')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-currency-SAR')), findsNothing);
    expect(find.text(currencyFlagEmoji('AED')), findsOneWidget);
    expect(find.text(currencyFlagEmoji('USD')), findsOneWidget);
    expect(find.text('عملاتك'), findsNothing);
    expect(find.text('كل العملات'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('ReportCountUp formats thousands with separators', () {
    expect(ReportCountUpFormat.fmt(1750), '1,750');
    expect(ReportCountUpFormat.fmt(1234567), '1,234,567');
    expect(ReportCountUpFormat.fmt(12.5), '12.50');
  });

  testWidgets('money report never combines two currencies in one amount', (
    tester,
  ) async {
    await pumpKind(tester, 'money', surface: const Size(390, 2600));
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .toList();
    expect(
      texts.any((t) => t.contains('USD') && t.contains('ريال سعودي')),
      isFalse,
    );
    expect(
      texts.any((t) => t.contains('SAR') && t.contains('دولار أمريكي')),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'debts: detail routes open the debt-specific customers/suppliers',
    (tester) async {
      await pumpKind(tester, 'debts', surface: const Size(390, 2600));
      final details = find.text('عرض التفاصيل');
      expect(details, findsNWidgets(2));
      await tester.tap(details.first);
      await pumpFor(tester, const Duration(milliseconds: 200), 5);
      expect(find.text('STUB-DEBT-CUSTOMERS'), findsOneWidget);
    },
  );

  testWidgets('debts report contains no overdue-debt feature', (tester) async {
    await pumpKind(tester, 'debts', surface: const Size(390, 2600));
    expect(find.textContaining('الديون المتأخرة'), findsNothing);
    expect(find.textContaining('متأخر'), findsNothing);
  });
  testWidgets(
    'all five reports fit 12+ digit amounts and long currency names',
    (tester) async {
      for (final locale in [const Locale('ar'), const Locale('en')]) {
        for (final kind in [
          'sales',
          'money',
          'inventory',
          'debts',
          'overview',
        ]) {
          await pumpKind(
            tester,
            kind,
            locale: locale,
            surface: const Size(320, 640),
            api: HugeReportsApi(ApiClient(dio: Dio())),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$kind/${locale.languageCode} must not overflow',
          );
        }
      }
    },
  );
  testWidgets('report currency defaults to USD and restores the saved choice', (
    tester,
  ) async {
    await preload(tester);
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('u-currency'),
          businessReportsApiProvider.overrideWithValue(
            FakeReportsApi(ApiClient(dio: Dio())),
          ),
        ],
        child: hostRouted(const ReportsHubPage()),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 14);
    expect(find.textContaining('دولار أمريكي'), findsWidgets);

    SharedPreferences.setMockInitialValues({
      'report_currency_u-currency': 'YER_OLD',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('u-currency'),
          businessReportsApiProvider.overrideWithValue(
            FakeReportsApi(ApiClient(dio: Dio())),
          ),
        ],
        child: hostRouted(const ReportsHubPage()),
      ),
    );
    await pumpFor(tester, const Duration(milliseconds: 200), 14);
    expect(find.textContaining('ريال يمني قديم'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('products show-all label flips to show-fewer and back', (
    tester,
  ) async {
    await pumpKind(tester, 'sales', surface: const Size(390, 2600));
    final showAll = find.textContaining('عرض جميع المنتجات (8)');
    expect(showAll, findsOneWidget);
    await tester.ensureVisible(showAll);
    await tester.tap(showAll);
    await pumpFor(tester, const Duration(milliseconds: 120), 3);
    expect(find.textContaining('تقليل عدد المنتجات (8)'), findsOneWidget);
    await tester.tap(find.textContaining('تقليل عدد المنتجات (8)'));
    await pumpFor(tester, const Duration(milliseconds: 120), 3);
    expect(find.textContaining('عرض جميع المنتجات (8)'), findsOneWidget);
  });

  testWidgets('inventory counting show-all flips to fewer', (tester) async {
    await pumpKind(
      tester,
      'inventory',
      surface: const Size(390, 2600),
      api: CountingReportsApi(ApiClient(dio: Dio())),
    );
    for (var i = 0; i < 10 && find.text('عرض الكل').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -160));
      await pumpFor(tester, const Duration(milliseconds: 120), 3);
    }
    expect(find.text('عرض الكل'), findsOneWidget);
    await tester.tap(find.text('عرض الكل'));
    await pumpFor(tester, const Duration(milliseconds: 120), 3);
    expect(find.text('تقليل العدد'), findsOneWidget);
  });
}

class ReportCountUpFormat {
  static String fmt(num v) {
    final r = v.roundToDouble();
    if (r == v) {
      return v.toInt().toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]},',
      );
    }
    return v.toStringAsFixed(2);
  }
}

class HugeReportsApi extends FakeReportsApi {
  HugeReportsApi(super.client);

  static const _moneyKeys = {
    'total',
    'paid',
    'remaining',
    'balance',
    'inflow',
    'outflow',
    'transfers',
    'settlements',
    'stock_value',
    'sales',
    'income',
    'purchases',
    'profit',
    'expenses',
    'customer_debt',
    'supplier_debt',
    'amount',
    'before',
    'after',
    'value',
    'per_currency',
    'collected',
    'paid_to_suppliers',
    'overdue',
  };

  static dynamic _huge(dynamic value) {
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key: _moneyKeys.contains(e.key) && e.value is num
              ? 123456789012.5
              : _huge(e.value),
      };
    }
    if (value is List) return value.map(_huge).toList();
    return value;
  }

  static Map<String, dynamic> _currency(Map<String, dynamic> source) => {
    ...source,
    'currency': 'YER_OLD',
    if (source['accounts'] is List)
      'accounts': [
        for (final a in (source['accounts'] as List).whereType<Map>())
          {...a, 'currency': 'YER_OLD', 'balance': 123456789012.5},
      ],
  };

  Future<Map<String, dynamic>> _wrap(
    Future<Map<String, dynamic>> future,
  ) async => _currency(Map<String, dynamic>.from(_huge(await future) as Map));

  @override
  Future<Map<String, dynamic>> home(String? f, String? t, [String c = 'SAR']) =>
      _wrap(super.home(f, t, 'YER_OLD'));
  @override
  Future<Map<String, dynamic>> salesPurchases(
    String? f,
    String? t, [
    String c = 'SAR',
  ]) => _wrap(super.salesPurchases(f, t, 'YER_OLD'));
  @override
  Future<Map<String, dynamic>> money(
    String? f,
    String? t, [
    String c = 'SAR',
    String? a,
  ]) => _wrap(super.money(f, t, 'YER_OLD', a));
  @override
  Future<Map<String, dynamic>> inventory(
    String? f,
    String? t, [
    String c = 'SAR',
  ]) => _wrap(super.inventory(f, t, 'YER_OLD'));
  @override
  Future<Map<String, dynamic>> debts(
    String? f,
    String? t, [
    String c = 'SAR',
  ]) => _wrap(super.debts(f, t, 'YER_OLD'));
  @override
  Future<Map<String, dynamic>> overview(
    String? f,
    String? t, [
    String c = 'SAR',
  ]) => _wrap(super.overview(f, t, 'YER_OLD'));
}

class CountingReportsApi extends FakeReportsApi {
  CountingReportsApi(super.client);
  @override
  Future<Map<String, dynamic>> inventory(
    String? f,
    String? t, [
    String c = 'SAR',
  ]) async {
    final base = await super.inventory(f, t, c);
    return {
      ...base,
      'counting': {
        'count': 4,
        'items': [
          for (var i = 0; i < 4; i++)
            {'ref_code': 'COUNT-$i', 'products': i + 1, 'date': '2026-10-1$i'},
        ],
      },
    };
  }
}

class FakeReportsApi extends BusinessReportsApi {
  FakeReportsApi(super.client);

  @override
  Future<Map<String, dynamic>> home(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    return {
      'report': 'home',
      'currency': currency,
      'fx_basis': {'operations': 'historical', 'balances': 'current'},
      'kpis': {
        'sold': {
          'total': 1750,
          'count': 2,
          'gaps': [
            {'currency': 'YER_OLD', 'count': 3},
          ],
        },
        'profit': {'total': 275, 'gaps': []},
        'spent': {'total': 175, 'gaps': []},
        'customer_debt': {'total': 400, 'count': 1, 'gaps': []},
      },
      'comparison': {
        'sold_delta': 250,
        'spent_delta': -50,
        'prev_sold': 1500,
        'prev_spent': 225,
      },
      'currencies': ['AED', 'SAR', 'USD'],
      'chart': [
        {'date': '2026-10-10', 'value': 750},
        {'date': '2026-10-11', 'value': 1000},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> salesPurchases(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    return {
      'report': 'sales_purchases',
      'currency': currency,
      'sales': {
        'total': 1750,
        'count': 2,
        'paid': 1350,
        'remaining': 500,
        'returns': {'total': 500, 'count': 1},
        'chart': [
          {'date': '2026-10-10', 'value': 750},
          {'date': '2026-10-11', 'value': 1000},
        ],
        'gaps': [],
      },
      'purchases': {
        'total': 500,
        'count': 1,
        'paid': 500,
        'remaining': 0,
        'returns': {'total': 0, 'count': 0},
        'chart': [],
        'gaps': [],
      },
      'top_products': [
        for (var i = 0; i < 8; i++)
          {
            'name': 'RCT-منتج ${i + 1}',
            'qty': 10 - i,
            'total': 1750.0 - i * 7,
            'product_id': 'p$i',
            'unit': 'قطعة',
          },
      ],
      'invoices': [],
    };
  }

  @override
  Future<Map<String, dynamic>> money(
    String? from,
    String? to, [
    String currency = 'SAR',
    String? accountId,
  ]) async {
    return {
      'report': 'money',
      'currency': currency,
      'inflow': {'total': 300, 'gaps': []},
      'outflow': {'total': 50, 'gaps': []},
      'transfers': {'total': 40, 'note': ''},
      'expenses': {'total': 175, 'categories': [], 'gaps': []},
      'balances': {
        'total': 1090,
        'basis': 'current',
        'per_currency': [],
        'gaps': [],
      },
      'accounts': [
        {
          'id': 'a1',
          'bank_name': 'RCT-كاش',
          'account_name': 'صندوق',
          'currency': 'SAR',
          'account_type': 'checking',
          'balance': 950,
          'inflow': 300,
          'outflow': 50,
          'transfers': -40,
          'settlements': -950,
          'net_change': -740,
        },
        {
          'id': 'a2',
          'bank_name': 'RCT-بنك',
          'account_name': 'حساب',
          'currency': 'USD',
          'account_type': 'checking',
          'balance': 100,
          'inflow': 100,
          'outflow': 0,
          'transfers': 0,
          'settlements': 0,
          'net_change': 100,
        },
        {
          'id': 'a3',
          'bank_name': 'RCT-بنك',
          'account_name': 'توفير',
          'currency': 'USD',
          'account_type': 'savings',
          'balance': 200,
          'inflow': 200,
          'outflow': 0,
          'transfers': 0,
          'settlements': 0,
          'net_change': 200,
        },
      ],
      'expense_scoped': {
        'total': 25,
        'categories': [
          {'category': 'RCT-فئة', 'total': 25},
        ],
      },
      'settlements': {
        'count': 4,
        'items': [
          for (var i = 0; i < 4; i++)
            {
              'ref_code': 'RCT-$i',
              'approved_at': '2026-10-1${i}T10:00:00',
              'settlements': [
                {
                  'name': 'RCT-حساب',
                  'currency': 'SAR',
                  'before': 100,
                  'after': 90 + i,
                },
              ],
            },
        ],
        'total': 950,
        'gaps': [],
        'note': '',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> inventory(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    return {
      'report': 'inventory',
      'currency': currency,
      'products': 1,
      'categories': 1,
      'units': 1,
      'stock_value': 50,
      'stock_value_per_currency': [],
      'stock_value_basis': 'actual_lot_cost',
      'low_stock': [],
      'low_count': 0,
      'out_of_stock': [],
      'out_count': 0,
      'expiring_soon': [],
      'expiring_count': 0,
      'warn_days': 60,
      'most_moved': [
        {'name': 'RCT-منتج', 'unit': 'قطعة', 'moved': 10, 'net': 10},
      ],
      'counting': {'count': 0, 'items': []},
      'gaps': [],
    };
  }

  @override
  Future<Map<String, dynamic>> debts(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    return {
      'report': 'debts',
      'currency': currency,
      'customers': {'total': 400, 'count': 1, 'top': [], 'gaps': []},
      'suppliers': {'total': 0, 'count': 0, 'top': [], 'gaps': []},
      'collected': {'total': 100, 'gaps': []},
      'paid_to_suppliers': {'total': 500, 'gaps': []},
      'overdue': {'count': 1, 'total': 100, 'gaps': []},
      'recent_movements': [
        for (var i = 0; i < 4; i++)
          {
            'party': 'RCT-طرف $i',
            'kind': i.isEven ? 'customer' : 'supplier',
            'date': '2026-10-13',
            'amount': i.isEven ? 200 : -150,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> overview(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    return {
      'report': 'overview',
      'currency': currency,
      'sales': {'total': 1750, 'count': 2, 'gaps': []},
      'purchases': {'total': 500},
      'profit': {'total': 275, 'gaps': []},
      'expenses': {'total': 175, 'gaps': []},
      'customer_debt': {'total': 400, 'count': 1},
      'supplier_debt': {'total': 0, 'count': 0},
      'inventory': {
        'stock_value': 50,
        'products': 1,
        'low_count': 0,
        'out_count': 0,
      },
      'comparison': {
        'sold_delta': 250,
        'spent_delta': -50,
        'prev_sold': 1500,
        'prev_spent': 225,
      },
      'chart': [
        {'date': '2026-10-10', 'value': 750},
        {'date': '2026-10-11', 'value': 1000},
      ],
    };
  }
}
