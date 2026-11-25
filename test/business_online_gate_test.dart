import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/business_online_gate.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_services_grid.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_movements_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/shared/widgets/connectivity_widgets.dart';

// The offline art plays one finite pass; bounded pumps keep the checks fast
// while the approved dialog is visible.
Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<GoRouter> _host(
  WidgetTester tester,
  ConnectivityService service, {
  bool falcon = false,
}) async {
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => falcon
            ? const ProductMovementsPage(id: 'p')
            : const Scaffold(
                body: SingleChildScrollView(child: BusinessServicesGrid()),
              ),
      ),
      for (final path in [
        '/employees',
        RouteNames.ai,
        RouteNames.salesAdd,
        '/inventory/falcon',
      ])
        GoRoute(
          path: path,
          builder: (_, _) => const Scaffold(body: Text('destination')),
        ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectivityServiceProvider.overrideWithValue(service),
        employeeCanProvider.overrideWith((ref, key) => true),
        productStatsProvider.overrideWith((ref, key) async => {}),
      ],
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Finder _entry(WidgetTester tester, String key) {
  final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold).first));
  return key == 'invFalcon'
      ? find.byTooltip(l10n.translate(key))
      : find.text(l10n.translate(key));
}

void _expectApprovedDialog(WidgetTester tester) {
  final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)));
  expect(l10n.locale.languageCode, 'ar');
  expect(find.text(l10n.translate('noInternet')), findsOneWidget);
  expect(
    find.text(l10n.translate('offlineSectionRequiresInternet')),
    findsOneWidget,
  );
  expect(
    find.text('هذه الخدمة تحتاج إلى اتصال بالإنترنت.'),
    findsOneWidget,
  );
  expect(find.text('لا يوجد اتصال بالإنترنت'), findsOneWidget);
  // The auto-sync promise is no longer part of this notice.
  expect(find.text(l10n.translate('offlineAutoSyncHint')), findsNothing);
  expect(find.textContaining('ستتم المزامنة'), findsNothing);
  expect(find.byType(OfflineSignalArt), findsOneWidget);
}

void main() {
  setUp(() {
    BranchScope.allMode = false;
    BranchScope.branchId = null;
  });
  tearDown(() {
    BranchScope.allMode = false;
    BranchScope.branchId = null;
  });

  for (final key in ['bizEmployees', 'bizSara', 'invFalcon']) {
    testWidgets('$key offline blocks navigation; online retry proceeds', (
      tester,
    ) async {
      final service = ConnectivityService(debugOnline: false);
      addTearDown(service.dispose);
      final router = await _host(tester, service, falcon: key == 'invFalcon');
      await tester.ensureVisible(_entry(tester, key));
      await tester.tap(_entry(tester, key));
      await _pumpDialog(tester);
      _expectApprovedDialog(tester);
      expect(router.routerDelegate.currentConfiguration.last.matchedLocation, '/');
      expect(find.text('destination'), findsNothing);

      // Retrying while offline must not navigate or replace the approved text.
      await tester.tap(find.byType(ElevatedButton));
      await _pumpDialog(tester);
      _expectApprovedDialog(tester);
      expect(router.routerDelegate.currentConfiguration.last.matchedLocation, '/');

      service.debugSetOnline(true);
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('destination'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        key == 'bizEmployees'
            ? '/employees'
            : key == 'bizSara'
            ? RouteNames.ai
            : '/inventory/falcon',
      );
      if (key == 'invFalcon') {
        expect(GoRouterState.of(tester.element(find.text('destination'))).uri.queryParameters, {
          'scope': 'product',
          'id': 'p',
        });
      }
    });

    testWidgets('$key online never opens an offline dialog', (tester) async {
      final service = ConnectivityService(debugOnline: true);
      addTearDown(service.dispose);
      await _host(tester, service, falcon: key == 'invFalcon');
      await tester.ensureVisible(_entry(tester, key));
      await tester.tap(_entry(tester, key));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('destination'), findsOneWidget);
    });
  }

  testWidgets('draft sale form can open without claiming a server write', (tester) async {
    final service = ConnectivityService(debugOnline: false);
    addTearDown(service.dispose);
    final router = await _host(tester, service);
    await tester.tap(_entry(tester, 'bizSaleInvoice'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('destination'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.last.matchedLocation, RouteNames.salesAdd);
    expect(service.isOnline, isFalse);
  });

  testWidgets('dismissed approved dialog returns false without proceeding', (
    tester,
  ) async {
    final service = ConnectivityService(debugOnline: false);
    addTearDown(service.dispose);
    bool? result;
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectivityServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await ensureBusinessOnline(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await _pumpDialog(tester);
    _expectApprovedDialog(tester);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop(false);
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
