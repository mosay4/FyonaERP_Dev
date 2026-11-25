import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The free-plan welcome reaches the phone twice by design (the app's own
/// local greeting AND the server FCM push with the identical frozen copy).
/// Both paths share ONE persisted tray identity, so it is painted once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int paints;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    paints = 0;
    NotificationService.debugWelcomePainter = ({String? deepLink}) async {
      paints++;
      return true;
    };
  });
  tearDown(() => NotificationService.debugWelcomePainter = null);

  /// The key the FCM foreground bridge / background handler / poll compute
  /// for the server welcome push (payload "notifications" for free plans).
  String fcmKey() => NotificationService.trayEventKey(
        actionPayload: 'notifications',
        title: NotificationService.serverWelcomeTitle,
        body: NotificationService.serverWelcomeBody,
      );

  NotificationService svc() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c.read(notificationServiceProvider);
  }

  test('frozen copy matches the backend welcome and the Arabic ARB', () {
    final arb = jsonDecode(File('assets/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    expect(NotificationService.serverWelcomeTitle, arb['subWelcomeTitle']);
    expect(NotificationService.serverWelcomeBody, arb['subWelcomeBody']);
    final py = File('backend/app/domain/services/subscription_welcome.py')
        .readAsStringSync();
    expect(py, contains('WELCOME_TITLE = "${NotificationService.serverWelcomeTitle}"'));
    expect(py, contains('WELCOME_BODY = "${NotificationService.serverWelcomeBody}"'));
    expect(py, contains('WELCOME_TRAY_TAG = "${NotificationService.welcomeTrayTag}"'));
  });

  test('local first: the later FCM push is suppressed (exactly one)', () async {
    final scope = NotificationService.welcomeScopeKey(userId: 'u1', isFree: true);
    expect(await svc().showSubscriptionWelcomeOnce(scopeKey: scope), isTrue);
    expect(paints, 1);
    // FCM bridge arrives afterwards with the server strings.
    expect(await NotificationService.tryClaimTrayKey(fcmKey()), isFalse);
  });

  test('FCM first: the local greeting is suppressed (exactly one)', () async {
    expect(await NotificationService.tryClaimTrayKey(fcmKey()), isTrue);
    final scope = NotificationService.welcomeScopeKey(userId: 'u1', isFree: true);
    expect(await svc().showSubscriptionWelcomeOnce(scopeKey: scope), isFalse);
    expect(paints, 0);
    // And it stays suppressed for this activation.
    expect(await svc().showSubscriptionWelcomeOnce(scopeKey: scope), isFalse);
    expect(paints, 0);
  });

  test('repeat of the same activation never paints again', () async {
    final scope = NotificationService.welcomeScopeKey(userId: 'u1', isFree: true);
    final s = svc();
    expect(await s.showSubscriptionWelcomeOnce(scopeKey: scope), isTrue);
    expect(await s.showSubscriptionWelcomeOnce(scopeKey: scope), isFalse);
    expect(paints, 1);
  });

  test('failed paint releases the identity so the push still shows', () async {
    NotificationService.debugWelcomePainter = ({String? deepLink}) async => false;
    final scope = NotificationService.welcomeScopeKey(userId: 'u1', isFree: true);
    await svc().showSubscriptionWelcomeOnce(scopeKey: scope);
    expect(await NotificationService.tryClaimTrayKey(fcmKey()), isTrue);
  });

  test('a second account on the same phone still gets its one welcome',
      () async {
    final s = svc();
    expect(
        await s.showSubscriptionWelcomeOnce(
            scopeKey: NotificationService.welcomeScopeKey(userId: 'a', isFree: true)),
        isTrue);
    expect(
        await s.showSubscriptionWelcomeOnce(
            scopeKey: NotificationService.welcomeScopeKey(userId: 'b', isFree: true)),
        isTrue);
    expect(paints, 2);
    // ...and B's server push is then the duplicate, not a second welcome.
    expect(await NotificationService.tryClaimTrayKey(fcmKey()), isFalse);
  });

  test('paid welcome uses the invoice deep link as its identity', () {
    final key = NotificationService.welcomeTrayKey(
        deepLink: '/subscription/invoice?invoice_no=INV-1');
    expect(key, startsWith('/subscription/invoice?invoice_no=INV-1\n'));
    expect(NotificationService.welcomeTrayKey(), fcmKey());
  });
}
