import 'package:flutter/material.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';

/// What the merchant chose when leaving an invoice with unsaved data.
enum UnsavedExitAction { keep, discard, cancel }

/// Shows the «keep data / discard / cancel» prompt used by the sale & purchase
/// invoice screens when the merchant leaves with data still entered.
///
/// Returns [UnsavedExitAction.cancel] when dismissed by tapping outside.
Future<UnsavedExitAction> showUnsavedExitDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final res = await showDialog<UnsavedExitAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.translate('unsavedExitTitle'),
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
      content: Text(l10n.translate('unsavedExitBody'),
          style: const TextStyle(fontFamily: 'Cairo')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, UnsavedExitAction.keep),
          child: Text(l10n.translate('unsavedExitKeep'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppColors.success,
                  fontWeight: FontWeight.w700)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, UnsavedExitAction.discard),
          child: Text(l10n.translate('unsavedExitDiscard'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppColors.danger,
                  fontWeight: FontWeight.w700)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, UnsavedExitAction.cancel),
          child: Text(l10n.translate('cancel'),
              style: TextStyle(
                  fontFamily: 'Cairo', color: AppColors.textSecondary)),
        ),
      ],
    ),
  );
  return res ?? UnsavedExitAction.cancel;
}
