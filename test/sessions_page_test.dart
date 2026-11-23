import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/audit_service.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/auth/data/datasources/auth_local_data_source.dart';
import 'package:fyona_flutter/features/auth/data/models/session_model.dart';
import 'package:fyona_flutter/features/auth/domain/repositories/auth_repository.dart';
import 'package:fyona_flutter/features/auth/domain/services/auth_service.dart'
    show AuthService;
import 'package:fyona_flutter/features/auth/domain/services/firebase_auth_service.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/sessions_page.dart'
    show
        SessionsPage,
        orderedSessions,
        sessionCardBorder,
        relativeTimeParts;
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

import 'test_utils.dart';

/// Sessions page: ordering, current-only red frame, relative-time ladder,
/// and no overflow on a 320px phone — offline-safe (fake notifier, canned
/// sessions, mocked prefs; no network, no DB).

class _FakeRepo implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAudit implements AuditService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal extends AuthLocalDataSource {
  _FakeLocal() : super(storage: SecureStorageService());

  @override
  Future<String?> getAccessToken() async => 'tok';

  @override
  Future<String?> getUsageMode() async => null;

  @override
  Future<UserModel?> getUser() async => const UserModel(id: 'u1');

  @override
  Future<void> saveUser(UserModel user) async {}
}

class _FakeDomainService extends AuthService {
  _FakeDomainService({required super.repository, required super.auditService});

  @override
  Future<bool> hasSession() async => true;

  @override
  bool isTokenExpired(String token) => false;

  @override
  Future<UserModel?> getProfile() async => const UserModel(id: 'u1');
}

class _FakeAuthNotifier extends AuthNotifier {
  final List<SessionModel> sessions;

  _FakeAuthNotifier(
    AuthService service,
    AuthLocalDataSource local,
    FirebaseAuthService firebase,
    Ref ref,
    this.sessions,
  ) : super(service, local, firebase, ref);

  @override
  Future<List<SessionModel>> getActiveSessions(String userId) async =>
      sessions;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {});
    await ensureTestLocalization();
  });

  tearDown(() async {
    SharedPreferences.setMockInitialValues({});
  });

  SessionModel session({
    required String id,
    bool primary = false,
    bool current = false,
    DateTime? createdAt,
    DateTime? lastActivity,
    String? ip,
  }) {
    final now = DateTime.now();
    return SessionModel(
      id: id,
      userId: 'u1',
      ipAddress: ip,
      deviceInfo: 'Samsung SM-S918B',
      deviceModel: 'SM-S918B',
      osVersion: 'Android 14',
      isCurrent: current,
      isPrimary: primary,
      lastActivity: lastActivity ?? now,
      createdAt: createdAt ?? now,
    );
  }

  group('pure session rules', () {
    test('ordering is current, then primary, then newest', () {
      final now = DateTime.now();
      final secondaryOld = session(
          id: 's-old', createdAt: now.subtract(const Duration(days: 3)));
      final primary = session(
          id: 's-primary', primary: true, createdAt: now.subtract(const Duration(days: 5)));
      final current = session(
          id: 's-current', current: true, createdAt: now.subtract(const Duration(days: 1)));
      final ordered = orderedSessions(
          [secondaryOld, primary, current], (s) => s.isCurrent);
      expect(ordered.map((s) => s.id).toList(),
          ['s-current', 's-primary', 's-old']);
    });

    test('red frame only on current', () {
      final mine = sessionCardBorder(isMine: true);
      expect(mine.color, AppColors.danger);
      expect(mine.width, 1.5);
      final other = sessionCardBorder(isMine: false);
      expect(other.color, AppColors.border);
      expect(other.color, isNot(AppColors.danger));
      expect(other.width, 1);
    });

    test('relative time ladder', () {
      final now = DateTime(2026, 9, 19, 12, 0, 0);
      String key(Duration d) =>
          relativeTimeParts(now.subtract(d), now).key;
      expect(key(const Duration(seconds: 30)), 'justNow');
      expect(key(const Duration(minutes: 1)), 'sessionsMinutesAgo');
      expect(key(const Duration(minutes: 10)), 'sessionsMinutesAgo');
      expect(key(const Duration(minutes: 59)), 'sessionsMinutesAgo');
      expect(key(const Duration(hours: 1)), 'sessionsHoursAgo');
      expect(key(const Duration(hours: 8)), 'sessionsHoursAgo');
      expect(key(const Duration(hours: 23)), 'sessionsHoursAgo');
      expect(key(const Duration(days: 1)), 'sessionsDayAgo');
      expect(key(const Duration(days: 2)), 'sessionsTwoDaysAgo');
      expect(key(const Duration(days: 5)), 'sessionsDaysAgo');
      expect(
          relativeTimeParts(now.subtract(const Duration(days: 5)), now)
              .params['days'],
          5);
    });
  });

  group('sessions page at 320px', () {
    testWidgets('no overflow, one red frame on current, times render',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final now = DateTime.now();
      final canned = [
        session(
            id: 's-current',
            current: true,
            ip: '192.168.8.145',
            lastActivity: now.subtract(const Duration(minutes: 10))),
        session(
            id: 's-primary',
            primary: true,
            ip: '192.168.8.138',
            lastActivity: now.subtract(const Duration(days: 2)),
            createdAt: now.subtract(const Duration(days: 9))),
        session(
            id: 's-old',
            lastActivity: now.subtract(const Duration(days: 5)),
            createdAt: now.subtract(const Duration(days: 6))),
      ];
      final router = GoRouter(
        initialLocation: '/sessions',
        routes: [
          GoRoute(
            path: '/sessions',
            builder: (_, __) => const SessionsPage(),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) {
              final n = _FakeAuthNotifier(
                _FakeDomainService(
                  repository: _FakeRepo(),
                  auditService: _FakeAudit(),
                ),
                _FakeLocal(),
                FirebaseAuthService(),
                ref,
                canned,
              );
              n.state = const AuthState(
                status: AuthStatus.authenticated,
                user: UserModel(id: 'u1'),
              );
              return n;
            }),
          ],
          child: MaterialApp.router(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: router,
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // No layout overflow anywhere on the small screen.
      expect(tester.takeException(), isNull);

      // Exactly one red (current-device) frame; no primary-colored frames.
      var dangerFrames = 0;
      var primaryFrames = 0;
      for (final e in find.byType(Container).evaluate()) {
        final w = e.widget;
        if (w is Container && w.decoration is BoxDecoration) {
          final border =
              (w.decoration as BoxDecoration).border;
          if (border is Border) {
            if (border.top.color == AppColors.danger) dangerFrames++;
            if (border.top.color == AppColors.primary) primaryFrames++;
          }
        }
      }
      expect(dangerFrames, 1,
          reason: 'exactly the current device carries the red frame');
      expect(primaryFrames, 0,
          reason: 'primary must not frame itself in red');

      // Rendered relative times (Arabic).
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .join(' | ');
      expect(texts.contains('10'), isTrue,
          reason: '10-minute activity must render. got: $texts');
      expect(texts.contains('5'), isTrue,
          reason: '5-day activity must render. got: $texts');
    });
  });
}
