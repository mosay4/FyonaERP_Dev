import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final TwoToneIconData icon;
  final Color? color;
  final String? subtitle;
  final double? changePercent;
  final VoidCallback? onTap;
  final bool useGradient;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    this.color,
    this.subtitle,
    this.changePercent,
    this.onTap,
    this.useGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor = color ?? AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: useGradient
            ? BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    cardColor.withAlpha(40),
                    cardColor.withAlpha(10),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: AppRadius.mdBorder,
                border: Border.all(color: cardColor.withAlpha(60)),
              )
            : BoxDecoration(
                color: AppColors.surface,
                borderRadius: AppRadius.mdBorder,
                border: Border.all(color: AppColors.border, width: 0.5),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cardColor.withAlpha(30),
                    borderRadius: AppRadius.smBorder,
                  ),
                  child: TwoToneIcon(data: icon, size: 20, outlineColor: cardColor),
                ),
                Spacer(),
                if (changePercent != null)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: (changePercent! >= 0
                              ? AppColors.success
                              : AppColors.danger)
                          .withAlpha(20),
                      borderRadius: AppRadius.fullBorder,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TwoToneIcon(
                          data: TwoToneIcons.trendingUp,
                          size: 12,
                          outlineColor: changePercent! >= 0
                              ? AppColors.success
                              : AppColors.danger,
                        ),
                         SizedBox(width: 2),
                        Text(
                          '${changePercent! >= 0 ? '+' : ''}${changePercent!.toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            fontWeight: FontWeight.w700,
                            color: changePercent! >= 0
                                ? AppColors.success
                                : AppColors.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
             SizedBox(height: 14),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 24),
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
                height: 1.1,
              ),
            ),
            ),
             SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
               SizedBox(height: 2),
              Text(
                subtitle!,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  color: AppColors.textDisabled,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
