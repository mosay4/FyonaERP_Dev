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
  const OfflineSignalArt({super.key, this.width = 150});

  @override
  State<OfflineSignalArt> createState() => _OfflineSignalArtState();
}

class _OfflineSignalArtState extends State<OfflineSignalArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    return Semantics(
      label: 'offline',
      child: SizedBox(
        width: w,
        height: w * 0.78,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _OfflineArtPainter(
              t: _c.value,
              accent: const Color(0xFFE0892B),
              track: AppColors.textTertiary,
              cloud: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineArtPainter extends CustomPainter {
  _OfflineArtPainter({
    required this.t,
    required this.accent,
    required this.track,
    required this.cloud,
  });

  final double t;
  final Color accent;
  final Color track;
  final Color cloud;

  double _seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final dot = Offset(w * 0.36, h * 0.80);
    final radii = [h * 0.15, h * 0.29, h * 0.43];
    final r3 = radii[2];

    // Soft halo behind the mark (pops in once).
    final halo = Curves.easeOutBack.transform(_seg(0, .3));
    canvas.drawCircle(dot + Offset(0, -r3 * .55), r3 * .97 * halo,
        Paint()..color = accent.withValues(alpha: .09));

    // Cloud (top-end) drifting away and dimming once the link breaks.
    final drift = Curves.easeInOutCubic.transform(_seg(.45, .9));
    final cAppear = _seg(.05, .3);
    final cc = Offset(w * 0.84 + 5 * drift, h * 0.22 - 3 * drift);
    final cPaint = Paint()
      ..color = cloud.withValues(alpha: (.55 - .25 * drift) * cAppear);
    final u = w * 0.055;
    canvas.drawCircle(cc + Offset(-u * 1.1, u * .35), u * .9, cPaint);
    canvas.drawCircle(cc + Offset(0, -u * .15), u * 1.25, cPaint);
    canvas.drawCircle(cc + Offset(u * 1.15, u * .4), u * .85, cPaint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cc.dx - u * 1.9, cc.dy + u * .2, cc.dx + u * 1.95,
            cc.dy + u * 1.25),
        Radius.circular(u * .55),
      ),
      cPaint,
    );

    // Dotted link mark → cloud: appears, then the middle dots fall away.
    final from = dot + Offset(r3 * .78, -r3 * .84);
    final to = cc + Offset(-u * 2.0, u * 1.4);
    for (var i = 0; i < 4; i++) {
      final f = (i + .5) / 4;
      final appear = _seg(.12 + i * .04, .26 + i * .04);
      final breakAt = i == 1 || i == 2 ? _seg(.42, .6) : _seg(.62, .85) * .6;
      final a = appear * (1 - breakAt);
      if (a <= 0) continue;
      final p = Offset.lerp(from, to, f)! +
          Offset(0, (i == 1 || i == 2) ? 6 * breakAt : 0);
      canvas.drawCircle(
          p, w * 0.014, Paint()..color = track.withValues(alpha: .7 * a));
    }

    // Wi-Fi arcs: light inner → outer, then fade outer-first.
    final stroke = h * 0.055;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    const sweep = 1.5;
    const start = -1.5708 - sweep / 2;
    for (var i = 0; i < 3; i++) {
      final rect = Rect.fromCircle(center: dot, radius: radii[i]);
      final on = Curves.easeOut.transform(_seg(.04 + i * .07, .18 + i * .07));
      final off = Curves.easeInOut.transform(
          _seg(.42 + (2 - i) * .07, .58 + (2 - i) * .07));
      canvas.drawArc(rect, start, sweep, false,
          arc..color = track.withValues(alpha: .22 * on));
      final lit = on * (1 - off * .78);
      if (lit > 0) {
        canvas.drawArc(
          rect,
          start + sweep * (1 - on) / 2,
          sweep * on,
          false,
          arc..color = accent.withValues(alpha: lit),
        );
      }
    }
    canvas.drawCircle(dot, stroke * .95,
        Paint()..color = accent.withValues(alpha: _seg(0, .12)));

    // Strike draws across the mark.
    final k = Curves.easeInOutCubic.transform(_seg(.62, .88));
    if (k > 0) {
      final p1 = dot + Offset(-r3 * .78, -r3 * .98);
      final p2 = dot + Offset(r3 * .62, r3 * .08);
      canvas.drawLine(
        p1,
        Offset.lerp(p1, p2, k)!,
        Paint()
          ..color = accent
          ..strokeWidth = stroke * .95
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OfflineArtPainter old) =>
      old.t != t ||
      old.accent != accent ||
      old.track != track ||
      old.cloud != cloud;
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
            const SizedBox(height: 2),
            Text(l10n.translate('offlineAutoSyncHint'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11.5,
                    height: 1.5,
                    color: AppColors.textTertiary)),
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
    // User tapped retry — check connectivity
    if (connectivity != null && connectivity.isOnline) return true;
    // Still offline — show dialog again
  }
}