import 'package:flutter/material.dart';

/// الشعار الرسمي لـ Google بألوانه الأربعة، مرسوم يدوياً ليطابق أسلوب التطبيق.
class GoogleLogo extends StatelessWidget {
  final double size;

  const GoogleLogo({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: const _GoogleLogoPainter(),
    );
  }
}

final List<(Path, Color)> _googleParts = [
  (
    _svgPath(
      'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 '
      '14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z',
    ),
    const Color(0xFF4285F4),
  ),
  (
    _svgPath(
      'M12.54 19.41l-7.98-6.19C1.73 17.01 0 20.34 0 24s1.73 6.99 4.56 10.78'
      'l7.98-6.19C10.77 26.33 10 25.22 10 24s.77-2.33 2.54-4.59z',
    ),
    const Color(0xFF34A853),
  ),
  (
    _svgPath(
      'M24 38.5c-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 '
      '24 48c6.47 0 11.9-2.38 16.06-6.25l-6.85-6.85c-2.5 2.38-5.67 3.6-9.21 3.6z',
    ),
    const Color(0xFFFBBC05),
  ),
  (
    _svgPath(
      'M43.06 24c0-1.66-.15-3.25-.44-4.78H24v9.06h10.7c-.46 2.48-1.86 4.59'
      '-3.97 6.01l6.85 6.85C40.77 37.14 43.06 31.02 43.06 24z',
    ),
    const Color(0xFFEA4335),
  ),
];

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48);
    for (final (path, color) in _googleParts) {
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// مُحلِّل صغير لبيانات مسارات SVG يدعم الأوامر المستخدمة في شعار Google:
/// M/L/H/V/C/S/Z بأشكالها النسبية والمطلقة مع استمرار ضمني للأوامر.
Path _svgPath(String d) {
  final tokenRe =
      RegExp(r'[A-Za-z]|[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?');
  final tokens = tokenRe.allMatches(d).map((m) => m.group(0)!).toList();

  final path = Path();
  double x = 0, y = 0;
  double sx = 0, sy = 0;
  double lastCtrlX = 0, lastCtrlY = 0;
  var lastCmd = '';

  double num() => double.parse(tokens.removeAt(0));

  while (tokens.isNotEmpty) {
    var cmd = tokens.first;
    if (RegExp(r'^[A-Za-z]$').hasMatch(cmd)) {
      tokens.removeAt(0);
    } else {
      cmd = lastCmd;
    }
    if (cmd.isEmpty) break;

    final relative = cmd.toLowerCase() == cmd;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = relative ? x + num() : num();
        y = relative ? y + num() : num();
        path.moveTo(x, y);
        sx = x;
        sy = y;
        lastCmd = 'L';
      case 'L':
        x = relative ? x + num() : num();
        y = relative ? y + num() : num();
        path.lineTo(x, y);
        lastCmd = 'L';
      case 'H':
        x = relative ? x + num() : num();
        path.lineTo(x, y);
        lastCmd = 'H';
      case 'V':
        y = relative ? y + num() : num();
        path.lineTo(x, y);
        lastCmd = 'V';
      case 'C':
        double c1x, c1y, c2x, c2y, ex, ey;
        if (relative) {
          c1x = x + num(); c1y = y + num();
          c2x = x + num(); c2y = y + num();
          ex = x + num(); ey = y + num();
        } else {
          c1x = num(); c1y = num();
          c2x = num(); c2y = num();
          ex = num(); ey = num();
        }
        path.cubicTo(c1x, c1y, c2x, c2y, ex, ey);
        lastCtrlX = c2x;
        lastCtrlY = c2y;
        x = ex;
        y = ey;
        lastCmd = 'C';
      case 'S':
        double c1x, c1y, c2x, c2y, ex, ey;
        if (lastCmd == 'C' || lastCmd == 'S') {
          c1x = 2 * x - lastCtrlX;
          c1y = 2 * y - lastCtrlY;
        } else {
          c1x = x;
          c1y = y;
        }
        if (relative) {
          c2x = x + num(); c2y = y + num();
          ex = x + num(); ey = y + num();
        } else {
          c2x = num(); c2y = num();
          ex = num(); ey = num();
        }
        path.cubicTo(c1x, c1y, c2x, c2y, ex, ey);
        lastCtrlX = c2x;
        lastCtrlY = c2y;
        x = ex;
        y = ey;
        lastCmd = 'S';
      case 'Z':
        path.close();
        x = sx;
        y = sy;
        lastCmd = 'Z';
    }
  }
  return path;
}
