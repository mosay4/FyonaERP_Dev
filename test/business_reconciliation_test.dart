import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart'
    show apiClientProvider, secureStorageProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart'
    show SecureStorageService;
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_relay_identity.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_ledger_session.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_bank_pages.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_detail_page.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

class _CashVault extends Fake implements SecureStorageService {
  _CashVault(this.grant);
  final BusinessLedgerAccess grant;

  @override
  Future<String?> getToken() async {
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'type': 'access',
      'sub': grant.directory.workspace.accountId,
      'sid': grant.cashSessionId,
    })));
    return 'fixture.$payload.signature';
  }
}

DirectoryAccess _scope(DirectoryWorkspace workspace) => DirectoryAccess(
  workspace: workspace,
  branchId: _id(),
  readable: {},
  writable: {},
  financialCutover: true,
);

Future<void> _bank(
  BusinessLedger ledger,
  BusinessLedgerAccess grant,
  String id,
  String currency,
) async {
  await ledger.createAccount(
    grant,
    commandId: id,
    bankName: 'Fixture bank',
    accountName: 'Account $currency',
    accountNumber: '1',
    currency: currency,
    openingMinor: 10000,
  );
}

void main() {
  test(
    'bank comparison and approval are separate, durable, scoped and atomic',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-recon-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://recon.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      final scope = _scope(workspace), sibling = _scope(workspace);
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      final grant = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final other = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final ids = [_id(), _id(), _id()]..sort();
      final [sar, usd, shared] = ids;
      final outsider = _id();
      await _bank(db.ledger, grant, sar, 'SAR');
      await _bank(db.ledger, grant, usd, 'USD');
      await _bank(db.ledger, grant, shared, 'KWD');
      await _bank(db.ledger, other, outsider, 'SAR');
      await db.ledger.cashSync.provision(
        grant,
        shared,
        grantVersion: 1,
        allowNegative: false,
      );
      Future<Map<Object?, Object?>> balances() async => {
        for (final row in await db.ledger.accounts(grant))
          row['id']: row['balance_minor'],
      };
      BusinessBankMeasurement measured(
        String id,
        int actual, [
        int? expected,
      ]) => (accountId: id, actualMinor: actual, expectedMinor: expected);
      Future<Map<String, dynamic>> check(
        String id,
        List<BusinessBankMeasurement> rows,
      ) => db.ledger.checkBankReconciliation(
        grant,
        id: id,
        entries: rows,
        notes: 'Physical check',
        allowed: () => true,
      );
      Future<Map<String, dynamic>> approve(
        String id,
        List<BusinessBankMeasurement> rows, {
        bool Function()? allowed,
      }) => db.ledger.approveBankReconciliation(
        grant,
        id: id,
        entries: rows,
        allowed: allowed ?? () => true,
      );
      final unchanged = {sar: 10000, usd: 10000, shared: 10000};
      final first = _id();
      final actual = [measured(sar, 9382), measured(usd, 12345)];
      final approval = [
        measured(sar, 9382, 10000),
        measured(usd, 12345, 10000),
      ];
      final snapshot = await check(first, actual);
      expect(await balances(), unchanged);
      expect(
        (snapshot['lines'] as List).map((r) => [r['currency'], r['diff']]),
        [
          ['SAR', -6.18],
          ['USD', 23.45],
        ],
      );
      expect(await check(first, actual.reversed.toList()), snapshot);
      await expectLater(
        check(first, [measured(sar, 7000)]),
        throwsA(isA<BusinessLedgerError>()),
      );
      await expectLater(
        check(_id(), [measured(outsider, 7000)]),
        throwsA(isA<BusinessLedgerError>()),
      );
      await expectLater(
        approve(first, [measured(shared, 7000, 10000)]),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );
      await expectLater(
        approve(first, [measured(sar, 9381, 10000)]),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );
      expect(await db.ledger.bankReconciliationArchive(other), isEmpty);

      final sharedCheck = _id();
      await check(sharedCheck, [measured(sar, 9382), measured(shared, 8000)]);
      await expectLater(
        approve(sharedCheck, [
          measured(sar, 9382, 10000),
          measured(shared, 8000, 10000),
        ]),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.sharedCashRequiresArbitration,
          ),
        ),
      );
      expect(await balances(), unchanged);
      expect(await db.ledger.cashSync.pending(grant), isEmpty);

      // A movement and its inverse also invalidate the checked snapshot even
      // though checking the final numeric balance alone would miss the change.
      for (final withdraw in [false, true]) {
        await db.ledger.move(
          grant,
          commandId: _id(),
          accountId: usd,
          amountMinor: 3,
          withdraw: withdraw,
        );
      }
      await expectLater(
        approve(first, approval),
        throwsA(isA<BusinessReconciliationChanged>()),
      );
      expect(await balances(), unchanged);
      expect((await db.ledger.statement(grant, sar)), hasLength(1));

      final second = _id();
      await check(second, actual);
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      Future<void> stopCommit() => raw.execute('''
      CREATE TRIGGER fixture_fail_approval BEFORE UPDATE OF status ON business_reconciliations
      BEGIN SELECT RAISE(ABORT, 'fixture'); END
    ''');
      await stopCommit();
      await raw.close();
      db = await open();
      await expectLater(
        approve(second, approval),
        throwsA(isA<DatabaseException>()),
      );
      expect(await balances(), unchanged);
      expect(
        (await db.ledger.bankReconciliationDetail(grant, second))['status'],
        'checked',
      );
      await db.close();
      final unlock = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      await unlock.execute('DROP TRIGGER fixture_fail_approval');
      await unlock.close();
      db = await open();
      var checks = 0;
      await expectLater(
        approve(second, approval, allowed: () => checks++ == 0),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await balances(), unchanged);
      final saved = await approve(second, approval);
      expect(saved['status'], 'approved');
      expect(await balances(), {sar: 9382, usd: 12345, shared: 10000});
      await db.close();
      db = await open();
      expect(await approve(second, approval.reversed.toList()), saved);
      expect(await db.ledger.bankReconciliationDetail(grant, second), saved);
      final results = await db.ledger.bankReconciliationArchive(
        grant,
        status: 'approved',
        search: 'physical',
      );
      expect(results.single, saved);
      expect(
        await db.ledger.bankReconciliationArchive(grant, dateTo: '2001-01-01'),
        isEmpty,
      );
      expect(
        (await db.ledger.statement(grant, sar)).first['kind'],
        'reconciliation_decrease',
      );
      expect(
        (await db.ledger.statement(grant, usd)).first['kind'],
        'reconciliation_increase',
      );
      final operations = await db.ledger.operations(
        grant,
        allowedKinds: {'reconciliation'},
      );
      expect(operations, hasLength(2));
      expect(
        operations.every((row) => row['reconciliation_id'] == second),
        isTrue,
      );
      expect(operations.map((row) => row['source_id']).toSet(), hasLength(2));
      final manual = await db.ledger.manualMovements(
        grant,
        showIncome: true,
        showExpenses: true,
      );
      expect(
        manual,
        hasLength(2),
      ); // Only the USD 0.03 movement and its inverse.
      expect((await db.ledger.accounts(other)).single['balance_minor'], 10000);
    },
  );

  testWidgets(
    'original bank buttons check offline and cannot approve after scope changes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final workspace = DirectoryWorkspace(
        server: DirectoryPilotBuild.baseUrl,
        accountId: _id(),
        organizationId: _id(),
      );
      final scope = _scope(workspace);
      final grant = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final id = _id();
      late Directory root;
      late DirectoryPilotStore store;
      Future<void> select(String branch) => BranchScope.save(
        token: 'fixture',
        branchId: branch,
        branchName: 'معمل',
        organizationId: workspace.organizationId,
        allMode: false,
      );
      await tester.runAsync(() async {
        await AppLocalizations.preload('ar');
        await select(scope.branchId);
        root = await Directory.systemTemp.createTemp('fyona-bank-recon-ui-');
        store = DirectoryPilotStore(
          root: () async => root,
          keys: FixtureDirectoryKeys(),
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
        await store.withLedger(
          grant,
          () => scope,
          (ledger) => _bank(ledger, grant, id, 'SAR'),
        );
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
        await BranchScope.clear();
      });
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) {
              requests++;
              h.reject(
                DioException.connectionError(
                  requestOptions: r,
                  reason: 'offline',
                ),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      final choice = StateProvider<DirectoryAccess?>((_) => scope);
      final container = ProviderContainer(
        overrides: [
          businessLocalLedgerScopeProvider.overrideWith(
            (ref) => ref.watch(choice),
          ),
          directoryPilotStoreProvider.overrideWithValue(store),
          employeeCanProvider.overrideWith((_, __) => true),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        ],
      );
      addTearDown(container.dispose);
      final source = container.read(reconciliationApiProvider);
      final router = GoRouter(
        initialLocation: RouteNames.reconciliationBankRun,
        routes: [
          GoRoute(
            path: RouteNames.reconciliationBankRun,
            builder: (_, __) => ReconBankRunPage(
              accountIds: '',
              localLink: LocalReconciliationLink(source, id),
            ),
          ),
          GoRoute(
            path: RouteNames.reconciliationBankResult,
            builder: (_, state) {
              final extra = state.extra! as Map;
              expect(state.uri.queryParameters, isEmpty);
              return ReconBankResultPage(
                record: extra['record'] as Map<String, dynamic>,
                localSource: extra['source'] as ReconciliationApi,
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      Widget host(Widget child) =>
          UncontrolledProviderScope(container: container, child: child);
      await tester.pumpWidget(
        host(
          MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
          ),
        ),
      );
      Future<void> see(Finder finder) async {
        for (var i = 0; i < 110 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)),
          );
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
        }
        expect(finder, findsOneWidget);
      }

      final amount = find.byType(TextField);
      await see(amount);
      await tester.enterText(amount, '89.47');
      await tester.tap(find.text(AppLocalizations.t('reconCheckNow')));
      final equalize = find.text(AppLocalizations.t('reconEqualizeSystem'));
      await see(equalize);
      await tester.pumpAndSettle();
      late String reconId;
      await tester.runAsync(() async {
        final list = await source.archive(rtype: 'bank');
        expect(list.single['status'], 'checked');
        reconId = list.single['id'] as String;
        expect((await source.accounts()).single['balance'], 100);
      });
      await tester.tap(equalize);
      final confirm = find.text(AppLocalizations.t('reconConfirmBtn'));
      await see(confirm);
      await tester.pumpAndSettle();
      await tester.runAsync(() => select(_id()));
      container.read(choice.notifier).state = null;
      container.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizations.t('reconDeviceDenied')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        host(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: ReconDetailPage(
              reconId: '',
              localLink: LocalReconciliationLink(source, reconId),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizations.t('reconDeviceDenied')),
        findsOneWidget,
      );
      expect(requests, 0);
      await tester.runAsync(
        () => store.withLedger(grant, () => scope, (ledger) async {
          expect((await ledger.accounts(grant)).single['balance_minor'], 10000);
          expect(
            (await ledger.bankReconciliationDetail(grant, reconId))['status'],
            'checked',
          );
        }),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );

  testWidgets('original result saves an offline adjustment request, not a success', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scope = _scope(DirectoryWorkspace(
      server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id(),
    ));
    final grant = BusinessLedgerAccess(
      scope, BusinessLedgerAction.values.toSet(), cashSessionId: _id(),
    );
    final account = _id(), recon = _id();
    final entries = [(accountId: account, expectedMinor: 10000, actualMinor: 8800)];
    late final DirectoryPilotStore store;
    late final Map<String, dynamic> check;
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
      await BranchScope.save(
        token: 'fixture', branchId: scope.branchId, branchName: 'Fixture',
        allMode: false, organizationId: scope.workspace.organizationId,
      );
      final root = await Directory.systemTemp.createTemp('fyona-shared-recon-ui-');
      addTearDown(() => root.delete(recursive: true));
      store = DirectoryPilotStore(root: () async => root, keys: FixtureDirectoryKeys());
      addTearDown(store.close);
      await store.remember(scope, {
        'status': 'active',
        'business_setup_completed': true,
        'sections': {
          'business': {
            'active': true,
            'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
          },
        },
      });
      await store.withLedger(grant, () => scope, (ledger) async {
        await _bank(ledger, grant, account, 'SAR');
        await ledger.cashSync.provision(grant, account, grantVersion: 1, allowNegative: false);
        await ledger.cashSync.bindReplica(grant, sessionId: grant.cashSessionId!,
          checkpoint: cashTestCheckpoint(scope, account, balance: 10000), settlementProtocol: true);
        check = await ledger.checkBankReconciliation(
          grant, id: recon, entries: entries, allowed: () => true,
        );
      });
    });
    addTearDown(BranchScope.clear);
    var requests = 0;
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
      requests++;
      h.reject(DioException.connectionError(requestOptions: r, reason: 'offline'));
    }));
    addTearDown(() => dio.close(force: true));
    final container = ProviderContainer(overrides: [
      businessLocalLedgerScopeProvider.overrideWithValue(scope),
      directoryPilotStoreProvider.overrideWithValue(store),
      secureStorageProvider.overrideWithValue(_CashVault(grant)),
      apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
      employeeCanProvider.overrideWith((_, _) => true),
    ]);
    addTearDown(container.dispose);
    final source = container.read(reconciliationApiProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ReconBankResultPage(record: check, localSource: source),
      ),
    ));
    await tester.pumpAndSettle();
    final equalize = find.text(AppLocalizations.t('reconEqualizeSystem'));
    await tester.ensureVisible(equalize);
    await tester.tap(equalize);
    await tester.pumpAndSettle();
    final confirm = find.text(AppLocalizations.t('reconConfirmBtn'));
    await tester.tap(confirm);
    Future<void> see(Finder finder) async {
      for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(finder, findsOneWidget);
    }
    final pending = find.text(AppLocalizations.t('reconDeviceCashQueued'));
    final approved = find.text(AppLocalizations.t('reconEqualized'));
    await see(pending);
    expect(equalize, findsOneWidget);
    expect(approved, findsNothing);
    await tester.runAsync(() => store.withLedger(grant, () => scope, (ledger) async {
      expect((await ledger.accounts(grant)).single['balance_minor'], 10000);
      final payload = await ledger.cashSync.pendingEqualization(grant);
      expect(payload, isNotNull);
      expect(await ledger.cashSync.applyEqualization(
        grant, commandId: payload!['command_id'] as String, sequence: 1,
        lines: [(accountId: account, currency: 'SAR', expectedMinor: 10000, actualMinor: 8800)],
        allowed: () => true,
      ), isTrue);
    }));
    container.read(businessBankRevisionProvider.notifier).state++;
    await see(approved);
    expect(pending, findsNothing);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !DirectoryPilotBuild.signupEnabled || !businessCashRelayEnabled);
}
