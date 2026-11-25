import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/splash/domain/intro_replay_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime(2026, 11, 1, 10);

  tearDown(() => IntroReplayPolicy.clock = DateTime.now);

  group('IntroReplayPolicy.shouldPlay', () {
    test('first ever launch plays', () {
      expect(IntroReplayPolicy.shouldPlay(lastPlayed: null, now: t0), isTrue);
    });
    test('less than 72h since last play → skip', () {
      expect(
          IntroReplayPolicy.shouldPlay(
              lastPlayed: t0, now: t0.add(const Duration(hours: 71, minutes: 59))),
          isFalse);
    });
    test('exactly 72h → plays', () {
      expect(
          IntroReplayPolicy.shouldPlay(
              lastPlayed: t0, now: t0.add(const Duration(hours: 72))),
          isTrue);
    });
    test('stamp in the future (clock moved back) → plays', () {
      expect(
          IntroReplayPolicy.shouldPlay(
              lastPlayed: t0.add(const Duration(days: 3)), now: t0),
          isTrue);
    });
  });

  group('IntroReplayPolicy persistence with injected clock', () {
    test('markPlayed persists the stamp and gates the next 72h', () async {
      SharedPreferences.setMockInitialValues({});
      IntroReplayPolicy.clock = () => t0;
      expect(await IntroReplayPolicy.shouldPlayNow(), isTrue);
      await IntroReplayPolicy.markPlayed();

      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt(IntroReplayPolicy.prefsKey), t0.millisecondsSinceEpoch);

      IntroReplayPolicy.clock = () => t0.add(const Duration(hours: 1));
      expect(await IntroReplayPolicy.shouldPlayNow(), isFalse);
      IntroReplayPolicy.clock = () => t0.add(const Duration(hours: 72, minutes: 1));
      expect(await IntroReplayPolicy.shouldPlayNow(), isTrue);
    });
  });
}
