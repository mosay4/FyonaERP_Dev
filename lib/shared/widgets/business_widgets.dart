import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  final bool showBack;

  PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: TwoToneIcon(
                data: TwoToneIcons.arrowRight,
                size: 20,
                outlineColor: AppColors.textPrimary,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 20),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class SearchBarWidget extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hintText;
  final VoidCallback? onFilter;

   SearchBarWidget({
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
            size: 20,
            outlineColor: AppColors.textSecondary,
          ),
          suffixIcon: onFilter != null
              ? IconButton(
                  icon: TwoToneIcon(
                    data: TwoToneIcons.filter,
                    size: 20,
                    outlineColor: AppColors.textSecondary,
                  ),
                  onPressed: onFilter,
                )
              : null,
          filled: true,
          fillColor: AppColors.surfaceVariant,
          border: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide:  BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide:  BorderSide(color: AppColors.border),
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

class EmptyStateWidget extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Object icon;
  final Widget? action;

  EmptyStateWidget({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withAlpha(100),
                borderRadius: AppRadius.xlBorder,
              ),
              child: Center(
                child: _buildIcon(),
              ),
            ),
             SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            if (subtitle != null) ...[
               SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIcon() {
    if (icon is Widget) return icon as Widget;
    if (icon is TwoToneIconData) return TwoToneIcon(data: icon as TwoToneIconData, size: 40, outlineColor: AppColors.textDisabled);
    return Icon(icon as IconData, size: 40, color: AppColors.textDisabled);
  }
}

class StatusBadge extends StatelessWidget {
  final String status;
  final double? fontSize;

  const StatusBadge({super.key, required this.status, this.fontSize});

  Color get _color {
    switch (status.toLowerCase()) {
      case 'paid':
      case 'active':
      case 'confirmed':
      case 'in':
      case 'approved':
        return AppColors.success;
      case 'draft':
      case 'pending':
      case 'partially_paid':
      case 'partial':
        return AppColors.warning;
      case 'cancelled':
      case 'overdue':
      case 'out':
        return AppColors.danger;
      case 'refunded':
      case 'settled':
        return AppColors.info;
      default:
        return AppColors.textSecondary;
    }
  }

  String _label(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (status.toLowerCase()) {
      case 'paid': return l10n.translate('status_paid');
      case 'confirmed': return l10n.translate('status_confirmed');
      case 'cancelled': return l10n.translate('status_cancelled');
      case 'draft': return l10n.translate('status_draft');
      case 'overdue': return l10n.translate('status_overdue');
      case 'active': return l10n.translate('status_active');
      case 'settled': return l10n.translate('status_settled');
      case 'approved': return l10n.translate('status_approved');
      case 'refunded': return l10n.translate('status_refunded');
      case 'in': return l10n.translate('status_in');
      case 'out': return l10n.translate('status_out');
      case 'pending': return l10n.translate('fnPaymentPending');
      case 'partially_paid':
      case 'partial':
        return l10n.translate('status_partially_paid');
      default: return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withAlpha(25),
        borderRadius: AppRadius.fullBorder,
        border: Border.all(color: _color.withAlpha(80), width: 0.5),
      ),
      child: Text(
        _label(context),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: fontSize ?? 11,
          fontWeight: FontWeight.w700,
          color: _color,
        ),
      ),
    );
  }
}

class LoadingShimmer extends StatelessWidget {
  final int itemCount;

  const LoadingShimmer({super.key, this.itemCount = 5});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: itemCount,
      padding: const EdgeInsets.all(16),
      itemBuilder: (context, index) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.mdBorder,
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 150,
              height: 14,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: AppRadius.smBorder,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: 100,
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: AppRadius.smBorder,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

