import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/security/device_identity.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_api.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_models.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_service.dart';
import 'package:fyona_flutter/features/auth/auth2/social_sign_in.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/forgot_password_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/login_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/otp_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/register_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/reset_password_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/social_phone_page.dart';
import 'package:fyona_flutter/features/auth/presentation/pages/verify_device_page.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/auth/data/models/auth_response.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

/// Recorded call: `name` + JSON-ish args.
class ApiCall {
  final String name;
  final Map<String, Object?> args;
  ApiCall(this.name, this.args);
  @override
  String toString() => '$name$args';
}

Auth2Authenticated fakeAuthenticated({String phone = '+967771234567', bool primary = false}) =>
    Auth2Authenticated(
      AuthResponse.fromJson({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'user': {
          'id': 'u-1',
          'organization_id': 'o-1',
          'full_name': 'Sara Ali',
          'phone': phone,
          'phone_complete': true,
          'role': 'owner',
        },
      }),
      isPrimary: primary,
    );

OtpChallenge fakeChallenge({
  String id = 'ch-1',
  String channel = 'whatsapp',
  String status = 'queued',
  int resendAfter = 30,
  int expiresIn = 300,
}) =>
    OtpChallenge(
      challengeId: id,
      channel: channel,
      status: status,
      resendAfter: resendAfter,
      expiresIn: expiresIn,
    );

/// Scriptable in-memory auth2 server.
class FakeAuth2Api implements Auth2Api {
  final List<ApiCall> calls = [];
  int _nonce = 0;

  Auth2LoginResult loginResult = fakeAuthenticated();
  Auth2LoginResult socialResult = const Auth2NeedsPhone('social-session-1');
  OtpStatus status = const OtpStatus(status: 'delivered', channel: 'whatsapp', canRequestSms: false);
  String validCode = '123456';
  Auth2Exception? startError;
  List<PendingApproval> pending = [];
  ApprovalCode? approval;
  List<TrustedDevice> deviceList = [];
  Auth2Authenticated? resetResult;

  List<String> names() => calls.map((c) => c.name).toList();
  ApiCall last(String name) => calls.lastWhere((c) => c.name == name);

  void _check(String code) {
    if (code != validCode) {
      throw const Auth2Exception(code: 'invalid_code', statusCode: 400);
    }
  }

  @override
  Future<String> nonce(String deviceId) async {
    calls.add(ApiCall('nonce', {'device_id': deviceId}));
    return 'nonce-${++_nonce}';
  }

  @override
  Future<OtpChallenge> registerStart({
    required String fullName,
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    required String idempotencyKey,
  }) async {
    calls.add(ApiCall('registerStart', {
      'full_name': fullName,
      'phone': phoneE164,
      'device': device.toJson(),
      'idem': idempotencyKey,
    }));
    if (startError != null) throw startError!;
    return fakeChallenge();
  }

  @override
  Future<OtpStatus> otpStatus(String challengeId) async {
    calls.add(ApiCall('otpStatus', {'id': challengeId}));
    return status;
  }

  @override
  Future<OtpChallenge> otpResend(String challengeId, {String? channel}) async {
    calls.add(ApiCall('otpResend', {'id': challengeId, 'channel': channel}));
    return fakeChallenge(id: '$challengeId-r', channel: channel ?? 'whatsapp');
  }

  @override
  Future<Auth2Authenticated> registerVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async {
    calls.add(ApiCall('registerVerify',
        {'id': challengeId, 'code': code, 'nonce': nonce, 'signature': signature}));
    _check(code);
    return fakeAuthenticated(primary: true);
  }

  @override
  Future<Auth2LoginResult> login({
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  }) async {
    calls.add(ApiCall('login', {
      'phone': phoneE164,
      'password': password,
      'nonce': nonce,
      'signature': signature,
    }));
    if (password == 'wrong') {
      throw const Auth2Exception(code: 'invalid_credentials', statusCode: 401);
    }
    return loginResult;
  }

  @override
  Future<OtpChallenge> loginVerifyStart({
    required String verificationId,
    required String channel,
  }) async {
    calls.add(ApiCall('loginVerifyStart', {'id': verificationId, 'channel': channel}));
    return fakeChallenge(id: 'ch-login', channel: channel);
  }

  @override
  Future<Auth2Authenticated> loginVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async {
    calls.add(ApiCall('loginVerify', {'id': challengeId, 'code': code, 'nonce': nonce}));
    _check(code);
    return fakeAuthenticated();
  }

  @override
  Future<Auth2LoginResult> social({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  }) async {
    calls.add(ApiCall('social', {
      'provider': provider,
      'id_token': idToken,
      'raw_nonce': rawNonce,
      'nonce': nonce,
    }));
    return socialResult;
  }

  @override
  Future<OtpChallenge> socialPhoneStart({
    required String socialSession,
    required String phoneE164,
    required String idempotencyKey,
  }) async {
    calls.add(ApiCall('socialPhoneStart', {'session': socialSession, 'phone': phoneE164}));
    if (startError != null) throw startError!;
    return fakeChallenge(id: 'ch-social');
  }

