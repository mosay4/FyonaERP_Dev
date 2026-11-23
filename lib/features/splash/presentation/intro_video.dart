import 'dart:async';
import 'package:video_player/video_player.dart';
import '../../../core/startup/startup_logger.dart';

/// Production-ready intro video controller utility.
/// CRITICAL: Never call `initialize()` before the Flutter video platform is
/// ready (i.e. NOT in main() before runApp). The video platform registers
/// itself during the first frame — so the SplashScreen creates the controller,
/// mounts the [VideoPlayer] widget immediately, and only then (on the frame
/// after mount) calls [prepareForPlayback].
class IntroVideo {
  static Future<VideoPlayerController> create() async {
    StartupLogger.log('VIDEO_INITIALIZING', 'creating controller');
    return VideoPlayerController.asset('assets/video/intro.mp4');
  }

  /// Bounded init + config. Called AFTER the first frame has rendered so the
  /// platform is registered. Returns true on success.
  static Future<bool> prepareForPlayback(VideoPlayerController c, {Duration timeout = const Duration(seconds: 8)}) async {
    try {
      await c.initialize().timeout(timeout);
      await c.setVolume(1.0);
      await c.setLooping(false);
      await c.seekTo(Duration.zero);
      StartupLogger.log('VIDEO_READY', 'initialized ${c.value.duration}');
      return true;
    } catch (e, st) {
      StartupLogger.error('VIDEO_READY_FAILED', e, st);
      return false;
    }
  }
}