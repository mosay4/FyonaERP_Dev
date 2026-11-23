import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';

class InteractiveCard extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final bool useGradient;
  final Color? gradientColor;

  const InteractiveCard({
    super.key,
    required this.child,
    this.borderColor,
    this.onTap,
    this.margin,
    this.padding,
    this.useGradient = false,
    this.gradientColor,
  });

  @override
  Widget build(BuildContext context) {
    final gc = gradientColor ?? AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          margin: margin,
          padding: padding ?? const EdgeInsets.all(16),
          decoration: useGradient
              ? BoxDecoration(
                  gradient: LinearGradient(
                    colors: [gc.withAlpha(30), gc.withAlpha(8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: AppRadius.mdBorder,
                  border: Border.all(
                    color: borderColor ?? gc.withAlpha(60),
                    width: 0.5,
                  ),
                )
              : BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.mdBorder,
                  border: Border.all(
                    color: borderColor ?? AppColors.border,
                    width: 0.5,
                  ),
                ),
          child: DefaultTextStyle(
            style: const TextStyle(overflow: TextOverflow.ellipsis),
            child: child,
          ),
        ),
      ),
    );
  }
}
