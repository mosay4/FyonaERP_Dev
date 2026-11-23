import 'package:flutter/material.dart';

/// Clear, compact payment-brand chips (like international payment pages).
///
/// Each brand is a small rounded chip with its official colours + a crisp
/// single-line wordmark. Widths are fixed and small so a row of them wraps
/// (or scrolls) cleanly on every screen size — no overflow.
class PaymentMethodIcons {
  PaymentMethodIcons._();

  static const double _h = 24;

  static Widget visa({double height = _h}) => _chip(
        height: height,
        background: const Color(0xFF1A1F71),
        child: Text(
          'VISA',
          style: TextStyle(
            color: Colors.white,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            fontSize: (height * 0.4).clamp(10, 14),
            height: 1,
          ),
        ),
      );

  static Widget mastercard({double height = _h}) => _chip(
        height: height,
        background: Colors.white,
        borderColor: const Color(0xFFD8D8D8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              Align(alignment: Alignment.centerLeft, child: _dot(height * 0.32, const Color(0xFFEB001B))),
              Align(alignment: Alignment.centerRight, child: _dot(height * 0.32, const Color(0xFFF79E1B))),
            ]),
          ],
        ),
      );

  static Widget amazonPay({double height = _h}) => _chip(
        height: height,
        background: Colors.white,
        borderColor: const Color(0xFFD8D8D8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('amazon', style: TextStyle(color: const Color(0xFF232F3E), fontWeight: FontWeight.w800, fontSize: (height * 0.32).clamp(9, 13), height: 1)),
            const SizedBox(width: 2),
            const Icon(Icons.sentiment_satisfied, size: 11, color: Color(0xFFFFB02E)),
          ],
        ),
      );

  static Widget applePay({double height = _h}) => _chip(
        height: height,
        background: const Color(0xFF000000),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apple, color: Colors.white, size: (height * 0.52).clamp(11, 15)),
            const SizedBox(width: 3),
            Text('Pay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: (height * 0.32).clamp(9, 13), height: 1)),
          ],
        ),
      );

  static Widget googlePay({double height = _h}) => _chip(
        height: height,
        background: Colors.white,
        borderColor: const Color(0xFFD8D8D8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: (height * 0.52).clamp(11, 14), height: (height * 0.52).clamp(11, 14), child: CustomPaint(painter: _GoogleGPainter())),
            const SizedBox(width: 3),
            Text('Pay', style: TextStyle(color: const Color(0xFF5F6368), fontWeight: FontWeight.w700, fontSize: (height * 0.32).clamp(9, 13), height: 1)),
          ],
        ),
      );

  static Widget payPal({double height = _h}) => _chip(
        height: height,
        background: Colors.white,
        borderColor: const Color(0xFFD8D8D8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Pay', style: TextStyle(color: const Color(0xFF003087), fontWeight: FontWeight.w800, fontStyle: FontStyle.italic, fontSize: (height * 0.34).clamp(9, 13), height: 1)),
            Text('Pal', style: TextStyle(color: const Color(0xFF009CDE), fontWeight: FontWeight.w800, fontStyle: FontStyle.italic, fontSize: (height * 0.34).clamp(9, 13), height: 1)),
          ],
        ),
      );

  static Widget mada({double height = _h}) => _chip(
        height: height,
        background: const Color(0xFF1B4E8F),
        child: Text('mada', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: (height * 0.36).clamp(10, 14), height: 1)),
      );

  static Widget stripe({double height = _h}) => _chip(
        height: height,
        background: const Color(0xFF635BFF),
        child: Text('stripe', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontStyle: FontStyle.italic, fontSize: (height * 0.36).clamp(10, 14), height: 1)),
      );

  static Widget _dot(double size, Color color) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));

  static Widget _chip({
    required double height,
    required Color background,
    required Widget child,
    Color? borderColor,
  }) {
    // Slim compact chip; width is controlled by the parent (Row/Expanded →
    // international-payment look): fixed small height, centered content.
    return Container(
      height: height,
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(5),
        border: borderColor != null ? Border.all(color: borderColor, width: 1) : null,
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Authentic Google "G" — blue/red/yellow/green four-piece monogram.
class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h / 2);
    final r = w / 2;

    final blue = Paint()..color = const Color(0xFF4285F4);
    final red = Paint()..color = const Color(0xFFEA4335);
    final yellow = Paint()..color = const Color(0xFFFBBC05);
    final green = Paint()..color = const Color(0xFF34A853);

    canvas.drawArc(Rect.fromCircle(center: center, radius: r * 0.7), 3 * 3.14159 / 2, 1.05 * 3.14159 / 2, true, blue);
    canvas.drawArc(Rect.fromCircle(center: center, radius: r * 0.7), 0, 1.05 * 3.14159 / 2, true, red);
    canvas.drawRect(Rect.fromCenter(center: Offset(w * 0.8, h / 2), width: w * 0.16, height: h * 0.72), yellow);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, h * 0.62), width: w * 0.9, height: h * 0.28), Radius.circular(2)), green);
  }

  @override
  bool shouldRepaint(covariant _GoogleGPainter oldDelegate) => false;
}