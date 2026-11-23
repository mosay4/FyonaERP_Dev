import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';

/// Badge showing the user's plan-based verification level with the plan's
/// identity color:
/// level 1 → personal (blue) · level 2 → business (red) ·
/// level 3 → premium / أعمال + شخصي (gold).
class PlanVerificationBadge extends StatelessWidget {
  final int level;
  final double size;

  const PlanVerificationBadge({
    super.key,
    this.level = 0,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    if (level <= 0) return const SizedBox.shrink();
    final (color, tooltip) = switch (level) {
      1 => (AppColors.info,
          AppLocalizations.of(context).translate('subVerifiedPersonal')),
      2 => (AppColors.danger,
          AppLocalizations.of(context).translate('subVerifiedBusiness')),
      3 => (AppColors.gold,
          AppLocalizations.of(context).translate('sharedVerifiedPremium')),
      _ => (AppColors.info,
          AppLocalizations.of(context).translate('sharedVerifiedAccount')),
    };
    return Tooltip(
      message: tooltip,
      child: Icon(Icons.verified, size: size, color: color),
    );
  }
}