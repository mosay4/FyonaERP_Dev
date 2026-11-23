import 'dart:math';

class LoginRateLimiter {
  static const int maxAttempts = 5;
  static const int windowMinutes = 15;
  static const int lockoutMinutes = 30;

  final Map<String, List<DateTime>> _attempts = {};
  final Map<String, DateTime> _lockouts = {};

  static final LoginRateLimiter _instance = LoginRateLimiter._internal();
  factory LoginRateLimiter() => _instance;
  LoginRateLimiter._internal();

  /// Constructor for testing (non-singleton instances)
  LoginRateLimiter.test();

  String _normalize(String key) => key.trim().toLowerCase();

  (bool locked, int remainingSeconds) isLocked(String key) {
    final k = _normalize(key);
    final now = DateTime.now();
    final lockout = _lockouts[k];
    if (lockout != null) {
      final remaining = lockout.difference(now).inSeconds;
      if (remaining > 0) return (true, remaining);
      _lockouts.remove(k);
    }
    return (false, 0);
  }

  void recordFailure(String key) {
    final k = _normalize(key);
    final now = DateTime.now();
    _attempts[k] = (_attempts[k] ?? [])
        .where((t) => now.difference(t).inMinutes < windowMinutes)
        .toList();
    _attempts[k]!.add(now);

    if (_attempts[k]!.length >= maxAttempts) {
      _lockouts[k] = now.add(const Duration(minutes: lockoutMinutes));
      _attempts.remove(k);
    }
  }

  void recordSuccess(String key) {
    final k = _normalize(key);
    _attempts.remove(k);
    _lockouts.remove(k);
  }

  int remainingAttempts(String key) {
    final k = _normalize(key);
    final now = DateTime.now();
    final attempts = _attempts[k];
    if (attempts == null) return maxAttempts;
    final recent = attempts
        .where((t) => now.difference(t).inMinutes < windowMinutes)
        .length;
    return max(0, maxAttempts - recent);
  }
}
