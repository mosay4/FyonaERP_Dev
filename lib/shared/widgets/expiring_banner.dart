import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';

class ExpiringBanner extends StatelessWidget {
  final int daysRemaining;
  final String? planName;
  final VoidCallback? onRenew;

  ExpiringBanner({
    super.key,
    required this.daysRemaining,
    this.planName,
    this.onRenew,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.warning,
            AppColors.warning.withAlpha(180),
          ],
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
              Icons.warning_amber_rounded,
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
                  AppLocalizations.of(context).translate('sharedExpiringMsg', params: {'days': daysRemaining}),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (planName != null) ...[
                   SizedBox(height: 2),
                  Text(
                    planName!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withAlpha(200),
                    ),
                  ),
                ],
              ],
            ),
          ),
           SizedBox(width: 8),
          Material(
            color: Colors.white,
            borderRadius: AppRadius.mdBorder,
            child: InkWell(
              borderRadius: AppRadius.mdBorder,
              onTap: onRenew,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  AppLocalizations.of(context).translate('renew'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
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

