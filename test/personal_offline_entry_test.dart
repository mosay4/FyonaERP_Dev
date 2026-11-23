import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart' as api;
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/subscription/domain/personal_offline_access.dart';
import 'package:fyona_flutter/features/subscription/domain/section_access.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/account_entry_page.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/widgets/subscription_gate.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedIn extends StateNotifier<AuthState> implements AuthNotifier {
  _SignedIn(UserModel user)
    : super(AuthState(status: AuthStatus.authenticated, user: user));

  @override
  Future<void> setUsageMode(String mode) async {
    state = state.copyWith(preferredUsageMode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const access = PersonalOfflineAccess('https://test.example/api/v1');
  const end = '2030-01-01T00:00:00Z';
  const profile = UserModel(
    id: 'user-a',
    organizationId: 'org-a',
    status: 'active',
    subscriptionPlan: 'premium',
    subscriptionEndDate: end,
  );
  final server = <String, dynamic>{
    'status': 'active',
    'sections': {
      'personal': {'active': true, 'end_date': end},
      'business': {'active': true, 'end_date': end},
    },
  };
  final now = DateTime.utc(2029);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('upgrade uses a dated Personal grant, never a Business grant', () async {
    final status = await access.read(profile, now: now);
    expect(hasSectionAccess(status, 'personal', now: now), isTrue);
    expect(hasSectionAccess(status, 'business', now: now), isFalse);
    expect(await access.read(profile, now: DateTime.utc(2030)), isNull);
    expect(
      await access.read(
        profile.copyWith(subscriptionPlan: 'business'),
        now: now,
      ),
      isNull,
    );
  });

  test(
    'stored entitlement is scoped and live revocation beats the profile',
    () async {
      final modernProfile = profile.copyWith(subscriptionPlan: 'business');
      await access.remember(profile.id, profile.organizationId, server);
      expect(await access.read(modernProfile, now: now), isNotNull);
      expect(
        await access.read(modernProfile.copyWith(id: 'user-b'), now: now),
        isNull,
      );
      expect(
        await const PersonalOfflineAccess(
          'https://other.example',
        ).read(modernProfile, now: now),
        isNull,
      );
      final denied = <String, dynamic>{
        'status': 'cancelled',
        'sections': {
          'personal': {'active': false, 'end_date': end},
        },
      };
      final result = await resolvePersonalEntry(
        connected: true,
        live: () async => denied,
        local: () => access.read(profile, now: now),
      );
      expect(identical(result, denied), isTrue);
      await access.remember(profile.id, profile.organizationId, denied);
      expect(await access.read(profile, now: now), isNull);
    },
  );

  test('unreachable API falls back; explicit HTTP denial does not', () async {
    final status = await resolvePersonalEntry(
      connected: true,
      live: () async => throw api.OfflineException(message: 'offline'),
      local: () => access.read(profile, now: now),
    );
    expect(hasSectionAccess(status, 'personal', now: now), isTrue);
    await expectLater(
      resolvePersonalEntry(
        connected: true,
        live: () async => throw api.UnauthorizedException(message: 'denied'),
        local: () => access.read(profile, now: now),
      ),
      throwsA(isA<api.UnauthorizedException>()),
    );
  });

  testWidgets('cold account entry opens Personal in airplane mode', (
    tester,
  ) async {
    final connectivity = ConnectivityService(debugOnline: false);
    addTearDown(connectivity.dispose);
    await tester.runAsync(() => SectionHistory.save(profile.id, 'business'));
    final router = GoRouter(
      initialLocation: '/account-entry',
      routes: [
        GoRoute(
          path: '/account-entry',
          builder: (_, _) => const AccountEntryPage(),
        ),
        GoRoute(
          path: RouteNames.personalDashboard,
          builder: (_, _) => const Text('Personal arrived'),
        ),
      ],
    );
    addTearDown(router.dispose);
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => _SignedIn(profile)),
          connectivityServiceProvider.overrideWithValue(connectivity),
          personalOfflineAccessProvider.overrideWithValue(access),
          subscriptionStatusProvider.overrideWith((_) async {
            requests++;
            throw api.OfflineException(message: 'offline');
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Personal arrived'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('connected Wi-Fi without internet cannot stall offline entry', (
    tester,
  ) async {
    final request = Completer<Map<String, dynamic>>();
    final result = resolvePersonalEntry(
      connected: true,
      live: () => request.future,
      local: () => access.read(profile, now: now),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(hasSectionAccess(await result, 'personal', now: now), isTrue);
  });

  testWidgets('a failed refresh does not cover an admitted Personal screen', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: RouteNames.personalDashboard,
      routes: [
        GoRoute(
          path: RouteNames.personalDashboard,
          builder: (_, _) => const SubscriptionGate(
            child: Text('Local Personal data'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            (_) => _SignedIn(profile.copyWith(status: 'pending')),
          ),
          subscriptionStatusProvider.overrideWith((_) async {
            throw api.OfflineException(message: 'offline');
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Local Personal data'), findsOneWidget);
  });
}
