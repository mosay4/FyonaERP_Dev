import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Native playback does not run through Dio's auth interceptor.
Future<void> initializeChatVideoController(VideoPlayerController controller,
    {Future<String?>? accessToken, required bool Function() isActive}) async {
  if (accessToken != null) {
    final token = await accessToken.timeout(const Duration(seconds: 5));
    if (!isActive()) return;
    if (token != null && token.isNotEmpty) {
      controller.httpHeaders['Authorization'] = 'Bearer $token';
    }
  }
  if (!isActive()) return;
  await controller.initialize().timeout(const Duration(seconds: 20));
}

/// Only the continuous buffered range at the playhead can satisfy playback.
/// A seek into a gap must not count a disconnected range as playable data.
double videoBufferedFraction(VideoPlayerValue value) {
  final total = value.duration.inMilliseconds;
  final position = value.position.inMilliseconds.clamp(0, total);
  if (total <= 0) return 0;
  if (position >= total) return 1;
  var end = position;
  final ranges = [...value.buffered]..sort((a, b) => a.start.compareTo(b.start));
  for (final range in ranges) {
    if (range.start.inMilliseconds <= end && range.end.inMilliseconds > end) {
      end = range.end.inMilliseconds;
    }
  }
  return ((end - position) / (total - position)).clamp(0.0, 1.0);
}

bool showVideoBufferOverlay(VideoPlayerValue value) =>
    !value.hasError && !value.isCompleted &&
    (!value.isInitialized || (value.isPlaying && value.isBuffering &&
        value.position < value.duration && videoBufferedFraction(value) < 1));

class ChatVideoSurface extends StatelessWidget {
  const ChatVideoSurface({super.key, required this.controller,
    required this.onRetry, this.failed = false});
  final VideoPlayerController controller;
  final VoidCallback onRetry;
  final bool failed;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VideoPlayerValue>(
    valueListenable: controller,
    builder: (_, value, _) {
      final error = failed || value.hasError;
      final ar = value.aspectRatio;
      return AspectRatio(
        aspectRatio: ar.isFinite && ar > 0 ? ar : 16 / 9,
        child: Stack(alignment: Alignment.center, children: [
          Positioned.fill(child: VideoPlayer(controller)),
          if (error)
            FilledButton.icon(onPressed: onRetry,
              icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة'))
          else if (showVideoBufferOverlay(value))
            Positioned(bottom: 12, left: 16, right: 16,
              child: IgnorePointer(child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black.withAlpha(180),
                    borderRadius: BorderRadius.circular(8)),
                child: Padding(padding: const EdgeInsets.all(10),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(value.duration == Duration.zero
                        ? 'جارٍ تهيئة الفيديو — النسبة غير متاحة'
                        : 'تحميل المتبقي ${(videoBufferedFraction(value) * 100).floor()}%',
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: videoBufferedFraction(value)),
                  ])),
              ))),
        ]),
      );
    },
  );
}
