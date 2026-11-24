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

/// Modal dialog shown when the user tries to use an internet-required section
/// while offline. Centered + animated connectivity icon.
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
        // on short screens — the back button always renders fully.
        scrollable: true,
        backgroundColor: AppColors.surface,
        title: Text(t, style: TextStyle(fontFamily: 'Cairo', fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary), textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          const SizedBox(height: 12),
          ConnectivityIndicator(online: false, size: 40),
          const SizedBox(height: 14),
          Text(m, textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, height: 1.6, color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Text(l10n.translate('offlineAutoSyncHint'),
              textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textDisabled)),
        ]),
        actions: [
          // Primary CTA (full-width column): Retry first, then Back below it.
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(buttonLabel ?? l10n.translate('retry'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              // Hide — only closes this notice; the screen stays as it is.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(ctx, false),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(l10n.translate('offlineDialogHide'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
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