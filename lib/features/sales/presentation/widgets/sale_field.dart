import 'package:flutter/material.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';

/// The single compact selection field used across the sale screen:
///
/// [ اضغط للاختيار                    ▼ ]
///
/// Shows [value] (or the grey [placeholder]), opens the picker's sheet on
/// tap. One tidy field per choice — never a wall of buttons.
class SaleField extends StatelessWidget {
  final String value;
  final String placeholder;
  final VoidCallback onTap;
  final bool enabled;

  /// Tighter text so a full «bank-currency» label fits even with long names.
  final bool compact;

  const SaleField({
    super.key,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 14, vertical: compact ? 13 : 13),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withAlpha(70),
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  empty ? placeholder : value,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, compact ? 11.5 : 14),
                    fontWeight:
                        empty ? FontWeight.w500 : FontWeight.w700,
                    color: empty
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: compact ? 4 : 8),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: compact ? 18 : 22,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
