import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SaraSound { welcome, sent, reply, success, error, tap }

class SaraWelcomeLedger {
  static final _claimed = <String>{};
  static Future<bool> claim(String user) async {
    if (user.isEmpty || user == 'guest' || _claimed.contains(user)) return false;
    final prefs = await SharedPreferences.getInstance();
    final key = 'sara_first_encounter_$user';
    if (prefs.getBool(key) == true) { _claimed.add(user); return false; }
    _claimed.add(user);
    await prefs.setBool(key, true);
    return true;
  }
}

/// UI earcons, never recording or speech synthesis. Sonification + ambient
/// audio categories respect system silent mode and do not claim music focus.
class SaraPremiumSounds {
  SaraPremiumSounds(this.user, {AudioPlayer? player}) : _player = player ?? AudioPlayer() { _ready = _configure(); }
  final String user;
  final AudioPlayer _player;
  late final Future<void> _ready;
  bool get enabled => true;
  Future<void> get ready => _ready;
  bool _disposed = false;
  Future<void> _configure() async {
    try {
      await _player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(usageType: AndroidUsageType.assistanceSonification,
          contentType: AndroidContentType.sonification, audioFocus: AndroidAudioFocus.none),
        iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
      ));
      await _player.setPlayerMode(PlayerMode.lowLatency);
      await _player.setVolume(.22);
    } catch (_) {}
  }
  Future<void> play(SaraSound sound) async {
    try {
      await _ready;
      if (_disposed) return;
      await _player.play(AssetSource('audio/sara_${sound.name}.wav'), volume: .22);
    } catch (_) {} // An unavailable audio route must never interrupt a task.
  }
  Future<void> stop() async { try { await _player.stop(); } catch (_) {} }
  void dispose() { _disposed = true; unawaited(_player.dispose()); }
}
