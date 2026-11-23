import 'directory_pilot_build.dart';

class AppConfig {
  AppConfig._();

  static const String appName = 'FYONA ERP';
  static const String appVersion = '1.0.0';
  static const String appDescription = 'FYONA Business Suite';
  static const String defaultCurrency = 'SAR';
  static const String defaultLocale = 'ar';

  // ── API ──
  // Override at build time: flutter build apk --dart-define=API_BASE_URL=https://api.yourdomain.com/api/v1
  // Port 80 by default: mobile networks and public hotspots routinely filter
  // unusual outbound ports (the backend also serves 8001).
  static const _defaultApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://187.7.30.197:80/api/v1',
  );
  static String get apiBaseUrl =>
      DirectoryPilotBuild.enabled ? DirectoryPilotBuild.baseUrl : _defaultApiBaseUrl;

  /// Runtime override (server address screen): any LAN device can point the
  /// app at the local backend without rebuilding. Persisted in
  /// SharedPreferences, applied before runApp and on every change.
  static String? _overrideBaseUrl;
  static String get effectiveApiBaseUrl => _overrideBaseUrl ?? apiBaseUrl;
  static set overrideBaseUrl(String? v) {
    if (!DirectoryPilotBuild.enabled || v == null || v == apiBaseUrl) {
      _overrideBaseUrl = v;
    }
  }

  static const int apiTimeoutSeconds = 30;
  static const int apiConnectTimeoutSeconds = 15;
  static const int apiReceiveTimeoutSeconds = 30;

  /// Root host URL (without the `/api/v1` prefix). Used for assets served at
  /// the server root such as `/uploads/...` (the files router is mounted
  /// without a prefix on the backend).
  static String get apiHostUrl {
    final base = effectiveApiBaseUrl;
    const suffix = '/api/v1';
    if (base.endsWith(suffix)) return base.substring(0, base.length - suffix.length);
    return base;
  }

  // ── Auth ──
  static const int accessTokenExpiryMinutes = 60;
  static const int refreshTokenExpiryDays = 7;
  static const int passwordMinLength = 8;
  static const int passwordMaxAgeDays = 90;
  static const int loginMaxAttempts = 5;
  static const int loginLockoutMinutes = 30;

  // ── Pagination ──
  static const int defaultPageSize = 20;
  static const int maxPageSize = 100;

  // ── Cache ──
  static const int cacheTtlSeconds = 300;

  // ── File ──
  static const int maxFileSizeBytes = 50 * 1024 * 1024; // 50 MB
  static const int defaultStorageQuotaBytes = 500 * 1024 * 1024; // 500 MB

  // ── Receipt ──
  static const double receiptMinFontSize = 16;
  static const double receiptPadding = 16;
}
