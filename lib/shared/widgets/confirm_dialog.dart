import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmText,
  String? cancelText,
  bool danger = false,
  List<MapEntry<IconData, String>>? details,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.xlBorder,
      ),
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: (danger ? AppColors.danger : AppColors.warning).withAlpha(25),
              borderRadius: AppRadius.smBorder,
            ),
            child: TwoToneIcon(
              data: danger ? TwoToneIcons.warning : TwoToneIcons.alert,
              outlineColor: danger ? AppColors.danger : AppColors.warning,
              size: 20,
            ),
          ),
           SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: R.dialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            if (details != null) ...[
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withAlpha(120),
                  borderRadius: AppRadius.smBorder,
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                child: Column(
                  children: details
                      .map(
                        (d) => Padding(
                          padding: EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Icon(d.key, color: AppColors.textDisabled, size: 16),
                               SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  d.value,
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 13),
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(
            cancelText ?? l10n.translate('cancel'),
            style:  TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
            foregroundColor: danger ? AppColors.danger : AppColors.primary,
          ),
          child: Text(
            confirmText ?? l10n.translate('confirm'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w700,
              color: danger ? AppColors.danger : AppColors.primary,
            ),
          ),
        ),
      ],
      actionsAlignment: MainAxisAlignment.spaceBetween,
    ),
  );
}

void showSnackbar(
  BuildContext context, {
  required String message,
  Color color = AppColors.success,
  int durationMs = 3500,
}) {
  final twoToneIcon = color == AppColors.success
      ? TwoToneIcons.check
      : color == AppColors.danger
          ? TwoToneIcons.warning
          : TwoToneIcons.info;

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            TwoToneIcon(data: twoToneIcon, outlineColor: Colors.white, size: 20),
             SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: color,
        duration: Duration(milliseconds: durationMs),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
      ),
    );
}

