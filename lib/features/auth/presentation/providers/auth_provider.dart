import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/services/fcm_service.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/avatar_provider.dart';
import '../../../../shared/models/user_model.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/firebase_auth_service.dart';
import '../../di/auth_providers.dart';
import '../../data/datasources/auth_local_data_source.dart';
import '../../data/models/session_model.dart';
import '../../data/models/token_response.dart';
import '../../../../core/network/session_notifier.dart';
import '../../../../core/network/session_timeout_provider.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/database/database_helper.dart';
import '../../../personal/data/ledger/personal_ledger.dart';
import '../../../../core/database/providers/database_providers.dart';
import '../../data/models/auth_response.dart';
import '../../auth2/auth2_models.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart' show auth2ErrorText, auth2T;

enum AuthStatus { initial, authenticated, unauthenticated, loading, verificationPending, sessionExpired }

class AuthState {
  final AuthStatus status;
  final UserModel? user;
  final String? error;
  final bool isLoading;
  final bool rememberMe;
  final String? preferredUsageMode;
  final String? pendingVerificationEmail;
  /// True when the account signed in with Google and neither this device nor
  /// the account itself has a chosen usage mode — forces the choose-usage
  /// screen exactly once per account (at creation/first entry).
  final bool forceUsageChoice;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.error,
    this.isLoading = false,
    this.rememberMe = false,
    this.preferredUsageMode,
    this.pendingVerificationEmail,
    this.forceUsageChoice = false,
  });

  AuthState copyWith({
    AuthStatus? status,
    UserModel? user,
    String? error,
    bool? isLoading,
    bool? rememberMe,
    String? preferredUsageMode,
    String? pendingVerificationEmail,
    bool? forceUsageChoice,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      error: error,
      isLoading: isLoading ?? this.isLoading,
      rememberMe: rememberMe ?? this.rememberMe,
      preferredUsageMode: preferredUsageMode ?? this.preferredUsageMode,
      pendingVerificationEmail:
          pendingVerificationEmail ?? this.pendingVerificationEmail,
      forceUsageChoice: forceUsageChoice ?? this.forceUsageChoice,
    );
  }

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isUnauthenticated => status == AuthStatus.unauthenticated;
}

final authProvider = authStateProvider;

