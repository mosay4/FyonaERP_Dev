import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_smart_coordinator.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/sara_quick_add_page.dart';
import 'package:fyona_flutter/features/personal/presentation/widgets/sara_smart_notifications_tile.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_daily_planner.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_notice_composer.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_smart_scheduler.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_smart_settings.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/shared/services/alarm_tap_bridge.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _native = MethodChannel('com.fyona.erp/alarm_native');

Widget _tileApp({
  String uid = 'u1',
  Future<TimeOfDay?> Function(BuildContext, TimeOfDay)? pick,
}) =>
    ProviderScope(
      overrides: [currentUserIdProvider.overrideWithValue(uid)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SaraSmartNotificationsTile(pickTime: pick),
        ),
      ),
    );

void main() {
  group('Preferences: Sara smart notifications switch + time picker', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('on by default with automatic (peak hour) time', (t) async {
      await t.runAsync(
          () => AppLocalizations.delegate.load(const Locale('en')));
      await t.pumpWidget(_tileApp());
      await t.pumpAndSettle();
      expect(find.text("Sara's smart notifications"), findsOneWidget);
      final sw = t.widget<Switch>(find.byKey(const Key('saraSmartNotifSwitch')));
      expect(sw.value, isTrue);
      expect(find.byKey(const Key('saraSmartNotifTimeRow')), findsOneWidget);
      expect(find.text('Auto (8:00 PM)'), findsOneWidget);
      // The time row says exactly «Daily notification time.» — no extra
      // hints under it (owner's request).
      expect(find.text('Daily notification time.'), findsOneWidget);
      expect(find.textContaining('not affected'), findsNothing);
      expect(find.textContaining('usually log'), findsNothing);
    });

    testWidgets('Arabic time row reads exactly «وقت الإشعار اليومي.»',
        (t) async {
      await t.runAsync(
          () => AppLocalizations.delegate.load(const Locale('ar')));
      await t.pumpWidget(ProviderScope(
        overrides: [currentUserIdProvider.overrideWithValue('u1')],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SaraSmartNotificationsTile()),
        ),
      ));
      await t.pumpAndSettle();
      final desc = t.widget<Text>(
          find.byKey(const Key('saraSmartNotifTimeDesc')));
      expect(desc.data, 'وقت الإشعار اليومي.');
      expect(find.textContaining('سارة تختار الساعة'), findsNothing);
      expect(find.textContaining('ما تتأثر'), findsNothing);
    });

    testWidgets('switch off hides the timer and persists per user', (t) async {
      await t.runAsync(
          () => AppLocalizations.delegate.load(const Locale('en')));
      await t.pumpWidget(_tileApp());
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('saraSmartNotifSwitch')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('saraSmartNotifTimeRow')), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SaraSmartSettingsStore.enabledKey('u1')), isFalse);
      // Another user keeps their own default (on).
      expect(prefs.getBool(SaraSmartSettingsStore.enabledKey('u2')), isNull);
      expect((await SaraSmartSettingsStore.load('u2')).enabled, isTrue);

      // Back on → the timer row reappears.
      await t.tap(find.byKey(const Key('saraSmartNotifSwitch')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('saraSmartNotifTimeRow')), findsOneWidget);
      expect(prefs.getBool(SaraSmartSettingsStore.enabledKey('u1')), isTrue);
    });

    testWidgets('time picker sets a custom daily time; can go back to auto',
        (t) async {
      await t.runAsync(
          () => AppLocalizations.delegate.load(const Locale('en')));
      TimeOfDay? offered;
      await t.pumpWidget(_tileApp(pick: (ctx, initial) async {
        offered = initial;
        return const TimeOfDay(hour: 7, minute: 30);
      }));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('saraSmartNotifTimeRow')));
      await t.pumpAndSettle();
      expect(offered, const TimeOfDay(hour: 20, minute: 0));
      expect(find.text('7:30 AM'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SaraSmartSettingsStore.timeKey('u1')), 7 * 60 + 30);

      await t.tap(find.byKey(const Key('saraSmartNotifUseAuto')));
      await t.pumpAndSettle();
      expect(find.text('Auto (8:00 PM)'), findsOneWidget);
      expect(prefs.getInt(SaraSmartSettingsStore.timeKey('u1')), isNull);
    });

    testWidgets('saved settings are restored', (t) async {
      SharedPreferences.setMockInitialValues({
        'flutter.${SaraSmartSettingsStore.timeKey('u1')}': 21 * 60 + 15,
        'flutter.${SaraSmartSettingsStore.peakKey('u1')}': 19,
      });
      await t.runAsync(
          () => AppLocalizations.delegate.load(const Locale('en')));
      await t.pumpWidget(_tileApp());
      await t.pumpAndSettle();
      expect(find.text('9:15 PM'), findsOneWidget);
      final s = await SaraSmartSettingsStore.load('u1');
      expect(s.effectiveMinutes, 21 * 60 + 15);
      expect(s.peakHour, 19);
    });
  });

  group('tap routing (payload → exact detail screen)', () {
    late GoRouter router;
    final paths = [
      '/splash',
      '/ready',
      '/personal/savings-detail/:goalId',
      '/personal/savings',
      '/personal/budget/detail',
      '/personal/reports/view',
      '/personal/quick-add',
      '/personal/transactions',
    ];

    setUp(() {
      AlarmTapBridge.resetDedupeForTests();
      router = GoRouter(
        navigatorKey: rootNavigatorKey,
        initialLocation: '/ready',
        routes: [
          for (final p in paths)
            GoRoute(path: p, builder: (_, _) => const SizedBox.shrink()),
        ],
      );
    });

    Future<void> mount(WidgetTester t) async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router));
      await t.pumpAndSettle();
      addTearDown(() async {
        router.go('/ready');
        await t.pumpAndSettle();
        NotificationRouter.flushPending();
        await t.pumpWidget(const SizedBox.shrink());
        router.dispose();
      });
    }

    String loc() => router.routeInformationProvider.value.uri.toString();

    testWidgets('warm tap: each Sara payload opens its screen', (t) async {
      await mount(t);
      final payloads = [
        SaraRoutes.goal('g-42'),
        SaraRoutes.goals,
        SaraRoutes.budget('b-7'),
        SaraRoutes.spendingReport,
        SaraRoutes.quickAddExpense,
        SaraRoutes.transactions,
      ];
      for (final p in payloads) {
        final ctx = rootNavigatorKey.currentContext!;
        expect(NotificationRouter.navigate(ctx, p), isTrue, reason: p);
        await t.pumpAndSettle();
        expect(loc(), p);
      }
    });

    testWidgets('cold start: a tap queued before the app is ready lands once',
        (t) async {
      router.go('/splash');
      await mount(t);
      router.go('/splash');
      await t.pumpAndSettle();
      final ctx = rootNavigatorKey.currentContext!;
      expect(NotificationRouter.navigate(ctx, SaraRoutes.goal('g1')), isFalse);
      expect(loc(), '/splash');
      router.go('/ready');
      await t.pumpAndSettle();
      expect(NotificationRouter.flushPending(), 1);
      await t.pumpAndSettle();
      expect(loc(), '/personal/savings-detail/g1');
    });

    testWidgets('native alarm tap (killed app / resume) routes via the bridge',
        (t) async {
      await mount(t);
      var served = false;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_native,
          (call) async {
        if (call.method == 'getInitialAlarmPayload' && !served) {
          served = true;
          return {
            'kind': 'sara',
            'refId': 'digest-20261125',
            'route': SaraRoutes.quickAddExpense,
          };
        }
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_native, null));
      expect(await AlarmTapBridge.consumeAndRoute(), isTrue);
      await t.pumpAndSettle();
      expect(loc(), '/personal/quick-add?type=expense');
      // Consumed once: a later resume does not re-route.
      expect(await AlarmTapBridge.consumeAndRoute(), isFalse);
    });
  });

  group('quick-add deep link', () {
    testWidgets('opens the add-transaction sheet exactly once', (t) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
        home: SaraQuickAddPage(
          type: 'income',
          background: const SizedBox.shrink(),
          openSheet: (_, type) => opened.add(type),
        ),
      ));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 1));
      expect(opened, ['income']);
      expect(SaraQuickAddPage.normalizeType('weird'), 'expense');
      expect(SaraQuickAddPage.normalizeType(null), 'expense');
    });
  });

  group('device scheduling (native alarm pipeline, kind=sara)', () {
    final calls = <MethodCall>[];

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls.clear();
      SaraSmartScheduler.debugPlatform = 'android';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_native, (call) async {
        calls.add(call);
        return true;
      });
    });

    tearDown(() {
      SaraSmartScheduler.debugPlatform = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_native, null);
    });

    SaraSlot slot(DateTime at, String route) => SaraSlot(
          fireAt: at,
          dayKey: SaraDailyPlanner.dayKey(at),
          notice: SaraNotice(
              kind: 'plan', title: 'Sara', body: 'Body', route: route),
        );

    test('schedules one sara alarm per day with its tap route', () async {
      final base = DateTime.now().add(const Duration(days: 1));
      final at = DateTime(base.year, base.month, base.day, 20);
      await SaraSmartScheduler.apply([
        slot(at, '/personal/savings-detail/g1'),
        slot(at.add(const Duration(days: 1)), '/personal/quick-add?type=expense'),
      ]);
      final sched =
          calls.where((c) => c.method == 'scheduleReminderAlarm').toList();
      expect(sched.length, 2);
      final args = Map<String, dynamic>.from(sched.first.arguments as Map);
      expect(args['kind'], 'sara');
      expect(args['route'], '/personal/savings-detail/g1');
      expect(args['millis'], at.millisecondsSinceEpoch);
      expect(args['requestCode'],
          SaraSmartScheduler.requestCodeForDay(SaraDailyPlanner.dayKey(at)));
      final prefs = await SharedPreferences.getInstance();
      final store = jsonDecode(prefs.getString(SaraSmartScheduler.storeKey)!)
          as Map<String, dynamic>;
      expect(store.length, 2);

      // Re-plan with only the second day → the first one is cancelled.
      calls.clear();
      await SaraSmartScheduler.apply([
        slot(at.add(const Duration(days: 1)), '/personal/quick-add?type=expense'),
      ]);
      final cancelled = calls
          .where((c) => c.method == 'cancelReminderAlarm')
          .map((c) => (c.arguments as Map)['requestCode'])
          .toList();
      expect(cancelled,
          [SaraSmartScheduler.requestCodeForDay(SaraDailyPlanner.dayKey(at))]);

      // Switch off → everything pending is cancelled and the store cleared.
      calls.clear();
      await SaraSmartScheduler.cancelAll();
      expect(calls.where((c) => c.method == 'cancelReminderAlarm').length, 1);
      expect(prefs.getString(SaraSmartScheduler.storeKey), isNull);
    });

    test('a fired day is remembered so it never re-fires', () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      final key = SaraDailyPlanner.dayKey(past);
      SharedPreferences.setMockInitialValues({
        'flutter.${SaraSmartScheduler.storeKey}': jsonEncode({
          'sara_$key': {
            'millis': past.millisecondsSinceEpoch,
            'requestCode': 1,
            'day': key,
          },
        }),
      });
      expect(await SaraSmartScheduler.lastFiredDay(), key);
    });

    test('every Sara notification carries her avatar + custom sound', () {
      final d = SaraSmartScheduler.detailsForTest('Body').android!;
      final icon = d.largeIcon as DrawableResourceAndroidBitmap;
      expect(icon.data, 'sara_avatar_notif');
      expect((d.sound as RawResourceAndroidNotificationSound).sound,
          'sound_1');
      expect(d.channelId, 'sara_channel');
    });

    test('instant alerts are capped per day', () async {
      expect(await SaraSmartScheduler.claimInstantSlot('20261125'), isTrue);
      expect(await SaraSmartScheduler.claimInstantSlot('20261125'), isTrue);
      expect(await SaraSmartScheduler.claimInstantSlot('20261125'), isFalse);
      expect(await SaraSmartScheduler.claimInstantSlot('20261126'), isTrue);
    });
  });

  group('coordinator (silent background planner)', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      SaraSmartScheduler.debugPlatform = 'android';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_native, (call) async {
        calls.add(call);
        return true;
      });
    });

    tearDown(() {
      SaraSmartScheduler.debugPlatform = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_native, null);
    });

    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        currentUserIdProvider.overrideWithValue('u1'),
        currencyEngineProvider.overrideWith((ref) => CurrencyEngine()),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    void seed(ProviderContainer c) {
      final now = DateTime.now();
      final txs = <PersonalTransaction>[
        for (var i = 1; i <= 40; i++)
          PersonalTransaction(
            id: 'e$i',
            type: 'expense',
            amount: 100,
            category: 'Food',
            currency: 'USD',
            date: DateTime(now.year, now.month, now.day - i),
          ),
        for (final m in [1, 31])
          PersonalTransaction(
            id: 'in$m',
            type: 'income',
            amount: 6000,
            category: 'Salary',
            currency: 'USD',
            date: DateTime(now.year, now.month, now.day - m),
          ),
      ];
      // ignore: invalid_use_of_protected_member
      c.read(personalFinanceProvider.notifier).state = PersonalFinanceState(
        walletCurrency: 'USD',
        transactions: txs,
        savingsGoals: [
          SavingsGoal(
            id: 'g1',
            name: 'Car',
            targetAmount: 5000,
            currency: 'USD',
            deadline: DateTime(now.year, now.month, now.day + 60)
                .toIso8601String()
                .substring(0, 10),
          ),
        ],
      );
    }

    test('plans and schedules the next digests from Personal data', () async {
      SharedPreferences.setMockInitialValues({});
      final c = container();
      seed(c);
      await c.read(saraSmartCoordinatorProvider).run();
      final sched =
          calls.where((x) => x.method == 'scheduleReminderAlarm').toList();
      expect(sched.length, 3);
      for (final x in sched) {
        expect((x.arguments as Map)['kind'], 'sara');
      }
      final routes = sched.map((x) => (x.arguments as Map)['route']).toSet();
      expect(routes, contains('/personal/savings-detail/g1'));
    });

    test('switch off → nothing scheduled, pending digests cancelled', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.${SaraSmartSettingsStore.enabledKey('u1')}': false,
        'flutter.${SaraSmartScheduler.storeKey}': jsonEncode({
          'sara_x': {
            'millis': DateTime.now()
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch,
            'requestCode': 77,
            'day': '20991231',
          },
        }),
      });
      final c = container();
      seed(c);
      await c.read(saraSmartCoordinatorProvider).run();
      expect(calls.where((x) => x.method == 'scheduleReminderAlarm'), isEmpty);
      expect(
          calls
              .where((x) => x.method == 'cancelReminderAlarm')
              .map((x) => (x.arguments as Map)['requestCode']),
          [77]);
    });

    test('Personal data not loaded yet → keeps the existing schedule',
        () async {
      SharedPreferences.setMockInitialValues({});
      final c = container();
      await c.read(saraSmartCoordinatorProvider).run();
      expect(calls, isEmpty);
    });
  });
}
