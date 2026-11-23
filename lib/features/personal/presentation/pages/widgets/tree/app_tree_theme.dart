import 'package:flutter/material.dart';
import '../../../../../../core/theme/app_colors.dart';

/// Premium dark financial design system for the tree feature.
/// Unified spacing, radius, typography, and color tokens.
class TreeTheme {
  TreeTheme._();

  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 20;
  static const double radiusFull = 999;

  static TextStyle get headingLg => TextStyle(
    fontFamily: 'Cairo', fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary,
  );
  static TextStyle get headingMd => TextStyle(
    fontFamily: 'Cairo', fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary,
  );
  static TextStyle get headingSm => TextStyle(
    fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary,
  );
  static TextStyle get bodyLg => TextStyle(
    fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary,
  );
  static TextStyle get bodyMd => TextStyle(
    fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary,
  );
  static TextStyle get bodySm => TextStyle(
    fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary,
  );
  static TextStyle get caption => TextStyle(
    fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.textTertiary,
  );
  static TextStyle get label => TextStyle(
    fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary,
  );

  static BoxDecoration get cardDecoration => BoxDecoration(
    color: AppColors.surfaceVariant,
    borderRadius: BorderRadius.circular(radiusLg),
    border: Border.all(color: AppColors.border, width: 1),
  );

  static BoxDecoration get cardDecorationSelected => BoxDecoration(
    color: AppColors.surfaceVariant,
    borderRadius: BorderRadius.circular(radiusLg),
    border: Border.all(color: AppColors.primary, width: 1.5),
  );

  static InputDecoration inputDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontFamily: 'Cairo', color: AppColors.textPlaceholder),
    filled: true,
    fillColor: AppColors.surfaceVariant,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusMd),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusMd),
      borderSide:  BorderSide(color: AppColors.border, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusMd),
      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
    ),
  );

  static Color nodeAccent(String typeId) {
    switch (typeId) {
      case 'income': return AppColors.success;
      case 'expense': return AppColors.danger;
      case 'asset': return AppColors.info;
      case 'investment': return const Color(0xFF8E24AA);
      case 'debt': return AppColors.warning;
      case 'saving': return const Color(0xFF00897B);
      case 'receivable': return const Color(0xFF43A047);
      default: return AppColors.primary;
    }
  }
}
