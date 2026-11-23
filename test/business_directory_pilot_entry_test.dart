import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/app_router.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/local_commerce_navigation.dart';
import 'package:fyona_flutter/features/subscription/domain/personal_offline_access.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/account_entry_page.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/providers/platform_controls_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/directory_test_keys.dart';

class _SignedIn extends StateNotifier<AuthState> implements AuthNotifier {
  _SignedIn(UserModel user)
    : super(AuthState(status: AuthStatus.authenticated, user: user));

  @override
  Future<void> setUsageMode(String mode) async {
    state = state.copyWith(
      user: state.user!.copyWith(preferredUsageMode: mode),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedControls extends PlatformControlsNotifier {
  @override
  Future<PlatformControls> build() async => const PlatformControls();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'the real router opens scoped details without waiting for subscription HTTP',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const user = UserModel(
        id: 'b722efef-8a1c-4830-885b-3ad90492e837',
        organizationId: '0f683120-9e30-4876-ac15-6dd2decafaa6',
        phoneComplete: true,
        phoneMasked: '***0176',
        role: 'owner',
        status: 'active',
        preferredUsageMode: 'business',
      );
      const branch = 'da2e39ff-3990-4c16-863d-293fb902b93d';
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: user.id,
          organizationId: user.organizationId!,
        ),
        branchId: branch,
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
        financialCutover: true,
      );
      final store = DirectoryPilotStore(
        root: () async => Directory.systemTemp,
        keys: FixtureDirectoryKeys(),
      );
      final live = Completer<Map<String, dynamic>>();
      final status = <String, dynamic>{
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
      };
      var requests = 0;
      final selected = StateProvider<DirectoryAccess?>((_) => scope);
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((_) => _SignedIn(user)),
          directoryPilotAccessProvider.overrideWith(
            (ref) => ref.watch(selected),
          ),
          businessLocalLedgerScopeProvider.overrideWith((ref) => ref.watch(selected)),
          directoryPilotStoreProvider.overrideWithValue(store),
          subscriptionStatusProvider.overrideWith((_) {
            requests++;
            return live.future;
          }),
          platformControlsProvider.overrideWith(_FixedControls.new),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(goRouterProvider);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      final configuration = router.configuration;
      Future<String?> navigate(String location, [Object? extra]) async {
        final uri = Uri.parse(location);
        return await configuration.topRedirect(
          context,
          GoRouterState(
            configuration,
            uri: uri,
            matchedLocation: uri.path,
            fullPath: uri.path,
            pathParameters: const {},
            pageKey: ValueKey(uri.path),
            extra: extra,
          ),
        );
      }

      await tester.runAsync(() async {
        await store.remember(scope, status);
        final bank = LocalBankAccountTarget(scope, 'c55a5d0a-c155-421b-859d-1c9abaf97d39');
        expect(await navigate('/banks', null), isNull);
        expect(await navigate(LocalBankAccountTarget.path, bank), isNull);
        expect(await navigate(LocalBankAccountTarget.path), '/banks');
        expect(await navigate('/banks/account/${bank.id}'), '/banks');
        expect(await navigate('${LocalBankAccountTarget.path}?id=${bank.id}', bank), '/banks');
        for (final path in [
          RouteNames.sales, RouteNames.salesAdd, RouteNames.purchasesAdd, RouteNames.returns,
          RouteNames.inventory, RouteNames.inventoryProductEdit,
        ]) {
          expect(await navigate(path).timeout(const Duration(seconds: 2)), isNull);
        }
        final product = LocalCommerceTarget(scope, RouteNames.inventoryProduct, bank.id);
        expect(await navigate(RouteNames.inventoryProduct, product), isNull);
        expect(await navigate('${RouteNames.inventoryProduct}?id=${bank.id}'), RouteNames.inventory);
        expect(await navigate('${RouteNames.inventoryProduct}?id=${bank.id}', product), RouteNames.inventory);
        expect(await navigate(RouteNames.returnsView, product), RouteNames.returns);
        container.read(selected.notifier).state = null;
        expect(await navigate(LocalBankAccountTarget.path, bank), '/banks');
        expect(await navigate(RouteNames.inventoryProduct, product), RouteNames.inventory);
        container.read(selected.notifier).state = scope;
        for (final kind in DirectoryPartyKind.values) {
          final sections = kind == DirectoryPartyKind.supplier
              ? '/suppliers'
              : '/customers';
          final id = 'bde02dff-9c1d-4c56-bf33-cbad9abc5aad';
          final target = DirectoryPartyReference(
            scope: scope,
            kind: kind,
            id: id,
          );
          expect(
            await navigate(
              '$sections/detail',
              target,
            ).timeout(const Duration(seconds: 2)),
            isNull,
          );
          expect(await navigate('/debts/party-individual', target), isNull);
          expect(await navigate('/debts/party-sections', target), isNull);
          expect(
            await navigate(
              '/debts/party-section',
              DirectoryDebtGroupReference(party: target, id: id),
            ),
            isNull,
          );
           expect(await navigate('$sections/detail?id=$id'), sections);
           final invoice = DirectoryDebtInvoiceReference(party: target, id: id);
           expect(await navigate('/debts/operation', invoice), isNull);
           expect(await navigate('/invoices/view', invoice), isNull);
           expect(await navigate('/debts/operation?inv=$id'), '/customers');
           expect(await navigate('/debts/operation?inv=$id', invoice), sections);
           container.read(selected.notifier).state = null;
           expect(await navigate('$sections/detail', target), sections);
           expect(await navigate('/debts/operation', invoice), sections);
          // The ordinary connected route is unchanged for other branches.
          expect(await navigate('$sections/detail?id=$id'), isNull);
          container.read(selected.notifier).state = scope;
        }
      });
      expect(requests, 1);
      expect(live.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final preferred in ['business', 'personal']) {
    testWidgets(
      'cold app entry can choose $preferred without a live API reply',
      (tester) async {
        final base = DirectoryPilotBuild.baseUrl;
        const user = UserModel(
          id: 'b722efef-8a1c-4830-885b-3ad90492e837',
          organizationId: '0f683120-9e30-4876-ac15-6dd2decafaa6',
          status: 'active',
          preferredUsageMode: 'business',
        );
        final keys = FixtureDirectoryKeys();
        final workspace = DirectoryWorkspace(
          server: base,
          accountId: user.id,
          organizationId: user.organizationId!,
        );
        final scope = DirectoryAccess(
          workspace: workspace,
          branchId: 'da2e39ff-3990-4c16-863d-293fb902b93d',
          readable: DirectoryPartyKind.values.toSet(),
          writable: DirectoryPartyKind.values.toSet(),
        );
        final localPersonal = PersonalOfflineAccess(base);
        final end = DateTime.now()
            .toUtc()
            .add(const Duration(days: 3))
            .toIso8601String();
        final expiry = {'active': true, 'end_date': end};
        final status = <String, dynamic>{
          'status': 'active',
          'business_setup_completed': true,
          'sections': {'business': expiry, 'personal': expiry},
        };
        // An independent instance reads previously written auth evidence.
        final reopened = DirectoryPilotStore(
          root: () async => Directory.systemTemp,
          keys: keys,
        );
        await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          await AppLocalizations.preload('ar');
          await DirectoryPilotStore(
            root: () async => Directory.systemTemp,
            keys: keys,
          ).remember(scope, status);
          await localPersonal.remember(user.id, user.organizationId, status);
          await SectionHistory.save(user.id, preferred);
        });
        var requests = 0;
        final offline = ConnectivityService(debugOnline: false);
        final router = GoRouter(
          initialLocation: '/account-entry',
          routes: [
            GoRoute(
              path: '/account-entry',
              builder: (_, _) => const AccountEntryPage(),
            ),
            GoRoute(
              path: RouteNames.dashboard,
              builder: (_, _) => const Text('Entered Business'),
            ),
            GoRoute(
              path: RouteNames.personalDashboard,
              builder: (_, _) => const Text('Entered Personal'),
            ),
          ],
        );
        addTearDown(offline.dispose);
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((_) => _SignedIn(user)),
              directoryPilotAccessProvider.overrideWithValue(scope),
              directoryPilotStoreProvider.overrideWithValue(reopened),
              connectivityServiceProvider.overrideWithValue(offline),
              personalOfflineAccessProvider.overrideWithValue(localPersonal),
              subscriptionStatusProvider.overrideWith((_) async {
                requests++;
                throw StateError('Network disabled in the fixture');
              }),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(
          find.text(
            preferred == 'business' ? 'Entered Business' : 'Entered Personal',
          ),
          findsOneWidget,
        );
        expect(requests, 0);
      },
    );
  }
}
