import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-lifetime scanner SFX.
///
/// Reliability rules (learned the hard way):
/// - DEFAULT media mode (MediaPlayer): it loads `AssetSource` correctly.
///   `PlayerMode.lowLatency` (SoundPool) fails to load asset:// sources on
///   many devices → total silence. Never switch modes here.
/// - ONE dedicated player per sound, source PRELOADED once. A beep is then a
///   `seek(0) + resume()` — instant and always in sync with the alert.
/// - `ReleaseMode.stop` keeps the prepared source alive between beeps.
/// - Short UI beeps route to the sonification/system audio attributes with
///   NO audio focus: audible even when the media stream is muted, and they
///   never pause background music.
///
/// Sounds (synthesized originally for FYONA by tools/product_sounds.py):
/// - barcode_capture: rounded scanner beep on a decode (success).
/// - product_alert: gentle two-step descending alert (out of stock,
///   insufficient quantity, unknown code).
/// - product_select: calm soft «tock» when a product is picked.
/// - invoice_done: short bell arpeggio when an invoice is created.
class ScanSfx {
  ScanSfx._();

  static const String _okSrc = 'audio/barcode_capture.wav';
  static const String _badSrc = 'audio/product_alert.wav';
  static const String _selectSrc = 'audio/product_select.wav';
  static const String _doneSrc = 'audio/invoice_done.wav';
  // Reconciliation motion sounds — BOTH synthesized originally for FYONA
  // (license-free): a 4s scan composition synced to the motion phases, and a
  // 1.3s crystal confirmation chime for the equalization seal.
  static const String _scanSrc = 'audio/recon_scan.mp3';
  static const String _crystalSrc = 'audio/recon_crystal.mp3';

  static final AudioPlayer _ok = AudioPlayer(playerId: 'fyona_scan_ok');
  static final AudioPlayer _bad = AudioPlayer(playerId: 'fyona_scan_bad');
  static final AudioPlayer _eq = AudioPlayer(playerId: 'fyona_recon_eq');
  static final AudioPlayer _pick = AudioPlayer(playerId: 'fyona_pick');
  static final AudioPlayer _done = AudioPlayer(playerId: 'fyona_invoice_done');

  static bool _warmed = false;

  static AudioContext get _ctx => AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      );

  /// Preloads both sounds. Call early (e.g. when the camera page opens) so
  /// the first beep fires exactly at the decode moment, not ~100ms later.
  static Future<void> warmUp() async {
    if (_warmed) return;
    _warmed = true;
    try {
      await _ok.setAudioContext(_ctx);
      await _bad.setAudioContext(_ctx);
      await _eq.setAudioContext(_ctx);
      await _ok.setSource(AssetSource(_okSrc));
      await _bad.setSource(AssetSource(_badSrc));
      await _eq.setSource(AssetSource(_scanSrc));
      await _eq.setSource(AssetSource(_crystalSrc));
      await _ok.setReleaseMode(ReleaseMode.stop);
      await _bad.setReleaseMode(ReleaseMode.stop);
      await _eq.setReleaseMode(ReleaseMode.stop);
      await _ok.setVolume(1.0);
      await _bad.setVolume(1.0);
      await _eq.setVolume(1.0);
    } catch (e) {
      if (kDebugMode) debugPrint('ScanSfx warmUp failed: $e');
    }
  }

  /// QR/barcode decoded (and product added) — rounded scanner beep.
  static Future<void> success() => _fire(_ok, _okSrc);

  /// Out of stock / insufficient quantity / unknown code — gentle alert.
  static Future<void> error() => _fire(_bad, _badSrc);

  /// A product was picked (tap in a picker) — calm soft tock.
  /// Follows the motion-sound rule: silent/vibrate/DND → no sound.
  static Future<void> select() => _cue(() => _pick, _selectSrc);

  /// A sale/purchase invoice was created — short bell arpeggio, in sync
  /// with the success motion. Same silent/vibrate/DND rule.
  static Future<void> invoiceDone() => _cue(() => _done, _doneSrc);

  static const MethodChannel _motion = MethodChannel('fyona/motion_audio');
  static final Set<String> _cueReady = {};

  /// Same gate as the other motion sounds (`fyona/motion_audio` → canPlay):
  /// ringer normal, system volume > 0 and DND off.
  static Future<bool> _soundOn() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _motion.invokeMethod<bool>('canPlay') == true;
    } catch (_) {
      return false;
    }
  }

  // The player is created only after the gate passes (static players are
  // lazy; a muted phone or a test never opens their platform streams).
  static Future<void> _cue(AudioPlayer Function() player, String src) async {
    if (!await _soundOn()) return;
    final p = player();
    if (_cueReady.add(src)) {
      try {
        await p.setAudioContext(_ctx);
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(AssetSource(src));
      } catch (e) {
        if (kDebugMode) debugPrint('ScanSfx cue warm failed: $e');
      }
    }
    await _fire(p, src);
  }

  /// Reconciliation scan (4s composition, synced with the motion phases).
  /// Fired ONCE when the scan overlay mounts — never on rebuild.
  static Future<void> scan() => _fire(_eq, _scanSrc);

  /// Crystal confirmation chime at the seal merge (success only — callers
  /// guard: it is never played when the operation failed).
  static Future<void> crystal() => _fire(_eq, _crystalSrc);

  static Future<void> _fire(AudioPlayer p, String src) async {
    await warmUp();
    try {
      await p.seek(Duration.zero);
      await p.resume();
      return;
    } catch (e) {
      if (kDebugMode) debugPrint('ScanSfx resume failed: $e');
    }
    try {
      await p.stop();
      await p.play(AssetSource(src), volume: 1.0);
    } catch (e) {
      if (kDebugMode) debugPrint('ScanSfx play failed: $e');
    }
  }
}