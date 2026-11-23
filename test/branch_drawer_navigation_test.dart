import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/router/app_router.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:fyona_flutter/features/subscription/domain/business_offline_access.dart';
import 'package:fyona_flutter/features/subscription/domain/personal_offline_access.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/features/suggestions/di/suggestions_providers.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/providers/platform_controls_provider.dart';
import 'package:fyona_flutter/shared/widgets/app_drawer.dart';

const _owner = UserModel(
  id: 'b722efef-8a1c-4830-885b-3ad90492e837',
  organizationId: '0f683120-9e30-4876-ac15-6dd2decafaa6',
  phoneComplete: true,
  phoneMasked: '***0176',
  role: 'owner',
  status: 'active',
  preferredUsageMode: 'business',
);
const _hadda = '11111111-1111-4111-8111-111111111111';
const _asbahi = '22222222-2222-4222-8222-222222222222';
const _third = '33333333-3333-4333-8333-333333333333';
const _names = {_hadda: 'فرع حده', _asbahi: 'الاصبحي', _third: 'فرع ثالث'};
const _sid = '44444444-4444-4444-8444-444444444444';
final _base = DirectoryPilotBuild.baseUrl;

String _jwt(Map<String, Object?> claims) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode(claims)))}.signature';

String _token(String? id, {String? account}) => _jwt({
  'typ': 'branch_scope',
  'sub': account ?? _owner.id,
  'org': _owner.organizationId,
  'branch': id,
  'mode': id == null ? 'all' : 'branch',
  'exp':
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000,
});

Map<String, dynamic> _status({bool business = true}) => {
  'status': 'active',
  'business_setup_completed': true,
  'sections': {
    'personal': {'active': true, 'end_date': '2099-01-01T00:00:00Z'},
    'business': {'active': business, 'end_date': '2099-01-01T00:00:00Z'},
  },
};

class _SignedIn extends StateNotifier<AuthState> implements AuthNotifier {
  _SignedIn(UserModel user)
    : super(AuthState(status: AuthStatus.authenticated, user: user));

  @override
  Future<void> setUsageMode(String mode) async {
    state = state.copyWith(
      user: state.user!.copyWith(preferredUsageMode: mode),
      preferredUsageMode: mode,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controls extends PlatformControlsNotifier {
  @override
  Future<PlatformControls> build() async => const PlatformControls();
}

class _Personal extends StateNotifier<PersonalFinanceState>
    implements PersonalFinanceNotifier {
  _Personal() : super(PersonalFinanceState());

  @override
  Future<void> load() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Server implements HttpClientAdapter {
  final calls = <String>[];
  final selected = <String?>[];
  bool offline = false;
  bool denySelection = false;
  bool expiredScope = false;
  Completer<void>? holdSelection;
  Completer<void>? selectionStarted;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add('${options.method} ${options.path}');
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'QA offline fixture',
      );
    }
    ResponseBody data(Object payload, {int status = 200}) =>
        ResponseBody.fromString(
          jsonEncode({'data': payload}),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
    switch (options.path) {
      case '/branches/access':
        return data({
          'companies': [
            {
              'organization_id': _owner.organizationId,
              'role': 'owner',
              'branches': [
                for (final e in _names.entries)
                  {'id': e.key, 'name': e.value, 'is_default': e.key == _hadda},
              ],
            },
          ],
        });
      case '/branches/select':
        final id = (options.data as Map)['branch_id'] as String?;
        selected.add(id);
        selectionStarted?.complete();
        await holdSelection?.future;
        if (expiredScope) {
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'lost network during branch refresh',
          );
        }
        if (denySelection) return data({}, status: 403);
        return data({
          'branch_id': id,
          'organization_id': _owner.organizationId,
          'branch': id == null ? null : {'name': _names[id]},
          'token': _token(id),
        });
      case '/sales':
        if (expiredScope) {
          return ResponseBody.fromString(
            '{"detail":{"code":"branch_scope_expired"}}',
            401,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }
        return data({});
      default:
        return data({});
    }
  }

  @override
  void close({bool force = false}) {}
}

({
  ProviderContainer container,
  ConnectivityService connectivity,
  _Server server,
})
_fixture({
  UserModel user = _owner,
  bool online = true,
  bool liveDenied = false,
  Object? subscriptionError,
}) {
  final connectivity = ConnectivityService(debugOnline: online);
  final server = _Server();
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((_) => _SignedIn(user)),
      connectivityServiceProvider.overrideWithValue(connectivity),
      serverBaseUrlProvider.overrideWith((_) => _base),
      businessOfflineAccessProvider.overrideWithValue(
        BusinessOfflineAccess(_base),
      ),
      personalOfflineAccessProvider.overrideWithValue(
        PersonalOfflineAccess(_base),
      ),
      subscriptionStatusProvider.overrideWith(
        (_) => subscriptionError != null
            ? Future.error(subscriptionError)
            : liveDenied
            ? Future.value(_status(business: false))
            : Completer<Map<String, dynamic>>().future,
      ),
      platformControlsProvider.overrideWith(_Controls.new),
      personalFinanceProvider.overrideWith((_) => _Personal()),
      myInvitationsProvider.overrideWith((_) async => []),
      suggestionUnreadCountProvider.overrideWith((_) async => 0),
    ],
  );
  container.read(dioProvider).httpClientAdapter = server;
  addTearDown(container.dispose);
  addTearDown(connectivity.dispose);
  return (container: container, connectivity: connectivity, server: server);
}

