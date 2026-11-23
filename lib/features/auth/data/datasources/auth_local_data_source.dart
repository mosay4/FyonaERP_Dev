import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../../core/storage/secure_storage.dart';
import '../../../../shared/models/user_model.dart';
import '../models/token_response.dart';

class AuthLocalDataSource {
  final SecureStorageService _storage;
  final FlutterSecureStorage _secureStorage;

  AuthLocalDataSource({required this._storage})
      : _secureStorage = const FlutterSecureStorage();

  Future<void> saveTokens(TokenResponse token) async {
    await _storage.saveToken(token.accessToken);
    if (token.refreshToken != null) {
      await _storage.saveRefreshToken(token.refreshToken!);
    }
  }

  Future<String?> getAccessToken() => _storage.getToken();

  Future<String?> getRefreshToken() => _storage.getRefreshToken();

  Future<void> saveUser(UserModel user) async {
    final json = jsonEncode(user.toJson());
    await _storage.saveUserData(json);
  }

  Future<UserModel?> getUser() async {
    final data = await _storage.getUserData();
    if (data == null) return null;
    try {
      return UserModel.fromJson(jsonDecode(data) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRememberMe(bool value) async {
    await _secureStorage.write(key: 'remember_me', value: value.toString());
  }

  Future<bool> getRememberMe() async {
    final value = await _secureStorage.read(key: 'remember_me');
    return value == 'true';
  }

  Future<void> saveUsername(String username) async {
    await _secureStorage.write(key: 'saved_username', value: username);
  }

  Future<String?> getSavedUsername() async {
    return await _secureStorage.read(key: 'saved_username');
  }

  Future<void> clearSavedUsername() async {
    await _secureStorage.delete(key: 'saved_username');
  }

  Future<void> clearRememberedDevice() async {
    await _secureStorage.delete(key: 'saved_username');
    await _secureStorage.delete(key: 'biometric_enabled');
    await _secureStorage.delete(key: 'biometric_email');
    await _secureStorage.delete(key: 'biometric_password');
  }

  Future<void> clearAuth() async {
    await _storage.deleteToken();
    await _storage.deleteRefreshToken();
    await _storage.deleteUserData();
  }

  Future<void> clearAll() => _storage.clearAll();

  Future<bool> hasSession() async {
    final token = await _storage.getToken();
    return token != null && token.isNotEmpty;
  }

  Future<void> saveBiometricEnabled(bool value) async {
    await _secureStorage.write(key: 'biometric_enabled', value: value.toString());
  }

  Future<bool> getBiometricEnabled() async {
    final value = await _secureStorage.read(key: 'biometric_enabled');
    return value == 'true';
  }

  Future<void> clearBiometric() async {
    await _secureStorage.delete(key: 'biometric_enabled');
  }

  Future<void> clearBiometricAll() async {
    await _secureStorage.delete(key: 'biometric_enabled');
    await _secureStorage.delete(key: 'biometric_email');
    await _secureStorage.delete(key: 'biometric_password');
    await _secureStorage.delete(key: 'bio_snapshot_access');
    await _secureStorage.delete(key: 'bio_snapshot_refresh');
    await _secureStorage.delete(key: 'bio_snapshot_user');
    await _secureStorage.delete(key: 'bio_snapshot_mode');
  }

  /// Fingerprint-gated session snapshot: lets a fingerprint restore the
  /// account directly (online AND offline) without email/password.
  /// Only ever used after a successful device biometric check.
  Future<void> saveBiometricSnapshot({
    required String accessToken,
    String? refreshToken,
    required String userJson,
    String? usageMode,
  }) async {
    await _secureStorage.write(key: 'bio_snapshot_access', value: accessToken);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _secureStorage.write(key: 'bio_snapshot_refresh', value: refreshToken);
    } else {
      await _secureStorage.delete(key: 'bio_snapshot_refresh');
    }
    await _secureStorage.write(key: 'bio_snapshot_user', value: userJson);
    if (usageMode != null && usageMode.isNotEmpty) {
      await _secureStorage.write(key: 'bio_snapshot_mode', value: usageMode);
    } else {
      await _secureStorage.delete(key: 'bio_snapshot_mode');
    }
  }

  Future<String?> getBiometricSnapshotAccess() =>
      _secureStorage.read(key: 'bio_snapshot_access');

  Future<String?> getBiometricSnapshotRefresh() =>
      _secureStorage.read(key: 'bio_snapshot_refresh');

  Future<String?> getBiometricSnapshotUser() =>
      _secureStorage.read(key: 'bio_snapshot_user');

  Future<String?> getBiometricSnapshotMode() =>
      _secureStorage.read(key: 'bio_snapshot_mode');

  Future<bool> hasBiometricSnapshot() async {
    final access = await _secureStorage.read(key: 'bio_snapshot_access');
    final user = await _secureStorage.read(key: 'bio_snapshot_user');
    return access != null &&
        access.isNotEmpty &&
        user != null &&
        user.isNotEmpty;
  }

  Future<void> clearBiometricSnapshot() async {
    await _secureStorage.delete(key: 'bio_snapshot_access');
    await _secureStorage.delete(key: 'bio_snapshot_refresh');
    await _secureStorage.delete(key: 'bio_snapshot_user');
    await _secureStorage.delete(key: 'bio_snapshot_mode');
  }

  Future<void> saveBiometricCredentials({required String email, required String password}) async {
    await _secureStorage.write(key: 'biometric_email', value: email);
    await _secureStorage.write(key: 'biometric_password', value: password);
  }

  Future<String?> getBiometricEmail() => _secureStorage.read(key: 'biometric_email');
  Future<String?> getBiometricPassword() => _secureStorage.read(key: 'biometric_password');

  Future<void> saveUsageMode(String mode) async {
    await _secureStorage.write(key: 'usage_mode', value: mode);
  }

  Future<String?> getUsageMode() async {
    return await _secureStorage.read(key: 'usage_mode');
  }

  Future<void> clearUsageMode() async {
    await _secureStorage.delete(key: 'usage_mode');
  }

  static const sessionTimeoutKey = 'session_timeout_minutes';
  static const sessionTimeoutNever = 'never';
  static const sessionTimeoutDefaultMinutes = 15;

  Future<void> saveSessionTimeoutMinutes(Duration? duration) async {
    if (duration == null) {
      await _secureStorage.write(key: sessionTimeoutKey, value: sessionTimeoutNever);
    } else {
      await _secureStorage.write(key: sessionTimeoutKey, value: duration.inMinutes.toString());
    }
  }

  /// Stored raw preference: null (not set yet), 'never', or a minutes number.
  Future<String?> getSessionTimeoutPreference() async {
    return _secureStorage.read(key: sessionTimeoutKey);
  }

  /// Resolves the stored preference into an effective duration.
  /// Disabled by default: nothing stored means the timeout is OFF until the
  /// user explicitly enables it (and creates an app PIN).
  Future<Duration?> getSessionTimeoutDuration() async {
    final value = await _secureStorage.read(key: sessionTimeoutKey);
    if (value == null) return null;
    if (value == sessionTimeoutNever) return null;
    final minutes = int.tryParse(value);
    if (minutes == null || minutes <= 0) return null;
    return Duration(minutes: minutes);
  }

  static const _appPinKey = 'app_pin';

  Future<void> saveAppPin(String record) async {
    await _secureStorage.write(key: _appPinKey, value: record);
  }

  Future<String?> getAppPin() async {
    try {
      return await _secureStorage.read(key: _appPinKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearAppPin() async {
    try {
      await _secureStorage.delete(key: _appPinKey);
    } catch (_) {}
  }
}
