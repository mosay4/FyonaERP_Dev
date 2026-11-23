import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/security/rate_limiter.dart';

void main() {
  group('LoginRateLimiter', () {
    late LoginRateLimiter limiter;

    setUp(() {
      limiter = LoginRateLimiter.test();
    });

    test('initial state is not locked', () {
      final (locked, _) = limiter.isLocked('testuser');
      expect(locked, false);
    });

    test('locks after max attempts', () {
      for (int i = 0; i < 5; i++) {
        limiter.recordFailure('testuser');
      }
      final (locked, _) = limiter.isLocked('testuser');
      expect(locked, true);
    });

    test('clears on success', () {
      for (int i = 0; i < 3; i++) {
        limiter.recordFailure('testuser');
      }
      limiter.recordSuccess('testuser');
      final (locked, _) = limiter.isLocked('testuser');
      expect(locked, false);
    });

    test('tracks remaining attempts', () {
      expect(limiter.remainingAttempts('testuser'), 5);
      limiter.recordFailure('testuser');
      expect(limiter.remainingAttempts('testuser'), 4);
    });

    test('normalizes keys to lowercase', () {
      limiter.recordFailure('TestUser');
      expect(limiter.remainingAttempts('testuser'), 4);
    });
  });
}
