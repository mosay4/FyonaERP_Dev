import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_models.dart';
import 'package:fyona_flutter/features/auth/auth2/widgets/otp_view.dart';

import '../support/auth2_fakes.dart';
import '../test_utils.dart';

DateTime _now = DateTime.now();

/// Moves the injected clock and the fake timers together.
Future<void> _advance(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    _now = _now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
}

class _Server {
  OtpStatus status = const OtpStatus(status: 'queued', channel: 'whatsapp', canRequestSms: false);
  final List<String> verified = [];
  final List<String?> resends = [];
  Auth2Exception? verifyError;
}

Future<_Server> _pump(
  WidgetTester tester, {
  OtpChallenge? challenge,
  _Server? server,
}) async {
  final s = server ?? _Server();
  _now = DateTime.now();
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: OtpView(
          challenge: challenge ?? fakeChallenge(resendAfter: 30, expiresIn: 300),
          destination: '+967771234567',
          pollInterval: const Duration(seconds: 1),
          clock: () => _now,
          loadStatus: (_) async => s.status,
          resend: (id, channel) async {
            s.resends.add(channel);
            return fakeChallenge(id: '$id-r', channel: channel ?? 'whatsapp');
          },
          onVerify: (code) async {
            s.verified.add(code);
            if (s.verifyError != null) throw s.verifyError!;
          },
        ),
      ),
    ),
  ));
  await tester.pump();
  return s;
}

void main() {
  setUpAll(() => ensureTestLocalization('en'));

  test('extractOtp finds the code in a pasted WhatsApp message', () {
    expect(extractOtp('Your FYONA code is 482 913. Do not share it.'), '482913');
    expect(extractOtp('٤٨٢٩١٣'), '482913');
    expect(extractOtp('12'), isNull);
  });

  testWidgets('live status: sent → delivered → read, then SMS fallback', (tester) async {
    final s = await _pump(tester);
    expect(find.text('Sending the code via WhatsApp…'), findsOneWidget);
    s.status = const OtpStatus(status: 'delivered', channel: 'whatsapp', canRequestSms: false);
    await pumpFor(tester, const Duration(milliseconds: 1200));
    expect(find.text('Delivered to WhatsApp'), findsOneWidget);
    s.status = const OtpStatus(status: 'read', channel: 'whatsapp', canRequestSms: false);
    await pumpFor(tester, const Duration(milliseconds: 1200));
    expect(find.text('Read in WhatsApp'), findsOneWidget);
    expect(find.byKey(const Key('otp_sms')), findsNothing);
    s.status = const OtpStatus(status: 'fallback_sms', channel: 'sms', canRequestSms: false);
    await pumpFor(tester, const Duration(milliseconds: 1200));
    expect(find.text('WhatsApp did not deliver — we sent it by SMS'), findsOneWidget);
  });

  testWidgets('«send by SMS» appears only when the server allows it', (tester) async {
    final s = await _pump(tester);
    expect(find.byKey(const Key('otp_sms')), findsNothing);
    s.status = const OtpStatus(status: 'failed', channel: 'whatsapp', canRequestSms: true);
    await pumpFor(tester, const Duration(milliseconds: 1200));
    expect(find.byKey(const Key('otp_sms')), findsOneWidget);
    await tester.tap(find.byKey(const Key('otp_sms')));
    await pumpFor(tester);
    expect(s.resends, ['sms']);
  });

  testWidgets('resend timer counts down, then resends', (tester) async {
    final s = await _pump(tester, challenge: OtpChallenge(challengeId: 'c', channel: 'whatsapp', status: 'queued', resendAfter: 3, expiresIn: 300, receivedAt: DateTime.now()));
    expect(find.textContaining('Resend in'), findsOneWidget);
    await tester.tap(find.byKey(const Key('otp_resend')));
    await tester.pump();
    expect(s.resends, isEmpty);
    await _advance(tester, 4);
    expect(find.text('Resend'), findsOneWidget);
    await tester.tap(find.byKey(const Key('otp_resend')));
    await pumpFor(tester);
    expect(s.resends, [null]);
  });

  testWidgets('wrong code shows the message and clears the boxes', (tester) async {
    final s = _Server()..verifyError = const Auth2Exception(code: 'invalid_code');
    await _pump(tester, server: s);
    await tester.enterText(find.byKey(const Key('otp_input')), '111111');
    await pumpFor(tester);
    expect(s.verified, ['111111']);
    expect(find.text('Incorrect code'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('otp_input')));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('locked challenge disables entry and offers a new code', (tester) async {
    final s = _Server()..verifyError = const Auth2Exception(code: 'locked');
    await _pump(tester, server: s);
    await tester.enterText(find.byKey(const Key('otp_input')), '222222');
    await pumpFor(tester);
    expect(find.text('Too many wrong attempts. Request a new code later.'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('otp_input')));
    expect(field.enabled, isFalse);
    expect(find.text('Resend'), findsOneWidget);
  });

  testWidgets('expiry countdown, then expired state', (tester) async {
    await _pump(tester, challenge: fakeChallenge(expiresIn: 3, resendAfter: 1));
    expect(find.textContaining('Code expires in 0:0'), findsOneWidget);
    await _advance(tester, 4);
    expect(find.byKey(const Key('otp_expired')), findsOneWidget);
    expect(find.byKey(const Key('otp_expiry')), findsNothing);
  });

  testWidgets('paste button reads the clipboard and verifies', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': 'FYONA: 654 321'};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final s = await _pump(tester);
    await tester.tap(find.byKey(const Key('otp_paste')));
    await pumpFor(tester);
    expect(s.verified, ['654321']);
  });

  testWidgets('primary-device channel explains where the code is', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OtpView(
            challenge: fakeChallenge(channel: 'device'),
            destination: '',
            primaryDeviceName: 'Galaxy S24',
            onVerify: (_) async {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('Galaxy S24'), findsOneWidget);
    expect(find.text('The code is now shown on your primary device'), findsOneWidget);
    expect(find.byKey(const Key('otp_sms')), findsNothing);
  });
}
