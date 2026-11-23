import 'package:flutter/material.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';

/// Section card for the sale flow: same business card language
/// (surface, border, radius 12, padding 16) with a Cairo w700 title.
class SaleSectionCard extends StatelessWidget {
  final String titleKey;
  final Widget? trailing;
  final Widget child;

  const SaleSectionCard({
    super.key,
    required this.titleKey,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  AppLocalizations.of(context).translate(titleKey),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (trailing case final t?) t,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
