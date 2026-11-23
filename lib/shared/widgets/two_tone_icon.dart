import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../../core/theme/app_colors.dart';

class TwoToneIconData {
  final List<List<dynamic>> outline;
  final List<List<dynamic>>? detail;
  final double detailScale;
  final double detailOffsetX;
  final double detailOffsetY;

  const TwoToneIconData({
    required this.outline,
    this.detail,
    this.detailScale = 0.45,
    this.detailOffsetX = 0,
    this.detailOffsetY = 0,
  });
}

class TwoToneIcon extends StatelessWidget {
  final TwoToneIconData data;
  final double size;
  final Color? outlineColor;
  final Color? detailColor;
  final double strokeWidth;

  const TwoToneIcon({
    super.key,
    required this.data,
    this.size = 24,
    this.outlineColor,
    this.detailColor,
    this.strokeWidth = 1.8,
  });

  @override
  Widget build(BuildContext context) {
    final base = outlineColor ?? AppColors.textSecondary.withAlpha(160);
    final accent = detailColor ?? AppColors.primary;

    if (data.detail == null) {
      return HugeIcon(
        icon: data.outline,
        color: base,
        size: size,
        strokeWidth: strokeWidth,
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        HugeIcon(
          icon: data.outline,
          color: base,
          size: size,
          strokeWidth: strokeWidth,
        ),
        Transform.translate(
          offset: Offset(data.detailOffsetX, data.detailOffsetY),
          child: HugeIcon(
            icon: data.detail!,
            color: accent,
            size: size * data.detailScale,
            strokeWidth: strokeWidth + 0.6,
          ),
        ),
      ],
    );
  }
}
