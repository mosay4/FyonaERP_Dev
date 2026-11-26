import 'package:flutter/widgets.dart';

import '../../../core/localization/app_localizations.dart';
import 'auth2_models.dart';

/// Strings of the phone-first sign-in, trusted devices and approvals
/// (AR / EN). Kept beside the feature so tests need no ARB loading.
const Map<String, Map<String, String>> _strings = {
  'ar': {
    'welcome': 'مرحباً بعودتك',
    'loginSubtitle': 'سجّل الدخول برقم هاتفك',
    'phone': 'رقم الهاتف',
    'password': 'كلمة المرور',
    'confirmPassword': 'تأكيد كلمة المرور',
    'fullName': 'الاسم الكامل',
    'login': 'تسجيل الدخول',
    'or': 'أو',
    'google': 'المتابعة باستخدام Google',
    'apple': 'المتابعة باستخدام Apple',
    'createAccount': 'إنشاء حساب جديد',
    'forgot': 'نسيت كلمة المرور؟',
    'registerTitle': 'إنشاء حساب',
    'registerSubtitle': 'سنرسل رمز التحقق إلى واتساب على رقمك',
    'continue': 'متابعة',
    'haveAccount': 'لديك حساب؟ سجّل الدخول',
    'errName': 'أدخل اسمك الكامل',
    'errPhone': 'أدخل رقم هاتف صحيحاً',
    'errPassword': 'أدخل كلمة المرور',
    'errPasswordShort': 'كلمة المرور 8 أحرف على الأقل',
    'errMismatch': 'كلمتا المرور غير متطابقتين',
    'strengthWeak': 'ضعيفة',
    'strengthFair': 'متوسطة',
    'strengthGood': 'جيدة',
    'strengthStrong': 'قوية',
    'strengthHint': 'استخدم 8 أحرف أو أكثر مع أرقام وحروف ورموز',
    'countryTitle': 'اختر الدولة',
    'countrySearch': 'ابحث باسم الدولة أو الرمز',
    'otpTitle': 'أدخل رمز التحقق',
    'otpSubtitle': 'أرسلنا رمزاً من 6 أرقام إلى {phone}',
    'otpSubtitleDevice': 'افتح التطبيق على جهازك الأساسي ({device}) وأدخل الرمز الظاهر هناك',
    'otpPaste': 'لصق الرمز',
    'otpVerify': 'تحقق',
    'otpResend': 'إعادة الإرسال',
    'otpResendIn': 'إعادة الإرسال بعد {s} ث',
    'otpSendSms': 'إرسال الرمز برسالة SMS',
    'otpExpiresIn': 'ينتهي الرمز خلال {t}',
    'otpExpired': 'انتهت صلاحية الرمز. اطلب رمزاً جديداً.',
    'otpLocked': 'محاولات خاطئة كثيرة. اطلب رمزاً جديداً لاحقاً.',
    'otpWrong': 'الرمز غير صحيح',
    'otpWrongLeft': 'الرمز غير صحيح. المحاولات المتبقية: {n}',
    'stQueued': 'جارٍ إرسال الرمز عبر واتساب…',
    'stSent': 'أُرسل عبر واتساب',
    'stDelivered': 'وصل إلى واتساب',
    'stRead': 'تمت قراءته في واتساب',
    'stFailed': 'تعذّر الإرسال عبر واتساب',
    'stFallbackSms': 'لم يصل عبر واتساب — أرسلناه برسالة SMS',
    'stSms': 'أُرسل برسالة SMS',
    'stDevice': 'الرمز معروض الآن على جهازك الأساسي',
    'verifyDeviceTitle': 'تحقق من هذا الجهاز',
    'verifyDeviceSubtitle': 'هذا جهاز جديد على حسابك. اختر طريقة استلام رمز التحقق.',
    'optPrimary': 'جهازي الأساسي',
    'optPrimaryHint': 'يظهر الرمز داخل التطبيق على {device}',
    'optPrimaryHintNoName': 'يظهر الرمز داخل التطبيق على جهازك الأساسي',
    'optWhatsapp': 'واتساب',
    'optWhatsappHint': 'نرسل الرمز إلى واتساب على رقم حسابك',
    'socialPhoneTitle': 'أكمل حسابك',
    'socialPhoneSubtitle': 'أضف رقم هاتفك للمتابعة. سنرسل رمز تحقق إلى واتساب.',
    'forgotTitle': 'استعادة كلمة المرور',
    'forgotSubtitle': 'أدخل رقم هاتف حسابك وسنرسل لك رمز تحقق',
    'sendCode': 'إرسال الرمز',
    'newPasswordTitle': 'كلمة مرور جديدة',
    'newPassword': 'كلمة المرور الجديدة',
    'savePassword': 'حفظ كلمة المرور',
    'passwordChanged': 'تم تغيير كلمة المرور. سجّل الدخول بها الآن.',
    'deviceRevoked': 'تمت إزالة هذا الجهاز من حسابك. سجّل الدخول من جديد.',
    'socialCancelled': 'تم إلغاء تسجيل الدخول',
    'socialFailed': 'تعذّر تسجيل الدخول. حاول مرة أخرى.',
    'phoneTaken': 'هذا الرقم مرتبط بحساب آخر. سجّل الدخول بكلمة المرور ثم اربط الحساب.',
    'network': 'لا يوجد اتصال بالإنترنت',
    'genericError': 'حدث خطأ. حاول مرة أخرى.',
    'invalidCredentials': 'رقم الهاتف أو كلمة المرور غير صحيحة',
    'rateLimited': 'محاولات كثيرة. حاول بعد {s} ثانية.',
    // Approval
    'approvalTitle': 'محاولة تسجيل دخول',
    'approvalSubtitle': 'جهاز جديد يحاول الدخول إلى حسابك',
    'approvalDevice': 'الجهاز',
    'approvalOs': 'النظام',
    'approvalLocation': 'الموقع التقريبي',
    'approvalTime': 'الوقت',
    'approvalCode': 'رمز التحقق',
    'approvalExpiresIn': 'ينتهي خلال {t}',
    'approvalExpired': 'انتهت صلاحية هذا الطلب',
    'approvalDone': 'تم التعامل مع هذا الطلب',
    'approvalWarning': 'إذا لم تكن أنت من يحاول تسجيل الدخول، تجاهل هذه الرسالة ولا تشارك الرمز مع أي شخص',
    'approvalDeny': 'ليس أنا — رفض',
    'approvalClose': 'إغلاق',
    'approvalDenied': 'تم رفض محاولة الدخول',
    'approvalLoadingCode': 'جارٍ جلب الرمز بأمان…',
    'approvalsPageTitle': 'طلبات تسجيل الدخول',
    'approvalsEmpty': 'لا توجد طلبات معلّقة',
    'approvalNotifTitle': 'محاولة تسجيل دخول إلى حسابك',
    'approvalNotifBody': 'افتح التطبيق لمراجعة الطلب',
    // Devices
    'devicesTitle': 'الأجهزة الموثوقة',
    'devicesTile': 'الأجهزة الموثوقة',
    'devicesSubtitle': 'الأجهزة التي تدخل حسابك دون رمز تحقق',
    'devicePrimary': 'أساسي',
    'deviceCurrent': 'هذا الجهاز',
    'deviceTrusted': 'موثوق',
    'deviceUntrusted': 'غير موثوق',
    'deviceLastSeen': 'آخر نشاط: {t}',
    'deviceRename': 'إعادة التسمية',
    'deviceRevoke': 'إزالة الجهاز',
    'deviceMakePrimary': 'جعله الجهاز الأساسي',
    'deviceRevokeTitle': 'إزالة هذا الجهاز؟',
    'deviceRevokeBody': 'سيُسجَّل خروج {device} فوراً، ولن يدخل مجدداً إلا بعد التحقق.',
    'deviceMakePrimaryTitle': 'نقل الجهاز الأساسي؟',
    'deviceMakePrimaryBody': 'سيصبح {device} الجهاز الذي يستقبل رموز الدخول.',
    'deviceNameHint': 'اسم الجهاز',
    'save': 'حفظ',
    'cancel': 'إلغاء',
    'confirm': 'تأكيد',
    'retry': 'إعادة المحاولة',
    'lostPrimary': 'فقدت جهازي الأساسي',
    'lostPrimaryTitle': 'جعل هذا الجهاز أساسياً؟',
    'lostPrimaryBody': 'سيصبح هذا الجهاز أساسياً بعد 48 ساعة. يمكن للجهاز الأساسي الحالي إلغاء الطلب خلال هذه المدة.',
    'claimPending': 'هذا الجهاز سيصبح أساسياً في {t}',
    'claimCancel': 'إلغاء الطلب',
    'claimOther': 'جهاز آخر طلب أن يصبح أساسياً ({device})',
    'devicesEmpty': 'لا توجد أجهزة',
    // Phone change
    'changePhoneTile': 'تغيير رقم الهاتف',
    'changePhoneTitle': 'تغيير رقم الهاتف',
    'changePhoneReauth': 'لحماية حسابك، أدخل كلمة المرور الحالية',
    'changePhoneNew': 'أدخل الرقم الجديد. سنرسل رمز تحقق إليه عبر واتساب.',
    'changePhoneDone': 'تم تغيير رقم هاتفك بنجاح',
    'currentPhone': 'الرقم الحالي: {phone}',
    'done': 'تم',
  },
  'en': {
    'welcome': 'Welcome back',
    'loginSubtitle': 'Sign in with your phone number',
    'phone': 'Phone number',
    'password': 'Password',
    'confirmPassword': 'Confirm password',
    'fullName': 'Full name',
    'login': 'Sign in',
    'or': 'or',
    'google': 'Continue with Google',
    'apple': 'Continue with Apple',
    'createAccount': 'Create a new account',
    'forgot': 'Forgot password?',
    'registerTitle': 'Create account',
    'registerSubtitle': 'We will send a verification code to WhatsApp on your number',
    'continue': 'Continue',
    'haveAccount': 'Have an account? Sign in',
    'errName': 'Enter your full name',
    'errPhone': 'Enter a valid phone number',
    'errPassword': 'Enter your password',
    'errPasswordShort': 'Password must be at least 8 characters',
    'errMismatch': 'Passwords do not match',
    'strengthWeak': 'Weak',
    'strengthFair': 'Fair',
    'strengthGood': 'Good',
    'strengthStrong': 'Strong',
    'strengthHint': 'Use 8+ characters with letters, numbers and symbols',
    'countryTitle': 'Choose country',
    'countrySearch': 'Search by country or code',
    'otpTitle': 'Enter the verification code',
    'otpSubtitle': 'We sent a 6-digit code to {phone}',
    'otpSubtitleDevice': 'Open the app on your primary device ({device}) and enter the code shown there',
    'otpPaste': 'Paste code',
    'otpVerify': 'Verify',
    'otpResend': 'Resend',
    'otpResendIn': 'Resend in {s}s',
    'otpSendSms': 'Send the code by SMS',
    'otpExpiresIn': 'Code expires in {t}',
    'otpExpired': 'The code has expired. Request a new one.',
    'otpLocked': 'Too many wrong attempts. Request a new code later.',
    'otpWrong': 'Incorrect code',
    'otpWrongLeft': 'Incorrect code. Attempts left: {n}',
    'stQueued': 'Sending the code via WhatsApp…',
    'stSent': 'Sent via WhatsApp',
    'stDelivered': 'Delivered to WhatsApp',
    'stRead': 'Read in WhatsApp',
    'stFailed': 'Could not send via WhatsApp',
    'stFallbackSms': 'WhatsApp did not deliver — we sent it by SMS',
    'stSms': 'Sent by SMS',
    'stDevice': 'The code is now shown on your primary device',
    'verifyDeviceTitle': 'Verify this device',
    'verifyDeviceSubtitle': 'This is a new device on your account. Choose how to receive the code.',
    'optPrimary': 'My primary device',
    'optPrimaryHint': 'The code appears in the app on {device}',
    'optPrimaryHintNoName': 'The code appears in the app on your primary device',
    'optWhatsapp': 'WhatsApp',
    'optWhatsappHint': 'We send the code to WhatsApp on your account number',
    'socialPhoneTitle': 'Complete your account',
    'socialPhoneSubtitle': 'Add your phone number to continue. We will send a code to WhatsApp.',
    'forgotTitle': 'Reset password',
    'forgotSubtitle': 'Enter your account phone number and we will send you a code',
    'sendCode': 'Send code',
    'newPasswordTitle': 'New password',
    'newPassword': 'New password',
    'savePassword': 'Save password',
    'passwordChanged': 'Password changed. Sign in with it now.',
    'deviceRevoked': 'This device was removed from your account. Sign in again.',
    'socialCancelled': 'Sign-in cancelled',
    'socialFailed': 'Could not sign in. Try again.',
    'phoneTaken': 'This number belongs to another account. Sign in with its password, then link.',
    'network': 'No internet connection',
    'genericError': 'Something went wrong. Try again.',
    'invalidCredentials': 'Wrong phone number or password',
    'rateLimited': 'Too many attempts. Try again in {s} seconds.',
    'approvalTitle': 'Sign-in attempt',
    'approvalSubtitle': 'A new device is trying to sign in to your account',
    'approvalDevice': 'Device',
    'approvalOs': 'System',
    'approvalLocation': 'Approximate location',
    'approvalTime': 'Time',
    'approvalCode': 'Verification code',
    'approvalExpiresIn': 'Expires in {t}',
    'approvalExpired': 'This request has expired',
    'approvalDone': 'This request was already handled',
    'approvalWarning': 'If this is not you trying to sign in, ignore this message and never share the code with anyone',
    'approvalDeny': 'Not me — deny',
    'approvalClose': 'Close',
    'approvalDenied': 'Sign-in attempt denied',
    'approvalLoadingCode': 'Fetching the code securely…',
    'approvalsPageTitle': 'Sign-in requests',
    'approvalsEmpty': 'No pending requests',
    'approvalNotifTitle': 'Sign-in attempt on your account',
    'approvalNotifBody': 'Open the app to review the request',
    'devicesTitle': 'Trusted devices',
    'devicesTile': 'Trusted devices',
    'devicesSubtitle': 'Devices that sign in without a verification code',
    'devicePrimary': 'Primary',
    'deviceCurrent': 'This device',
    'deviceTrusted': 'Trusted',
    'deviceUntrusted': 'Not trusted',
    'deviceLastSeen': 'Last active: {t}',
    'deviceRename': 'Rename',
    'deviceRevoke': 'Remove device',
    'deviceMakePrimary': 'Make primary',
    'deviceRevokeTitle': 'Remove this device?',
    'deviceRevokeBody': '{device} will be signed out now and needs verification to sign in again.',
    'deviceMakePrimaryTitle': 'Move the primary device?',
    'deviceMakePrimaryBody': '{device} will receive the sign-in codes.',
    'deviceNameHint': 'Device name',
    'save': 'Save',
    'cancel': 'Cancel',
    'confirm': 'Confirm',
    'retry': 'Retry',
    'lostPrimary': 'I lost my primary device',
    'lostPrimaryTitle': 'Make this device primary?',
    'lostPrimaryBody': 'This device becomes primary after 48 hours. The current primary device can cancel during that time.',
    'claimPending': 'This device becomes primary on {t}',
    'claimCancel': 'Cancel request',
    'claimOther': 'Another device asked to become primary ({device})',
    'devicesEmpty': 'No devices',
    'changePhoneTile': 'Change phone number',
    'changePhoneTitle': 'Change phone number',
    'changePhoneReauth': 'To protect your account, enter your current password',
    'changePhoneNew': 'Enter the new number. We will send a code to it via WhatsApp.',
    'changePhoneDone': 'Your phone number was changed',
    'currentPhone': 'Current number: {phone}',
    'done': 'Done',
  },
};

