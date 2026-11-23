import 'package:flutter/material.dart';
import '../../../../../../core/utils/amount_input_formatter.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../shared/widgets/dots_loader.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'app_tree_theme.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

IconData iconForNodeType(FinancialTreeNodeType t) {
  switch (t) {
    case FinancialTreeNodeType.root: return Icons.account_tree;
    case FinancialTreeNodeType.income: return Icons.trending_up;
    case FinancialTreeNodeType.expense: return Icons.trending_down;
    case FinancialTreeNodeType.asset: return Icons.business;
    case FinancialTreeNodeType.investment: return Icons.candlestick_chart;
    case FinancialTreeNodeType.debt: return Icons.money_off;
    case FinancialTreeNodeType.liability: return Icons.remove_circle_outline;
    case FinancialTreeNodeType.transfer: return Icons.swap_horiz;
    case FinancialTreeNodeType.saving: return Icons.savings;
    case FinancialTreeNodeType.payment: return Icons.payment;
    case FinancialTreeNodeType.receivable: return Icons.currency_exchange;
    case FinancialTreeNodeType.custom: return Icons.category;
  }
}

class TreeTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? label;
  final bool isAmount;
  const TreeTextField({
    super.key, required this.controller, required this.hint,
    this.maxLines = 1, this.keyboardType, this.label,
    this.isAmount = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: TreeTheme.label),
          const SizedBox(height: 6),
        ],
        FyonaTextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          inputFormatters: isAmount ? [AmountInputFormatter()] : null,
          style:  TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
          decoration: TreeTheme.inputDecoration(hint),
        ),
      ],
    );
  }
}

class TreePrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool loading;
  final IconData? icon;
  const TreePrimaryButton({
    super.key, required this.label, required this.onPressed,
    this.loading = false, this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusMd)),
          minimumSize: const Size(0, 48),
          maximumSize: const Size(double.infinity, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: loading
            ? const DotsLoader.button()
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class TreeSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const TreeSectionHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: TreeTheme.space16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TreeTheme.headingSm),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class TreeEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? buttonLabel;
  final VoidCallback? onButtonPressed;
  const TreeEmptyState({
    super.key, required this.icon, required this.title, required this.subtitle,
    this.buttonLabel, this.onButtonPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(TreeTheme.space32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: AppColors.primary.withAlpha(180)),
            ),
            const SizedBox(height: TreeTheme.space20),
            Text(title, style: TreeTheme.headingSm, textAlign: TextAlign.center),
            const SizedBox(height: TreeTheme.space8),
            Text(subtitle, style: TreeTheme.bodySm, textAlign: TextAlign.center),
            if (buttonLabel != null && onButtonPressed != null) ...[
              const SizedBox(height: TreeTheme.space24),
              TreePrimaryButton(label: buttonLabel!, onPressed: onButtonPressed!, icon: Icons.add),
            ],
          ],
        ),
      ),
    );
  }
}

class TreeStepIndicator extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  const TreeStepIndicator({super.key, required this.currentStep, required this.totalSteps});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSteps, (i) {
        final active = i <= currentStep;
        final done = i < currentStep;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 4,
              decoration: BoxDecoration(
                color: done
                    ? AppColors.primary
                    : active
                        ? AppColors.primary.withAlpha(150)
                        : AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      }),
    );
  }
}

void showTreeBottomSheet(BuildContext context, {required Widget child, double heightFactor = 0.85}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(TreeTheme.radiusXl)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: heightFactor,
      child: child,
    ),
  );
}

Widget treeSheetHandle() => Center(
  child: Container(
    width: 36, height: 4,
    decoration: BoxDecoration(
      color: AppColors.textDisabled,
      borderRadius: BorderRadius.circular(2),
    ),
  ),
);
