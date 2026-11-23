import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../../shared/widgets/two_tone_icon.dart';
import '../../shared/widgets/two_tone_icons.dart';

class AppErrorWidget extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;
  final IconData icon;

  const AppErrorWidget({
    super.key,
    this.message,
    this.onRetry,
    this.icon = Icons.error_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: AppColors.danger),
            const SizedBox(height: 16),
            Text(
              message ?? AppLocalizations.of(context).translate('coreUnexpectedError'),
              textAlign: TextAlign.center,
              style: AppTypography.bodyStyle.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: TwoToneIcon(data: TwoToneIcons.refresh),
                label: Text(AppLocalizations.of(context).translate('retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
