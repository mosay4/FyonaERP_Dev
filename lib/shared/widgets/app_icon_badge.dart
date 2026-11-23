import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'dual_tone_icon.dart';

class AppIconBadge extends StatelessWidget {
  final List<List<dynamic>> icon;
  final double size;
  final double iconSize;
  final Color? backgroundColor;
  final Color? accentColor;
  final Color? borderColor;
  final double borderRadius;
  final double borderWidth;

  const AppIconBadge({
    super.key,
    required this.icon,
    this.size = 48,
    this.iconSize = 24,
    this.backgroundColor,
    this.accentColor,
    this.borderColor,
    this.borderRadius = 12,
    this.borderWidth = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.surface,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? AppColors.border,
          width: borderWidth,
        ),
      ),
      child: Center(
        child: DualToneHugeIcon(
          icon: icon,
          accentColor: accentColor ?? AppColors.primary,
          baseColor: AppColors.textSecondary,
          size: iconSize,
        ),
      ),
    );
  }
}
