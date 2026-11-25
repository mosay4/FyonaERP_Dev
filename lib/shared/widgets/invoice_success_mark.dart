import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../services/scan_sfx.dart';

/// Short, finite «invoice created» motion (~0.9 s, plays once):
/// the disc pops in, one soft ripple ring expands and fades, then the check
/// stroke draws itself. The completion chime ([ScanSfx.invoiceDone]) fires
/// as the check starts, so sound and motion land together.
class InvoiceSuccessMark extends StatefulWidget {
  final double size;
  final Color? color;
  final bool playSound;
  const InvoiceSuccessMark({
    super.key,
    this.size = 64,
    this.color,
    this.playSound = true,
  });

  @override
  State<InvoiceSuccessMark> createState() => _InvoiceSuccessMarkState();
}

class _InvoiceSuccessMarkState extends State<InvoiceSuccessMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _chime;

  @override
  void initState() {
    super.initState();
    _c.forward();
    if (widget.playSound) {
      _chime = Timer(const Duration(milliseconds: 180), () {
        unawaited(ScanSfx.invoiceDone());
      });
    }
  }

  @override
  void dispose() {
    _chime?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.success;
    final s = widget.size;
    return SizedBox(
      width: s * 1.5,
      height: s * 1.5,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          painter: _MarkPainter(_c.value, color, s),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final double t;
  final Color color;
  final double s;
  _MarkPainter(this.t, this.color, this.s);

  double _seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = s / 2;

    // Ripple: one ring expanding from the disc and fading out.
    final rp = Curves.easeOutCubic.transform(_seg(.15, .85));
    if (rp > 0 && rp < 1) {
      canvas.drawCircle(
        c,
        r * (1 + .45 * rp),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - rp) + .4
          ..color = color.withValues(alpha: .35 * (1 - rp)),
      );
    }

    // Disc pop (slight overshoot) with a soft tinted fill + thin rim.
    final pop = Curves.easeOutBack.transform(_seg(0, .4));
    final dr = r * pop;
    if (dr > 0) {
      canvas.drawCircle(c, dr, Paint()..color = color.withValues(alpha: .12));
      canvas.drawCircle(
        c,
        dr - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: .35 * _seg(0, .3)),
      );
    }

    // Check stroke draws itself.
    final ck = Curves.easeInOutCubic.transform(_seg(.28, .72));
    if (ck <= 0) return;
    final p1 = c + Offset(-r * .36, r * .02);
    final p2 = c + Offset(-r * .1, r * .27);
    final p3 = c + Offset(r * .38, -r * .26);
    final l1 = (p2 - p1).distance;
    final l2 = (p3 - p2).distance;
    final drawn = (l1 + l2) * ck;
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (drawn <= l1) {
      final q = Offset.lerp(p1, p2, drawn / l1)!;
      path.lineTo(q.dx, q.dy);
    } else {
      path.lineTo(p2.dx, p2.dy);
      final q = Offset.lerp(p2, p3, math.min(1.0, (drawn - l1) / l2))!;
      path.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s * .085
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t || old.color != color;
}
