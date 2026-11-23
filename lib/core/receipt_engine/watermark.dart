import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'models.dart';

class WatermarkPainter extends CustomPainter {
  final WatermarkConfig config;

  WatermarkPainter({required this.config});

  @override
  void paint(Canvas canvas, Size size) {
    if (!config.enabled) return;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(config.rotation * 3.14159 / 180);
    final textPainter = TextPainter(
      text: TextSpan(
        text: config.text,
        style: TextStyle(
          color: Colors.black.withValues(alpha: config.opacity),
          fontSize: config.size,
          fontFamily: 'Cairo',
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.rtl,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(-textPainter.width / 2, -textPainter.height / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WatermarkPainter old) => old.config != config;
}

pw.Widget buildPdfWatermark(WatermarkConfig config) {
  if (!config.enabled) return pw.SizedBox();
  return pw.Transform.rotate(
    angle: config.rotation * 3.14159 / 180,
    child: pw.Opacity(
      opacity: config.opacity,
      child: pw.Center(
        child: pw.Text(
          config.text,
          style: pw.TextStyle(
            fontSize: config.size,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}

