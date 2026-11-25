import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decides whether the opening intro motion should play on this app open.
///
/// The intro plays on the very first launch and then at most once every
/// [replayInterval] (72 hours). The moment it last started playing is stored
/// locally in SharedPreferences — works fully offline.
class IntroReplayPolicy {
  IntroReplayPolicy._();

  static const Duration replayInterval = Duration(hours: 72);
  static const String prefsKey = 'intro_motion_last_played_ms';

  /// Injectable clock for tests.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Pure decision: true when the intro never played, the stored stamp is in
  /// the future (clock changed), or at least [replayInterval] has elapsed.
  static bool shouldPlay({DateTime? lastPlayed, required DateTime now}) {
    if (lastPlayed == null) return true;
    if (lastPlayed.isAfter(now)) return true;
    return now.difference(lastPlayed) >= replayInterval;
  }

  /// Reads the stored stamp and decides. Any storage failure falls back to
  /// playing the intro (the pre-existing behaviour) — never blocks startup.
  static Future<bool> shouldPlayNow() async {
    try {
      final sp = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      final ms = sp.getInt(prefsKey);
      final last = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      return shouldPlay(lastPlayed: last, now: clock());
    } catch (_) {
      return true;
    }
  }

  /// Records that the intro just started playing.
  static Future<void> markPlayed() async {
    try {
      final sp = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      await sp.setInt(prefsKey, clock().millisecondsSinceEpoch);
    } catch (_) {}
  }
}
