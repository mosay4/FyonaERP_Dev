import 'package:flutter/material.dart';
import 'breakpoints.dart';

class TypographySizes {
  TypographySizes._();

  // Semantic style keys
  static const String caption = 'caption';
  static const String bodySmall = 'body_small';
  static const String body = 'body';
  static const String bodyLarge = 'body_large';
  static const String titleSmall = 'title_small';
  static const String title = 'title';
  static const String headingSmall = 'heading_small';
  static const String heading = 'heading';
  static const String display = 'display';

  // Base sizes — professional scale (phone baseline at 390px)
  // Inspired by Revolut / Notion / Stripe typography
  static const Map<String, double> _base = {
    caption: 14,
    bodySmall: 15,
    body: 16,
    bodyLarge: 18,
    titleSmall: 21,
    title: 24,
    headingSmall: 28,
    heading: 32,
    display: 38,
  };

  // Font weights — bolder for clear visual hierarchy
  static const Map<String, FontWeight> _weights = {
    caption: FontWeight.w500,
    bodySmall: FontWeight.w500,
    body: FontWeight.w500,
    bodyLarge: FontWeight.w600,
    titleSmall: FontWeight.w600,
    title: FontWeight.w700,
    headingSmall: FontWeight.w700,
    heading: FontWeight.w800,
    display: FontWeight.w900,
  };

  // Scale factors per device tier
  static const Map<DeviceType, double> _scale = {
    DeviceType.phoneSmall: 0.90,
    DeviceType.phone: 1.00,
    DeviceType.phoneLarge: 1.05,
    DeviceType.tablet: 1.15,
    DeviceType.tabletLarge: 1.25,
    DeviceType.desktop: 1.35,
  };

  static double size(String style, double screenWidth) {
    final device = Breakpoints.deviceType(screenWidth);
    final base = _base[style] ?? _base[body]!;
    final scale = _scale[device] ?? 1.0;
    return (base * scale).clamp(10.0, 60.0);
  }

  static FontWeight weight(String style) {
    return _weights[style] ?? FontWeight.w500;
  }
}

class GridSystem {
  GridSystem._();

  static int columns(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) return 1;
    if (screenWidth < Breakpoints.tablet) return 2;
    if (screenWidth < Breakpoints.tabletLarge) return 2;
    if (screenWidth < Breakpoints.desktop) return 3;
    return 4;
  }

  static double columnWidth(double screenWidth, {int? cols, double gutter = 12}) {
    final c = cols ?? columns(screenWidth);
    final available = screenWidth - (gutter * (c + 1));
    return available / c;
  }
}

class FormLayout {
  FormLayout._();

  static double? maxWidth(double screenWidth) {
    if (screenWidth < Breakpoints.tablet) return null;
    if (screenWidth < Breakpoints.desktop) return 600;
    return 680;
  }

  static double fieldHeight(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) return 44;
    if (screenWidth < Breakpoints.desktop) return 46;
    return 48;
  }

  static double fieldSpacing(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) return 12;
    if (screenWidth < Breakpoints.desktop) return 12;
    return 16;
  }

  static double buttonHeight(double screenWidth) => fieldHeight(screenWidth);

  static EdgeInsets buttonPadding(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) {
      return const EdgeInsets.symmetric(horizontal: 24, vertical: 12);
    }
    if (screenWidth < Breakpoints.desktop) {
      return const EdgeInsets.symmetric(horizontal: 28, vertical: 12);
    }
    return const EdgeInsets.symmetric(horizontal: 36, vertical: 14);
  }

  static double sectionSpacing(double screenWidth) {
    return Breakpoints.isDesktop(screenWidth) ? 32 : 24;
  }
}

class DialogLayout {
  DialogLayout._();

  static double width(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) {
      return (screenWidth * 0.90).clamp(0, 380);
    }
    if (screenWidth < Breakpoints.tablet) {
      return (screenWidth * 0.85).clamp(0, 440);
    }
    if (screenWidth < Breakpoints.desktop) {
      return (screenWidth * 0.55).clamp(0, 520);
    }
    return (screenWidth * 0.40).clamp(0, 560);
  }

  static EdgeInsets padding(double screenWidth) {
    return EdgeInsets.all(Breakpoints.isDesktop(screenWidth) ? 24 : 16);
  }
}

class CardLayout {
  CardLayout._();

  static double padding(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) return 12;
    if (screenWidth < Breakpoints.desktop) return 16;
    return 20;
  }

  static double radius(double screenWidth) {
    if (screenWidth < Breakpoints.phoneLarge) return 10;
    if (screenWidth < Breakpoints.desktop) return 12;
    return 14;
  }
}

