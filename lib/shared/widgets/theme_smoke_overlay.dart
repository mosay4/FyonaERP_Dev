import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Full-screen smoke transition for theme switching.
///
/// Dense soft fog (in [color]) rolls in, the theme is swapped underneath at
/// peak coverage ([onMidpoint]), then the smoke drifts up and dissipates to
/// reveal the new theme ([onComplete]).
class ThemeSmokeOverlay extends StatefulWidget {
  final Color color;
  final Duration duration;
  final VoidCallback onMidpoint;
  final VoidCallback onComplete;

  const ThemeSmokeOverlay({
    super.key,
    required this.color,
    this.duration = const Duration(milliseconds: 900),
    required this.onMidpoint,
    required this.onComplete,
  });

  @override
  State<ThemeSmokeOverlay> createState() => _ThemeSmokeOverlayState();
}

class _ThemeSmokeOverlayState extends State<ThemeSmokeOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _midFired = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addListener(() {
        if (!_midFired && _controller.value >= 0.5) {
          _midFired = true;
          widget.onMidpoint();
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onComplete();
        }
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          size: MediaQuery.of(context).size,
          painter: _SmokePainter(
            progress: _controller.value,
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _SmokePainter extends CustomPainter {
  final double progress;
  final Color color;

  _SmokePainter({required this.progress, required this.color});

  /// Deterministic pseudo-random in [0,1) so puffs are stable per frame.
  double _hash(int index, int salt) {
    var h = (index * 2654435761 + salt * 40503) & 0x7fffffff;
    h ^= h >> 13;
    h = (h * 1274126177) & 0x7fffffff;
    return (h % 10000) / 10000.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final t = Curves.easeInOut.transform(progress.clamp(0.0, 1.0));

    // Global fog veil: fades in, peaks mid-transition, fades out.
    final veil = math.sin(math.pi * t);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: 0.42 * veil),
    );

    // Rolling smoke puffs: staggered, drifting upward, growing + fading.
    const count = 26;
    final minSide = math.min(w, h);
    for (int i = 0; i < count; i++) {
      final h1 = _hash(i, 1);
      final h2 = _hash(i, 2);
      final h3 = _hash(i, 3);
      final h4 = _hash(i, 4);

      final start = h1 * 0.35;
      const span = 0.65;
      final local = ((t - start) / span).clamp(0.0, 1.0);
      if (local <= 0.0 || local >= 1.0) continue;

      final env = math.sin(math.pi * local);
      final cx =
          h2 * w + math.sin(local * math.pi * 2 + h3 * math.pi * 2) * (20 + 40 * h4);
      final cy = (0.10 + 0.90 * h3) * h - local * h * 0.32;
      final r = (0.10 + 0.24 * local) * minSide * (0.7 + 0.6 * h4);
      final a = env * (0.26 + 0.22 * h2);

      final center = Offset(cx, cy);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: a),
            color.withValues(alpha: a * 0.45),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(_SmokePainter old) =>
      old.progress != progress || old.color != color;
}