/// Whether the choose-usage screen must be forced: only when the caller did
/// not pass a mode, this device saved none, AND the account itself has none
/// server-side. A returning account on a new device (server mode present)
/// is never re-asked.
bool needsUsageChoice({
  String? usageMode,
  String? savedMode,
  String? serverMode,
}) {
  return usageMode == null &&
      (savedMode == null || savedMode.isEmpty) &&
      (serverMode == null || serverMode.isEmpty);
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;
  final AuthLocalDataSource _localDataSource;
  final FirebaseAuthService _firebaseAuthService;
  final Ref _ref;

  /// Held only in memory while authenticated so the lock screen can verify
  /// the password offline. Never persisted to disk.
  String? _sessionPassword;

  /// Short-lived reset token returned by [verifyResetOtp]. Held in memory
  /// only for the duration of the reset-password flow.
  String? _pendingResetToken;

  AuthNotifier(
    this._authService,
    this._localDataSource,
    this._firebaseAuthService,
    this._ref,
  ) : super(const AuthState()) {
    SessionNotifier.onExpired = () {
      unawaited(_handleSessionExpired());
    };
    SessionNotifier.onDeviceRevoked = () {
      unawaited(_handleDeviceRevoked());
    };
    _checkSession();
  }

  /// A 401 with a dead refresh token does NOT mean "ask for email+password".
  /// Unless the user explicitly logged out, the session is parked in the
  /// [AuthStatus.sessionExpired] re-entry gate (fingerprint / stored
  /// password only) whenever recovery material exists on this device.
  Future<void> _handleSessionExpired() async {
    _sessionPassword = null;
    try {
      _ref.read(sessionTimeoutProvider.notifier).unlock();
    } catch (_) {}
    if (!state.isAuthenticated) return;
    UserModel? displayUser = state.user ?? await _snapshotUser();
    if (await _hasRecoveryMaterial()) {
      state = state.copyWith(
        status: AuthStatus.sessionExpired,
        user: displayUser,
        isLoading: false,
        error: null,
      );
    } else {
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  /// True when this device can re-enter without typing email+password:
  /// a fingerprint snapshot or saved biometric credentials exist.
  Future<bool> _hasRecoveryMaterial() async {
    try {
      if (await _localDataSource.hasBiometricSnapshot()) return true;
      final email = await _localDataSource.getBiometricEmail();
      final password = await _localDataSource.getBiometricPassword();
      return email != null &&
          email.isNotEmpty &&
          password != null &&
          password.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<UserModel?> _snapshotUser() async {
    try {
      final raw = await _localDataSource.getBiometricSnapshotUser();
      if (raw == null || raw.isEmpty) return null;
      return UserModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Park in the re-entry gate when recovery exists, else full logout state.
  Future<void> _enterExpiredOrLoggedOut() async {
    final displayUser = state.user ?? await _snapshotUser();
    if (await _hasRecoveryMaterial()) {
      state = state.copyWith(
        status: AuthStatus.sessionExpired,
        user: displayUser,
        isLoading: false,
        error: null,
      );
    } else {
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  /// Verifies a password against the in-memory session password, falling back
  /// to the stored biometric credentials when available.
  Future<bool> verifySessionPassword(String password) async {
    if (_sessionPassword != null && _sessionPassword == password) return true;
    try {
      final bioPassword = await _localDataSource.getBiometricPassword();
      if (bioPassword != null && bioPassword.isNotEmpty && bioPassword == password) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Warm the canonical offline namespace for [realUserId] (stable id +
  /// legacy-row migration + orphan cleanup) BEFORE any authenticated state
  /// is published, so personal providers created afterwards start in the
  /// right namespace and never flip mid-session.
  Future<void> _warmNamespace(String realUserId) async {
    if (realUserId.isEmpty) return;
    try {
      await _ref.read(personalCacheRepositoryProvider).warmStableId(realUserId);
    } catch (_) {}
  }

  Future<void> _checkSession() async {
    try {
      final hasSession = await _authService.hasSession();
      if (!hasSession) {
        state = state.copyWith(status: AuthStatus.unauthenticated);
        return;
      }      final token = await _localDataSource.getAccessToken();
      if (token == null) {
        await _authService.clearSession();
        await _enterExpiredOrLoggedOut();
        return;
      }
      final savedMode = await _localDataSource.getUsageMode();
      final cachedUser = await _localDataSource.getUser();

      if (_authService.isTokenExpired(token)) {
        // Access token expired but the user never logged out: try a silent
        // refresh (the Dio interceptor renews it from the refresh token)
        // instead of wiping the session.
        try {
          final user = await _authService
              .getProfile()
              .timeout(const Duration(seconds: 8));
          if (user != null) {
            final updatedUser = savedMode != null
                ? user.copyWith(preferredUsageMode: savedMode)
                : user;
            unawaited(_warmNamespace(updatedUser.id));
            state = state.copyWith(
              status: AuthStatus.authenticated,
              user: updatedUser,
              preferredUsageMode: savedMode ?? user.preferredUsageMode,
            );
            await _localDataSource.saveUser(updatedUser);
            _ref.read(avatarProvider.notifier).load(userId: updatedUser.id);
            return;
          }
        } catch (_) {}
        // Offline with expired token: fall back to cached user instead of
        // clearing the session, so the app works without internet.
        if (cachedUser != null) {
          unawaited(_warmNamespace(cachedUser.id));
          state = state.copyWith(
            status: AuthStatus.authenticated,
            user: savedMode != null
                ? cachedUser.copyWith(preferredUsageMode: savedMode)
                : cachedUser,
            preferredUsageMode: savedMode ?? cachedUser.preferredUsageMode,
          );
          return;
        }
        await _authService.clearSession();
        await _enterExpiredOrLoggedOut();
        return;
      }
      if (cachedUser != null) {
        // Restore instantly from the local cache so startup stays fast;
        // refresh the profile from the network in the background.
        unawaited(_warmNamespace(cachedUser.id));
        state = state.copyWith(
          status: AuthStatus.authenticated,
          user: savedMode != null
              ? cachedUser.copyWith(preferredUsageMode: savedMode)
              : cachedUser,
          preferredUsageMode: savedMode ?? cachedUser.preferredUsageMode,
        );
        unawaited(_refreshProfileFromNetwork(cachedUser, savedMode));
        return;
      }
      try {
        final user = await _authService
            .getProfile()
            .timeout(const Duration(seconds: 5));
      if (user != null) {
        final updatedUser = savedMode != null
            ? user.copyWith(preferredUsageMode: savedMode)
            : user;
        unawaited(_warmNamespace(updatedUser.id));
        state = state.copyWith(
          status: AuthStatus.authenticated,
          user: updatedUser,
          preferredUsageMode: savedMode ?? user.preferredUsageMode,
        );
        await _localDataSource.saveUser(updatedUser);
        _ref.read(avatarProvider.notifier).load(userId: updatedUser.id);
        return;
      }
    } catch (_) {}
    await _authService.clearSession();
    await _enterExpiredOrLoggedOut();
    } catch (_) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> _refreshProfileFromNetwork(
    UserModel cachedUser,
    String? savedMode,
  ) async {
    try {
      final user = await _authService
          .getProfile()
          .timeout(const Duration(seconds: 10));
      if (user == null || !_ref.exists(authStateProvider)) return;
      final merged = user.copyWith(
        fullName: user.fullName ?? cachedUser.fullName,
        email: user.email ?? cachedUser.email,
        phone: user.phone ?? cachedUser.phone,
      );
      final updatedUser = savedMode != null
          ? merged.copyWith(preferredUsageMode: savedMode)
          : merged;
      state = state.copyWith(
        user: updatedUser,
        preferredUsageMode: savedMode ?? updatedUser.preferredUsageMode,
      );
      await _localDataSource.saveUser(updatedUser);
      _ref.read(avatarProvider.notifier).load(userId: updatedUser.id);
    } catch (_) {
      // Keep the cached session; do not log the user out on a transient
      // network error.
    }
  }

  /// Phone + password sign-in (auth2). Returns the server outcome so the
  /// page can continue to device verification; null on error ([state.error]).
  /// A trusted device with a valid key proof is signed in directly.
  Future<Auth2LoginResult?> login({
    required String phone,
    required String password,
    bool rememberMe = false,
    String? usageMode,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result =
          await _ref.read(auth2ServiceProvider).login(phone, password);
      if (result is Auth2Authenticated) {
        await completeAuth2(
          result,
          password: password,
          rememberMe: rememberMe,
          usageMode: usageMode,
        );
      } else {
        state = state.copyWith(isLoading: false, error: null);
      }
      return result;
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        isLoading: false,
        error: _toMessage(e),
      );
      return null;
    }
  }

  /// Google (Android) / Apple (iOS) sign-in through auth2 `/social`.
  /// Returns null when cancelled or failed ([state.error] set on failure).
  Future<Auth2LoginResult?> loginWithSocial({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _ref.read(auth2ServiceProvider).social(
            provider: provider,
            idToken: idToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce,
            fullName: fullName,
          );
      if (result is Auth2Authenticated) {
        await completeAuth2(result);
      } else {
        state = state.copyWith(isLoading: false, error: null);
      }
      return result;
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        isLoading: false,
        error: _toMessage(e),
      );
      return null;
    }
  }

  /// Persists an auth2 AuthResponse (tokens + user) and enters the app.
  Future<void> completeAuth2(
    Auth2Authenticated result, {
    String? password,
    bool rememberMe = false,
    String? usageMode,
  }) async {
    final response = result.response;
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    // No usage-mode question: entry resolves through /account-entry.
    await _applyAuthResponse(
      response,
      password: password,
      rememberMe: rememberMe,
      usageMode: usageMode,
    );
  }

  /// The server revoked THIS device (`device_revoked`): its key proofs are
  /// dead, so nothing on the device can re-enter silently. Wipe tokens and
  /// every recovery snapshot, then go to the login page.
  Future<void> _handleDeviceRevoked() async {
    _sessionPassword = null;
    try {
      _ref.read(sessionTimeoutProvider.notifier).unlock();
    } catch (_) {}
    try {
      await _localDataSource.clearAuth();
    } catch (_) {}
    try {
      await _localDataSource.clearBiometricSnapshot();
    } catch (_) {}
    try {
      await _localDataSource.clearUsageMode();
    } catch (_) {}
    try {
      await PersonalLedger.deactivate();
    } catch (_) {}
    try {
      _ref.read(avatarProvider.notifier).clear();
    } catch (_) {}
    state = AuthState(
      status: AuthStatus.unauthenticated,
      error: auth2T('deviceRevoked'),
    );
  }

  Future<void> _applyAuthResponse(
    AuthResponse response, {
    String? password,
    bool rememberMe = false,
    String? usageMode,
    bool forceUsageChoice = false,
  }) async {
    final savedMode = await _localDataSource.getUsageMode();
    final mode = usageMode ?? savedMode;
    final updatedUser = mode != null
        ? response.user.copyWith(preferredUsageMode: mode)
        : response.user;
    if (password != null) {
      _sessionPassword = password;
    }
    await _warmNamespace(response.user.id);
    state = state.copyWith(
      status: AuthStatus.authenticated,
      user: updatedUser,
      isLoading: false,
      rememberMe: rememberMe,
      preferredUsageMode: mode,
      error: null,
      pendingVerificationEmail: null,
      forceUsageChoice: forceUsageChoice,
    );
    _ref.read(avatarProvider.notifier).load(userId: response.user.id);
    if (mode != null) {
      await _localDataSource.saveUsageMode(mode);
    }
    // Keep the fingerprint snapshot in sync with the CURRENT account: a
    // different account logging in must never restore the previous one.
    try {
      final bioOn = await _localDataSource.getBiometricEnabled();
      if (bioOn) {
        final access = await _localDataSource.getAccessToken();
        if (access != null && access.isNotEmpty) {
          final refresh = await _localDataSource.getRefreshToken();
          await _localDataSource.saveBiometricSnapshot(
            accessToken: access,
            refreshToken: refresh,
            userJson: jsonEncode(updatedUser.toJson()),
            usageMode: mode,
          );
        }
      } else {
        await _localDataSource.clearBiometricSnapshot();
      }
    } catch (_) {}
    _ref.read(fcmServiceProvider).syncToken();
  }

  String _toMessage(Object e) {
    if (e is Auth2Exception) return auth2ErrorText(e);
    String msg = firebaseErrorMessage(e);
    msg = msg.replaceFirst('ApiException: ', '');
    msg = msg.replaceAll(RegExp(r'\s*\(status: [\dnull]+\)'), '');
    // Strip backend validation prefixes ("Value error, ...") so the user
    // only ever sees clean Arabic (or the localized English below).
    msg = msg.replaceFirst(
        RegExp(r'^\s*value\s*error\s*[,:\-]\s*', caseSensitive: false), '');
    // Map known backend messages to localized strings (correct EN included).
    // Google accounts are detected first (their message also mentions
    // external sign-in concepts, so order matters).
    if (msg.contains('عبر Google')) {
      return AppLocalizations.t('authErrGoogleAccount');
    }
    if (msg.contains('رمز التحقق غير صالح')) {
      return AppLocalizations.t('authErrInvalidOtp');
    }
    if (msg.contains('غير مسجل في التطبيق')) {
      return AppLocalizations.t('authErrEmailNotRegistered');
    }
    if (msg.contains('تسجيل دخول خارجي')) {
      return AppLocalizations.t('authErrExternalLogin');
    }
    // Device cap reached (server 409): "... ({limit} أجهزة) ...".
    if (msg.contains('الحد الأقصى للأجهزة')) {
      final limit = RegExp(r'\((\d+)').firstMatch(msg)?.group(1) ?? '3';
      return AppLocalizations.t('authErrSessionLimit', {'limit': limit});
    }
    return msg;
  }

  Future<void> logout() async {
    _sessionPassword = null;
    _ref.read(sessionTimeoutProvider.notifier).unlock();
    // Best-effort: unregister this device token so the account stops
    // receiving pushes. Fire-and-forget — never blocks logout.
    try {
      unawaited(_ref.read(fcmServiceProvider).unregisterToken());
    } catch (_) {}
    state = state.copyWith(isLoading: true);
    // Snapshot the live session FIRST so a later fingerprint restores this
    // exact account (works even after this explicit logout).
    try {
      final enabled = await _localDataSource.getBiometricEnabled();
      if (enabled) {
        final access = await _localDataSource.getAccessToken();
        final user = state.user ?? await _localDataSource.getUser();
        if (access != null && access.isNotEmpty && user != null) {
          final refresh = await _localDataSource.getRefreshToken();
          final mode = await _localDataSource.getUsageMode();
          await _localDataSource.saveBiometricSnapshot(
            accessToken: access,
            refreshToken: refresh,
            userJson: jsonEncode(user.toJson()),
            usageMode: mode,
          );
        }
      }
    } catch (_) {}
    // Explicit logout wipes the session, but the fingerprint + its session
    // snapshot are KEPT: a later fingerprint restores this exact account
    // directly (online and offline) without email/password. Only the saved
    // usage mode is cleared so a manual login never inherits it.
    try {
      await _authService.logout();
    } catch (_) {}
    try {
      await _firebaseAuthService.signOut();
    } catch (_) {}
    try {
      await _localDataSource.clearUsageMode();
    } catch (_) {}
    // Drop the offline notifications mirror so the next account on this
    // device never sees the previous account's cached notifications.
    try {
      await DatabaseHelper.rawDelete('DELETE FROM notifications');
    } catch (_) {}
    // Drop the cached subscription plans so the next account re-syncs fresh
    // prices instead of seeing the previous account's snapshot.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('subscription_plans_cache');
    } catch (_) {}
    _ref.read(avatarProvider.notifier).clear();
    // Session-timeout protection is per login: drop the app PIN and turn
    // the timeout off so the next account on this device starts clean and
    // can never be locked behind someone else's PIN.
    try {
      await _localDataSource.clearAppPin();
    } catch (_) {}
    try {
      await _ref.read(sessionTimeoutProvider.notifier).setDuration(null);
    } catch (_) {}
    // Close this user's encrypted Personal ledger: the data stays on the
    // device (encrypted) for the next login of the same user, and nothing
    // can read or write it until a user is selected again.
    try {
      await PersonalLedger.deactivate();
    } catch (_) {}
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Biometric entry WITHOUT email/password.
  ///
  /// The fingerprint only proves device ownership; the actual entry restores
  /// a session:
  ///  1. Live session still on device → validated profile.
  ///  2. Fingerprint session snapshot (kept across logout) → validated
  ///     profile, or the snapshot user when offline.
  ///  3. Saved email/password silent re-login.
  ///
  /// ONLINE the tokens are ALWAYS validated before entering: entering with
  /// dead/revoked tokens causes an instant 401 → immediate kick-out, so it
  /// is never done. OFFLINE the cached/snapshot account opens directly and
  /// sync resumes when the network returns.
  /// Returns an error message on failure, null on success.
  /// Open the cached account after a successful LOCAL proof (app PIN or
  /// device biometric). Works fully offline: no network profile call and no
  /// token mutation. Used only by the expired-session re-entry gate.
  Future<String?> restoreCachedSession() async {
    UserModel? user = state.user;
    try {
      user ??= await _localDataSource.getUser();
    } catch (_) {}
    if (user == null) {
      try {
        final json = await _localDataSource.getBiometricSnapshotUser();
        if (json != null && json.isNotEmpty) {
          user = UserModel.fromJson(jsonDecode(json) as Map<String, dynamic>);
        }
      } catch (_) {}
    }
    if (user == null) {
      state = state.copyWith(isLoading: false);
      return AppLocalizations.t('authErrBioLogin');
    }
    await _warmNamespace(user.id);
    final savedMode = await _localDataSource.getUsageMode();
    final updated = savedMode != null
        ? user.copyWith(preferredUsageMode: savedMode)
        : user;
    state = state.copyWith(
      status: AuthStatus.authenticated,
      user: updated,
      isLoading: false,
      error: null,
      preferredUsageMode: savedMode ?? updated.preferredUsageMode,
    );
    try {
      _ref.read(avatarProvider.notifier).load(userId: updated.id);
    } catch (_) {}
    return null;
  }

  Future<String?> loginWithBiometric() async {
    state = state.copyWith(isLoading: true, error: null);
    bool online = true;
    try {
      online = _ref.read(connectivityServiceProvider).isOnline;
    } catch (_) {}
    try {
      // ── Tier 1: live session still on device ──
      if (await _authService.hasSession()) {
        final user = await _authService.getProfile();
        if (user != null) {
          return await _enterBiometric(user);
        }
        // Profile unreachable: offline → open the cached account.
        // Online → the tokens are dead/revoked: fall through to the
        // snapshot/credentials tiers instead of entering with tokens
        // that will 401 on the very next call and kick the user out.
        if (!online) {
          final cached = await _localDataSource.getUser();
          if (cached != null) {
            return await _enterBiometric(cached);
          }
        }
      }
      // ── Tier 2: fingerprint snapshot (kept across logout) ──
      final snapAccess = await _localDataSource.getBiometricSnapshotAccess();
      final snapUserJson = await _localDataSource.getBiometricSnapshotUser();
      if (snapAccess != null &&
          snapAccess.isNotEmpty &&
          snapUserJson != null &&
          snapUserJson.isNotEmpty) {
        final snapRefresh =
            await _localDataSource.getBiometricSnapshotRefresh();
        final snapMode = await _localDataSource.getBiometricSnapshotMode();
        await _localDataSource.saveTokens(TokenResponse(
          accessToken: snapAccess,
          refreshToken: snapRefresh,
        ));
        UserModel? snapUser;
        try {
          snapUser =
              UserModel.fromJson(jsonDecode(snapUserJson) as Map<String, dynamic>);
        } catch (_) {
          snapUser = null;
        }
        final fresh = await _authService.getProfile();
        if (fresh != null) {
          // Server returned a profile → tokens are valid.
          if (snapMode != null && snapMode.isNotEmpty) {
            await _localDataSource.saveUsageMode(snapMode);
          }
          return await _enterBiometric(
            snapMode != null && snapMode.isNotEmpty
                ? fresh.copyWith(preferredUsageMode: snapMode)
                : fresh,
          );
        }
        // getProfile() failed: offline + unexpired snapshot → open it.
        // Online → the snapshot was revoked: drop the dead tokens just
        // written back and fall through to Tier 3 for fresh ones.
        if (!online &&
            snapUser != null &&
            !_authService.isTokenExpired(snapAccess)) {
          if (snapMode != null && snapMode.isNotEmpty) {
            await _localDataSource.saveUsageMode(snapMode);
          }
          return await _enterBiometric(
            snapMode != null && snapMode.isNotEmpty
                ? snapUser.copyWith(preferredUsageMode: snapMode)
                : snapUser,
          );
        }
        if (online) {
          try {
            await _localDataSource.clearAuth();
          } catch (_) {}
        }
      }
      // ── Tier 3: silent re-login with the credentials saved when
      // biometric was enabled (needs network) ──
      final email = await _localDataSource.getBiometricEmail();
      final password = await _localDataSource.getBiometricPassword();
      if (email == null ||
          email.isEmpty ||
          password == null ||
          password.isEmpty) {
        state = state.copyWith(isLoading: false);
        return AppLocalizations.t('authErrBioLogin');
      }
      if (!email.startsWith('+')) {
        // Legacy e-mail credentials: e-mail sign-in no longer exists.
        state = state.copyWith(isLoading: false);
        return AppLocalizations.t('authErrBioLogin');
      }
      final savedMode = await _localDataSource.getUsageMode();
      await login(phone: email, password: password, usageMode: savedMode);
      if (!state.isAuthenticated) {
        return state.error ?? AppLocalizations.t('authErrBioLogin');
      }
      return null;
    } catch (e) {
      state = state.copyWith(isLoading: false);
      return _toMessage(e);
    }
  }

  /// Silent re-login with the credentials saved when biometric was enabled.
  /// Used by the re-entry gate after the user proves device ownership
  /// (fingerprint or the stored password) — nothing is typed.
  Future<String?> reloginWithSavedCredentials() async {
    try {
      final email = await _localDataSource.getBiometricEmail();
      final password = await _localDataSource.getBiometricPassword();
      if (email == null ||
          email.isEmpty ||
          password == null ||
          password.isEmpty) {
        return AppLocalizations.t('authErrBioLogin');
      }
      if (!email.startsWith('+')) return AppLocalizations.t('authErrBioLogin');
      final savedMode = await _localDataSource.getUsageMode();
      await login(phone: email, password: password, usageMode: savedMode);
      if (!state.isAuthenticated) {
        return state.error ?? AppLocalizations.t('authErrBioLogin');
      }
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Abandon the expired session ("use another account"): wipes tokens and
  /// all biometric recovery material, then goes to the full login page.
  Future<void> abandonSession() async {
    try {
      await _localDataSource.clearAuth();
    } catch (_) {}
    try {
      await _localDataSource.clearBiometricAll();
    } catch (_) {}
    try {
      await _localDataSource.clearAppPin();
    } catch (_) {}
    try {
      await _ref.read(sessionTimeoutProvider.notifier).setDuration(null);
    } catch (_) {}
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Shared tail of every biometric entry: set authenticated state, refresh
  /// the snapshot with the live tokens, load avatar, sync FCM.
  Future<String?> _enterBiometric(UserModel user) async {
    final savedMode = await _localDataSource.getUsageMode();
    final updatedUser = savedMode != null
        ? user.copyWith(preferredUsageMode: savedMode)
        : user;
    await _warmNamespace(updatedUser.id);
    state = state.copyWith(
      status: AuthStatus.authenticated,
      user: updatedUser,
      isLoading: false,
      preferredUsageMode: savedMode ?? updatedUser.preferredUsageMode,
      error: null,
    );
    _ref.read(avatarProvider.notifier).load(userId: updatedUser.id);
    _ref.read(fcmServiceProvider).syncToken();
    try {
      final access = await _localDataSource.getAccessToken();
      if (access != null && access.isNotEmpty) {
        final refresh = await _localDataSource.getRefreshToken();
        await _localDataSource.saveBiometricSnapshot(
          accessToken: access,
          refreshToken: refresh,
          userJson: jsonEncode(updatedUser.toJson()),
          usageMode: savedMode,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<void> refreshProfile() async {
    try {
      final token = await _localDataSource.getAccessToken();
      if (token != null && _authService.isTokenExpired(token)) {
        return;
      }
      final cachedUser = await _localDataSource.getUser();
      final user = await _authService.getProfile();
      if (user != null && state.isAuthenticated) {
        final merged = cachedUser != null
            ? user.copyWith(
                fullName: user.fullName ?? cachedUser.fullName,
                email: user.email ?? cachedUser.email,
                phone: user.phone ?? cachedUser.phone,
              )
            : user;
        final savedMode = await _localDataSource.getUsageMode();
        final updatedUser = savedMode != null
            ? merged.copyWith(preferredUsageMode: savedMode)
            : merged;
        state = state.copyWith(user: updatedUser);
        await _localDataSource.saveUser(updatedUser);
      }
    } catch (_) {}
  }

  /// Sends a verification OTP to the given email through the backend.
  ///
  /// [purpose] `'reset'` (default) is for an ACCOUNT PASSWORD reset and is
  /// therefore limited to password-backed accounts. `'pin'` only proves the
  /// address is yours for the DEVICE PIN — it never touches the password, so
  /// accounts signed in with Google work with it too.
  Future<String?> forgotPassword(String email, {String purpose = 'reset'}) async {
    try {
      await _authService.forgotPassword(email, purpose: purpose);
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Verifies the OTP. For [purpose] `'reset'` the short-lived reset token is
  /// stored for the following [resetPassword] call; any other purpose is a
  /// pure ownership check (device PIN) and keeps no token.
  /// Returns an error message on failure.
  Future<String?> verifyResetOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  }) async {
    try {
      final result = await _authService.verifyOtp(
        email: email,
        otp: otp.trim(),
        purpose: purpose,
      );
      if (result.resetToken.isEmpty) {
        return AppLocalizations.t('authErrInvalidOtp');
      }
      if (purpose == 'reset') {
        _pendingResetToken = result.resetToken;
      }
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Completes the password reset using the reset token from [verifyResetOtp].
  /// Returns an error message on failure.
  Future<String?> resetPassword({
    required String newPassword,
    required String confirmNewPassword,
  }) async {
    if (newPassword != confirmNewPassword) {
      return AppLocalizations.t('authErrPasswordMismatch');
    }
    final token = _pendingResetToken;
    if (token == null || token.isEmpty) {
      return AppLocalizations.t('authErrResetExpired');
    }
    try {
      final response = await _authService.resetPassword(
        resetToken: token,
        newPassword: newPassword,
      );
      _pendingResetToken = null;
      await _applyAuthResponse(response, password: newPassword);
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Changes the password through the backend (revokes all sessions).
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
    required String confirmNewPassword,
  }) async {
    if (newPassword != confirmNewPassword) {
      return AppLocalizations.t('authErrPasswordMismatch');
    }
    try {
      await _authService.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      _sessionPassword = newPassword;
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Sends a verification code to the user's CURRENT (old) email. The new email
  /// is supplied later at [verifyEmailChange], so the user must prove ownership
  /// of the currently registered inbox before the email can be changed.
  Future<String?> requestEmailChange() async {
    try {
      await _authService.requestEmailChange();
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  /// Verifies the OTP sent to the OLD email and applies the new email address.
  /// On success the local tokens/user are refreshed so the session survives.
  Future<String?> verifyEmailChange({
    required String code,
    required String newEmail,
  }) async {
    try {
      final response = await _authService.verifyEmailChange(
        code: code,
        newEmail: newEmail,
      );
      final savedMode = await _localDataSource.getUsageMode();
      final updatedUser = savedMode != null
          ? response.user.copyWith(preferredUsageMode: savedMode)
          : response.user;
      state = state.copyWith(user: updatedUser);
      await _localDataSource.saveUser(updatedUser);
      await _localDataSource.saveTokens(response.token);
      return null;
    } catch (e) {
      return _toMessage(e);
    }
  }

  Future<String?> updateProfile({
    String? fullName,
    String? email,
    String? phone,
  }) async {
    final currentUser = state.user;
    if (currentUser == null) return AppLocalizations.t('authErrNoUser');
    try {
      final token = await _localDataSource.getAccessToken();
      if (token != null && _authService.isTokenExpired(token)) {
        return AppLocalizations.t('authErrSessionGone');
      }
      final serverUser = await _authService.updateProfile(
        fullName: fullName,
        email: email,
        phone: phone,
      );
      final savedMode = await _localDataSource.getUsageMode();
      final updated = savedMode != null
          ? serverUser.copyWith(preferredUsageMode: savedMode)
          : serverUser;
      state = state.copyWith(user: updated);
      await _localDataSource.saveUser(updated);
      return null;
    } catch (e) {
      String msg = e.toString().replaceFirst('ApiException: ', '');
      msg = msg.replaceAll(RegExp(r'\s*\(status: [\dnull]+\)'), '');
      return msg;
    }
  }

  /// Adds/replaces the current user's phone number (validated server-side).
  /// On success the local user is refreshed with the new masked phone.
  /// Returns an error message on failure, null on success.
  Future<String?> updatePhone({
    required String phone,
    String? country,
  }) async {
    final currentUser = state.user;
    if (currentUser == null) return AppLocalizations.t('authErrNoUser');
    try {
      final token = await _localDataSource.getAccessToken();
      if (token != null && _authService.isTokenExpired(token)) {
        return AppLocalizations.t('authErrSessionGone');
      }
      final serverUser = await _authService.updatePhone(
        phone: phone,
        country: country,
        userId: currentUser.id,
      );
      final savedMode = await _localDataSource.getUsageMode();
      final merged = serverUser.copyWith(
        fullName: serverUser.fullName ?? currentUser.fullName,
        email: serverUser.email ?? currentUser.email,
      );
      final updated = savedMode != null
          ? merged.copyWith(preferredUsageMode: savedMode)
          : merged;
      state = state.copyWith(user: updated);
      await _localDataSource.saveUser(updated);
      return null;
    } catch (e) {
      String msg = e.toString().replaceFirst('ApiException: ', '');
      msg = msg.replaceAll(RegExp(r'\s*\(status: [\dnull]+\)'), '');
      return msg;
    }
  }

  /// Apply an in-place update to the current user model and persist it locally.
  /// Useful when the backend already confirmed a state change (e.g. trial activation)
  /// but the subsequent [refreshProfile] call might silently fail.
  void applyUserUpdate(UserModel Function(UserModel) updater) {
    final current = state.user;
    if (current == null) return;
    final updated = updater(current);
    state = state.copyWith(user: updated);
    _localDataSource.saveUser(updated);
  }

  void setError(String message) {
    state = state.copyWith(error: message, isLoading: false);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  Future<void> setUsageMode(String mode) async {
    state = state.copyWith(isLoading: true, forceUsageChoice: false);
    try {
      await _localDataSource.saveUsageMode(mode);
      final user = state.user;
      if (user != null) {
        final updatedUser = user.copyWith(preferredUsageMode: mode);
        state = state.copyWith(
          user: updatedUser,
          preferredUsageMode: mode,
          isLoading: false,
        );
      } else {
        state = state.copyWith(
          preferredUsageMode: mode,
          isLoading: false,
        );
      }
    } catch (_) {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<List<SessionModel>> getActiveSessions(String userId) async {
    // Errors MUST propagate (never collapse to []): the sessions page must
    // distinguish "fetch failed — keep the old list" from "zero sessions".
    return await _authService.getActiveSessions(userId);
  }

  Future<void> logoutSession(String sessionId) async {
    final userId = state.user?.id;
    if (userId != null) {
      await _authService.logoutSession(sessionId, userId);
    }
  }

  Future<void> forceLogoutAll({String? userId, String? excludeSessionId}) async {
    await _authService.forceLogoutAll(
      userId: userId,
      excludeSessionId: excludeSessionId,
    );
  }

  Future<void> updateSessionName(String sessionId, String customName) async {
    await _authService.updateSessionName(sessionId, customName);
  }
}
