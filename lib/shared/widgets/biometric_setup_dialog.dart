import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../features/auth/presentation/providers/biometric_provider.dart';
import '../../features/auth/domain/services/biometric_service.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class BiometricSetupDialog extends ConsumerWidget {
  const BiometricSetupDialog({super.key});

  static Future<void> showIfNeeded(
    BuildContext context,
    WidgetRef ref, {
    String? loginIdentifier,
    String? loginPassword,
  }) async {
    final state = ref.read(biometricProvider);
    if (!state.shouldPrompt && !state.isDeviceSupported) return;
    if (!state.canCheckBiometrics) return;
    if (state.isEnabled) return;
    if (!context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BiometricSetupDialog(),
    );

    if (confirmed == true && context.mounted) {
      final result = await ref.read(biometricProvider.notifier).authenticate(
        reason: AppLocalizations.of(context).translate('sharedBioReason'),
      );
      if (!context.mounted) return;

      if (result == AuthResult.success) {
        if (loginIdentifier != null &&
            loginIdentifier.isNotEmpty &&
            loginPassword != null &&
            loginPassword.isNotEmpty) {
          await ref.read(biometricProvider.notifier).saveCredentials(
            email: loginIdentifier,
            password: loginPassword,
          );
        }
        await ref.read(biometricProvider.notifier).snapshotCurrentSession();
        await ref.read(biometricProvider.notifier).setEnabled(true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).translate('sharedBioEnabledOk'),
                style: TextStyle(fontFamily: 'Cairo'),
              ),
              backgroundColor: AppColors.success,
            ),
          );
        }
      } else if (result == AuthResult.lockedOut ||
          result == AuthResult.permanentlyLockedOut) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).translate('sharedBioLocked'),
                style: TextStyle(fontFamily: 'Cairo'),
              ),
              backgroundColor: AppColors.danger,
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).translate('sharedBioSkipped'),
                style: TextStyle(fontFamily: 'Cairo'),
              ),
              backgroundColor: AppColors.warning,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.xlBorder),
      contentPadding: EdgeInsets.zero,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 28),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: TwoToneIcon(
              data: TwoToneIcons.fingerprint,
              size: 38,
              outlineColor: AppColors.primary,
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              AppLocalizations.of(context).translate('sharedBioTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 18),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              AppLocalizations.of(context).translate('sharedBioSubtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: AppRadius.mdBorder,
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).translate('enable'),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  AppLocalizations.of(context).translate('later'),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
