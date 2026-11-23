
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

/// Hand-painted FYONA identity art for the reconciliation section — drawn in
/// the burgundy/grey palette, theme-aware, zero image assets. RepaintBoundary
/// everywhere so nothing repaints unless the theme flips.
class ReconArt extends StatelessWidget {
  final ReconArtKind kind;
  final double size;
  const ReconArt(this.kind, {super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _ReconArtPainter(kind: kind, dark: dark),
      ),
    );
  }
}

enum ReconArtKind { bank, cash, inventory }

class _ReconArtPainter extends CustomPainter {
  final ReconArtKind kind;
  final bool dark;
  _ReconArtPainter({required this.kind, required this.dark});

  static const _burgundy = AppColors.primary;
  Color get _stroke => dark ? Colors.white70 : const Color(0xFF565656);
  Color get _softFill =>
      dark ? Colors.white.withAlpha(14) : Colors.black.withAlpha(10);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    switch (kind) {
      case ReconArtKind.bank:
        _paintBank(canvas, s);
      case ReconArtKind.cash:
        _paintCash(canvas, s);
      case ReconArtKind.inventory:
        _paintInventory(canvas, s);
    }
  }

  void _paintBank(Canvas canvas, double s) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round
      ..color = _stroke;
    final accent = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.05
      ..strokeCap = StrokeCap.round
      ..color = _burgundy;
    // Pediment triangle
    final apex = Offset(s * 0.5, s * 0.10);
    final bl = Offset(s * 0.12, s * 0.30);
    final br = Offset(s * 0.88, s * 0.30);
    final ped = Path()
      ..moveTo(bl.dx, bl.dy)
      ..lineTo(apex.dx, apex.dy)
      ..lineTo(br.dx, br.dy)
      ..close();
    canvas.drawPath(ped, stroke..color = _stroke);
    // Columns (4)
    for (var i = 0; i < 4; i++) {
      final x = s * (0.20 + 0.20 * i);
      canvas.drawLine(Offset(x, s * 0.38), Offset(x, s * 0.72),
          stroke..color = _stroke);
    }
    // Base
    canvas.drawLine(Offset(s * 0.10, s * 0.78), Offset(s * 0.90, s * 0.78),
        stroke..color = _stroke);
    canvas.drawLine(Offset(s * 0.06, s * 0.86), Offset(s * 0.94, s * 0.86),
        accent);
    // Burgundy coin: the reconciliation lens
    canvas.drawCircle(Offset(s * 0.80, s * 0.44), s * 0.115,
        Paint()..color = _burgundy.withAlpha(28));
    canvas.drawCircle(Offset(s * 0.80, s * 0.44), s * 0.115,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.035
          ..color = _burgundy);
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.04
      ..strokeCap = StrokeCap.round
      ..color = _burgundy;
    canvas.drawLine(Offset(s * 0.745, s * 0.445), Offset(s * 0.785, s * 0.485), tick);
    canvas.drawLine(Offset(s * 0.785, s * 0.485), Offset(s * 0.858, s * 0.398), tick);
  }

  void _paintCash(Canvas canvas, double s) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round
      ..color = _stroke;
    final fill = Paint()..color = _softFill;
    // Two stacked banknotes
    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.14, s * 0.30, s * 0.72, s * 0.40),
        Radius.circular(s * 0.07));
    canvas.drawRRect(r, fill);
    canvas.drawRRect(r, stroke);
    canvas.drawCircle(Offset(s * 0.5, s * 0.50), s * 0.115,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.045
          ..color = _stroke);
    // '$' implied by a vertical stroke pair in the middle
    canvas.drawLine(Offset(s * 0.5, s * 0.415), Offset(s * 0.5, s * 0.585),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.04
          ..strokeCap = StrokeCap.round
          ..color = _burgundy);
    // Corner ticks
    for (final dx in [0.20, 0.80]) {
      canvas.drawLine(Offset(s * dx, s * 0.38), Offset(s * dx, s * 0.62),
          stroke..strokeWidth = s * 0.03);
    }
    // Settlement checkmark halo
    final p = Path()
      ..moveTo(s * 0.60, s * 0.16)
      ..lineTo(s * 0.70, s * 0.26)
      ..lineTo(s * 0.90, s * 0.02);
    canvas.drawPath(p, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.05
      ..strokeCap = StrokeCap.round
      ..color = _burgundy);
  }

  void _paintInventory(Canvas canvas, double s) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round
      ..color = _stroke;
    final fill = Paint()..color = _softFill;
    // Two crates
    final big = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.10, s * 0.28, s * 0.48, s * 0.52),
        Radius.circular(s * 0.07));
    final small = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.58, s * 0.48, s * 0.34, s * 0.32),
        Radius.circular(s * 0.06));
    canvas.drawRRect(big, fill);
    canvas.drawRRect(big, stroke);
    canvas.drawRRect(small, fill);
    canvas.drawRRect(small, stroke);
    // Tape on the big crate
    canvas.drawLine(Offset(s * 0.34, s * 0.28), Offset(s * 0.34, s * 0.80),
        stroke..strokeWidth = s * 0.03);
    // Counting checklist card with burgundy ticks
    final card = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.52, s * 0.06, s * 0.40, s * 0.34),
        Radius.circular(s * 0.06));
    canvas.drawRRect(card, Paint()..color = dark ? Colors.black.withAlpha(120) : Colors.white);
    canvas.drawRRect(card, stroke..strokeWidth = s * 0.035);
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.04
      ..strokeCap = StrokeCap.round
      ..color = _burgundy;
    canvas.drawLine(Offset(s * 0.58, s * 0.15), Offset(s * 0.625, s * 0.195), tick);
    canvas.drawLine(Offset(s * 0.625, s * 0.195), Offset(s * 0.70, s * 0.11), tick);
    canvas.drawLine(Offset(s * 0.74, s * 0.16), Offset(s * 0.86, s * 0.16),
        stroke..strokeWidth = s * 0.03);
    canvas.drawLine(Offset(s * 0.58, s * 0.30), Offset(s * 0.70, s * 0.335), tick);
    canvas.drawLine(Offset(s * 0.74, s * 0.32), Offset(s * 0.86, s * 0.32),
        stroke..strokeWidth = s * 0.03);
  }

  @override
  bool shouldRepaint(covariant _ReconArtPainter old) =>
      old.dark != dark || old.kind != kind;
}
