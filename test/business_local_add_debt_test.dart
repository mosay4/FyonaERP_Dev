import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_debt_pages.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  for (final kind in [DirectoryPartyKind.customer, DirectoryPartyKind.supplier]) {
    for (final inSection in [false, true]) {
      testWidgets(
        'device ledger: adding a ${inSection ? 'section' : 'single'} debt for a '
        '${kind.name} opens the credit invoice (no «حدث خطأ»)',
        (tester) async {
          final online = ConnectivityService(debugOnline: false);
          addTearDown(online.dispose);
          final scope = DirectoryAccess(
            workspace: DirectoryWorkspace(
              server: DirectoryPilotBuild.baseUrl,
              accountId: _id(),
              organizationId: _id(),
            ),
            branchId: _id(),
            readable: DirectoryPartyKind.values.toSet(),
            writable: DirectoryPartyKind.values.toSet(),
            financialCutover: true,
          );
          late Directory root;
          late DirectoryPilotStore store;
          late DirectoryPartyReference party;
          late DirectoryDebtGroupReference group;
          await tester.runAsync(() async {
            root = await Directory.systemTemp.createTemp('fyona-add-debt-');
            store = DirectoryPilotStore(keys: FixtureDirectoryKeys(), root: () async => root);
            SharedPreferences.setMockInitialValues({
              'enabled_currencies_fixture': ['USD'],
            });
            await BranchScope.clear();
            await AppLocalizations.preload('ar');
            await store.remember(scope, {
              'status': 'active',
              'business_setup_completed': true,
              'sections': {
                'business': {
                  'active': true,
                  'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
                },
              },
            });
            final row = await store.add(scope, kind, name: 'طرف تجريبي');
            party = DirectoryPartyReference(scope: scope, kind: kind, id: row.id);
            await store.createGroup(scope, party, 'قسم');
            final id = (await store.groups(scope, party)).single['id'] as String;
            group = DirectoryDebtGroupReference(party: party, id: id);
          });
          addTearDown(() async {
            await store.close();
            await root.delete(recursive: true);
          });
          Uri? opened;
          final router = GoRouter(
            initialLocation: '/start',
            routes: [
              GoRoute(path: '/start', builder: (_, _) => const SizedBox()),
              GoRoute(
                path: '/debts/party-individual',
                builder: (_, state) => PartyDebtsPage(
                  partyKind: kind.name,
                  partyId: '',
                  name: '',
                  localParty: state.extra as DirectoryPartyReference,
                ),
              ),
              GoRoute(
                path: '/debts/party-section',
                builder: (_, state) => PartySectionPage(
                  partyKind: kind.name,
                  partyId: '',
                  name: '',
                  groupId: '',
                  groupName: '',
                  localGroup: state.extra as DirectoryDebtGroupReference,
                ),
              ),
              for (final path in ['/sales/add', '/purchases/add'])
                GoRoute(
                  path: path,
                  builder: (_, state) {
                    opened = state.uri;
                    return const Scaffold(body: Text('invoice'));
                  },
                ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(ProviderScope(
            overrides: [
              directoryPilotAccessProvider.overrideWithValue(scope),
              businessLocalLedgerScopeProvider.overrideWithValue(scope),
              directoryPilotStoreProvider.overrideWithValue(store),
              connectivityServiceProvider.overrideWithValue(online),
              currentUserIdProvider.overrideWithValue('fixture'),
              employeeCanProvider.overrideWith((ref, key) => true),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
            ),
          ));
          if (inSection) {
            router.push('/debts/party-section', extra: group);
          } else {
            router.push('/debts/party-individual', extra: party);
          }
          final add = find.text('إضافة دين جديد');
          for (var i = 0; i < 80 && add.evaluate().isEmpty; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
            await tester.pump(const Duration(milliseconds: 25));
          }
          expect(add, findsOneWidget);
          await tester.tap(add);
          for (var i = 0; i < 20 && opened == null; i++) {
            await tester.pump(const Duration(milliseconds: 25));
          }
          expect(find.text('حدث خطأ'), findsNothing);
          final supplier = kind == DirectoryPartyKind.supplier;
          expect(opened?.path, supplier ? '/purchases/add' : '/sales/add');
          expect(opened?.queryParameters, {
            supplier ? 'supplier' : 'customer': party.id,
            if (inSection) 'group': group.id,
            'debt': '1',
          });
        },
        skip: !DirectoryPilotBuild.signupEnabled,
      );
    }
  }
}
