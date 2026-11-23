import 'package:flutter/material.dart';
import 'app_colors.dart';

class TwoToneIcon extends StatelessWidget {
  final IconData icon;
  final IconData secondaryIcon;
  final double size;
  final Color? primaryColor;
  final Color? accentColor;
  final double accentOpacity;

  const TwoToneIcon({
    super.key,
    required this.icon,
    required this.secondaryIcon,
    this.size = 24,
    this.primaryColor,
    this.accentColor,
    this.accentOpacity = 0.18,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: accentOpacity,
          child: Icon(
            secondaryIcon,
            size: size,
            color: accentColor ?? AppColors.primary,
          ),
        ),
        Icon(
          icon,
          size: size,
          color: primaryColor ?? AppColors.textPrimary,
        ),
      ],
    );
  }
}
