import 'dart:async';
import 'package:audioplayers/audioplayers.dart';

/// Independent from voice playback; failures must never affect chat or sends.
class ChatSounds {
  ChatSounds({AudioPlayer? sentPlayer, AudioPlayer? receivedPlayer})
    : _sent = sentPlayer ?? AudioPlayer(),
      _received = receivedPlayer ?? AudioPlayer() {
    _ready = _configure().catchError((Object _) {});
  }
  final AudioPlayer _sent;
  final AudioPlayer _received;
  bool _disposed = false;
  late final Future<void> _ready;
  Future<void> _sentQueue = Future.value();
  Future<void> _receivedQueue = Future.value();

  Future<void> _configure() async {
    final context = AudioContext(
      android: const AudioContextAndroid(
        usageType: AndroidUsageType.notification,
        contentType: AndroidContentType.sonification,
        audioFocus: AndroidAudioFocus.none,
      ),
      iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
    );
    for (final player in [_sent, _received]) {
      await player.setAudioContext(context);
      await player.setPlayerMode(PlayerMode.lowLatency);
      // Keep the local sample loaded after completion; the default release
      // mode unloads it, making subsequent low-latency plays unreliable.
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSource(
        AssetSource('audio/chat_${player == _sent ? 'sent' : 'received'}.wav'),
      );
      await player.setVolume(0.35);
    }
  }

  void play({required bool sent}) {
    if (_disposed) return;
    // Serialize bursts rather than restarting (and swallowing) the last play.
    if (sent) {
      _sentQueue = _sentQueue.then((_) => _play(true));
    } else {
      _receivedQueue = _receivedQueue.then((_) => _play(false));
    }
  }

  Future<void> _play(bool sent) async {
    try {
      await _ready;
      if (_disposed) return;
      final player = sent ? _sent : _received;
      await player.stop();
      await player.resume();
      await Future<void>.delayed(const Duration(milliseconds: 180));
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    unawaited(_sent.dispose());
    unawaited(_received.dispose());
  }
}