String _lookup(String lang, String key, Map<String, Object?>? params) {
  var text = _strings[lang]?[key] ?? _strings['ar']![key] ?? key;
  params?.forEach((k, v) => text = text.replaceAll('{$k}', '$v'));
  return text;
}

/// Context-aware lookup (follows the widget tree's locale).
String a2(BuildContext context, String key, [Map<String, Object?>? params]) {
  final lang = Localizations.maybeLocaleOf(context)?.languageCode ??
      AppLocalizations.currentLanguage;
  return _lookup(lang == 'en' ? 'en' : 'ar', key, params);
}

/// Context-free lookup (providers / services).
String auth2T(String key, [Map<String, Object?>? params]) =>
    _lookup(AppLocalizations.currentLanguage == 'en' ? 'en' : 'ar', key, params);

bool _isEn() => AppLocalizations.currentLanguage == 'en';

/// The user-facing text of an auth2 error: the server's own localized
/// message first, then a local fallback per code.
String auth2ErrorText(Auth2Exception e, {String? lang}) {
  final en = lang != null ? lang == 'en' : _isEn();
  final server = en ? e.messageEn : e.messageAr;
  if (server != null && server.trim().isNotEmpty) return server.trim();
  final other = en ? e.messageAr : e.messageEn;
  final l = en ? 'en' : 'ar';
  switch (e.code) {
    case 'network':
      return _lookup(l, 'network', null);
    case 'invalid_credentials':
      return _lookup(l, 'invalidCredentials', null);
    case 'invalid_code':
    case 'wrong_code':
      return _lookup(l, 'otpWrong', null);
    case 'expired':
    case 'challenge_expired':
      return _lookup(l, 'otpExpired', null);
    case 'locked':
    case 'challenge_locked':
      return _lookup(l, 'otpLocked', null);
    case 'phone_taken':
      return _lookup(l, 'phoneTaken', null);
    case 'device_revoked':
      return _lookup(l, 'deviceRevoked', null);
    case 'rate_limited':
    case 'too_many_requests':
      return _lookup(l, 'rateLimited', {'s': e.retryAfter ?? 60});
  }
  if (other != null && other.trim().isNotEmpty) return other.trim();
  return _lookup(l, 'genericError', null);
}

/// Context-aware variant for widgets.
String auth2ErrorTextOf(BuildContext context, Object e) {
  final lang = Localizations.maybeLocaleOf(context)?.languageCode ?? 'ar';
  if (e is Auth2Exception) return auth2ErrorText(e, lang: lang);
  return _lookup(lang == 'en' ? 'en' : 'ar', 'genericError', null);
}
