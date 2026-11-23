import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../../core/theme/app_colors.dart';
import 'two_tone_icon.dart';

enum AppIconStyle { twoTone, outline, filled, badge }

class AppIcon extends StatelessWidget {
  final TwoToneIconData? twoToneIcon;
  final List<List<dynamic>>? icon;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? accentColor;
  final Color? backgroundColor;
  final Color? borderColor;
  final AppIconStyle style;
  final double strokeWidth;

  const AppIcon({
    super.key,
    this.twoToneIcon,
    this.icon,
    this.size = 24,
    this.iconSize = 24,
    this.color,
    this.accentColor,
    this.backgroundColor,
    this.borderColor,
    this.style = AppIconStyle.twoTone,
    this.strokeWidth = 1.8,
  }) : assert(
          twoToneIcon != null || icon != null,
          'Either twoToneIcon or icon must be provided',
        );

  const AppIcon.raw({
    super.key,
    required List<List<dynamic>> iconData,
    this.size = 24,
    this.iconSize = 24,
    this.color,
    this.style = AppIconStyle.outline,
    this.strokeWidth = 1.8,
  })  : twoToneIcon = null,
        icon = iconData,
        accentColor = null,
        backgroundColor = null,
        borderColor = null;

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case AppIconStyle.twoTone:
        return _buildTwoTone();
      case AppIconStyle.badge:
        return _buildBadge();
      case AppIconStyle.filled:
        return _buildFilled();
      case AppIconStyle.outline:
        return _buildOutline();
    }
  }

  Widget _buildTwoTone() {
    if (twoToneIcon != null) {
      return TwoToneIcon(
        data: twoToneIcon!,
        size: iconSize,
        outlineColor: color,
        detailColor: accentColor,
        strokeWidth: strokeWidth,
      );
    }
    return _buildOutline();
  }

  Widget _buildOutline() {
    final c = color ?? AppColors.textSecondary;
    return HugeIcon(
      icon: icon ?? twoToneIcon!.outline,
      color: c,
      size: iconSize,
      strokeWidth: strokeWidth,
    );
  }

  Widget _buildFilled() {
    final c = color ?? AppColors.primary;
    return HugeIcon(
      icon: icon ?? twoToneIcon!.outline,
      color: c,
      size: iconSize,
      strokeWidth: strokeWidth + 0.4,
    );
  }

  Widget _buildBadge() {
    final bg = backgroundColor ?? AppColors.surface;
    final bd = borderColor ?? AppColors.border;
    final ac = accentColor ?? AppColors.primary;
    final iconWidget = twoToneIcon != null
        ? TwoToneIcon(
            data: twoToneIcon!,
            size: iconSize,
            detailColor: ac,
            strokeWidth: strokeWidth,
          )
        : HugeIcon(
            icon: icon ?? twoToneIcon!.outline,
            color: AppColors.textSecondary,
            size: iconSize,
            strokeWidth: strokeWidth,
          );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.25),
        border: Border.all(color: bd, width: 0.5),
      ),
      child: Center(child: iconWidget),
    );
  }
}
