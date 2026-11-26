import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_flow.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_models.dart';
import 'package:fyona_flutter/core/security/device_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/auth2_fakes.dart';
import '../test_utils.dart';

Future<void> _typePhone(WidgetTester tester, String national) async {
  await tester.enterText(find.byKey(const Key('phone_input')), national);
  await tester.pump();
}

Future<void> _pickCountry(WidgetTester tester, String code, {String? search}) async {
  await tester.tap(find.byKey(const Key('country_button')));
  await pumpFor(tester);
  if (search != null) {
    await tester.enterText(find.byKey(const Key('country_search')), search);
    await tester.pump();
  }
  await tester.tap(find.byKey(Key('country_$code')));
  await pumpFor(tester);
}

Future<void> _typeCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('otp_input')), code);
  await pumpFor(tester);
}

void testWidgetsOn(TargetPlatform platform, String description, WidgetTesterCallback body) =>
    testWidgets(description, body, variant: TargetPlatformVariant.only(platform));

void main() {
  setUpAll(() async {
    await ensureTestLocalization('en');
    await ensureTestLocalization('ar');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgetsOn(TargetPlatform.android, 'register → OTP (WhatsApp status) → signed in as primary', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester, initial: RouteNames.register);

    await tester.enterText(find.byKey(const Key('name_input')), 'Sara Ali');
    await _pickCountry(tester, 'YE', search: '967');
    await _typePhone(tester, '0771234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'Secret#2026xyz');
    await tester.pump();
    expect(find.textContaining('Strong'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('confirm_input')), 'Secret#2026xyz');
    await tester.tap(find.byKey(const Key('register_submit')));
    await pumpFor(tester);

    final start = h.api.last('registerStart');
    expect(start.args['phone'], '+967771234567', reason: 'trunk 0 stripped, E.164');
    expect((start.args['device'] as Map)['public_key'], isNotEmpty);
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.authOtp);
    // Live channel status from /otp/status.
    expect(find.text('Delivered to WhatsApp'), findsOneWidget);
    expect(find.byKey(const Key('otp_sms')), findsNothing, reason: 'server did not allow SMS');

    await _typeCode(tester, '123456');
    final verify = h.api.last('registerVerify');
    expect(verify.args['nonce'], startsWith('nonce-'));
    expect(
      h.identity.signed.last,
      DeviceKeyIdentity.proofMessage(
          nonce: verify.args['nonce'] as String, deviceId: h.identity.id, purpose: 'register_verify'),
    );
    expect(h.auth.completed, hasLength(1));
    expect(h.auth.lastUsageMode, 'personal');
    expect(find.text('HOME'), findsOneWidget);
    await pumpFor(tester, const Duration(seconds: 1));
  });

  testWidgetsOn(TargetPlatform.android, 'register: mismatching passwords never reach the server', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester, initial: RouteNames.register);
    await tester.enterText(find.byKey(const Key('name_input')), 'Sara');
    await _typePhone(tester, '771234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'Secret#2026');
    await tester.enterText(find.byKey(const Key('confirm_input')), 'Other#2026');
    await tester.tap(find.byKey(const Key('register_submit')));
    await pumpFor(tester);
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(h.api.names(), isNot(contains('registerStart')));
  });

  testWidgetsOn(TargetPlatform.android, 'login on a trusted device goes straight in (with a device proof)', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester);
    await _pickCountry(tester, 'SA', search: 'Saudi');
    expect(find.text('+966'), findsOneWidget);
    await _typePhone(tester, '501234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'pw-123456');
    await tester.tap(find.byKey(const Key('login_button')));
    await pumpFor(tester);

    final login = h.api.last('login');
    expect(login.args['phone'], '+966501234567');
    expect(login.args['signature'],
        FakeDeviceKeyIdentity.fakeSignature(DeviceKeyIdentity.proofMessage(
            nonce: login.args['nonce'] as String, deviceId: h.identity.id, purpose: 'login')));
    expect(find.text('HOME'), findsOneWidget);
    expect(h.api.names(), isNot(contains('loginVerifyStart')));
  });

  testWidgetsOn(TargetPlatform.android, 'wrong password shows the error and stays on login', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester);
    await _typePhone(tester, '771234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'wrong');
    await tester.tap(find.byKey(const Key('login_button')));
    await pumpFor(tester);
    expect(find.byKey(const Key('auth2_error')), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgetsOn(TargetPlatform.android, 'new device: primary device is the default option and shows its name', (tester) async {
    final h = Auth2Harness();
    h.api.loginResult = const Auth2NeedsVerification(DeviceVerification(
      verificationId: 'ver-1',
      options: ['device', 'whatsapp'],
      primaryDevice: PrimaryDeviceRef(name: 'Galaxy S24', model: 'SM-S921B'),
    ));
    await h.pump(tester);
    await _typePhone(tester, '771234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'pw-123456');
    await tester.tap(find.byKey(const Key('login_button')));
    await pumpFor(tester);

    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.verifyDevice);
    expect(find.text('Verify this device'), findsOneWidget);
    expect(find.textContaining('Galaxy S24'), findsOneWidget);
    expect(find.textContaining('SMS'), findsNothing, reason: 'never SMS for new-device login');
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

    await tester.tap(find.byKey(const Key('verify_device_continue')));
    await pumpFor(tester);
    expect(h.api.last('loginVerifyStart').args['channel'], 'device');
    expect(find.textContaining('primary device'), findsWidgets);
    expect(find.byKey(const Key('otp_sms')), findsNothing);

    await _typeCode(tester, '123456');
    expect(h.api.names(), contains('loginVerify'));
    expect(h.auth.lastPassword, 'pw-123456');
    expect(find.text('HOME'), findsOneWidget);
    await pumpFor(tester, const Duration(seconds: 1));
  });

  testWidgetsOn(TargetPlatform.android, 'new device: WhatsApp option sends channel whatsapp', (tester) async {
    final h = Auth2Harness();
    h.api.loginResult = const Auth2NeedsVerification(DeviceVerification(
      verificationId: 'ver-2',
      options: ['device', 'whatsapp', 'sms'],
      primaryDevice: PrimaryDeviceRef(name: 'iPhone 15', model: 'iPhone16,1'),
    ));
    await h.pump(tester);
    await _typePhone(tester, '771234567');
    await tester.enterText(find.byKey(const Key('password_input')), 'pw-123456');
    await tester.tap(find.byKey(const Key('login_button')));
    await pumpFor(tester);
    await tester.tap(find.byKey(const Key('option_whatsapp')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('verify_device_continue')));
    await pumpFor(tester);
    expect(h.api.last('loginVerifyStart').args['channel'], 'whatsapp');
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.authOtp);
    await pumpFor(tester, const Duration(seconds: 1));
  });

  testWidgetsOn(TargetPlatform.android, 'Google first time → mandatory phone completion → OTP → in', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester);
    expect(find.byKey(const Key('google_button')), findsOneWidget);
    expect(find.byKey(const Key('apple_button')), findsNothing);
    await tester.tap(find.byKey(const Key('google_button')));
    await pumpFor(tester);

    expect(h.social.googleCalls, 1);
    expect(h.api.last('social').args['id_token'], 'google-id-token');
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.socialPhone);
    expect(find.text('Complete your account'), findsOneWidget);

    await _typePhone(tester, '771234567');
    await tester.tap(find.byKey(const Key('social_phone_submit')));
    await pumpFor(tester);
    expect(h.api.last('socialPhoneStart').args['session'], 'social-session-1');

    await _typeCode(tester, '123456');
    expect(h.api.names(), contains('socialPhoneVerify'));
    expect(find.text('HOME'), findsOneWidget);
    await pumpFor(tester, const Duration(seconds: 1));
  });

  testWidgetsOn(TargetPlatform.iOS, 'iOS shows Apple only; Apple sends the raw nonce', (tester) async {
    final h = Auth2Harness();
    h.api.socialResult = fakeAuthenticated();
    await h.pump(tester);
    expect(find.byKey(const Key('apple_button')), findsOneWidget);
    expect(find.byKey(const Key('google_button')), findsNothing);
    await tester.tap(find.byKey(const Key('apple_button')));
    await pumpFor(tester);
    expect(h.social.appleCalls, 1);
    final call = h.api.last('social');
    expect(call.args['provider'], 'apple');
    expect(call.args['raw_nonce'], 'raw-nonce');
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgetsOn(TargetPlatform.android, 'forgot password → OTP → new password → back to login', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('forgot_button')));
    await pumpFor(tester);
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.forgotPassword);
    await _pickCountry(tester, 'YE', search: 'Yemen');
    await _typePhone(tester, '771234567');
    await tester.tap(find.byKey(const Key('forgot_submit')));
    await pumpFor(tester);
    expect(h.api.last('passwordForgot').args['phone'], '+967771234567');

    await _typeCode(tester, '123456');
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.resetPassword);
    await tester.enterText(find.byKey(const Key('new_password_input')), 'NewSecret#1');
    await tester.enterText(find.byKey(const Key('confirm_input')), 'NewSecret#1');
    await tester.tap(find.byKey(const Key('reset_submit')));
    await pumpFor(tester);
    final reset = h.api.last('passwordReset');
    expect(reset.args['code'], '123456');
    expect(reset.args['password'], 'NewSecret#1');
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.login);
    expect(find.text('Password changed. Sign in with it now.'), findsOneWidget);
    await pumpFor(tester, const Duration(seconds: 5));
  });

  testWidgetsOn(TargetPlatform.android, 'pasting an international number switches the country', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester);
    await _typePhone(tester, '+971501234567');
    expect(find.text('+971'), findsOneWidget);
    final field = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const Key('phone_input')), matching: find.byType(EditableText)));
    expect(field.controller.text, '501234567');
  });

  testWidgetsOn(TargetPlatform.android, 'country picker lists every country with Arabic names', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester, locale: const Locale('ar'));
    await tester.tap(find.byKey(const Key('country_button')));
    await pumpFor(tester);
    expect(find.text('اختر الدولة'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('country_search')), 'مصر');
    await tester.pump();
    expect(find.byKey(const Key('country_EG')), findsOneWidget);
    await tester.tap(find.byKey(const Key('country_EG')));
    await pumpFor(tester);
    expect(find.text('+20'), findsOneWidget);
  });

  testWidgetsOn(TargetPlatform.android, 'OTP page without a challenge falls back to login', (tester) async {
    final h = Auth2Harness();
    await h.pump(tester, initial: RouteNames.authOtp);
    await pumpFor(tester);
    expect(h.router.routerDelegate.currentConfiguration.uri.path, RouteNames.login);
    expect(h.container.read(auth2FlowProvider).challenge, isNull);
  });

  test('server options are filtered to device | whatsapp', () {
    final v = DeviceVerification.fromJson({
      'verification_id': 'v',
      'options': ['sms', 'whatsapp', 'device'],
    });
    expect(v.options, ['whatsapp', 'device']);
  });
}
