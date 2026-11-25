import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../core/utils/currency_formatter.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';
import '../../../../../../shared/widgets/money_text.dart';

/// Premium compact node card for the financial tree canvas.
class TreeNodeCard extends StatelessWidget {
  final FinancialTreeNode node;
  final bool selected;
  final bool highlighted;
  final bool matched;
  final bool hasChildren;
  final VoidCallback onTap;
  final VoidCallback onToggleCollapse;

  const TreeNodeCard({
    super.key,
    required this.node,
    required this.selected,
    required this.highlighted,
    required this.matched,
    required this.hasChildren,
    required this.onTap,
    required this.onToggleCollapse,
  });

  static const double cardWidth = 160;
  static const double cardHeight = 80;

  @override
  Widget build(BuildContext context) {
    final color = Color(node.type.color);
    final paid = node.paidAmount;
    final total = node.amount;
    final pct = total > 0 ? (paid / total).clamp(0.0, 1.0) : 0.0;
    final isRoot = node.type == FinancialTreeNodeType.root;
    final effectiveWidth = isRoot ? cardWidth + 16 : cardWidth;
    final effectiveHeight = isRoot ? cardHeight + 8 : cardHeight;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: effectiveWidth,
        height: effectiveHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlighted
              ? AppColors.gold.withAlpha(15)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
          border: Border.all(
            color: highlighted
                ? AppColors.gold
                : matched
                    ? AppColors.gold
                    : selected
                        ? color
                        : color.withAlpha(80),
            width: highlighted ? 2.5 : selected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: highlighted
                  ? AppColors.gold.withAlpha(120)
                  : selected
                      ? color.withAlpha(60)
                      : Colors.black.withAlpha(80),
              blurRadius: highlighted ? 20 : selected ? 14 : 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: color.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(iconForNodeType(node.type), size: 13, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (hasChildren)
                  GestureDetector(
                    onTap: onToggleCollapse,
                    child: Icon(
                      node.collapsed ? Icons.expand_more : Icons.expand_less,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
            const Spacer(),
            MoneyText(amount: fmtNum(node.amount), currency: currencySymbol(node.currency), style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: node.type == FinancialTreeNodeType.expense || node.type == FinancialTreeNodeType.debt
                    ? AppColors.danger
                    : AppColors.textPrimary,
              )),
            if (paid > 0) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 3,
                  backgroundColor: AppColors.border,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
