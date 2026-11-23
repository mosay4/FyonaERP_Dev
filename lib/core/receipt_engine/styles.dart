import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

PdfColor pdfColor(int value) {
  return PdfColor(
    ((value >> 16) & 0xFF) / 255,
    ((value >> 8) & 0xFF) / 255,
    (value & 0xFF) / 255,
  );
}

PdfColor pdfColorWithAlpha(int value, double opacity) {
  final r = ((value >> 16) & 0xFF) / 255;
  final g = ((value >> 8) & 0xFF) / 255;
  final b = (value & 0xFF) / 255;
  return PdfColor(r * opacity, g * opacity, b * opacity);
}

class DesignTokens {
  DesignTokens._();

  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacingMd = 12;
  static const double spacingLg = 16;
  static const double spacingXl = 24;
  static const double spacingXxl = 32;

  static const double radiusSm = 4;
  static const double radiusMd = 8;
  static const double radiusLg = 12;
  static const double radiusXl = 16;

  static const double fontSizeCaption = 9;
  static const double fontSizeSmall = 10;
  static const double fontSizeBody = 11;
  static const double fontSizeBodyLarge = 13;
  static const double fontSizeTitle = 14;
  static const double fontSizeHeader = 18;
  static const double fontSizeAmount = 20;
  static const double fontSizeDisplay = 24;

  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemiBold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;
}

class ThemeColors {
  ThemeColors._();

  static const Color primary = Color(0xFFA01530);
  static const Color primaryLight = Color(0xFFB82040);
  static const Color secondary = Color(0xFF4A4A4A);
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFE65100);
  static const Color danger = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);
  static const Color background = Color(0xFFF5F6F7);
  static const Color cardBackground = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFD5D8DA);
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF5A5A5A);
  static const Color textDisabled = Color(0xFF999999);
  static const Color amountText = Color(0xFFA01530);
  static const Color tableHeader = Color(0xFFA01530);
  static const Color tableRowEven = Color(0xFFF8F8F8);
  static const Color tableRowOdd = Color(0xFFFFFFFF);

  static const Color darkBackground = Color(0xFF0A0A0A);
  static const Color darkSurface = Color(0xFF151515);
  static const Color darkBorder = Color(0xFF252525);
  static const Color darkTextPrimary = Color(0xFFF5F5F5);
  static const Color darkTextSecondary = Color(0xFF888888);
}

class FontManager {
  FontManager._();

  static const String defaultFont = 'Cairo';
  static const List<String> arabicFonts = ['Cairo', 'Noto Naskh Arabic', 'Amiri'];

  static const Map<String, List<String>> fontFallbacks = {
    'Cairo': ['Noto Naskh Arabic', 'Amiri', 'Arial'],
    'Noto Naskh Arabic': ['Cairo', 'Amiri', 'Arial'],
    'Amiri': ['Cairo', 'Noto Naskh Arabic', 'Arial'],
  };

  static TextStyle style({
    required String fontFamily, required double fontSize,
    FontWeight fontWeight = FontWeight.w400, Color? color,
    double? height, TextDecoration? decoration,
  }) {
    return TextStyle(
      fontFamily: fontFamily, fontSize: fontSize,
      fontWeight: fontWeight, color: color, height: height,
      decoration: decoration, decorationColor: color,
    );
  }
}