  @override
  Future<Auth2Authenticated> socialPhoneVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async {
    calls.add(ApiCall('socialPhoneVerify', {'id': challengeId, 'code': code}));
    _check(code);
    return fakeAuthenticated(primary: true);
  }

  @override
  Future<List<PendingApproval>> pendingApprovals() async {
    calls.add(ApiCall('pendingApprovals', {}));
    return pending;
  }

  @override
  Future<ApprovalCode> approvalCode(
    String approvalId, {
    required String nonce,
    required String signature,
  }) async {
    calls.add(ApiCall('approvalCode', {'id': approvalId, 'nonce': nonce, 'signature': signature}));
    final a = approval;
    if (a == null) throw const Auth2Exception(code: 'expired', statusCode: 410);
    return a;
  }

  @override
  Future<void> denyApproval(String approvalId) async {
    calls.add(ApiCall('denyApproval', {'id': approvalId}));
    pending = pending.where((p) => p.approvalId != approvalId).toList();
  }

  @override
  Future<List<TrustedDevice>> devices() async {
    calls.add(ApiCall('devices', {}));
    return List.of(deviceList);
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    calls.add(ApiCall('revokeDevice', {'id': deviceId}));
    deviceList = deviceList.where((d) => d.deviceId != deviceId).toList();
  }

  @override
  Future<void> renameDevice(String deviceId, String name) async {
    calls.add(ApiCall('renameDevice', {'id': deviceId, 'name': name}));
    deviceList = [
      for (final d in deviceList) d.deviceId == deviceId ? d.copyWith(name: name) : d,
    ];
  }

  @override
  Future<void> makePrimary(String deviceId, {required String nonce, required String signature}) async {
    calls.add(ApiCall('makePrimary', {'id': deviceId, 'nonce': nonce}));
  }

  @override
  Future<DateTime?> claimPrimary() async {
    calls.add(ApiCall('claimPrimary', {}));
    final until = DateTime.now().add(const Duration(hours: 48));
    deviceList = [
      for (final d in deviceList)
        d.current
            ? TrustedDevice(
                deviceId: d.deviceId,
                name: d.name,
                model: d.model,
                os: d.os,
                osVersion: d.osVersion,
                appVersion: d.appVersion,
                isPrimary: d.isPrimary,
                trusted: d.trusted,
                lastSeen: d.lastSeen,
                createdAt: d.createdAt,
                current: d.current,
                primaryClaimUntil: until,
              )
            : d,
    ];
    return until;
  }

  @override
  Future<void> cancelClaimPrimary() async {
    calls.add(ApiCall('cancelClaimPrimary', {}));
  }

  @override
  Future<OtpChallenge> phoneChangeStart({
    required String newPhoneE164,
    String? password,
    required String nonce,
    required String signature,
    required String idempotencyKey,
  }) async {
    calls.add(ApiCall('phoneChangeStart',
        {'phone': newPhoneE164, 'password': password, 'nonce': nonce, 'signature': signature}));
    if (startError != null) throw startError!;
    return fakeChallenge(id: 'ch-phone');
  }

  @override
  Future<Map<String, dynamic>> phoneChangeVerify({
    required String challengeId,
    required String code,
  }) async {
    calls.add(ApiCall('phoneChangeVerify', {'id': challengeId, 'code': code}));
    _check(code);
    return {'phone': '+966501234567'};
  }

  @override
  Future<void> reauth(String password) async {
    calls.add(ApiCall('reauth', {}));
    if (password != 'pass1234') {
      throw const Auth2Exception(code: 'invalid_credentials', statusCode: 401);
    }
  }

  @override
  Future<OtpChallenge> passwordForgot({
    required String phoneE164,
    required DeviceDescriptor device,
  }) async {
    calls.add(ApiCall('passwordForgot', {'phone': phoneE164}));
    return fakeChallenge(id: 'ch-reset');
  }

  @override
  Future<Auth2Authenticated?> passwordReset({
    required String challengeId,
    required String code,
    required String newPassword,
  }) async {
    calls.add(ApiCall('passwordReset', {'id': challengeId, 'code': code, 'password': newPassword}));
    _check(code);
    return resetResult;
  }
}

class FakeSocialSignIn implements SocialSignIn {
  int googleCalls = 0;
  int appleCalls = 0;

  @override
  Future<SocialCredential> google() async {
    googleCalls++;
    return const SocialCredential(provider: 'google', idToken: 'google-id-token', fullName: 'Sara');
  }

  @override
  Future<SocialCredential> apple() async {
    appleCalls++;
    return const SocialCredential(
      provider: 'apple',
      idToken: 'apple-id-token',
      authorizationCode: 'apple-code',
      rawNonce: 'raw-nonce',
    );
  }
}