class TableLayout {
  TableLayout._();

  static double rowHeight(double screenWidth) {
    if (screenWidth < Breakpoints.tablet) return 48;
    return 52;
  }

  static double fontSize(double screenWidth) {
    return TypographySizes.size(TypographySizes.bodySmall, screenWidth);
  }
}

double _scaleValue(double value, double screenWidth) {
  final device = Breakpoints.deviceType(screenWidth);
  const scales = {
    DeviceType.phoneSmall: 0.90,
    DeviceType.phone: 1.00,
    DeviceType.phoneLarge: 1.05,
    DeviceType.tablet: 1.15,
    DeviceType.tabletLarge: 1.25,
    DeviceType.desktop: 1.35,
  };
  final factor = scales[device] ?? 1.0;
  return (value * factor).clamp(1, double.infinity);
}

class R {
  R._();

  // ── Screen Info ──

  static double width(BuildContext context) => MediaQuery.of(context).size.width;
  static double height(BuildContext context) => MediaQuery.of(context).size.height;

  // ── Device Detection ──

  static bool isPhone(BuildContext context) => Breakpoints.isPhone(width(context));
  static bool isTablet(BuildContext context) => Breakpoints.isTablet(width(context));
  static bool isDesktop(BuildContext context) => Breakpoints.isDesktop(width(context));
  static DeviceType device(BuildContext context) => Breakpoints.deviceType(width(context));

  // ── Responsive Sizing ──

  static double scale(BuildContext context, double value) => _scaleValue(value, width(context));

  static double font(BuildContext context, [String? style]) {
    return TypographySizes.size(style ?? TypographySizes.body, width(context));
  }

  /// Responsive font size from a raw pixel value.
  static double fontSize(BuildContext context, double size) {
    return _scaleValue(size, width(context));
  }

  static double icon(BuildContext context, [double base = 22]) {
    return _scaleValue(base, width(context));
  }

  static double radiusValue(BuildContext context, [double base = 12]) {
    return _scaleValue(base, width(context));
  }

  // ── Padding / Margin ──

  static EdgeInsets padding(BuildContext context) {
    final w = width(context);
    final h = w < Breakpoints.phoneLarge ? 12.0 : (w < Breakpoints.desktop ? 16.0 : 24.0);
    return EdgeInsets.symmetric(horizontal: h, vertical: 8);
  }

  static EdgeInsets paddingAll(BuildContext context, [double base = 12]) {
    return EdgeInsets.all(_scaleValue(base, width(context)));
  }

  static EdgeInsets paddingXY(BuildContext context, {double x = 12, double y = 8}) {
    return EdgeInsets.symmetric(
      horizontal: _scaleValue(x, width(context)),
      vertical: _scaleValue(y, width(context)),
    );
  }

  // ── Spacing ──

  static double spacing(BuildContext context, [double base = 12]) {
    return _scaleValue(base, width(context));
  }

  static double gap(BuildContext context) {
    return _scaleValue(8, width(context));
  }

  static double sectionGap(BuildContext context) {
    return _scaleValue(24, width(context));
  }

  // ── Grid ──

  static int columns(BuildContext context) => GridSystem.columns(width(context));
  static double columnWidth(BuildContext context, {int? cols}) {
    return GridSystem.columnWidth(width(context), cols: cols);
  }

  // ── Dimensions ──

  static double cardPadding(BuildContext context) => CardLayout.padding(width(context));
  static double cardRadius(BuildContext context) => CardLayout.radius(width(context));
  static double fieldHeight(BuildContext context) => FormLayout.fieldHeight(width(context));
  static double buttonHeight(BuildContext context) => FormLayout.buttonHeight(width(context));
  static EdgeInsets buttonPadding(BuildContext context) => FormLayout.buttonPadding(width(context));
  static double dialogWidth(BuildContext context) => DialogLayout.width(width(context));
  static double navHeight(BuildContext context) => Breakpoints.isPhone(width(context)) ? 56 : 65;
  static double? formMaxWidth(BuildContext context) => FormLayout.maxWidth(width(context));

  // ── Text Style (convenience) ──

  static TextStyle textStyle(BuildContext context, [String? style, Color? color]) {
    final s = style ?? TypographySizes.body;
    return TextStyle(
      fontFamily: 'Cairo',
      fontSize: TypographySizes.size(s, width(context)),
      fontWeight: TypographySizes.weight(s),
      color: color,
    );
  }
}

