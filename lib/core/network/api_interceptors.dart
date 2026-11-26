import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../storage/secure_storage.dart';
import '../security/device_identity.dart';
import '../../features/personal/data/ledger/personal_local_cutover.dart';

/// Real device identity for session recognition (cached after first read so
/// no request ever waits on platform channels). Falls back to the plain OS
/// name when the platform reports nothing (tests, emulators without host).
class DeviceIdentity {
  static const _fallbackKey = 'device_fingerprint_fallback';

  static String? _name;
  static String? _model;
  static String? _os;
  static String? _fingerprint;
  static String? _appVersion;
  static bool _warming = false;

  /// Fire-and-forget warmup, call once at app start.
  static void warm() {
    if (_warming || (_name != null && _fingerprint != null)) return;
    _warming = true;
    refresh().whenComplete(() => _warming = false);
  }

  static Future<void> refresh() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      final v = pkg.version.trim();
      final b = pkg.buildNumber.trim();
      if (v.isNotEmpty) _appVersion = b.isNotEmpty ? '$v+$b' : v;
    } catch (_) {}
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        final model = info.model.trim();
        final manufacturer = info.manufacturer.trim();
        final release = info.version.release.trim();
        _model = model.isNotEmpty ? model : null;
        _os = release.isNotEmpty ? 'Android $release' : 'Android';
        final pretty = [
          if (manufacturer.isNotEmpty) manufacturer,
          if (model.isNotEmpty) model,
        ].join(' ').trim();
        _name = pretty.isNotEmpty ? pretty : 'Android';
        final androidId = info.id.trim();
        if (androidId.isNotEmpty) _fingerprint = 'android:$androidId';
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final machine = info.utsname.machine.trim();
        final ver = info.systemVersion.trim();
        _model = machine.isNotEmpty ? machine : null;
        _os = ver.isNotEmpty ? 'iOS $ver' : 'iOS';
        _name = machine.isNotEmpty ? machine : 'iPhone';
        final vendor = info.identifierForVendor?.trim() ?? '';
        if (vendor.isNotEmpty) _fingerprint = 'ios:$vendor';
      }
    } catch (_) {
      // Platform channels unavailable (tests) — keep fallbacks.
    }
    // Stable persisted fallback so THIS device is recognizable even where
    // the platform exposes no stable id.
    if (_fingerprint == null || _fingerprint!.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        var saved = prefs.getString(_fallbackKey);
        if (saved == null || saved.isEmpty) {
          saved =
              'app:${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
          await prefs.setString(_fallbackKey, saved);
        }
        _fingerprint = saved;
      } catch (_) {}
    }
  }

  static String get name => _name ?? _fallbackName();
  static String? get model => _model;
  static String? get os => _os;

  /// App version as "1.2.3+45" (null until warmed / in tests).
  static String? get appVersion => _appVersion;

  /// Platform family reported with every request (android, ios, …).
  static String get platform {
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Stable per-device id, or null until warmed (tests / first launch).
  static String? get fingerprint => _fingerprint;

  static String _fallbackName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }

  /// Test seam: reset cached identity.
  static void debugReset() {
    _name = null;
    _model = null;
    _os = null;
    _fingerprint = null;
    _appVersion = null;
    _warming = false;
  }
}

class AuthInterceptor extends Interceptor {
  final SecureStorageService _secureStorage;

  AuthInterceptor(this._secureStorage);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _secureStorage.getToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    try {
      final refresh = await _secureStorage.getRefreshToken();
      if (refresh != null && refresh.isNotEmpty) {
        // Lets the server mark THIS session as current (sessions list) and
        // lets /auth/logout deactivate exactly this session.
        options.headers['X-Refresh-Token'] = refresh;
      }
    } catch (_) {}
    options.headers['X-Device-Name'] = DeviceIdentity.name;
    final model = DeviceIdentity.model;
    if (model != null && model.isNotEmpty) {
      options.headers['X-Device-Model'] = model;
    }
    final os = DeviceIdentity.os;
    if (os != null && os.isNotEmpty) {
      options.headers['X-Device-OS'] = os;
    }
    final fingerprint = DeviceIdentity.fingerprint;
    if (fingerprint != null && fingerprint.isNotEmpty) {
      options.headers['X-Device-Fingerprint'] = fingerprint;
    }
    // App version + platform: shown per device on the sessions screen.
    final appVersion = DeviceIdentity.appVersion;
    if (appVersion != null && appVersion.isNotEmpty) {
      options.headers['X-App-Version'] = appVersion;
    }
    options.headers['X-Device-Platform'] = DeviceIdentity.platform;
    // Trusted-device identity (auth2): stable random id per install.
    final deviceId = DeviceKeyIdentity.cachedDeviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      options.headers['X-Device-Id'] = deviceId;
    }
    // Device-only Personal builds say so: the server answers older builds
    // «update the app» instead of letting them sync Personal data.
    if (PersonalLocalMode.active) {
      options.headers[PersonalLocalMode.protocolHeader] = PersonalLocalMode.protocol;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (PersonalLocalMode.refusalCode(err.response?.data) ==
        PersonalLocalMode.codeUpdate) {
      PersonalLocalMode.notice.value = PersonalLocalNotice.updateRequired;
    }
    handler.next(err);
  }
}