/// Auth notifier double: same auth2 calls as the real one, no storage.
class FakeAuthNotifier extends StateNotifier<AuthState> implements AuthNotifier {
  FakeAuthNotifier(this._ref, [AuthState? initial])
      : super(initial ?? const AuthState(status: AuthStatus.unauthenticated));

  final Ref _ref;
  final List<Auth2Authenticated> completed = [];
  String? lastPassword;
  String? lastUsageMode;

  @override
  Future<Auth2LoginResult?> login({
    required String phone,
    required String password,
    bool rememberMe = false,
    String? usageMode,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final r = await _ref.read(auth2ServiceProvider).login(phone, password);
      if (r is Auth2Authenticated) {
        await completeAuth2(r, password: password);
      } else {
        state = state.copyWith(isLoading: false);
      }
      return r;
    } on Auth2Exception catch (e) {
      state = state.copyWith(
          status: AuthStatus.unauthenticated, isLoading: false, error: 'ERR:${e.code}');
      return null;
    }
  }

  @override
  Future<Auth2LoginResult?> loginWithSocial({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
  }) async {
    final r = await _ref.read(auth2ServiceProvider).social(
          provider: provider,
          idToken: idToken,
          authorizationCode: authorizationCode,
          rawNonce: rawNonce,
          fullName: fullName,
        );
    if (r is Auth2Authenticated) await completeAuth2(r);
    return r;
  }

  @override
  Future<void> completeAuth2(
    Auth2Authenticated result, {
    String? password,
    bool rememberMe = false,
    String? usageMode,
  }) async {
    completed.add(result);
    lastPassword = password;
    lastUsageMode = usageMode;
    state = AuthState(status: AuthStatus.authenticated, user: result.response.user);
  }

  @override
  void applyUserUpdate(UserModel Function(UserModel) updater) {
    final u = state.user;
    if (u != null) state = state.copyWith(user: updater(u));
  }

  @override
  void setError(String message) => state = state.copyWith(error: message, isLoading: false);

  @override
  void clearError() => state = state.copyWith(error: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Everything a sign-in screen needs, wired with fakes.
class Auth2Harness {
  Auth2Harness({FakeAuth2Api? api, FakeDeviceKeyIdentity? identity, FakeSocialSignIn? social})
      : api = api ?? FakeAuth2Api(),
        identity = identity ?? FakeDeviceKeyIdentity(),
        social = social ?? FakeSocialSignIn();

  final FakeAuth2Api api;
  final FakeDeviceKeyIdentity identity;
  final FakeSocialSignIn social;
  late final ProviderContainer container;
  late final GoRouter router;
  FakeAuthNotifier get auth => container.read(authStateProvider.notifier) as FakeAuthNotifier;

  List<Override> get overrides => [
        auth2ApiProvider.overrideWithValue(api),
        deviceKeyIdentityProvider.overrideWithValue(identity),
        socialSignInProvider.overrideWithValue(social),
        authStateProvider.overrideWith((ref) => FakeAuthNotifier(ref)),
        connectivityServiceProvider.overrideWithValue(ConnectivityService(debugOnline: true)),
      ];

  static const authRoutes = {
    RouteNames.login,
    RouteNames.register,
    RouteNames.forgotPassword,
    RouteNames.authOtp,
    RouteNames.verifyDevice,
    RouteNames.socialPhone,
    RouteNames.resetPassword,
  };

  Future<void> pump(WidgetTester tester, {String initial = RouteNames.login, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    router = GoRouter(
      initialLocation: initial,
      redirect: (_, state) {
        final authed = container.read(authStateProvider).isAuthenticated;
        if (authed && authRoutes.contains(state.matchedLocation)) return '/account-entry';
        return null;
      },
      routes: [
        GoRoute(path: RouteNames.login, builder: (_, _) => const LoginPage()),
        GoRoute(path: RouteNames.register, builder: (_, _) => const RegisterPage()),
        GoRoute(path: RouteNames.forgotPassword, builder: (_, _) => const ForgotPasswordPage()),
        GoRoute(path: RouteNames.authOtp, builder: (_, _) => const OtpPage()),
        GoRoute(path: RouteNames.verifyDevice, builder: (_, _) => const VerifyDevicePage()),
        GoRoute(path: RouteNames.socialPhone, builder: (_, _) => const SocialPhonePage()),
        GoRoute(path: RouteNames.resetPassword, builder: (_, _) => const ResetPasswordPage()),
        GoRoute(
          path: '/account-entry',
          builder: (_, _) => const Scaffold(body: Center(child: Text('HOME'))),
        ),
      ],
    );
    container.listen(authStateProvider, (_, _) => router.refresh());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.darkTheme,
        routerConfig: router,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pumps frames without waiting for the OTP / countdown tickers to settle.
Future<void> pumpFor(WidgetTester tester, [Duration d = const Duration(milliseconds: 600)]) async {
  final end = d.inMilliseconds;
  for (var t = 0; t < end; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
