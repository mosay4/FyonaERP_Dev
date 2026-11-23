import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/features/splash/presentation/splash_screen.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/auth/domain/repositories/auth_repository.dart';
import 'package:fyona_flutter/features/auth/domain/services/auth_service.dart';
import 'package:fyona_flutter/features/auth/domain/services/firebase_auth_service.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/auth/data/models/auth_response.dart';
import 'package:fyona_flutter/features/auth/data/models/otp_response.dart';
import 'package:fyona_flutter/features/auth/data/models/session_model.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/core/services/audit_service.dart';

class _FakeFirebaseAuthService implements FirebaseAuthService {
  @override
  Future<FirebaseUserResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) =>
      throw UnimplementedError();

  @override
  Future<FirebaseUserResult> registerWithEmailPassword({
    required String fullName,
    required String email,
    required String password,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> resendVerificationEmail() => throw UnimplementedError();

  @override
  Future<FirebaseUserResult> signInWithGoogle() => throw UnimplementedError();

  @override
  Future<void> sendPasswordResetEmail(String email) =>
      throw UnimplementedError();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}

/// Reports that no session is saved, so `AuthNotifier._checkSession` resolves
/// to `unauthenticated` on the first microtask instead of hanging forever on
/// the real secure-storage plugin (unavailable in the widget-test environment).
class _FakeAuthRepository implements AuthRepository {
  @override
  Future<bool> hasSession() async => false;

  @override
  Future<void> clearSession() async {}

  @override
  Future<AuthResponse> loginWithFirebase(String idToken, {String? googleIdToken}) =>
      throw UnimplementedError();

  @override
  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) =>
      throw UnimplementedError();

  @override
  Future<OtpSentResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    String? organizationName,
    String? preferredUsageMode,
  }) =>
      throw UnimplementedError();

  @override
  Future<AuthResponse> verifyRegistration({
    required String email,
    required String otp,
  }) =>
      throw UnimplementedError();

  @override
  Future<OtpSentResponse> resendRegistrationOtp(String email) =>
      throw UnimplementedError();

  @override
  Future<OtpSentResponse> forgotPassword(String email, {String purpose = 'reset'}) =>
      throw UnimplementedError();

  @override
  Future<ResetTokenResponse> verifyOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  }) =>
      throw UnimplementedError();

  @override
  Future<AuthResponse> resetPassword({
    required String resetToken,
    required String newPassword,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      throw UnimplementedError();

  @override
  Future<OtpSentResponse> requestEmailChange() => throw UnimplementedError();

  @override
  Future<AuthResponse> verifyEmailChange({
    required String code,
    required String newEmail,
  }) =>
      throw UnimplementedError();

  @override
  Future<AuthResponse> refreshToken(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<void> logout() => throw UnimplementedError();

  @override
  Future<void> logoutSession(String sessionId, String userId) =>
      throw UnimplementedError();

  @override
  Future<void> forceLogoutAll({String? userId, String? excludeSessionId}) =>
      throw UnimplementedError();

  @override
  Future<void> updateSessionName(String sessionId, String customName) async {}

  @override
  Future<UserModel> getProfile() => throw UnimplementedError();

  @override
  Future<UserModel> updateProfile(
      {String? fullName, String? email, String? phone}) =>
      throw UnimplementedError();

  @override
  Future<UserModel> updatePhone({required String phone, String? country}) =>
      throw UnimplementedError();

  @override
  Future<List<SessionModel>> getActiveSessions(String userId) =>
      throw UnimplementedError();
}

class _FakeAuditService implements AuditService {
  @override
  Future<void> logEvent(AuditEvent event) async {}

  @override
  Future<List<AuditEvent>> getLogs({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
    DateTime? fromDate,
    DateTime? toDate,
    int skip = 0,
    int limit = 100,
  }) async =>
      [];

  @override
  Future<int> getLogsCount({
    String? orgId,
    String? userId,
    String? action,
    String? resource,
  }) async =>
      0;
}

Widget createTestApp() {
  final router = GoRouter(
    initialLocation: RouteNames.splash,
    routes: [
      GoRoute(
        path: RouteNames.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: RouteNames.login,
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('Login')),
        ),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      firebaseAuthServiceProvider.overrideWithValue(_FakeFirebaseAuthService()),
      authServiceProvider.overrideWithValue(
        AuthService(
          repository: _FakeAuthRepository(),
          auditService: _FakeAuditService(),
        ),
      ),
    ],
    child: MaterialApp.router(
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('renders a pure black splash (no logo text, no spinner)', (tester) async {
    await tester.pumpWidget(createTestApp());
    await tester.pump();

    // Production-ready splash: pure black background, NO logo text, NO
    // loading indicator. The intro video is a bundled asset.
    expect(find.text('FYONA'), findsNothing);
    expect(find.text('نظام إدارة الأعمال'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
  });
}