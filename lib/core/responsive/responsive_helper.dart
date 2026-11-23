import 'package:flutter/material.dart';
import 'breakpoints.dart';
import 'r_api.dart';

class ResponsiveHelper {
  ResponsiveHelper._();

  @Deprecated('Use R.scale() instead')
  static double fontScale(double width) {
    if (width < Breakpoints.tablet) return 1.0;
    if (width < Breakpoints.desktop) return 1.1;
    return 1.2;
  }

  @Deprecated('Use R.font() instead')
  static double fontSize(double baseSize, double width) {
    return baseSize * fontScale(width);
  }

  @Deprecated('Use R.spacing() instead')
  static double spacing(double baseSpacing, double width) {
    if (width < Breakpoints.tablet) return baseSpacing;
    if (width < Breakpoints.desktop) return baseSpacing * 1.25;
    return baseSpacing * 1.5;
  }

  @Deprecated('Use R.icon() instead')
  static double iconSize(double baseSize, double width) {
    if (width < Breakpoints.tablet) return baseSize;
    if (width < Breakpoints.desktop) return baseSize * 1.15;
    return baseSize * 1.3;
  }

  @Deprecated('Use R.padding() instead')
  static EdgeInsets screenPadding(double width) {
    if (width < Breakpoints.tablet) {
      return const EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    }
    if (width < Breakpoints.desktop) {
      return const EdgeInsets.symmetric(horizontal: 24, vertical: 16);
    }
    return const EdgeInsets.symmetric(horizontal: 32, vertical: 20);
  }

  @Deprecated('Use R.cardPadding() instead')
  static EdgeInsets cardPadding(double width) {
    if (width < Breakpoints.tablet) {
      return const EdgeInsets.all(12);
    }
    return const EdgeInsets.all(16);
  }

  @Deprecated('Use R.buttonHeight() instead')
  static double buttonHeight(double width) {
    return FormLayout.buttonHeight(width);
  }

  @Deprecated('Use R.fieldHeight() instead')
  static double inputHeight(double width) {
    return FormLayout.fieldHeight(width);
  }
}
