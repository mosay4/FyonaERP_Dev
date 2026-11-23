import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class GettingStartedStep {
  final String action;
  final String description;
  final IconData? icon;
  final bool isDone;
  final VoidCallback? onTap;

  const GettingStartedStep({
    required this.action,
    this.description = '',
    this.icon,
    this.isDone = false,
    this.onTap,
  });
}

class GettingStartedWidget extends StatelessWidget {
  final List<GettingStartedStep> steps;
  final String? title;
  final String description;
  final int completedCount;
  final int totalCount;

  const GettingStartedWidget({
    super.key,
    required this.steps,
    this.title,
    this.description = '',
    required this.completedCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    if (completedCount >= totalCount) return SizedBox.shrink();

    final progress = totalCount > 0 ? completedCount / totalCount : 0.0;
    final displayTitle = title ?? AppLocalizations.of(context).translate('sharedGettingStarted');

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withAlpha(15),
            AppColors.surface,
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: AppColors.primary.withAlpha(40), width: 0.5),
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
                  color: AppColors.primary.withAlpha(30),
                  borderRadius: AppRadius.smBorder,
                ),
                child: TwoToneIcon(
                  data: TwoToneIcons.sparkle,
                  size: 20,
                  outlineColor: AppColors.primary,
                ),
              ),
               SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 16),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          ClipRRect(
            borderRadius: AppRadius.fullBorder,
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.surfaceVariant,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              minHeight: 6,
            ),
          ),
           SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).translate('sharedStepsProgress', params: {'completed': completedCount, 'total': totalCount}),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: 8),
          ...steps.asMap().entries.map(
            (entry) => _buildStep(context, entry.value, entry.key),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(BuildContext context, GettingStartedStep step, int index) {
    return Container(
      margin: EdgeInsets.only(top: 4),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: step.isDone ? AppColors.surfaceVariant.withAlpha(80) : Colors.transparent,
        borderRadius: AppRadius.smBorder,
      ),
      child: InkWell(
        onTap: step.isDone ? null : step.onTap,
        borderRadius: AppRadius.smBorder,
        child: Row(
          children: [
            TwoToneIcon(
              data: step.isDone ? TwoToneIcons.check : TwoToneIcons.close,
              size: 22,
              outlineColor: step.isDone ? AppColors.success : AppColors.textDisabled,
            ),
             SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.action,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w600,
                      color: step.isDone ? AppColors.textSecondary : AppColors.textPrimary,
                    ),
                  ),
                  if (step.description.isNotEmpty)
                    Text(
                      step.description,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w500,
                        color: AppColors.textDisabled,
                      ),
                    ),
                ],
              ),
            ),
            if (!step.isDone && step.icon != null)
              Icon(step.icon, size: 20, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

