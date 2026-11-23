import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';

class SubscriptionBadge extends StatelessWidget {
  final String planName;
  final double? fontSize;
  final double? height;

  const SubscriptionBadge({
    super.key,
    required this.planName,
    this.fontSize,
    this.height,
  });

  Color get _color {
    final name = planName.toLowerCase();
    if (name.contains('ذهبية') || name.contains('gold') || name.contains('بريميوم') || name.contains('premium')) {
      return AppColors.gold;
    }
    if (name.contains('أعمال') || name.contains('business') || name.contains('شركات')) {
      return AppColors.info;
    }
    if (name.contains('شخصي') || name.contains('personal') || name.contains('أساسية') || name.contains('basic')) {
      return AppColors.success;
    }
    if (name.contains('تجريبي') || name.contains('trial') || name.contains('مجاني') || name.contains('free')) {
      return AppColors.warning;
    }
    return AppColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final h = height ?? 26.0;
    return Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: h * 0.5),
      decoration: BoxDecoration(
        color: _color.withAlpha(25),
        borderRadius: AppRadius.fullBorder,
        border: Border.all(color: _color.withAlpha(80), width: 0.5),
      ),
      child: Center(
        child: Text(
          planName,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: fontSize ?? (h * 0.42).clamp(10.0, 13.0),
            fontWeight: FontWeight.w700,
            color: _color,
          ),
        ),
      ),
    );
  }
}

