import 'package:flutter/material.dart';

/// Visual identity from RANY.pdf — soft rose background, crimson bubbles.
class ChatStyle {
  static const red = Color(0xFFD20E3A);
  static const redDark = Color(0xFFB0082B);
  static const redLight = Color(0xFFE63A5F);
  static const pinkBg = Color(0xFFFFF6F8);
  static const pinkSoft = Color(0xFFF7DDE6);
  static const pinkPale = Color(0xFFFCEBF0);
  static const white = Colors.white;
  static const ink = Color(0xFF20242B);
  static const grey = Color(0xFF8A8F98);
  static const green = Color(0xFF1FBF6B);
  static const blue = Color(0xFF2F80ED);
}

class ChatBackgroundPainter extends CustomPainter {
  const ChatBackgroundPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [ChatStyle.pinkBg, Color(0xFFFDEDF2)],
      ).createShader(rect);
    canvas.drawRect(rect, bg);
    void blob(Offset c, double r, Color color) {
      final p = Paint()
        ..shader = RadialGradient(
                colors: [color, color.withAlpha(0)])
            .createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, p);
    }

    blob(Offset(size.width * .05, size.height * .10), size.width * .55,
        ChatStyle.pinkSoft.withAlpha(160));
    blob(Offset(size.width * .98, size.height * .32), size.width * .5,
        ChatStyle.pinkSoft.withAlpha(110));
    blob(Offset(size.width * .18, size.height * .96), size.width * .6,
        ChatStyle.pinkSoft.withAlpha(130));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