Future<void> _seed(ProviderContainer container, {bool business = true}) async {
  await BusinessOfflineAccess(
    _base,
  ).remember(_owner.id, _owner.organizationId, _status(business: business));
  await PersonalOfflineAccess(
    _base,
  ).remember(_owner.id, _owner.organizationId, _status(business: business));
  final api = container.read(branchApiProvider);
  await api.access();
  for (final branch in [_asbahi, _hadda]) {
    await api.select(branchId: branch, organizationId: _owner.organizationId);
  }
}

Future<GoRouter> _mountDrawer(
  WidgetTester tester,
  ProviderContainer container, {
  String start = RouteNames.dashboard,
}) async {
  final realRouter = container.read(goRouterProvider);
  addTearDown(realRouter.dispose);
  final router = GoRouter(
    initialLocation: start,
    redirect: (context, state) =>
        realRouter.configuration.topRedirect(context, state),
    routes: [
      for (final path in [RouteNames.dashboard, RouteNames.personalDashboard])
        GoRoute(
          path: path,
          builder: (context, state) => Scaffold(
            appBar: AppBar(),
            drawer: AppDrawer(
              currentRoute: state.matchedLocation,
              user: container.read(authProvider).user,
            ),
            body: Text(path),
          ),
        ),
      GoRoute(
        path: '/account-entry',
        builder: (_, _) => const Scaffold(body: Text('Account entry')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
}

Finder _branchRow(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is PopupMenuItem<String> &&
      widget.value == '${_owner.organizationId}|$id',
);

Future<void> _openBranches(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppLocalizations.preload('ar'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'auth_token': _jwt({'type': 'access', 'sub': _owner.id, 'sid': _sid}),
    });
    await BranchScope.clear();
  });
  tearDown(BranchScope.clear);

  testWidgets(
    'actual drawer changes branch in airplane mode and returns to it',
    (tester) async {
      final fx = _fixture();
      await tester.runAsync(() => _seed(fx.container));
      final previousToken = BranchScope.token;
      fx.server.calls.clear();
      fx.server.offline = true;
      fx.connectivity.debugSetOnline(false);
      final router = await _mountDrawer(tester, fx.container);
      await _openDrawer(tester);
      await _openBranches(tester);
      await tester.tap(_branchRow(_asbahi));
      await tester.pumpAndSettle();
      expect(BranchScope.branchId, _asbahi);
      expect(BranchScope.token, isNotNull);
      expect(BranchScope.token, isNot(previousToken));
      expect(BranchScope.tokenClaims(BranchScope.token)?['branch'], _asbahi);
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteNames.dashboard,
      );
      expect(find.byType(SnackBar), findsNothing);

      await _openDrawer(tester);
      expect(find.text('الاصبحي'), findsOneWidget);
      await _openBranches(tester);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: _branchRow(_asbahi),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      // Close only the popup, then take the real drawer action.
      Navigator.of(tester.element(_branchRow(_asbahi))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('الانتقال إلى حسابي الشخصي'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteNames.personalDashboard,
      );
      await _openDrawer(tester);
      final business = find.text('الانتقال إلى قسم الأعمال');
      expect(business, findsOneWidget);
      await tester.tap(business);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteNames.dashboard,
      );
      await BranchScope.load();
      expect(BranchScope.branchId, _asbahi);
      expect(BranchScope.branchName, 'الاصبحي');
      await _openDrawer(tester);
      await _openBranches(tester);
      await tester.tap(_branchRow(_hadda));
      await tester.pumpAndSettle();
      expect(BranchScope.branchId, _hadda);
      expect(BranchScope.token, previousToken);
      expect(
        fx.server.calls.where((call) => call.contains('/branches/')),
        isEmpty,
      );
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('a live Business denial keeps the return button hidden', (
    tester,
  ) async {
    final fx = _fixture(liveDenied: true);
    await tester.runAsync(() => _seed(fx.container));
    fx.connectivity.debugSetOnline(false);
    fx.container.read(authProvider.notifier).setUsageMode('personal');
    await _mountDrawer(
      tester,
      fx.container,
      start: RouteNames.personalDashboard,
    );
    await _openDrawer(tester);
    expect(find.text('الانتقال إلى قسم الأعمال'), findsNothing);
  });

  testWidgets(
    'a failed subscription refresh leaves the offline return action',
    (tester) async {
      final fx = _fixture(
        subscriptionError: OfflineException(message: 'offline'),
      );
      await tester.runAsync(() => _seed(fx.container));
      fx.server.offline = true;
      fx.connectivity.debugSetOnline(false);
      await fx.container.read(authProvider.notifier).setUsageMode('personal');
      final router = await _mountDrawer(
        tester,
        fx.container,
        start: RouteNames.personalDashboard,
      );
      await _openDrawer(tester);
      await tester.tap(find.text('الانتقال إلى قسم الأعمال'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteNames.dashboard,
      );
      expect(BranchScope.branchId, _hadda);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  test('an unverified branch cannot send data to the legacy default', () async {
    final fx = _fixture();
    await _seed(fx.container);
    final api = fx.container.read(branchApiProvider);
    fx.server.calls.clear();
    await api.selectFromDrawer(
      organizationId: _owner.organizationId!,
      branchId: _third,
      all: false,
      connected: false,
    );
    expect(BranchScope.branchId, _third);
    expect(BranchScope.token, isNull);
    expect(fx.server.calls, isEmpty);
    final dio = fx.container.read(dioProvider);
    await expectLater(dio.get('/sales'), throwsA(isA<DioException>()));
    await expectLater(
      dio.post('/banking/accounts'),
      throwsA(isA<DioException>()),
    );
    expect(fx.server.calls, isEmpty);
    await dio.get('/personal/transactions');
    expect(fx.server.calls, ['GET /personal/transactions']);
    expect(await api.resumeDrawerSelection(stillSelected: () => true), isTrue);
    expect(BranchScope.branchId, _third);
    expect(BranchScope.tokenClaims(BranchScope.token)?['branch'], _third);
    expect(fx.server.selected.last, _third);
  });

  test(
    'a delayed reconnect cannot override a newer branch selection',
    () async {
      final fx = _fixture();
      await _seed(fx.container);
      final api = fx.container.read(branchApiProvider);
      await api.selectFromDrawer(
        organizationId: _owner.organizationId!,
        branchId: _third,
        all: false,
        connected: false,
      );
      fx.server.holdSelection = Completer<void>();
      fx.server.selectionStarted = Completer<void>();
      final resumed = api.resumeDrawerSelection(stillSelected: () => true);
      await fx.server.selectionStarted!.future;
      await api.selectFromDrawer(
        organizationId: _owner.organizationId!,
        branchId: _asbahi,
        all: false,
        connected: false,
      );
      fx.server.holdSelection!.complete();
      expect(await resumed, isFalse);
      await BranchScope.load();
      expect(BranchScope.branchId, _asbahi);
      expect(BranchScope.tokenClaims(BranchScope.token)?['branch'], _asbahi);
    },
  );

  test(
    'a lost reply refreshing the scope does not clear the saved branch',
    () async {
      final fx = _fixture();
      await _seed(fx.container);
      final token = BranchScope.token;
      fx.server.calls.clear();
      fx.server.expiredScope = true;
      await expectLater(
        fx.container.read(dioProvider).get('/sales'),
        throwsA(isA<DioException>()),
      );
      expect(fx.server.calls, ['GET /sales', 'POST /branches/select']);
      await BranchScope.load();
      expect(BranchScope.branchId, _hadda);
      expect(BranchScope.token, token);
      expect(
        await const FlutterSecureStorage().read(key: 'auth_token'),
        isNotNull,
      );
    },
  );

  test('unreachable Wi-Fi falls back but a live refusal does not', () async {
    final fx = _fixture();
    await _seed(fx.container);
    final api = fx.container.read(branchApiProvider);
    fx.server.holdSelection = Completer<void>();
    await api.selectFromDrawer(
      organizationId: _owner.organizationId!,
      branchId: _asbahi,
      all: false,
      connected: true,
    );
    expect(BranchScope.branchId, _asbahi);
    fx.server.holdSelection!.complete();
    fx.server.holdSelection = null;
    fx.server.denySelection = true;
    await expectLater(
      api.selectFromDrawer(
        organizationId: _owner.organizationId!,
        branchId: _hadda,
        all: false,
        connected: true,
      ),
      throwsA(isA<DioException>()),
    );
    expect(BranchScope.branchId, _asbahi);
    final companies = (await api.cachedAccess())!;
    expect(
      BranchApi.selectableBranches(companies.single).map((row) => row['id']),
      [_asbahi, _third],
    );
  });

  test(
    'a different account/server cannot use a saved selection or menu',
    () async {
      final fx = _fixture();
      await _seed(fx.container);
      for (final api in [
        BranchApi(
          ApiClient(dio: fx.container.read(dioProvider)),
          account: 'another-account',
          homeOrganization: _owner.organizationId,
        ),
        BranchApi(
          ApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://other.invalid/api/v1')),
          ),
          account: _owner.id,
          homeOrganization: _owner.organizationId,
        ),
      ]) {
        expect(api.ownsSavedSelection, isFalse);
        expect(await api.cachedAccess(), isNull);
        await expectLater(
          api.selectFromDrawer(
            organizationId: _owner.organizationId!,
            branchId: _asbahi,
            all: false,
            connected: false,
          ),
          throwsStateError,
        );
      }
      expect(
        await BusinessOfflineAccess(
          _base,
        ).read(_owner.copyWith(id: 'another-account')),
        isNull,
      );
      expect(BranchScope.branchId, _hadda);
    },
  );

  test(
    'upgrading keeps the old signed selection but not an unscoped menu',
    () async {
      SharedPreferences.setMockInitialValues({
        'branch_scope_token': _token(_asbahi),
        'branch_scope_id': _asbahi,
        'branch_scope_org': _owner.organizationId!,
        'branch_scope_name': 'الاصبحي',
        'branch_access_cache_v1': '[{"organization_id":"another-store"}]',
      });
      await BranchScope.load();
      final fx = _fixture(online: false);
      final api = fx.container.read(branchApiProvider);
      expect(api.ownsSavedSelection, isTrue);
      expect(BranchScope.branchId, _asbahi);
      expect(BranchScope.branchName, 'الاصبحي');
      expect(await api.cachedAccess(), isNull);
      final otherAccount = BranchApi(
        ApiClient(dio: fx.container.read(dioProvider)),
        account: 'another-account',
        homeOrganization: _owner.organizationId,
      );
      expect(otherAccount.ownsSavedSelection, isFalse);
    },
  );
}
