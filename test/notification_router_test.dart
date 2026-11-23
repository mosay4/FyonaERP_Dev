import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:go_router/go_router.dart';

/// Central NotificationRouter: payload → absolute route.
///
/// - absolute routes (incl. query params) pass through untouched
/// - slash-less payloads are repaired, ids are never dropped
/// - unknown payloads are a safe no-op (null)
void main() {
  group('pending navigation readiness', () {
    late GoRouter router;

    setUp(() {
      router = GoRouter(
        navigatorKey: rootNavigatorKey,
        initialLocation: '/splash',
        routes: [
          for (final path in ['/splash', '/ready', '/job-requests'])
            GoRoute(
              path: path,
              builder: (context, state) => const SizedBox.shrink(),
            ),
        ],
      );
    });

    Future<void> mountRouter(WidgetTester tester) async {
      await tester.pumpWidget(
        WidgetsApp.router(color: const Color(0xFFFFFFFF), routerConfig: router),
      );
      await tester.pumpAndSettle();
      addTearDown(() async {
        router.go('/ready');
        await tester.pumpAndSettle();
        NotificationRouter.flushPending();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      });
    }

    testWidgets('flush retains splash taps and delivers once ready', (
      tester,
    ) async {
      await mountRouter(tester);
      expect(NotificationRouter.pendingCountForTests, isEmpty);
      NotificationRouter.queuePending('/job-requests?invite=exact');

      expect(NotificationRouter.flushPending(), 0);
      expect(NotificationRouter.pendingCountForTests, [
        '/job-requests?invite=exact',
      ]);
      expect(router.routeInformationProvider.value.uri.path, '/splash');

      router.go('/ready');
      await tester.pumpAndSettle();

      expect(NotificationRouter.flushPending(), 1);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/job-requests?invite=exact',
      );
      expect(NotificationRouter.pendingCountForTests, isEmpty);
      expect(NotificationRouter.flushPending(), 0);
    });

    testWidgets('navigate queues known splash taps without navigating', (
      tester,
    ) async {
      await mountRouter(tester);
      expect(NotificationRouter.pendingCountForTests, isEmpty);
      final context = rootNavigatorKey.currentContext!;

      for (var i = 0; i < 2; i++) {
        expect(
          NotificationRouter.navigate(context, '/job-requests?invite=exact'),
          isFalse,
        );
      }
      expect(NotificationRouter.navigate(context, 'unknown-payload'), isFalse);
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/splash');
      expect(NotificationRouter.pendingCountForTests, [
        '/job-requests?invite=exact',
      ]);
    });
  });

  group('resolveRoute absolute passthrough', () {
    test('subscription invoice keeps params', () {
      expect(
        NotificationRouter.resolveRoute(
          '/subscription/invoice?invoice_no=INV-1&period=yearly',
        ),
        '/subscription/invoice?invoice_no=INV-1&period=yearly',
      );
    });

    test('recurring detail keeps id', () {
      expect(
        NotificationRouter.resolveRoute('/personal/recurring/detail?id=r1'),
        '/personal/recurring/detail?id=r1',
      );
    });

    test('personal debts keeps debtId', () {
      expect(
        NotificationRouter.resolveRoute('/personal/debts?debtId=d1'),
        '/personal/debts?debtId=d1',
      );
    });

    test('notifications list with id preserved', () {
      expect(
        NotificationRouter.resolveRoute('/notifications?id=42'),
        '/notifications?id=42',
      );
    });
  });

  group('resolveRoute slash-less fix', () {
    test('notifications?id=X gains slash, keeps id', () {
      expect(
        NotificationRouter.resolveRoute('notifications?id=99'),
        '/notifications?id=99',
      );
    });

    test('bare notifications', () {
      expect(
        NotificationRouter.resolveRoute('notifications'),
        RouteNames.notifications,
      );
    });

    test('slash-less personal route repaired', () {
      expect(
        NotificationRouter.resolveRoute('personal/debts?debtId=x'),
        '/personal/debts?debtId=x',
      );
    });

    test('slash-less subscription route repaired', () {
      expect(
        NotificationRouter.resolveRoute('subscription/pending'),
        '/subscription/pending',
      );
    });
  });

  group('resolveRoute keywords', () {
    test('sara opens the assistant', () {
      expect(NotificationRouter.resolveRoute('sara'), RouteNames.personalAi);
    });

    test('sessions', () {
      expect(NotificationRouter.resolveRoute('sessions'), RouteNames.sessions);
    });

    test('suggestions + admin variant', () {
      expect(
        NotificationRouter.resolveRoute('suggestions'),
        RouteNames.suggestions,
      );
      expect(
        NotificationRouter.resolveRoute('admin_suggestions'),
        RouteNames.suggestions,
      );
    });

    test('home defaults to personal, custom home honored', () {
      expect(
        NotificationRouter.resolveRoute('home'),
        RouteNames.personalDashboard,
      );
      expect(
        NotificationRouter.resolveRoute(
          'home',
          homeRoute: RouteNames.dashboard,
        ),
        RouteNames.dashboard,
      );
    });

    test('maintenance rows open the notifications list', () {
      expect(
        NotificationRouter.resolveRoute('maintenance-feature-x'),
        RouteNames.notifications,
      );
      expect(
        NotificationRouter.resolveRoute('maintenance_personal'),
        RouteNames.notifications,
      );
    });
  });

  group('resolveRoute unknown safe', () {
    test('unknown payload is null', () {
      expect(NotificationRouter.resolveRoute('foobar'), isNull);
    });

    test('empty / blank payload is null', () {
      expect(NotificationRouter.resolveRoute(''), isNull);
      expect(NotificationRouter.resolveRoute('   '), isNull);
    });

    test('lookalike prefixes do not match', () {
      expect(NotificationRouter.resolveRoute('sara_extra'), isNull);
      expect(NotificationRouter.resolveRoute('homely'), isNull);
    });
  });
}
