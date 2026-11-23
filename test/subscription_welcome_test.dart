import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/shared/services/notification_service.dart';

/// Subscription activation welcome:
/// - stable once-scopes (free keyed by user, paid by invoice/plan+start),
/// - device greeting shows exactly once per scope and never throws.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('welcomeScopeKey', () {
    test('free plans key by user only', () {
      expect(
        NotificationService.welcomeScopeKey(userId: 'u1', isFree: true),
        'trial:u1',
      );
    });

    test('paid plans key by invoice when present', () {
      expect(
        NotificationService.welcomeScopeKey(
            userId: 'u1', isFree: false, invoiceNo: 'INV-1'),
        'paid:u1:INV-1',
      );
    });

    test('paid plans fall back to plan+start', () {
      expect(
        NotificationService.welcomeScopeKey(
            userId: 'u1', isFree: false, plan: 'business', start: '2026-01-01'),
        'paid:u1:business|2026-01-01',
      );
    });

    test('scopes separate users and activations', () {
      final a = NotificationService.welcomeScopeKey(userId: 'u1', isFree: true);
      final b = NotificationService.welcomeScopeKey(userId: 'u2', isFree: true);
      final c = NotificationService.welcomeScopeKey(
          userId: 'u1', isFree: false, invoiceNo: 'INV-1');
      expect({a, b, c}.length, 3);
    });
  });

  group('paid scopeKey once-guard', () {
    test('paid invoice scope shows once, then suppresses', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      final scope = NotificationService.welcomeScopeKey(
          userId: 'u9', isFree: false, invoiceNo: 'INV-9');
      expect(scope, 'paid:u9:INV-9');
      expect(await svc.showSubscriptionWelcomeOnce(scopeKey: scope), isTrue);
      expect(await svc.showSubscriptionWelcomeOnce(scopeKey: scope), isFalse);
    });

    test('derived paid scope (invoiceNo named args, no scopeKey)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      expect(
          await svc.showSubscriptionWelcomeOnce(
              isFree: false, invoiceNo: 'INV-X', userId: 'u9'),
          isTrue);
      expect(
          await svc.showSubscriptionWelcomeOnce(
              isFree: false, invoiceNo: 'INV-X', userId: 'u9'),
          isFalse);
    });

    test('different invoices are independent activations', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      expect(
          await svc.showSubscriptionWelcomeOnce(
              isFree: false, invoiceNo: 'INV-A', userId: 'u9'),
          isTrue);
      expect(
          await svc.showSubscriptionWelcomeOnce(
              isFree: false, invoiceNo: 'INV-B', userId: 'u9'),
          isTrue);
    });

    test('missing user cannot derive a scope', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      expect(
          await svc.showSubscriptionWelcomeOnce(
              isFree: false, invoiceNo: 'INV-Z', userId: ''),
          isFalse);
    });
  });

  group('showSubscriptionWelcomeOnce', () {
    test('shows once, then suppresses', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      final first = await svc.showSubscriptionWelcomeOnce(
          scopeKey: 'test-scope-1');
      expect(first, isTrue);
      final second = await svc.showSubscriptionWelcomeOnce(
          scopeKey: 'test-scope-1');
      expect(second, isFalse);
    });

    test('different scopes are independent', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(notificationServiceProvider);

      expect(
          await svc.showSubscriptionWelcomeOnce(scopeKey: 'test-scope-a'),
          isTrue);
      expect(
          await svc.showSubscriptionWelcomeOnce(scopeKey: 'test-scope-b'),
          isTrue);
    });
  });
}
