import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class DataTableWidget extends StatelessWidget {
  final List<DataColumn> columns;
  final List<DataRow> rows;
  final bool isLoading;
  final String? emptyMessage;
  final VoidCallback? onRefresh;

  DataTableWidget({
    super.key,
    required this.columns,
    required this.rows,
    this.isLoading = false,
    this.emptyMessage,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TwoToneIcon(data: TwoToneIcons.folder, size: 48, outlineColor: AppColors.textDisabled),
             SizedBox(height: 12),
            Text(
              emptyMessage ?? AppLocalizations.of(context).translate('noData'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(AppColors.surfaceVariant),
        dataRowColor: WidgetStateProperty.all(AppColors.surface),
        border: TableBorder.all(color: AppColors.border, width: 0.5),
        columnSpacing: 20,
        headingTextStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 13),
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        dataTextStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 13),
          color: AppColors.textPrimary,
        ),
        columns: columns,
        rows: rows,
      ),
    );
  }
}

class PaginationControls extends StatelessWidget {
  final int currentPage;
  final int totalPages;
  final int totalItems;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

   PaginationControls({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.totalItems,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            AppLocalizations.of(context).translate('sharedTotalItems', params: {'total': totalItems}),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary,
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: TwoToneIcon(data: TwoToneIcons.arrowRight, size: 20),
                color: currentPage > 1 ? AppColors.textPrimary : AppColors.textDisabled,
                onPressed: currentPage > 1 ? onPrevious : null,
              ),
              Text(
                AppLocalizations.of(context).translate('sharedPageXOfY', params: {'current': currentPage, 'total': totalPages}),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  color: AppColors.textSecondary,
                ),
              ),
              IconButton(
                icon: TwoToneIcon(data: TwoToneIcons.arrowLeft, size: 20),
                color: currentPage < totalPages ? AppColors.textPrimary : AppColors.textDisabled,
                onPressed: currentPage < totalPages ? onNext : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class FormCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final EdgeInsets? padding;

   FormCard({
    super.key,
    required this.title,
    required this.children,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: padding ?? EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 15),
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Divider(height: 20, color: AppColors.border),
          ...children,
        ],
      ),
    );
  }
}

class ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;

  ActionButton({
    super.key,
    required this.label,
    required this.icon,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final btnColor = color ?? AppColors.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: btnColor.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: btnColor.withAlpha(40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: btnColor),
             SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w500,
                color: btnColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

