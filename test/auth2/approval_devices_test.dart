import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/security/device_identity.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_api.dart';
import 'package:fyona_flutter/features/auth/auth2/auth2_models.dart';
import 'package:fyona_flutter/features/auth/auth2/security/approval_dialog.dart';
import 'package:fyona_flutter/features/auth/auth2/security/approvals_page.dart';
import 'package:fyona_flutter/features/auth/auth2/security/change_phone_page.dart';
import 'package:fyona_flutter/features/auth/auth2/security/devices_page.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

import '../support/auth2_fakes.dart';
import '../test_utils.dart';

DateTime _now = DateTime.now();

Future<void> _advance(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    _now = _now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
}

PendingApproval _approval({int expiresInSeconds = 120, String id = 'ap-1'}) {
  final created = DateTime.now().subtract(const Duration(seconds: 20));
  return PendingApproval(
    approvalId: id,
    deviceName: 'Pixel 9',
    deviceModel: 'GKWS6',
    os: 'Android',
    osVersion: '15',
    locationHint: 'Sana’a, YE',
    createdAt: created,
    expiresAt: DateTime.now().add(Duration(seconds: expiresInSeconds)),
  );
}

TrustedDevice _device(String id,
        {bool primary = false, bool current = false, bool trusted = true, String name = ''}) =>
    TrustedDevice(
      deviceId: id,
      name: name.isEmpty ? 'Device $id' : name,
      model: 'M-$id',
      os: 'Android',
      osVersion: '15',
      appVersion: '1.4.133',
      isPrimary: primary,
      trusted: trusted,
      lastSeen: DateTime(2026, 11, 26, 9, 30),
      createdAt: DateTime(2026, 11, 1),
      current: current,
    );

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  Widget page,
  FakeAuth2Api api, {
  UserModel? user,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    auth2ApiProvider.overrideWithValue(api),
    deviceKeyIdentityProvider.overrideWithValue(FakeDeviceKeyIdentity()),
    authStateProvider.overrideWith((ref) => FakeAuthNotifier(
          ref,
          AuthState(
            status: AuthStatus.authenticated,
            user: user ??
                const UserModel(
                  id: 'u-1',
                  organizationId: 'o-1',
                  phone: '+967771234567',
                  phoneMasked: '+967771234567',
                  phoneComplete: true,
                ),
          ),
        )),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: AppTheme.darkTheme,
      home: page,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  setUpAll(() => ensureTestLocalization('en'));

  group('approval popup', () {
    testWidgets('shows device, OS, location, time, code, countdown and the warning',
        (tester) async {
      _now = DateTime.now();
      final api = FakeAuth2Api()
        ..approval = ApprovalCode(code: '482913', expiresAt: DateTime.now().add(const Duration(seconds: 90)));
      final a = _approval();
      api.pending = [a];
      await _pumpPage(
          tester, ApprovalDialog(approval: a, clock: () => _now), api);
      await tester.pump();
      expect(find.text('Sign-in attempt'), findsOneWidget);
      expect(find.textContaining('Pixel 9'), findsOneWidget);
      expect(find.text('Android 15'), findsOneWidget);
      expect(find.text('Sana’a, YE'), findsOneWidget);
      expect(find.text(formatApprovalTime(a.createdAt)), findsOneWidget);
      expect(find.text('482 913'), findsOneWidget);
      expect(find.byKey(const Key('approval_countdown')), findsOneWidget);
      expect(find.textContaining('never share the code'), findsOneWidget);
      // The code was fetched with a FRESH device proof.
      final call = api.last('approvalCode');
      expect(call.args['nonce'], startsWith('nonce-'));
      expect(call.args['signature'], isNotEmpty);
    });

    testWidgets('the code disappears at expiry and never comes back', (tester) async {
      _now = DateTime.now();
      final api = FakeAuth2Api()
        ..approval = ApprovalCode(code: '111222', expiresAt: DateTime.now().add(const Duration(seconds: 3)));
      final a = _approval(expiresInSeconds: 60);
      api.pending = [a];
      await _pumpPage(tester, ApprovalDialog(approval: a, clock: () => _now), api);
      await tester.pump();
      expect(find.text('111 222'), findsOneWidget);
      await _advance(tester, 5);
      expect(find.byKey(const Key('approval_code')), findsNothing);
      expect(find.byKey(const Key('approval_expired')), findsOneWidget);
      expect(find.byKey(const Key('approval_deny')), findsNothing);
      await _advance(tester, 5);
      expect(find.byKey(const Key('approval_code')), findsNothing);
    });

    testWidgets('an already expired request never fetches nor shows a code', (tester) async {
      _now = DateTime.now();
      final api = FakeAuth2Api()
        ..approval = ApprovalCode(code: '999999', expiresAt: DateTime.now().add(const Duration(minutes: 5)));
      final a = _approval(expiresInSeconds: -1);
      await _pumpPage(tester, ApprovalDialog(approval: a, clock: () => _now), api);
      await tester.pump();
      expect(api.names(), isNot(contains('approvalCode')));
      expect(find.text('999 999'), findsNothing);
      expect(find.byKey(const Key('approval_expired')), findsOneWidget);
    });

    testWidgets('success elsewhere (no longer pending) hides the code', (tester) async {
      _now = DateTime.now();
      final api = FakeAuth2Api()
        ..approval = ApprovalCode(code: '333444', expiresAt: DateTime.now().add(const Duration(minutes: 2)));
      final a = _approval();
      api.pending = [a];
      await _pumpPage(
          tester,
          ApprovalDialog(approval: a, clock: () => _now, pendingPoll: const Duration(seconds: 1)),
          api);
      await tester.pump();
      expect(find.text('333 444'), findsOneWidget);
      api.pending = [];
      await _advance(tester, 2);
      expect(find.text('333 444'), findsNothing);
      expect(find.byKey(const Key('approval_done')), findsOneWidget);
    });

    testWidgets('notification center route opens the popup; Deny calls the server',
        (tester) async {
      final api = FakeAuth2Api()
        ..approval = ApprovalCode(code: '555666', expiresAt: DateTime.now().add(const Duration(minutes: 2)));
      api.pending = [_approval(id: 'ap-9')];
      await _pumpPage(tester, const ApprovalsPage(focusId: 'ap-9'), api);
      await pumpFor(tester);
      expect(find.byKey(const Key('approval_dialog')), findsOneWidget);
      expect(find.text('555 666'), findsOneWidget);
      await tester.tap(find.byKey(const Key('approval_deny')));
      await pumpFor(tester);
      expect(api.last('denyApproval').args['id'], 'ap-9');
      expect(find.byKey(const Key('approval_dialog')), findsNothing);
      expect(find.byKey(const Key('approvals_empty')), findsOneWidget);
    });
  });

  group('devices page', () {
    testWidgets('lists primary / current / trusted; revoke after confirm', (tester) async {
      final api = FakeAuth2Api()
        ..deviceList = [
          _device('b', current: true),
          _device('a', primary: true, name: 'Galaxy S24'),
          _device('c', trusted: false),
        ];
      await _pumpPage(tester, const DevicesPage(), api);
      await pumpFor(tester);
      expect(find.byKey(const Key('badge_primary_a')), findsOneWidget);
      expect(find.byKey(const Key('badge_current_b')), findsOneWidget);
      expect(find.text('Not trusted'), findsOneWidget);
      // Primary listed first.
      final aY = tester.getTopLeft(find.byKey(const Key('device_a'))).dy;
      final bY = tester.getTopLeft(find.byKey(const Key('device_b'))).dy;
      expect(aY, lessThan(bY));

      await tester.tap(find.byKey(const Key('device_menu_c')));
      await pumpFor(tester);
      // Not primary here → no «make primary».
      expect(find.byKey(const Key('menu_primary')), findsNothing);
      await tester.tap(find.byKey(const Key('menu_revoke')));
      await pumpFor(tester);
      expect(find.text('Remove this device?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm_ok')));
      await pumpFor(tester);
      expect(api.last('revokeDevice').args['id'], 'c');
      expect(find.byKey(const Key('device_c')), findsNothing);
    });

    testWidgets('the current device cannot revoke itself; rename works', (tester) async {
      final api = FakeAuth2Api()..deviceList = [_device('a', primary: true, current: true)];
      await _pumpPage(tester, const DevicesPage(), api);
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('device_menu_a')));
      await pumpFor(tester);
      expect(find.byKey(const Key('menu_revoke')), findsNothing);
      await tester.tap(find.byKey(const Key('menu_rename')));
      await pumpFor(tester);
      await tester.enterText(find.byKey(const Key('rename_input')), 'My phone');
      await tester.tap(find.byKey(const Key('rename_save')));
      await pumpFor(tester);
      expect(api.last('renameDevice').args['name'], 'My phone');
      expect(find.text('My phone'), findsOneWidget);
    });

    testWidgets('make primary from the primary device uses a device proof', (tester) async {
      final api = FakeAuth2Api()
        ..deviceList = [_device('a', primary: true, current: true), _device('b')];
      await _pumpPage(tester, const DevicesPage(), api);
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('device_menu_b')));
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('menu_primary')));
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('confirm_ok')));
      await pumpFor(tester);
      expect(api.last('makePrimary').args['id'], 'b');
      expect(api.last('makePrimary').args['nonce'], startsWith('nonce-'));
    });

    testWidgets('«I lost my primary device» starts a cancellable 48 h claim', (tester) async {
      final api = FakeAuth2Api()
        ..deviceList = [_device('a', primary: true), _device('b', current: true)];
      await _pumpPage(tester, const DevicesPage(), api);
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('lost_primary')));
      await pumpFor(tester);
      expect(find.textContaining('48 hours'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm_ok')));
      await pumpFor(tester);
      expect(api.names(), contains('claimPrimary'));
      expect(find.byKey(const Key('claim_banner')), findsOneWidget);
      expect(find.byKey(const Key('lost_primary')), findsNothing);
      await tester.tap(find.byKey(const Key('claim_cancel')));
      await pumpFor(tester);
      expect(api.names(), contains('cancelClaimPrimary'));
    });
  });

  group('change phone', () {
    testWidgets('re-auth → new number → OTP → success; user phone updated', (tester) async {
      final api = FakeAuth2Api();
      final container = await _pumpPage(tester, const ChangePhonePage(), api);
      expect(find.textContaining('+967771234567'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('reauth_password')), 'pw-123456');
      await tester.tap(find.byKey(const Key('reauth_continue')));
      await pumpFor(tester);
      await tester.tap(find.byKey(const Key('country_button')));
      await pumpFor(tester);
      await tester.enterText(find.byKey(const Key('country_search')), 'Saudi');
      await tester.pump();
      await tester.tap(find.byKey(const Key('country_SA')));
      await pumpFor(tester);
      await tester.enterText(find.byKey(const Key('phone_input')), '0501234567');
      await tester.tap(find.byKey(const Key('change_phone_send')));
      await pumpFor(tester);
      final start = api.last('phoneChangeStart');
      expect(start.args['phone'], '+966501234567');
      expect(start.args['password'], 'pw-123456');
      expect(start.args['nonce'], startsWith('nonce-'));
      expect(find.byKey(const Key('otp_input')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('otp_input')), '123456');
      await pumpFor(tester);
      expect(api.last('phoneChangeVerify').args['code'], '123456');
      expect(find.byKey(const Key('change_phone_done')), findsOneWidget);
      expect(container.read(authStateProvider).user?.phone, '+966501234567');
    });

    testWidgets('a taken number shows the server message and stays', (tester) async {
      final api = FakeAuth2Api()
        ..startError = const Auth2Exception(
            code: 'phone_taken', messageEn: 'This number is already used', messageAr: 'الرقم مستخدم');
      await _pumpPage(tester, const ChangePhonePage(), api);
      await tester.enterText(find.byKey(const Key('reauth_password')), 'pw');
      await tester.tap(find.byKey(const Key('reauth_continue')));
      await pumpFor(tester);
      await tester.enterText(find.byKey(const Key('phone_input')), '+966501234567');
      await tester.tap(find.byKey(const Key('change_phone_send')));
      await pumpFor(tester);
      expect(find.text('This number is already used'), findsOneWidget);
      expect(find.byKey(const Key('otp_input')), findsNothing);
    });
  });
}
