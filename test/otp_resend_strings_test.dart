import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

/// Resend-gate strings must resolve in both languages (used by the
/// forgot-password countdown button + resend snackbar).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppLocalizations.preload('ar');
    await AppLocalizations.preload('en');
  });

  String t(String lang, String key, [Map<String, dynamic>? params]) {
    final prev = AppLocalizations.currentLanguage;
    AppLocalizations.setStaticLanguage(lang);
    try {
      return AppLocalizations.t(key, params);
    } finally {
      AppLocalizations.setStaticLanguage(prev);
    }
  }

  group('otp resend strings', () {
    test('arabic resolves with countdown param', () {
      final label = t('ar', 'resendOtpIn', {'seconds': '45'});
      expect(label.contains('45'), isTrue, reason: 'got: $label');
      expect(label, isNot('resendOtpIn'));
      expect(t('ar', 'otpResentOk'), isNot('otpResentOk'));
    });

    test('english resolves with countdown param', () {
      final label = t('en', 'resendOtpIn', {'seconds': '45'});
      expect(label.contains('45'), isTrue, reason: 'got: $label');
      expect(label, isNot('resendOtpIn'));
      expect(t('en', 'otpResentOk'), isNot('otpResentOk'));
    });
  });

  group('auth error keys (forgot-password mapping targets)', () {
    test('invalid otp resolves to the exact required Arabic', () {
      expect(t('ar', 'authErrInvalidOtp'), 'رمز التحقق غير صالح');
      expect(t('en', 'authErrInvalidOtp'), 'Invalid verification code');
    });

    test('not-registered + external-login resolve both languages', () {      final arNotReg = t('ar', 'authErrEmailNotRegistered');
      expect(arNotReg, isNot('authErrEmailNotRegistered'));
      expect(arNotReg.contains('غير مسجل'), isTrue);
      final enNotReg = t('en', 'authErrEmailNotRegistered');
      expect(enNotReg, isNot('authErrEmailNotRegistered'));

      final arExt = t('ar', 'authErrExternalLogin');
      expect(arExt, isNot('authErrExternalLogin'));
      expect(arExt.contains('تسجيل دخول خارجي'), isTrue);
      final enExt = t('en', 'authErrExternalLogin');
      expect(enExt, isNot('authErrExternalLogin'));
    });

    test('google-account message resolves both languages', () {
      final ar = t('ar', 'authErrGoogleAccount');
      expect(ar, isNot('authErrGoogleAccount'));
      expect(ar.contains('Google'), isTrue,
          reason: 'page detection relies on the brand marker');
      final en = t('en', 'authErrGoogleAccount');
      expect(en, isNot('authErrGoogleAccount'));
      expect(en.contains('Google'), isTrue);
    });
  });
}
