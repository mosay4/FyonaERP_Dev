import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_reminder_store.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_daily_planner.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_insight_engine.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_smart_scheduler.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_smart_settings.dart';
import 'package:fyona_flutter/shared/services/alarm_tap_bridge.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:fyona_flutter/shared/services/reminder_codec.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owner reports:
///  - a debt reminder tapped from the shade opened HOME, not that debt;
///  - Sara's smart notification fired once (time set 1 minute ahead), then a
///    second time chosen the same day never arrived.
const _native = MethodChannel('com.fyona.erp/alarm_native');

String tr(String key, [Map<String, dynamic>? p]) => key;
String money(double a, String c) => '$c $a';

final _now = DateTime(2026, 11, 25, 10);

SaraInsightInput _input() => SaraInsightInput(
      now: _now,
      baseCurrency: 'SAR',
      transactions: [
        for (var d = 1; d <= 24; d++)
          InsightTx(
            id: 't$d',
            type: 'expense',
            amount: 100,
            category: 'Food',
            date: DateTime(2026, 11, d, 21),
            createdAt: DateTime(2026, 11, d, 21),
          ),
      ],
    );

void main() {
  group('Sara digest: a new time the same day always holds', () {
    final today = SaraDailyPlanner.dayKey(_now);
    final firedAt = DateTime(2026, 11, 25, 9, 1).millisecondsSinceEpoch;

    List<SaraSlot> plan({int? changedAt, int? lastFiredAt}) => SaraDailyPlanner.plan(
          input: _input(),
          now: _now,
          minutesOfDay: 14 * 60,
          lastFiredDay: today,
          lastFiredAtMs: lastFiredAt,
          timeChangedAtMs: changedAt,
          cooldown: const {},
          tr: tr,
          money: money,
        );

    test('time changed after today fired → today is scheduled at the new time', () {
      final slots = plan(
          lastFiredAt: firedAt,
          changedAt: DateTime(2026, 11, 25, 9, 30).millisecondsSinceEpoch);
      expect(slots.first.dayKey, today);
      expect(slots.first.fireAt, DateTime(2026, 11, 25, 14));
      // One digest per day: never two slots for today.
      expect(slots.where((s) => s.dayKey == today).length, 1);
    });

    test('no change since it fired → today stays done (no duplicate)', () {
      expect(plan(lastFiredAt: firedAt).any((s) => s.dayKey == today), isFalse);
      // The re-timed digest fired too: later re-plans do not repeat it.
      final secondFire = DateTime(2026, 11, 25, 9, 45).millisecondsSinceEpoch;
      expect(
          plan(lastFiredAt: secondFire,
                  changedAt: DateTime(2026, 11, 25, 9, 30).millisecondsSinceEpoch)
              .any((s) => s.dayKey == today),
          isFalse);
    });

    test('every planned day carries a notice (check-in when nothing new)', () {
      final slots = SaraDailyPlanner.plan(
        input: _input(),
        now: _now,
        minutesOfDay: 14 * 60,
        lastFiredDay: null,
        cooldown: const {},
        tr: tr,
        money: money,
      );
      expect(slots.map((s) => s.dayKey), ['20261125', '20261126', '20261127']);
      final c = SaraDailyPlanner.checkIn(tr);
      expect(c.route, '/personal/transactions');
      expect(c.title, 'saraNotifCheckInTitle');
    });

    test('setMinutes records when the time was changed', () async {
      SharedPreferences.setMockInitialValues({});
      final n = SaraSmartSettingsNotifier('u1');
      await Future<void>.delayed(Duration.zero);
      final at = DateTime(2026, 11, 25, 9, 30);
      await n.setMinutes(14 * 60, now: at);
      expect(n.state.timeChangedAtMs, at.millisecondsSinceEpoch);
      final back = await SaraSmartSettingsStore.load('u1');
      expect(back.minutes, 14 * 60);
      expect(back.timeChangedAtMs, at.millisecondsSinceEpoch);
    });
  });

  group('Sara retime: moves the stored digests at once', () {
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

    test('today already fired; new time 23:59 → re-armed today, same code', () async {
      final now = DateTime.now();
      final today = SaraDailyPlanner.dayKey(now);
      final fired = now.subtract(const Duration(minutes: 5));
      final rc = SaraSmartScheduler.requestCodeForDay(today);
      SharedPreferences.setMockInitialValues({
        'flutter.${SaraSmartScheduler.storeKey}': jsonEncode({
          'sara_$today': ReminderCodec.buildEntry(
            millis: fired.millisecondsSinceEpoch,
            title: 'Sara',
            body: 'Body',
            kind: 'sara',
            refId: 'digest-$today',
            requestCode: rc,
            route: '/personal/savings',
            extra: {'day': today},
          ),
        }),
      });
      // Only meaningful while 23:59 is still ahead today.
      final target = DateTime(now.year, now.month, now.day, 23, 59);
      if (!target.isAfter(now.add(const Duration(seconds: 31)))) return;
      await SaraSmartScheduler.retime(23 * 60 + 59, now: now);
      final sched = calls.where((c) => c.method == 'scheduleReminderAlarm').toList();
      expect(sched.length, 1);
      final args = Map<String, dynamic>.from(sched.single.arguments as Map);
      expect(args['millis'], target.millisecondsSinceEpoch);
      expect(args['requestCode'], rc);
      expect(args['route'], '/personal/savings');
      // What fired before is remembered, so the planner knows the change came after.
      expect(await SaraSmartScheduler.lastFiredAt(now: now), fired.millisecondsSinceEpoch);
    });

    test('a pending digest whose new time has passed is cancelled', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final day = SaraDailyPlanner.dayKey(tomorrow);
      final rc = SaraSmartScheduler.requestCodeForDay(day);
      SharedPreferences.setMockInitialValues({
        'flutter.${SaraSmartScheduler.storeKey}': jsonEncode({
          'sara_$day': {
            'millis': DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 20).millisecondsSinceEpoch,
            'requestCode': rc,
            'day': day,
            'route': '/personal/savings',
          },
        }),
      });
      // "now" is the day after tomorrow's 21:00: 08:00 of that day passed.
      final later = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
      await SaraSmartScheduler.retime(8 * 60, now: later);
      expect(calls.where((c) => c.method == 'cancelReminderAlarm').map((c) => (c.arguments as Map)['requestCode']),
          [rc]);
    });
  });

  group('reminder taps open their exact screen', () {
    test('route per kind; boot copy keeps the route', () {
      expect(AlarmTapBridge.routeFor('debt', 'd1', ''), '/personal/debts?debtId=d1');
      expect(AlarmTapBridge.routeFor('recurring', 'r1', ''), '/personal/recurring/detail?id=r1');
      expect(AlarmTapBridge.routeFor('sara', 'digest-1', '/personal/savings'), '/personal/savings');
      expect(AlarmTapBridge.routeFor('sara', 'digest-1', ''), RouteNames.personalDashboard);
      for (final store in [PersonalReminderStore.debt, PersonalReminderStore.recurring, PersonalReminderStore.sara]) {
        final boot = PersonalReminderStore.redactEntry(store, 'k', {
          'millis': 1, 'requestCode': 7, 'kind': 'debt', 'refId': 'd1',
          'route': '/personal/debts?debtId=d1', 'debt': {'id': 'd1', 'person_name': 'Ali'},
        });
        expect(boot['route'], '/personal/debts?debtId=d1', reason: store);
        expect(boot['refId'], 'd1');
        expect(jsonEncode(boot).contains('Ali'), isFalse);
      }
    });

    group('router', () {
      late GoRouter router;
      var gateNext = false;
      setUp(() {
        AlarmTapBridge.resetDedupeForTests();
        NotificationRouter.resetForTests();
        gateNext = false;
        router = GoRouter(
          navigatorKey: rootNavigatorKey,
          initialLocation: '/personal/dashboard',
          redirect: (_, state) {
            // Entitlements not settled yet: the guard sends the first
            // navigation to account entry (which then opens home).
            if (gateNext && state.matchedLocation == '/personal/debts') {
              gateNext = false;
              return '/account-entry';
            }
            return null;
          },
          routes: [
            for (final p in ['/personal/dashboard', '/personal/debts', '/account-entry', '/dashboard'])
              GoRoute(path: p, builder: (_, _) => const SizedBox.shrink()),
          ],
        );
      });

      Future<void> mount(WidgetTester t) async {
        await t.pumpWidget(WidgetsApp.router(color: const Color(0xFFFFFFFF), routerConfig: router));
        await t.pumpAndSettle();
        addTearDown(() async {
          NotificationRouter.resetForTests();
          await t.pumpWidget(const SizedBox.shrink());
          router.dispose();
        });
      }

      String loc() => router.routeInformationProvider.value.uri.toString();

      testWidgets('a tap bounced to account entry is delivered after it', (t) async {
        await mount(t);
        gateNext = true;
        NotificationRouter.navigateOrQueue('/personal/debts?debtId=d1');
        await t.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/account-entry');
        expect(NotificationRouter.pendingCountForTests, ['/personal/debts?debtId=d1']);
        // Account entry opens home, then flushes the waiting tap.
        router.go('/personal/dashboard');
        await t.pumpAndSettle();
        expect(NotificationRouter.flushPending(), 1);
        await t.pumpAndSettle();
        expect(loc(), '/personal/debts?debtId=d1');
        expect(NotificationRouter.pendingCountForTests, isEmpty);
      });

      testWidgets('the Personal section is selected before a Personal tap opens', (t) async {
        await mount(t);
        router.go('/dashboard');
        await t.pumpAndSettle();
        final prepared = <String>[];
        NotificationRouter.prepareSection = (route) async => prepared.add(route);
        NotificationRouter.navigateOrQueue('/personal/debts?debtId=d2');
        await t.pumpAndSettle();
        expect(prepared, ['/personal/debts?debtId=d2']);
        expect(loc(), '/personal/debts?debtId=d2');
      });

      testWidgets('a native tap routes once; the same reminder later routes again', (t) async {
        await mount(t);
        var served = 0;
        AlarmTapBridge.debugReadPayload = () async {
          served++;
          return {'kind': 'debt', 'refId': 'd3', 'route': ''};
        };
        addTearDown(() => AlarmTapBridge.debugReadPayload = null);
        final seen = <String>[];
        AlarmTapBridge.onTap = (k, id) => seen.add('$k:$id');
        addTearDown(() => AlarmTapBridge.onTap = null);
        expect(await AlarmTapBridge.consumeAndRoute(), isTrue);
        await t.pumpAndSettle();
        expect(loc(), '/personal/debts?debtId=d3');
        expect(seen, ['debt:d3']);
        // Resume right after the same tap: not routed twice.
        router.go('/personal/dashboard');
        await t.pumpAndSettle();
        expect(await AlarmTapBridge.consumeAndRoute(), isTrue);
        await t.pumpAndSettle();
        expect(loc(), '/personal/dashboard');
        expect(served, 2);
      });
    });
  });
}
