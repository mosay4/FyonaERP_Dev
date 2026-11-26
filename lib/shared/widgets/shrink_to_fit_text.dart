import 'package:flutter/material.dart';

/// A name that is shown whole: it shrinks step by step from the style's
/// size down to [minFontSize] to fit one line; a name still too long at the
/// smallest size wraps onto a second line instead of being cut.
class ShrinkToFitText extends StatelessWidget {
  const ShrinkToFitText(
    this.text, {
    super.key,
    required this.style,
    this.minFontSize = 10,
    this.maxLines = 2,
    this.textAlign,
  });

  final String text;
  final TextStyle style;
  final double minFontSize;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final dir = Directionality.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      final maxSize = style.fontSize ?? 14;
      var size = maxSize;
      bool fits(double s, int lines) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style.copyWith(fontSize: s)),
          textDirection: dir,
          textScaler: scaler,
          maxLines: lines,
        )..layout(maxWidth: box.maxWidth);
        final ok = !tp.didExceedMaxLines;
        tp.dispose();
        return ok;
      }

      if (box.maxWidth.isFinite) {
        while (size > minFontSize && !fits(size, 1)) {
          size = (size - 0.5).clamp(minFontSize, maxSize);
        }
      }
      final oneLine = !box.maxWidth.isFinite || fits(size, 1);
      return Text(
        text,
        maxLines: oneLine ? 1 : maxLines,
        softWrap: !oneLine,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: style.copyWith(fontSize: size, height: oneLine ? null : 1.25),
      );
    });
  }
}
