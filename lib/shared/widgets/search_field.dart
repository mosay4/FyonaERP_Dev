import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Alias for backward compatibility.
/// For new code, prefer using [SearchBarWidget] directly from business_widgets.dart.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hintText;
  final VoidCallback? onFilter;

   SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText,
    this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final displayHint = hintText ?? AppLocalizations.of(context).translate('sharedSearchHint');
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: FyonaTextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 14),
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: displayHint,
          hintStyle: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            fontWeight: FontWeight.w500,
            color: AppColors.textDisabled,
          ),
          prefixIcon: TwoToneIcon(
            data: TwoToneIcons.search,
            outlineColor: AppColors.textSecondary,
            size: 20,
          ),
          suffixIcon: onFilter != null
              ? IconButton(
                  icon: TwoToneIcon(
                    data: TwoToneIcons.filter,
                    outlineColor: AppColors.textSecondary,
                    size: 20,
                  ),
                  onPressed: onFilter,
                )
              : null,
          filled: true,
          fillColor: AppColors.surfaceVariant,
          border: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: const BorderSide(
              color: AppColors.primary,
              width: 1.5,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}

