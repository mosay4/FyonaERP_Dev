import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/config/app_config.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/customers_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_detail_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_debt_pages.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/suppliers_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/directory_test_keys.dart';

const _account = 'b722efef-8a1c-4830-885b-3ad90492e837';
const _org = '0f683120-9e30-4876-ac15-6dd2decafaa6';
const _branch = 'da2e39ff-3990-4c16-863d-293fb902b93d';

String _token({String account = _account}) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'typ': 'branch_scope', 'mode': 'branch', 'sub': account, 'org': _org, 'branch': _branch})))}.fixture';

DirectoryAccess? _resolve({
  String account = _account,
  String org = _org,
  String branch = _branch,
  String? token,
  String? server,
  bool readOnly = false,
}) => resolveDirectoryPilot(
  server: server ?? DirectoryPilotBuild.baseUrl,
  accountId: account,
  organizationId: org,
  selectedOrganizationId: org,
  selectedBranchId: branch,
  selectedToken: token,
  readOnly: readOnly,
);

Map<String, dynamic> _entitlement({bool enabled = true, DateTime? end}) => {
  'status': enabled ? 'active' : 'cancelled',
  'business_setup_completed': true,
  'sections': {
    'business': {
      'active': enabled,
      'end_date': (end ?? DateTime.now().toUtc().add(const Duration(days: 2)))
          .toIso8601String(),
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final usePilot = DirectoryPilotBuild.enabled;
  test('the pilot is opt-in and restricted to exactly the expected scope', () {
    final resolved = _resolve(token: _token());
    expect(resolved != null, usePilot);
    if (!usePilot) return;
    expect(_resolve(token: null), isNull);
    expect(_resolve(token: 'x.invalid.x'), isNull);
    expect(_resolve(token: _token(account: _org)), isNull);
    expect(_resolve(token: _token(), account: _org), isNull);
    expect(_resolve(token: _token(), org: _account), isNull);
    expect(_resolve(token: _token(), branch: _account), isNull);
    expect(_resolve(token: _token(), readOnly: true), isNull);
    expect(
      _resolve(token: _token(), server: 'https://example.test/api/v1'),
      isNull,
    );
    expect(
      DirectoryPilotBuild.allows(
        Uri.parse('${DirectoryPilotBuild.baseUrl}/customers'),
      ),
      isTrue,
    );
    final otherOrigin =
        DirectoryPilotBuild.baseUrl == DirectoryPilotBuild.loopbackBase
        ? DirectoryPilotBuild.stagingBase
        : DirectoryPilotBuild.loopbackBase;
    expect(DirectoryPilotBuild.allows(Uri.parse(otherOrigin)), isFalse);
    expect(
      DirectoryPilotBuild.allows(Uri.parse('http://127.0.0.1:8001/api/v1')),
      isFalse,
    );
    expect(
      DirectoryPilotBuild.allows(
        Uri.parse('http://127.0.0.1.example.test:18083/api/v1'),
      ),
      isFalse,
    );
    expect(
      DirectoryPilotBuild.allows(Uri.parse('https://example.test/api/v1')),
      isFalse,
    );
    AppConfig.overrideBaseUrl = 'https://example.test/api/v1';
    expect(AppConfig.effectiveApiBaseUrl, DirectoryPilotBuild.baseUrl);
    AppConfig.overrideBaseUrl = null;
  });
  if (!usePilot) return;

  test('signup owner only gets the signed concrete directory branch', () {
    if (!DirectoryPilotBuild.signupEnabled) return;
    const newOwner = 'a52c3d89-cda4-4d37-acc0-bf9920389ba9';
    const newOrg = '97a83324-5920-4dee-bcfc-c040bd168eb2';
    const first = '646bb3bb-f50d-4424-b93c-e2149ba9f76f';
    const other = '7d4eece8-6471-4140-b27a-cfe9f3ee6d87';
    String scoped({
      bool permitted = true,
      String branch = first,
      String mode = 'branch',
    }) {
      final data = jsonEncode({
        'typ': 'branch_scope',
        'mode': mode,
        'sub': newOwner,
        'org': newOrg,
        'branch': branch,
        if (permitted) 'qa_directory': true,
      });
      return 'e30.${base64Url.encode(utf8.encode(data))}.fixture';
    }

    DirectoryAccess? access(
      String token, {
      String branch = first,
      bool all = false,
      String account = newOwner,
      String? origin,
    }) => resolveDirectoryPilot(
      server: origin ?? DirectoryPilotBuild.baseUrl,
      accountId: account,
      organizationId: newOrg,
      selectedOrganizationId: newOrg,
      selectedBranchId: branch,
      selectedToken: token,
      readOnly: all,
    );

    expect(access(scoped())?.branchId, first);
    expect(access(scoped(permitted: false)), isNull);
    expect(access(scoped(), account: _account), isNull);
    expect(access(scoped(), branch: other), isNull);
    expect(access(scoped(mode: 'all'), all: true), isNull);
    expect(
      access(scoped(), origin: 'https://production.invalid/api/v1'),
      isNull,
    );
  });

  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  final access = _resolve(token: _token())!;
  const c = DirectoryPartyKind.customer;
  const s = DirectoryPartyKind.supplier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.clear();
    root = await Directory.systemTemp.createTemp('fyona-pilot-test-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('the original directory grant cannot select or write the local ledger', () async {
    final container = ProviderContainer(overrides: [
      directoryPilotAccessProvider.overrideWithValue(access),
    ]);
    addTearDown(container.dispose);
    expect(container.read(businessLocalLedgerScopeProvider), isNull);
    await store.remember(access, _entitlement());
    final grant = BusinessLedgerAccess(access, {BusinessLedgerAction.moveMoney});
    await expectLater(
      store.withLedger(grant, () => access, (_) async => fail('No financial cutover')),
      throwsA(isA<DirectoryAccessDenied>()),
    );
  });

  test('the seed directory does not populate an empty financial recovery destination', () async {
    final cutover = DirectoryAccess(
      workspace: access.workspace,
      branchId: access.branchId,
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true,
    );
    final grant = BusinessLedgerAccess(cutover, {BusinessLedgerAction.manageBackup});
    await store.remember(cutover, _entitlement());
    expect(await store.search(cutover, c, ''), isEmpty);
    expect(await store.search(cutover, s, ''), isEmpty);
    final file = File('${root.path}/empty.fyonabiz');
    await expectLater(
      store.withLedger(grant, () => cutover, (ledger) => ledger.captureBackup(
        grant, id: '17a56f74-b781-49c3-9b9c-2aa76dd73418', destination: file,
        code: BusinessBackupCode.generate(), allowed: () => true,
      )),
      throwsA(isA<BusinessBackupRejected>().having(
        (e) => e.problem, 'problem', BusinessBackupProblem.nothingToBackUp,
      )),
    );
  });

  test(
    'expired, missing, or explicitly revoked Business grant fails closed',
    () async {
      await expectLater(
        store.search(access, c, ''),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await store.remember(access, _entitlement(end: DateTime.utc(1999)));
      expect(await store.entry(access), isNull);
      await store.remember(access, _entitlement());
      expect(await store.search(access, c, ''), hasLength(1));
      expect(await store.search(access, s, ''), hasLength(1));
      await store.remember(access, _entitlement(enabled: false));
      await expectLater(
        store.search(access, c, ''),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        store.add(access, c, name: 'denied row'),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await store.remember(access, _entitlement());
      expect(await store.search(access, c, ''), hasLength(1));
    },
  );

  testWidgets(
    'both directory widgets save and search online, offline, and during a cut',
    (tester) async {
      await tester.runAsync(() async {
        await AppLocalizations.preload('ar');
        await store.remember(access, _entitlement());
      });
      var legacyCalls = 0;
      final connectivity = ConnectivityService(debugOnline: true);
      addTearDown(connectivity.dispose);
      final unexpected = FlutterError('The pilot used the REST directory');
      Widget app(Widget page) {
        final router = GoRouter(initialLocation: '/list', routes: [
          GoRoute(path: '/list', builder: (_, _) => page),
          for (final (path, supplier) in [
            ('/customers/detail', false), ('/suppliers/detail', true),
          ])
            GoRoute(path: path, builder: (_, state) {
              expect(state.uri.queryParameters, isEmpty);
              return PartyDetailPage(id: '', isSupplier: supplier,
                localParty: state.extra as DirectoryPartyReference);
            }),
          GoRoute(path: '/debts/party-sections', builder: (_, state) {
            expect(state.uri.queryParameters, isEmpty);
            final local = state.extra as DirectoryPartyReference;
            return PartySectionsPage(partyKind: local.kind.name, partyId: '',
              name: '', localParty: local);
          }),
          GoRoute(path: '/debts/party-section', builder: (_, state) {
            expect(state.uri.queryParameters, isEmpty);
            final local = state.extra as DirectoryDebtGroupReference;
            return PartySectionPage(
              partyKind: local.party.kind.name, partyId: '', name: '',
              groupId: '', groupName: '', localGroup: local,
            );
          }),
        ]);
        addTearDown(router.dispose);
        return ProviderScope(
        overrides: [
          directoryPilotAccessProvider.overrideWithValue(access),
          directoryPilotStoreProvider.overrideWithValue(store),
          connectivityServiceProvider.overrideWithValue(connectivity),
          purchaseApiProvider.overrideWith((ref) {
            legacyCalls++;
            throw unexpected;
          }),
          merchantApiProvider.overrideWith((ref) {
            legacyCalls++;
            throw unexpected;
          }),
          employeeCanProvider.overrideWith((ref, key) => true),
        ],
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      );
      }

      Future<void> settleUntil(Finder text) async {
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          expect(find.byType(CircularProgressIndicator), findsNothing);
          if (text.evaluate().isNotEmpty) return;
        }
        expect(text, findsWidgets);
      }

      for (final row in [
        (
          const CustomersPage(),
          'عميل تجريبي',
          'Customer Offline QA',
          '0219990001',
          'Customer Online QA',
          '0219980001',
          'Customer Link Cut QA',
        ),
        (
          const SuppliersPage(),
          'مورد تجريبي',
          'Supplier Offline QA',
          '0219990002',
          'Supplier Online QA',
          '0219980002',
          'Supplier Link Cut QA',
        ),
      ]) {
        await tester.pumpWidget(app(row.$1));
        await settleUntil(find.text(row.$2));
        for (final (online, cut, name, phone) in [
          (true, false, row.$5, row.$6),
          (false, false, row.$3, row.$4),
          (true, true, row.$7, '${row.$6}8'),
        ]) {
          connectivity.debugSetOnline(online);
          await tester.tap(find.byIcon(Icons.add));
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog);
          final inputs = find.descendant(
            of: dialog,
            matching: find.byType(EditableText),
          );
          await tester.enterText(inputs.at(0), name);
          await tester.enterText(inputs.at(1), phone);
          final save = tester
              .widget<FilledButton>(
                find.descendant(
                  of: dialog,
                  matching: find.byType(FilledButton),
                ),
              )
              .onPressed!;
          var cutObserved = false;
          if (cut) {
            keys.onRead = (key) {
              if (!key.startsWith('grant-v1-')) return;
              keys.onRead = null;
              cutObserved = connectivity.isOnline;
              // This save has entered the local store but has not yet
              // committed its SQLCipher transaction.
              connectivity.debugSetOnline(false);
            };
          }
          await tester.runAsync(() async {
            save();
            save();
          });
          // Assert against the card only after the dialog route is gone.
          await tester.pumpAndSettle();
          await settleUntil(find.text(name));
          expect(find.text(name), findsOneWidget);
          expect(find.byType(SnackBar), findsNothing);
          expect(cutObserved, cut);
        }
        final field = find.byType(EditableText).first;
        await tester.enterText(field, row.$4.substring(4));
        await settleUntil(find.text(row.$3));
        for (
          var i = 0;
          i < 10 && find.text(row.$2).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump();
        }
        expect(find.text(row.$2), findsNothing);
        expect(find.text(row.$5), findsNothing);
        expect(find.text(row.$7), findsNothing);
        expect(find.text(row.$3), findsOneWidget);
        // The real screen opens using a scoped local target, not a remote ID
        // or the misleading "not found" snack from the rollout.
        await tester.tap(find.text(row.$3));
        await tester.pumpAndSettle();
        await settleUntil(find.text('تاريخ الإضافة'));
        expect(find.byType(PartyDetailPage), findsOneWidget);
        expect(find.text('العميل غير موجود'), findsNothing);
        expect(find.text('المورد غير موجود'), findsNothing);
        final edited = '${row.$3} Updated';
        await tester.tap(find.byTooltip('تعديل البيانات'));
        await tester.pumpAndSettle();
        final nameField = find.descendant(of: find.byType(AlertDialog),
          matching: find.byType(EditableText)).first;
        await tester.enterText(nameField, edited);
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
        });
        await tester.pumpAndSettle();
        await settleUntil(find.text(edited));
        expect(find.byType(SnackBar), findsNothing);

        await tester.tap(find.text('مجموعات الديون'));
        await tester.pumpAndSettle();
        await settleUntil(find.byType(PartySectionsPage));
        final addGroup = find.byIcon(Icons.create_new_folder_outlined);
        await tester.tap(addGroup);
        await tester.pumpAndSettle();
        final dialogField = find.descendant(of: find.byType(AlertDialog),
          matching: find.byType(EditableText));
        await tester.enterText(dialogField, 'قسم تجريبي');
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
        });
        await tester.pumpAndSettle();
        await settleUntil(find.text('قسم تجريبي'));
        await tester.tap(find.text('قسم تجريبي'));
        await tester.pumpAndSettle();
        await settleUntil(find.text('قسم تجريبي'));
        expect(find.byType(PartySectionPage), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
      expect(legacyCalls, 0);
      await tester.runAsync(() async {
        await store.close();
        final restarted = DirectoryPilotStore(
          root: () async => root,
          keys: keys,
        );
        expect(
          (await restarted.search(access, c, 'QA')).map((p) => p.name),
          unorderedEquals([
            'Customer Online QA',
            'Customer Offline QA Updated',
            'Customer Link Cut QA',
          ]),
        );
        expect(
          (await restarted.search(access, s, 'QA')).map((p) => p.name),
          unorderedEquals([
            'Supplier Online QA',
            'Supplier Offline QA Updated',
            'Supplier Link Cut QA',
          ]),
        );
        await restarted.close();
      });
      expect(tester.takeException(), isNull);
    },
  );
}
