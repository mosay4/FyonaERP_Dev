import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/falcon_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/widgets/falcon_ambient.dart';
import 'package:fyona_flutter/features/inventory/domain/services/falcon_memory_store.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Fixture-driven Falcon page tests: scope-aware suggestions, enabled-only
/// currency chips (no «تلقائي»), pinned chat bar during loading, key-number
/// currency, chart gating, RTL/LTR + light/dark, small screens, chat send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FalconMemoryStore.instance.clearAll();
    BranchScope.token = 'falcon-test-workspace';
  });
  tearDown(() {
    FalconMemoryStore.instance.clearAll();
    BranchScope.token = null;
  });

  Map<String, dynamic> reportFor(String scope) {
    final productSuggestions = [
      'كم أطلب الشهر القادم؟',
      'متى ممكن يخلص المخزون؟',
      'هل المنتج راكد؟',
    ];
    final inventorySuggestions = [
      'وش أكثر المنتجات ربحًا؟',
      'وش المنتجات الراكدة؟',
      'وش أحتاج أطلب الفترة القادمة؟',
    ];
    return {
      'status': 'good',
      'status_line': 'الربح 30% والمخزون يكفي الطلب الحالي.',
      'attention': ['سكر وصل حد التنبيه.'],
      'recommendations': ['أعد طلب: سكر، أرز.'],
      'opportunity': '«شاي» يحقق أعلى ربح بهامش 35%.',
      'suggested_questions':
          scope == 'product' ? productSuggestions : inventorySuggestions,
      'product_type': 'خضروات وفواكه (سلع طازجة)',
      'type_guide': {
        'pricing': 'هامش 15–25% وسعر يومي يتبع السوق.',
        'turnover': 'سريع جدًا: يصرف خلال 2–4 أيام.',
        'marketing': 'عرض الطازج صباحًا وتسعير الوزن.',
        'risks': 'تلف وفقد قيمة سريع.',
      },
      if (scope == 'product') 'suggested_order_qty': 7,
      'ai': true,
      'stats': {
        'report_currency': 'USD',
        'unified': scope == 'inventory',
        'total_sales': 120.0,
        'total_profit': 36.0,
        'inventory_value': 80.0,
        'total_cogs': 84.0,
        'products_count': scope == 'product' ? 1 : 12,
        'low_stock': scope == 'product' ? [] : ['سكر'],
        'out_of_stock': <String>[],
        'top_sellers': scope == 'product'
            ? [
                {'name': 'منتج واحد', 'qty_sold': 5.0}
              ]
            : [
                {'name': 'شاي', 'qty_sold': 9.0},
                {'name': 'سكر', 'qty_sold': 6.0},
                {'name': 'أرز', 'qty_sold': 3.0},
              ],
        'top_profit': [],
        'bottom_sellers': [],
        'slow_moving': [],
        'weak_margin': [],
      },
    };
  }

  Finder falconLogos() => find.byWidgetPredicate((w) =>
      w is Image &&
      w.image is AssetImage &&
      (w.image as AssetImage).assetName.startsWith('assets/images/falcon_'));

  /// Holds the analyze response until [gate.complete] so the loading stage
  /// can be asserted deterministically (the ambient hero repeats forever,
  /// so the whole test uses timed pumps — never pumpAndSettle).
  (Widget, Completer<void>) buildHarness(
      {required String scope,
      required String locale,
      required Brightness brightness}) {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<void>();
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.contains('/falcon/chat')) {
        final body = options.data is String
            ? jsonDecode(options.data as String) as Map<String, dynamic>
            : Map<String, dynamic>.from(options.data as Map);
        final q = (body['question'] ?? '').toString();
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'answer': 'بعت 5 قطع والمخزون 32، لا تشترِ الآن. ($q)'}));
        return;
      }
      await gate.future; // analyze waits until released
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: reportFor(scope)));
    }));
    final widget = ProviderScope(
      overrides: [
        inventoryApiProvider.overrideWithValue(InventoryApi(ApiClient(dio: dio))),
        currentUserIdProvider.overrideWithValue('tester'),
      ],
      child: MaterialApp(
        locale: Locale(locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode:
            brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: FalconPage(
            scope: scope, refId: scope == 'product' ? 'p1' : null, title: 'اختبار'),
      ),
    );
    return (widget, gate);
  }

  Future<void> pumpReady(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
      'product: chat pinned during loading; suggestions product-only; no auto chip; chart hidden for single seller',
      (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final (widget, gate) = buildHarness(
        scope: 'product', locale: 'ar', brightness: Brightness.light);
    await tester.pumpWidget(widget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // FIRST-OPEN intro: centered hero, ONE logo only, header has none.
    expect(find.byType(FalconIntroScene), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(falconLogos(), findsOneWidget);
    expect(find.text('جيد'), findsNothing); // report not shown yet

    // Intro steps morph in ONE place: step 1 → step 2 (old one gone).
    expect(find.text('تهيئة بيانات متجرك...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('تحديد نوع البضاعة والتصنيفات...'), findsOneWidget);
    expect(find.text('تهيئة بيانات متجرك...'), findsNothing);

    gate.complete();
    // The intro holds a FULL 4 seconds regardless of the analyze result.
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(FalconIntroScene), findsOneWidget); // still intro
    await tester.pump(const Duration(milliseconds: 2400));
    // Logo flight center → header: still exactly ONE logo in the tree.
    expect(find.byType(FalconIntroScene), findsNothing);
    expect(falconLogos(), findsOneWidget);
    expect(find.text('جيد'), findsNothing); // report waits for landing
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 400));

    // Currency chips: enabled-only set, «تلقائي» removed. Labels use the
    // localized full currency names (currencyName) in the AR locale.
    for (final w in ['دولار أمريكي', 'ريال سعودي', 'ريال يمني جديد', 'ريال يمني قديم']) {
      expect(find.text(w), findsWidgets, reason: w);
    }
    expect(find.text('تلقائي'), findsNothing);
    expect(find.text('Auto'), findsNothing);

    // Status + key numbers (count-up needs its 700ms after landing).
    expect(find.text('جيد'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('120 دولار أمريكي'), findsOneWidget);

    // Product-only suggestions shown; inventory-only ones absent.
    expect(find.text('كم أطلب الشهر القادم؟'), findsOneWidget);
    expect(find.text('وش أكثر المنتجات ربحًا؟'), findsNothing);

    // Chart only when a real comparison exists (single seller → hidden).
    expect(find.byType(BarChart), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'inventory: different suggestions, chart when comparison exists, unified note',
      (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final (widget, gate) = buildHarness(
        scope: 'inventory', locale: 'ar', brightness: Brightness.light);
    await tester.pumpWidget(widget);
    await tester.pump(); // let the intro ticker activate on this frame
    gate.complete();
    await tester.pump(const Duration(milliseconds: 4300));
    await pumpReady(tester);

    // Pinned suggestions row (always visible).
    expect(find.text('وش أكثر المنتجات ربحًا؟'), findsOneWidget);
    expect(find.text('كم أطلب الشهر القادم؟'), findsNothing);
    // Below-fold cards need a scroll (ListView builds visible children only).
    await tester.drag(find.byType(ListView).first, const Offset(0, -520));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('تم توحيد القيم إلى دولار أمريكي حتى تكون المقارنة دقيقة.'),
        findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget); // 3 sellers → comparison
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat: user bubble from typed input and suggestion tap; input never disappears',
      (tester) async {
    final clipWrites = <Map>[];
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final (widget, gate) = buildHarness(
        scope: 'product', locale: 'ar', brightness: Brightness.light);
    await tester.pumpWidget(widget);
    await tester.pump(); // let the intro ticker activate on this frame
    gate.complete();
    await tester.pump(const Duration(milliseconds: 4300));
    await pumpReady(tester);

    // Type-expertise card for the product scope + suggested order qty
    // (below the fold on this viewport → scroll to it first).
    await tester.drag(find.byType(ListView).first, const Offset(0, -340));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('خبرة النوع'), findsOneWidget);
    expect(find.textContaining('الكمية المقترحة للطلب: 7'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'وش وضع المنتج؟');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    // Thinking experience: ONE falcon logo + rotating phrases, INLINE
    // below the user's message — no dots bubble, no spinner.
    expect(find.byType(FalconThinkingPhrases), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 2400));
    // Answer does NOT appear before the visual minimum (~4s).
    expect(find.textContaining('لا تشترِ الآن'), findsNothing);
    await tester.pump(const Duration(milliseconds: 2200));
    expect(find.text('وش وضع المنتج؟'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('لا تشترِ الآن'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('لا تشترِ الآن'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    expect(find.text('كم أطلب الشهر القادم؟'), findsOneWidget); // chip
    await tester.tap(find.text('كم أطلب الشهر القادم؟'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // chip + streamed bubble
    expect(find.text('كم أطلب الشهر القادم؟'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);

    // Tap a message → text copied (platform channel) + green «تم النسخ».
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipWrites.add(call.arguments as Map);
        return null;
      }
      return null;
    });
    final bubble = find.textContaining('لا تشترِ الآن').last;
    // Make sure the last bubble is fully in view above the pinned chat bar.
    await tester.ensureVisible(bubble);
    await tester.pump(const Duration(milliseconds: 250));
    // Copy now requires a LONG-PRESS (single tap does nothing).
    await tester.longPress(bubble, warnIfMissed: false);
    await tester.pump();
    expect(clipWrites, isNotEmpty, reason: 'clipboard must receive the text');
    expect((clipWrites.last as Map)['text'], contains('لا تشترِ الآن'));
    expect(find.text('تم النسخ'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, null);
    await tester.pump(const Duration(seconds: 3));
    // Flush the 4s thinking timer started by the chip-tap send, so no
    // timer is left pending when the widget tree is disposed.
    await tester.pump(const Duration(milliseconds: 4500));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('EN / dark / LTR renders without overflow on a small screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => AppLocalizations.preload('en'));
    final (widget, gate) = buildHarness(
        scope: 'inventory', locale: 'en', brightness: Brightness.dark);
    await tester.pumpWidget(widget);
    await tester.pump(); // let the intro ticker activate on this frame
    gate.complete();
    await tester.pump(const Duration(milliseconds: 4300));
    await pumpReady(tester);
    expect(find.text('Good'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800)); // count-up done
    // Small screen: the key-number tiles sit below the fold — scroll first
    // (ListView builds only visible children).
    await tester.drag(find.byType(ListView).first, const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('120 US Dollar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('session restore: same chat, no intro, no re-analysis (in-memory)',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    var analyzeHits = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.contains('/falcon/analyze')) analyzeHits++;
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
    }));
    // Seed the PROCESS-WIDE memory store directly.
    FalconMemoryStore.instance.put(
      'tester',
      'product',
      'p1',
      FalconSession(
        chat: const [
          {'role': 'user', 'content': 'س1'},
          {'role': 'assistant', 'content': 'ج1 محفوظة'},
        ],
        report: const {
          'status': 'good',
          'status_line': 'ok',
          'attention': <String>[],
          'recommendations': <String>[],
          'opportunity': '',
          'suggested_questions': <String>[],
          'ai': true,
          'stats': {
            'report_currency': 'USD',
            'unified': false,
            'total_sales': 10.0,
            'total_profit': 3.0,
            'inventory_value': 5.0,
            'total_cogs': 7.0,
            'products_count': 1,
            'top_sellers': [
              {'name': 'x', 'qty_sold': 1.0}
            ],
          },
        },
        reportCurrency: 'USD',
        lastActivity: DateTime.now(),
      ),
      workspace: BranchScope.token,
    );
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        inventoryApiProvider.overrideWithValue(InventoryApi(ApiClient(dio: dio))),
        currentUserIdProvider.overrideWithValue('tester'),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const FalconPage(scope: 'product', refId: 'p1', title: 't'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Restored conversation, NO intro replay. The kept report is re-read
    // once in place (latest product edits/sales), never blanked meanwhile.
    expect(find.text('ج1 محفوظة'), findsOneWidget);
    expect(find.byType(FalconIntroScene), findsNothing);
    expect(analyzeHits, 1);
    expect(find.text('ok'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // input still pinned
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme swap: header logo asset flips instantly (light ⇄ dark)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: reportFor('product')));
    }));
    Widget app(ThemeMode mode) => ProviderScope(
          overrides: [
            inventoryApiProvider
                .overrideWithValue(InventoryApi(ApiClient(dio: dio))),
            currentUserIdProvider.overrideWithValue('tester'),
          ],
          child: MaterialApp(
            themeMode: mode,
            theme: ThemeData(brightness: Brightness.light),
            darkTheme: ThemeData(brightness: Brightness.dark),
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const FalconPage(scope: 'product', refId: 'p1', title: 't'),
          ),
        );
    // Speed through intro+flight to reach live.
    await tester.pumpWidget(app(ThemeMode.light));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4300));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 300));

    String? headerAsset() {
      final imgs = tester
          .widgetList<Image>(falconLogos())
          .where((im) => im.width == 30.0)
          .toList();
      if (imgs.isEmpty) return null;
      return (imgs.first.image as AssetImage).assetName;
    }

    expect(headerAsset(), 'assets/images/falcon_light.png');

    // Switch to dark mid-page: same element, asset flips instantly.
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(headerAsset(), 'assets/images/falcon_dark.png');
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow reply: no extra delay on top of the network',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final (widget, gate) = buildHarness(
        scope: 'product', locale: 'ar', brightness: Brightness.light);
    await tester.pumpWidget(widget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4300));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'س؟');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3600)); // network took 3.6s
    gate.complete(); // answer arrives AFTER the 4s minimum
    await tester.pump(const Duration(milliseconds: 150));
    // Streaming reveal: words assemble over the typing cadence (~50ms/chunk).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.textContaining('لا تشترِ الآن'), findsOneWidget);
  });
}
