import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';

class TrialBanner extends StatelessWidget {
  final int daysRemaining;
  final VoidCallback? onSubscribe;

  TrialBanner({
    super.key,
    required this.daysRemaining,
    this.onSubscribe,
  });

  @override
  Widget build(BuildContext context) {
    final isUrgent = daysRemaining <= 3;

    return Container(
      width: double.infinity,
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isUrgent
              ? [AppColors.danger, AppColors.warning]
              : [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: AppRadius.mdBorder,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(30),
              borderRadius: AppRadius.smBorder,
            ),
            child: Icon(
              isUrgent ? Icons.hourglass_empty_rounded : Icons.timer_outlined,
              color: Colors.white,
              size: 22,
            ),
          ),
           SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).translate('sharedTrialRemaining', params: {'days': daysRemaining}),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                 SizedBox(height: 2),
                Text(
                  isUrgent ? AppLocalizations.of(context).translate('sharedTrialUrgent') : AppLocalizations.of(context).translate('sharedTrialContinue'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withAlpha(200),
                  ),
                ),
              ],
            ),
          ),
           SizedBox(width: 8),
          Material(
            color: Colors.white,
            borderRadius: AppRadius.mdBorder,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: AppRadius.mdBorder,
              onTap: onSubscribe,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Text(
                  AppLocalizations.of(context).translate('subscribeNow'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: isUrgent ? AppColors.danger : AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

