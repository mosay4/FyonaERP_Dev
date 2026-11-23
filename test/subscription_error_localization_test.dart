import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/subscription/domain/subscription_errors.dart';

/// The backend's Premium guard must never reach the user in English only:
/// it is mapped to the app language (and the receipt-upload path shows the
/// same notice).
void main() {
  const raw =
      'Exception: Premium already includes Personal and Business; individual plans cannot be added';

  test('premium guard is recognized and mapped', () {
    final mapped = premiumSubscriptionMessage(Exception(raw));
    expect(mapped, isNotNull);
    expect(mapped, isNot(contains('Premium already includes')));
  });

  test('unrelated errors stay untouched', () {
    expect(premiumSubscriptionMessage(Exception('boom')), isNull);
    expect(localizeSubscriptionError(Exception('boom')), contains('boom'));
  });

  test('api errors keep their own message', () {
    expect(localizeSubscriptionError(Exception('network down')),
        contains('network down'));
  });
}
