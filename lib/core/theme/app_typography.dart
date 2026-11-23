import 'package:flutter/material.dart';

class AppTypography {
  AppTypography._();

  static const String fontFamily = 'Cairo';

  // ── Font Sizes ──
  static const double caption = 11;
  static const double bodySmall = 13;
  static const double body = 15;
  static const double bodyLarge = 17;
  static const double title = 19;
  static const double headline = 26;
  static const double display = 34;
  static const double displayLarge = 42;

  // ── Text Styles ──
  static const TextStyle captionStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: caption,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle bodySmallStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: bodySmall,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle bodyStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: body,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle bodyLargeStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: bodyLarge,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle titleStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: title,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle headlineStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: headline,
    fontWeight: FontWeight.w800,
  );

  static const TextStyle displayStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: display,
    fontWeight: FontWeight.w900,
  );

  static const TextStyle displayLargeStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: displayLarge,
    fontWeight: FontWeight.w900,
  );
}

