import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_presence_host.dart';

class _Auth extends StateNotifier<AuthState> implements AuthNotifier {
  _Auth() : super(const AuthState(status: AuthStatus.authenticated));
  void logoutForTest() =>
      state = const AuthState(status: AuthStatus.unauthenticated);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PresenceApi extends EmployeeApi {
  _PresenceApi() : super(ApiClient(dio: Dio()));
  final events = <bool>[];
  Completer<void>? inFlight;
  @override
  Future<void> heartbeat({bool online = true, String? scopeToken}) async {
    events.add(online);
    if (online) await inFlight?.future;
  }
}

void main() {
  setUp(() {
    BranchScope.organizationId = 'merchant';
  });
  tearDown(() {
    BranchScope.organizationId = null;
  });

  Future<ProviderContainer> mount(
    WidgetTester tester,
    _PresenceApi api,
    _Auth auth, {
    AppSection section = AppSection.business,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => auth),
          employeeApiProvider.overrideWithValue(api),
          activeSectionProvider.overrideWith((ref) => section),
          branchAccessProvider.overrideWith(
            (ref) async => [
              {'organization_id': 'merchant', 'role': 'member'},
              {'organization_id': 'own', 'role': 'owner'},
            ],
          ),
        ],
        child: const EmployeePresenceHost(child: SizedBox()),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(EmployeePresenceHost)),
    );
  }

  testWidgets(
    'heartbeat is exclusive to foreground merchant business workspace',
    (tester) async {
      final api = _PresenceApi();
      final auth = _Auth();
      final container = await mount(
        tester,
        api,
        auth,
        section: AppSection.personal,
      );
      expect(api.events, isEmpty);
      container.read(activeSectionProvider.notifier).state =
          AppSection.business;
      await tester.pump();
      expect(api.events, [true]);
      await tester.pump(const Duration(seconds: 25));
      expect(api.events, [true, true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(api.events.last, isFalse);
      final count = api.events.length;
      await tester.pump(const Duration(seconds: 60));
      expect(api.events.length, count);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.events.last, isTrue);
      container.read(activeSectionProvider.notifier).state =
          AppSection.personal;
      await tester.pump();
      expect(api.events.last, isFalse);
      BranchScope.organizationId = 'own';
      container.read(branchEpochProvider.notifier).state++;
      container.read(activeSectionProvider.notifier).state =
          AppSection.business;
      await tester.pump();
      expect(api.events.last, isFalse);
      BranchScope.organizationId = null;
      container.read(branchEpochProvider.notifier).state++;
      await tester.pump(const Duration(seconds: 60));
      expect(api.events.last, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'logout and unlink stop heartbeats without waiting for stale timeout',
    (tester) async {
      final api = _PresenceApi();
      final auth = _Auth();
      final container = await mount(tester, api, auth);
      expect(api.events, [true]);
      container.invalidate(branchAccessProvider);
      BranchScope.organizationId = 'revoked';
      container.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      expect(api.events.last, isFalse);
      BranchScope.organizationId = 'merchant';
      container.read(branchEpochProvider.notifier).state++;
      await tester.pump();
      expect(api.events.last, isTrue);
      auth.logoutForTest();
      await tester.pump();
      expect(api.events.last, isFalse);
      final count = api.events.length;
      await tester.pump(const Duration(seconds: 60));
      expect(api.events.length, count);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('offline follows an in-flight online request on detach', (
    tester,
  ) async {
    final api = _PresenceApi()..inFlight = Completer<void>();
    await mount(tester, api, _Auth());
    expect(api.events, [true]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(api.events, [true]);
    api.inFlight!.complete();
    await tester.pump();
    expect(api.events, [true, false]);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
