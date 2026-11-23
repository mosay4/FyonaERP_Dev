import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/report_view_page.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/reports_hub_page.dart';
import 'package:fyona_flutter/features/reports/presentation/widgets/report_scenes.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

DirectoryAccess _scope(DirectoryWorkspace workspace) => DirectoryAccess(
  workspace: workspace,
  branchId: _id(),
  financialCutover: true,
  readable: DirectoryPartyKind.values.toSet(),
  writable: DirectoryPartyKind.values.toSet(),
);

Future<String> _opening(
  BusinessLedger ledger,
  BusinessLedgerAccess access,
  DirectoryPartyKind kind,
  int amount,
  String currency, {
  required String name,
}) async {
  final id = _id();
  await ledger.addPartyWithOpeningDebt(
    access,
    kind,
    commandId: id,
    name: name,
    amountMinor: amount,
    currency: currency,
  );
  return id;
}

void main() {
  test(
    'branch debt balances, overdue and period receipts use actual saved amounts',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-debts-report-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://report.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      final scope = _scope(workspace), sibling = _scope(workspace);
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final other = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final ledger = db.ledger;
      final customer = await _opening(
        ledger,
        access,
        DirectoryPartyKind.customer,
        10000,
        'SAR',
        name: 'Buyer',
      );
      final vendor = await _opening(
        ledger,
        access,
        DirectoryPartyKind.supplier,
        4200,
        'USD',
        name: 'Vendor',
      );
      await _opening(
        ledger,
        other,
        DirectoryPartyKind.customer,
        770000,
        'SAR',
        name: 'Separate buyer',
      );
      final account = _id();
      await ledger.createAccount(
        access,
        commandId: account,
        bankName: 'Cash',
        accountName: 'USD',
        accountNumber: '1',
        currency: 'USD',
        openingMinor: 10000,
      );
      await ledger.issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'SAR',
        partyId: customer,
        dueDate: '2001-02-03',
        lines: const [
          CommerceIssueLine(
            description: 'Service',
            quantity: '1',
            unitMinor: 5000,
            isService: true,
          ),
        ],
        payments: [
          CommerceIssuePayment(
            accountId: account,
            paymentCurrency: 'USD',
            originalMinor: 500,
            rate: BusinessRate('USD', 'SAR', '4'),
          ),
        ],
      );
      await ledger.issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.purchase,
        commandId: _id(),
        currency: 'USD',
        partyId: vendor,
        lines: const [
          CommerceIssueLine(
            description: 'Purchase service',
            quantity: '1',
            unitMinor: 1800,
            isService: true,
          ),
        ],
        payments: [
          CommerceIssuePayment(
            accountId: account,
            paymentCurrency: 'USD',
            originalMinor: 300,
          ),
        ],
      );
      await db.close();
      db = await open();
      Future<Map<String, dynamic>> report({String? from, String? to}) =>
          db.ledger.debtReport(access, currency: 'SAR', from: from, to: to);
      final data = await report();
      expect(data['branch_ids'], [scope.branchId]);
      expect(data['customers']['total'], '130.00');
      expect(data['customers']['count'], 1);
      expect(data['customers']['top'].single['name'], 'Buyer');
      expect(data['suppliers']['total'], isNull);
      expect(data['suppliers']['per_currency'], [
        {'currency': 'USD', 'total': '57.00'},
      ]);
      expect(data['overdue']['total'], '30.00');
      expect(data['overdue']['count'], 1);
      expect(data['collected']['total'], '20.00');
      expect(data['collected']['per_currency'], [
        {'currency': 'USD', 'total': '5.00'},
      ]);
      expect(data['paid_to_suppliers']['total'], isNull);
      expect(data['paid_to_suppliers']['per_currency'], [
        {'currency': 'USD', 'total': '3.00'},
      ]);
      expect(data['totals_complete'], isFalse);
      expect(
        data['recent_movements'].map((row) => row['amount']),
        unorderedEquals(['5.00', '-3.00']),
      );
      expect(
        data['recent_movements'].every((row) => row['currency'] == 'USD'),
        isTrue,
      );
      final earlier = await report(from: '2001-01-01', to: '2001-02-03');
      expect(earlier['customers']['total'], '130.00');
      expect(earlier['collected']['total'], '0.00');
      expect(earlier['recent_movements'], isEmpty);
      expect(
        () => report(from: '2001-03-01', to: '2001-02-03'),
        throwsFormatException,
      );
      expect(() => report(from: '2001-02-31'), throwsFormatException);
      expect(await db.ledger.debtReportCurrencies(access), {'SAR', 'USD'});
    },
  );

  testWidgets(
    'report page and hub use the device only, and clear values after permission loss',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const audioGlobal = MethodChannel('xyz.luan/audioplayers.global');
      const audio = MethodChannel('xyz.luan/audioplayers');
      const audioEvents = EventChannel('xyz.luan/audioplayers.global/events');
      const motion = MethodChannel('fyona/motion_audio');
      messenger.setMockMethodCallHandler(audioGlobal, (_) async => null);
      messenger.setMockStreamHandler(
        audioEvents,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      messenger.setMockMethodCallHandler(motion, (_) async => false);
      messenger.setMockMethodCallHandler(audio, (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$id'),
            MockStreamHandler.inline(onListen: (_, _) {}),
          );
        }
        return null;
      });
      final scope = _scope(
        DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: _id(),
          organizationId: _id(),
        ),
      );
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      late Directory root;
      late DirectoryPilotStore store;
      await tester.runAsync(() async {
        await AppLocalizations.preload('ar');
        root = await Directory.systemTemp.createTemp('fyona-debt-report-ui-');
        store = DirectoryPilotStore(
          root: () async => root,
          keys: FixtureDirectoryKeys(),
        );
        await BranchScope.save(
          token: 'fixture',
          branchId: scope.branchId,
          branchName: 'معمل',
          organizationId: scope.workspace.organizationId,
          allMode: false,
        );
        await store.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {
            'business': {
              'active': true,
              'end_date': DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            },
          },
        });
        await store.withLedger(access, () => scope, (ledger) async {
          final account = _id();
          await ledger.createAccount(
            access,
            commandId: account,
            bankName: 'Local reports bank',
            accountName: 'Fixture account',
            accountNumber: '1',
            currency: 'SAR',
            openingMinor: 9900,
          );
          await ledger.move(
            access,
            commandId: _id(),
            accountId: account,
            amountMinor: 2501,
            withdraw: true,
            expenseCategory: 'Transport fixture',
          );
          await _opening(
            ledger,
            access,
            DirectoryPartyKind.customer,
            123456,
            'SAR',
            name: 'Local buyer A',
          );
          await _opening(
            ledger,
            access,
            DirectoryPartyKind.customer,
            654321,
            'USD',
            name: 'Local buyer B',
          );
        });
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
        await BranchScope.clear();
      });
      final denied = StateProvider<Set<String>>((_) => {});
      final connectivity = ConnectivityService(debugOnline: false);
      addTearDown(connectivity.dispose);
      final rateDio = Dio();
      addTearDown(rateDio.close);
      final calls = <String>[];
      rateDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls.add('${options.method} ${options.path}');
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          connectivityServiceProvider.overrideWithValue(connectivity),
          businessLocalLedgerScopeProvider.overrideWithValue(scope),
          directoryPilotStoreProvider.overrideWithValue(store),
          employeeCanProvider.overrideWith(
            (ref, key) => !ref.watch(denied).contains(key),
          ),
          apiClientProvider.overrideWithValue(ApiClient(dio: rateDio)),
        ],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });
      final api = container.read(businessReportsApiProvider);
      // Every report uses this device, with the connected writer forbidden.
      await tester.runAsync(() async {
        final inventory = await api.inventory(null, null, 'SAR');
        expect(inventory['report'], 'inventory');
        expect(inventory['local_valuation'], 'as_recorded');
        expect(inventory['totals_complete'], isTrue);
        expect(inventory['products'], 0);
        expect(inventory['categories'], isNull);
        final overview = await api.overview(null, null, 'SAR');
        expect(overview['branch_ids'], [scope.branchId]);
        expect(overview['totals_complete'], isFalse);
        expect(overview['customer_debt']['total'], isNull);
        expect(overview['expenses']['total'], '25.01');
        final home = await api.home(null, null, 'SAR');
        expect(home['kpis']['customer_debt']['total'], isNull);
        expect(home['kpis']['spent']['total'], '25.01');
        expect(
          (await api.salesPurchases(null, null, 'SAR'))['sales']['count'],
          0,
        );
      });
      tester.view.physicalSize = const Size(400, 1320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Drain the fake-async queue before awaiting any store work: a store
      // entry queued from a listener callback must run and release the lock.
      Future<void> drain() async {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }

      Future<void> mount(Widget page) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: page,
            ),
          ),
        );
        await tester.pump();
      }

      Future<void> see(Finder finder) async {
        for (var i = 0; i < 90 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 45));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)),
          );
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
        }
        expect(finder, findsWidgets);
      }

      await mount(const ReportsHubPage());
      await see(find.text(AppLocalizations.t('repQSold')));
      expect(find.text(AppLocalizations.t('repDebts')), findsOneWidget);
      expect(find.text(AppLocalizations.t('repMoney')), findsOneWidget);
      container.read(denied.notifier).state = {'sales.view'};
      await tester.pump();
      expect(find.text(AppLocalizations.t('repQSold')), findsNothing);
      container.read(denied.notifier).state = {};
      await mount(
        const ReportViewPage(kind: 'debts', currency: 'SAR', autoStart: true),
      );
      await see(find.textContaining('1,234.56'));
      // The owner asked for no device/currency notice on the reports.
      expect(
        find.text(AppLocalizations.t('repDebtStoredCurrencies')),
        findsNothing,
      );
      expect(find.textContaining('6,543.21'), findsWidgets);
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
      container.read(denied.notifier).state = {'customers.details'};
      await tester.pump();
      expect(find.textContaining('6,543.21'), findsNothing);
      expect(find.text('غير مصرح بعرض التقرير'), findsOneWidget);
      await drain();
      await tester.runAsync(
        () => expectLater(
          api.debts(null, null),
          throwsA(isA<DirectoryAccessDenied>()),
        ),
      );
      container.read(denied.notifier).state = {};
      await mount(
        const ReportViewPage(
          key: ValueKey('local-money'),
          kind: 'money',
          currency: 'USD',
          autoStart: true,
        ),
      );
      await see(find.text('Transport fixture'));
      expect(find.textContaining('25.01'), findsWidgets);
      expect(find.text('Local reports bank'), findsWidgets);
      expect(
        find.text(AppLocalizations.t('repDebtStoredCurrencies')),
        findsNothing,
      );
      container.read(denied.notifier).state = {'transactions'};
      await tester.pump();
      expect(find.text('Local reports bank'), findsNothing);
      expect(find.text('غير مصرح بعرض التقرير'), findsOneWidget);
      await drain();
      await tester.runAsync(
        () => expectLater(
          api.money(null, null),
          throwsA(isA<DirectoryAccessDenied>()),
        ),
      );
      container.read(denied.notifier).state = {};
      await mount(
        const ReportViewPage(
          key: ValueKey('local-inventory'),
          kind: 'inventory',
          currency: 'SAR',
          autoStart: true,
        ),
      );
      await see(find.text(AppLocalizations.t('repStockValueHero')));
      expect(find.text(AppLocalizations.t('repDebtStored')), findsNothing);
      // Categories do not exist on the device ledger — shown as missing,
      // never as a guessed zero.
      expect(find.text('—'), findsWidgets);

      // Real hub confirmation, route, scene, result and back navigation
      // for every report, with only the device source available.
      final router = GoRouter(
        initialLocation: '/reports',
        routes: [
          GoRoute(path: '/reports', builder: (_, _) => const ReportsHubPage()),
          GoRoute(
            path: '/reports/view',
            builder: (_, state) {
              final q = state.uri.queryParameters;
              return ReportViewPage(
                kind: q['kind']!,
                currency: q['currency'],
                period: q['period'],
                autoStart: q['autostart'] == '1',
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: router,
          ),
        ),
      );
      await see(find.text(AppLocalizations.t('reportsHow')));
      expect(find.text(AppLocalizations.t('repLocalReportsReady')), findsNothing);
      Future<void> openCard(
        String title,
        ReportScene scene, {
        bool cancel = false,
      }) async {
        final card = find.text(AppLocalizations.t(title)).last;
        await tester.scrollUntilVisible(
          card,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(card);
        await tester.pumpAndSettle();
        await tester.tap(find.text(AppLocalizations.t('repViewReport')));
        final overlay = find.byType(ReportSceneOverlay);
        for (var frame = 0; frame < 16 && overlay.evaluate().isEmpty; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(overlay, findsOneWidget);
        expect(tester.widget<ReportSceneOverlay>(overlay).scene, scene);
        if (cancel) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(ReportsHubPage), findsOneWidget);
          return;
        }
        final todayChip = find.descendant(
          of: find.byType(ReportViewPage),
          matching: find.text(AppLocalizations.t('reconPeriodToday')),
        );
        await see(todayChip);
        await tester.pumpAndSettle();
        expect(overlay, findsNothing);
        await tester.tap(todayChip);
        await tester.pump();
        expect(overlay, findsNothing);
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new).first);
        await tester.pumpAndSettle();
        expect(find.byType(ReportsHubPage), findsOneWidget);
      }

      await openCard('repSalesPurchases', ReportScene.sales, cancel: true);
      await openCard('repSalesPurchases', ReportScene.sales);
      await openCard('repMoney', ReportScene.money);
      await openCard('repInventory', ReportScene.inventory);
      await openCard('repDebts', ReportScene.debts);
      await openCard('repOverview', ReportScene.overview);
      expect(
        calls,
        isEmpty,
      ); // flight mode: no FX refresh or report network call

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await mount(
        const ReportViewPage(
          kind: 'overview',
          currency: 'SAR',
          autoStart: true,
        ),
      );
      await see(find.textContaining('6,543.21'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
      disposed = true;
    },
    skip: !DirectoryPilotBuild.signupEnabled,
    timeout: const Timeout(Duration(seconds: 65)),
  );
}
