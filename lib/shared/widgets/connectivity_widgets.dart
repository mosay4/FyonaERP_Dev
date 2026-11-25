import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/services/connectivity_service.dart';

/// Connection badge for the app bars (Personal and Business): a clean Wi-Fi
/// mark in a round button that matches the bell beside it.
///  • online  — green arcs that light up one after another, then rest;
///  • offline — muted arcs crossed by a line in amber, breathing slowly.
/// Switching state cross-fades with a soft scale.
class ConnectivityIndicator extends StatefulWidget {
  final bool online;
  final double size;
  const ConnectivityIndicator({this.online = true, this.size = 20, super.key});

  @override
  State<ConnectivityIndicator> createState() => _ConnectivityIndicatorState();
}

class _ConnectivityIndicatorState extends State<ConnectivityIndicator>
    with TickerProviderStateMixin {
  /// One reveal of the arcs when the connection (re)appears.
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  /// Slow breathing while offline only.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.online) _breath.repeat(reverse: true, count: 6);
  }

  @override
  void didUpdateWidget(covariant ConnectivityIndicator old) {
    super.didUpdateWidget(old);
    if (old.online == widget.online) return;
    if (widget.online) {
      _breath.stop();
      _breath.value = 0;
      _reveal.forward(from: 0);
    } else {
      _breath.repeat(reverse: true, count: 6);
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.online;
    final s = widget.size;
    final box = s + 12.0;
    final color = online ? const Color(0xFF2FA866) : const Color(0xFFE0892B);
    return Semantics(
      label: online ? 'online' : 'offline',
      child: Container(
        width: box,
        height: box,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surface,
          border: Border.all(color: AppColors.border, width: 1),
        ),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.7, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: AnimatedBuilder(
            key: ValueKey(online),
            animation: Listenable.merge([_reveal, _breath]),
            builder: (context, _) => CustomPaint(
              size: Size.square(s),
              painter: _WifiMark(
                color: color,
                online: online,
                reveal: Curves.easeOut.transform(_reveal.value),
                breath: _breath.value,
                track: AppColors.textTertiary.withAlpha(70),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _reveal.dispose();
    _breath.dispose();
    super.dispose();
  }
}

class _WifiMark extends CustomPainter {
  _WifiMark({
    required this.color,
    required this.online,
    required this.reveal,
    required this.breath,
    required this.track,
  });

  final Color color;
  final bool online;
  final double reveal;
  final double breath;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final centre = Offset(w / 2, size.height * 0.80);
    final stroke = w * 0.105;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    const sweep = 1.55; // radians of each arc, centred upwards
    final radii = [w * 0.20, w * 0.38, w * 0.56];
    for (var i = 0; i < radii.length; i++) {
      final r = radii[i];
      final rect = Rect.fromCircle(center: centre, radius: r);
      final start = -1.5708 - sweep / 2;
      if (online) {
        // Each arc lights after the previous one.
        final t = ((reveal * 3) - i).clamp(0.0, 1.0);
        canvas.drawArc(rect, start, sweep, false, paint..color = track);
        if (t > 0) {
          canvas.drawArc(
            rect,
            start + sweep * (1 - t) / 2,
            sweep * t,
            false,
            paint..color = color,
          );
        }
      } else {
        final alpha = (150 + 80 * breath).round();
        canvas.drawArc(rect, start, sweep, false,
            paint..color = color.withAlpha(i == 0 ? alpha : (alpha * 0.55).round()));
      }
    }
    // The dot.
    canvas.drawCircle(
      centre,
      stroke * 0.85,
      Paint()..color = online ? color : color.withAlpha((170 + 70 * breath).round()),
    );
    if (!online) {
      // A clean strike line.
      canvas.drawLine(
        Offset(w * 0.16, size.height * 0.10),
        Offset(w * 0.84, size.height * 0.86),
        Paint()
          ..color = color
          ..strokeWidth = stroke * 0.9
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WifiMark old) =>
      old.reveal != reveal ||
      old.breath != breath ||
      old.online != online ||
      old.color != color ||
      old.track != track;
}

/// «No internet» illustration for the offline dialog — one finite pass
/// (~1.6 s, then still): the Wi-Fi arcs light up, the link to a small cloud
/// breaks and the cloud drifts off, the arcs fade outer-first and a soft
/// strike draws across the mark.
class OfflineSignalArt extends StatefulWidget {
  final double width;
  const OfflineSignalArt({super.key, this.width = 64});

  @override
  State<OfflineSignalArt> createState() => _OfflineSignalArtState();
}

/// A compact «no connection» mark: a soft tile, a cloud drawn in a fine
/// line, then a slash in the warning colour — once, about one second.
class _OfflineSignalArtState extends State<OfflineSignalArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    const accent = Color(0xFFE0892B);
    return Semantics(
      label: 'offline',
      child: Container(
        width: w,
        height: w,
        decoration: BoxDecoration(
          color: accent.withAlpha(22),
          borderRadius: BorderRadius.circular(w * 0.32),
          border: Border.all(color: accent.withAlpha(46)),
        ),
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _OfflineArtPainter(
              t: Curves.easeOutCubic.transform(_c.value),
              accent: accent,
              line: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineArtPainter extends CustomPainter {
  _OfflineArtPainter({required this.t, required this.accent, required this.line});
  final double t;
  final Color accent;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final stroke = w * 0.045;
    // Cloud outline (two bumps + base), centred in the tile.
    final cloud = Path()
      ..moveTo(w * 0.30, w * 0.64)
      ..lineTo(w * 0.70, w * 0.64)
      ..arcToPoint(Offset(w * 0.70, w * 0.44),
          radius: Radius.circular(w * 0.10), clockwise: false)
      ..arcToPoint(Offset(w * 0.44, w * 0.38),
          radius: Radius.circular(w * 0.15), clockwise: false)
      ..arcToPoint(Offset(w * 0.30, w * 0.64),
          radius: Radius.circular(w * 0.13), clockwise: false)
      ..close();
    final reveal = (t / 0.65).clamp(0.0, 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = line.withAlpha(200);
    for (final metric in cloud.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * reveal), paint);
    }
    // The slash draws after the cloud.
    final s = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
    if (s > 0) {
      final from = Offset(w * 0.27, w * 0.27);
      final to = Offset(w * 0.73, w * 0.73);
      canvas.drawLine(
        from,
        Offset.lerp(from, to, s)!,
        Paint()
          ..color = accent
          ..strokeWidth = stroke * 1.15
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OfflineArtPainter old) =>
      old.t != t || old.accent != accent || old.line != line;
}
/// Modal dialog shown when the user tries to use an internet-required section
/// while offline: a finite «no internet» motion, one short line, then
/// «إعادة المحاولة» and «إخفاء».
///
/// Returns `true` when the user taps retry and the device is online
/// (caller should refresh). Returns `false` when dismissed.
Future<bool> showOfflineDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? buttonLabel,
  ConnectivityService? connectivity,
}) async {
  final l10n = AppLocalizations.of(context);
  final t = title ?? l10n.translate('noInternet');
  final m = message ?? l10n.translate('offlineSectionRequiresInternet');

  Future<bool> showOnce() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        // Scrollable so the two stacked action buttons can NEVER be clipped
        // on short screens — the hide button always renders fully.
        scrollable: true,
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: OfflineSignalArt()),
            const SizedBox(height: 10),
            Text(t,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1.4,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            Text(m,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    height: 1.55,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 20),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh_rounded, size: 19),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(buttonLabel ?? l10n.translate('retry'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Hide — only closes this notice; the screen stays as it is.
            SizedBox(
              height: 46,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  backgroundColor: AppColors.surfaceVariant.withAlpha(90),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(l10n.translate('offlineDialogHide'),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  while (true) {
    final retried = await showOnce();
    if (!retried) return false;
    // User tapped retry — check connectivity (a very poor link is probed
    // once right now, bounded by the probe timeout).
    if (connectivity != null &&
        (connectivity.isOnline || await connectivity.recheck())) {
      return true;
    }
    // Still offline — show dialog again
  }
}