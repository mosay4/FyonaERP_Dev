import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class AppLocalizations {
  final Locale locale;
  late Map<String, dynamic> _strings;

  /// Cached decoded ARB tables so the bundle is read once per locale.
  static final Map<String, Map<String, dynamic>> _stringCache = {};

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('ar'),
    Locale('en'),
  ];

  static List<LocalizationsDelegate> get localizationsDelegates => [
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ];

  /// Pre-cache an ARB table so the app can start in the correct locale
  /// without waiting for the delegate to fire.
  static Future<void> preload(String languageCode) async {
    if (_stringCache.containsKey(languageCode)) return;
    try {
      final jsonString = await rootBundle.loadString('assets/l10n/app_$languageCode.arb');
      final decoded = json.decode(jsonString) as Map<String, dynamic>;
      _stringCache[languageCode] = decoded;
    } catch (_) {}
  }

  Future<void> load() async {
    final localeName = locale.languageCode;
    final cached = _stringCache[localeName];
    if (cached != null) {
      _strings = cached;
      return;
    }
    final path = 'assets/l10n/app_$localeName.arb';
    try {
      final jsonString = await rootBundle.loadString(path);
      final decoded = json.decode(jsonString) as Map<String, dynamic>;
      _strings = decoded;
      _stringCache[localeName] = decoded;
    } catch (_) {
      _strings = {};
    }
  }

  String translate(String key, {Map<String, dynamic>? params}) {
    final value = _strings[key];
    if (value == null) return key;

    String result = value.toString();
    if (params != null) {
      params.forEach((k, v) {
        result = result.replaceAll('{$k}', v.toString());
      });
    }
    return result;
  }

  String? translateOptional(String key) => _strings[key]?.toString();

  /// Last language pushed via [setStaticLanguage] (mirrors [LocaleNotifier]).
  static String _staticLang = 'ar';

  /// Current application language code ('ar' | 'en').
  static String get currentLanguage => _staticLang;

  /// Read-only view of a preloaded ARB table (null when not loaded yet).
  /// Used by the Information Clicker to map a visible label back to its
  /// key, so help survives wording changes in the .arb files.
  static Map<String, dynamic>? cachedTable(String languageCode) =>
      _stringCache[languageCode];

  /// Keeps the static lookup below in sync with the app language.
  /// Called from [LocaleNotifier] on every change (see locale_provider.dart).
  static void setStaticLanguage(String languageCode) {
    _staticLang = languageCode;
  }

  /// Context-free lookup for providers/services/validators that have no
  /// [BuildContext]. Uses the last synced language; falls back to Arabic
  /// (today's behavior) when the other table isn't cached yet.
  static String t(String key, [Map<String, dynamic>? params]) {
    final table = _stringCache[_staticLang] ?? _stringCache['ar'];
    final value = table?[key];
    if (value == null) return key;
    var result = value.toString();
    params?.forEach((k, v) {
      result = result.replaceAll('{$k}', v.toString());
    });
    return result;
  }

  List<String> translateList(String key) {
    final value = _strings[key];
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String) return [value];
    return [];
  }

  // ── Convenience Getters ──

  String get appName => translate('appName');
  String get appTagline => translate('appTagline');

  // Auth
  String get login => translate('login');
  String get register => translate('register');
  String get logout => translate('logout');
  String get forgotPassword => translate('forgotPassword');
  String get resetPassword => translate('resetPassword');
  String get email => translate('email');
  String get password => translate('password');
  String get confirmPassword => translate('confirmPassword');
  String get username => translate('username');
  String get fullName => translate('fullName');
  String get phone => translate('phone');

  // Login
  String get welcomeBack => translate('welcomeBack');
  String get loginSubtitle => translate('loginSubtitle');
  String get requiredPhone => translate('requiredPhone');
  String get requiredPassword => translate('requiredPassword');
  String get loginButton => translate('loginButton');
  String get createAccount => translate('createAccount');
  String get forgotPasswordLink => translate('forgotPasswordLink');

  // Language
  String get language => translate('language');
  String get arabic => translate('arabic');
  String get english => translate('english');
  String get switchToEnglish => translate('switchToEnglish');
  String get switchToArabic => translate('switchToArabic');

  // Biometric
  String get biometricNotSaved => translate('biometricNotSaved');
  String get biometricLocked => translate('biometricLocked');
  String get biometricReasonLogin => translate('biometricReasonLogin');

  // Device
  String get forgetThisDevice => translate('forgetThisDevice');
  String get deviceForgotten => translate('deviceForgotten');
  String get forgetDeviceConfirmTitle => translate('forgetDeviceConfirmTitle');
  String get forgetDeviceConfirmBody => translate('forgetDeviceConfirmBody');
  String get pressBackAgainToExit => translate('pressBackAgainToExit');

  // Lock screen
  String get lockScreenTitle => translate('lockScreenTitle');
  String get lockScreenSubtitle => translate('lockScreenSubtitle');
  String get unlockWithBiometric => translate('unlockWithBiometric');
  String get unlock => translate('unlock');
  String get unlockPasswordHint => translate('unlockPasswordHint');
  String get wrongPassword => translate('wrongPassword');
  String get reentryTitle => translate('reentryTitle');
  String get reentrySubtitle => translate('reentrySubtitle');
  String get useAnotherAccount => translate('useAnotherAccount');
  String get reentryPasswordHint => translate('reentryPasswordHint');
  String get reentryPasswordHelp => translate('reentryPasswordHelp');

  // Session timeout
  String get sessionTimeout => translate('sessionTimeout');
  String get sessionTimeoutSubtitle => translate('sessionTimeoutSubtitle');
  String get timeout15 => translate('timeout15');
  String get timeout30 => translate('timeout30');
  String get timeout1h => translate('timeout1h');
  String get timeout2h => translate('timeout2h');
  String get timeout4h => translate('timeout4h');
  String get timeout8h => translate('timeout8h');
  String get timeout12h => translate('timeout12h');
  String get timeout24h => translate('timeout24h');
  String get timeoutNever => translate('timeoutNever');

  // Navigation
  String get home => translate('home');
  String get dashboard => translate('dashboard');
  String get customers => translate('customers');
  String get suppliers => translate('suppliers');
  String get products => translate('products');
  String get inventory => translate('inventory');
  String get sales => translate('sales');
  String get purchases => translate('purchases');
  String get payments => translate('payments');
  String get expenses => translate('expenses');
  String get accounting => translate('accounting');
  String get reports => translate('reports');
  String get settings => translate('settings');
  String get profile => translate('profile');
  String get notifications => translate('notifications');
  String get subscription => translate('subscription');

  // Common Actions
  String get save => translate('save');
  String get cancel => translate('cancel');
  String get delete => translate('delete');
  String get edit => translate('edit');
  String get add => translate('add');
  String get search => translate('search');
  String get filter => translate('filter');
  String get clear => translate('clear');
  String get confirm => translate('confirm');
  String get loading => translate('loading');
  String get noData => translate('noData');
  String get errorOccurred => translate('errorOccurred');
  String get retry => translate('retry');
  String get success => translate('success');
  String get warning => translate('warning');
  String get error => translate('error');
  String get info => translate('info');

  // Validation
  String get required => translate('required');
  String get invalidEmail => translate('invalidEmail');
  String get invalidPhone => translate('invalidPhone');
  String get passwordTooShort => translate('passwordTooShort');
  String get passwordMismatch => translate('passwordMismatch');

  String statusText(String status) {
    final key = 'status_$status';
    return translateOptional(key) ?? status;
  }

  // Subscription
  String get trial => translate('trial');
  String get personal => translate('personal');
  String get business => translate('business');
  String get premium => translate('premium');

  // Errors
  String get sessionExpired => translate('sessionExpired');
  String get unauthorized => translate('unauthorized');
  String get networkError => translate('networkError');
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ar', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final localizations = AppLocalizations(locale);
    await localizations.load();
    return localizations;
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
