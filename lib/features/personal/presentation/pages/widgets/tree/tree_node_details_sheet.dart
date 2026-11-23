import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/services/currency/currency_engine.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../core/utils/currency_formatter.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';

/// Context menu + details bottom sheet for a tree node.
class TreeNodeDetailsSheet extends ConsumerWidget {
  final FinancialTreeNode node;
  final VoidCallback? onAddChild;
  final VoidCallback? onEdit;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;
  const TreeNodeDetailsSheet({
    super.key,
    required this.node,
    this.onAddChild,
    this.onEdit,
    this.onMove,
    this.onDelete,
  });

  String _tr(BuildContext context, String key) => AppLocalizations.of(context).translate(key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(financialTreeProvider);
    final current = state.nodes.where((n) => n.id == node.id).firstOrNull;
    if (current == null) return const SizedBox.shrink();
    final color = Color(current.type.color);
    final paid = current.paidAmount;
    final remaining = current.remainingAmount;
    final hasChildren = state.nodes.any((c) => c.parentId == current.id);

    final converted = _converted(context, ref, current.amount, current.currency);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: TreeTheme.space16, vertical: TreeTheme.space16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          treeSheetHandle(),
          const SizedBox(height: TreeTheme.space12),
          // Header
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: color.withAlpha(20),
                  borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
                ),
                child: Icon(iconForNodeType(current.type), color: color, size: 20),
              ),
              const SizedBox(width: TreeTheme.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(current.name, style: TreeTheme.headingSm, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(_tr(context, current.type.labelKey), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: color)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: TreeTheme.space12),
          // Amount
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fmtNum(current.amount), style: TreeTheme.headingLg),
                if (converted.isNotEmpty)
                  Text('≈ $converted', style: TreeTheme.bodySm),
                if (!current.isRoot && paid > 0) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (paid / current.amount).clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: AppColors.border,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${_tr(context, 'paidLabel')}: ${fmtNum(paid)}', style: TreeTheme.caption),
                      Text('${_tr(context, 'remainingLabel')}: ${fmtNum(remaining)}', style: TreeTheme.caption),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Notes
          if (current.notes.isNotEmpty) ...[
            const SizedBox(height: TreeTheme.space12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
              ),
              child: Row(
                children: [
                  const Icon(Icons.notes, size: 16, color: AppColors.gold),
                  const SizedBox(width: 8),
                  Expanded(child: Text(current.notes, style: TreeTheme.bodySm)),
                ],
              ),
            ),
          ],
          const SizedBox(height: TreeTheme.space16),
          // Actions grid
          Row(
            children: [
              _actionTile(context, Icons.add, _tr(context, 'addChildNode'), AppColors.primary, () {
                Navigator.pop(context);
                onAddChild?.call();
              }),
              if (!current.isRoot)
                _actionTile(context, Icons.edit, _tr(context, 'editItem'), AppColors.info, () {
                  Navigator.pop(context);
                  onEdit?.call();
                }),
              if (!current.isRoot)
                _actionTile(context, Icons.drive_file_move, _tr(context, 'moveItem'), AppColors.warning, () {
                  Navigator.pop(context);
                  onMove?.call();
                }),
            ],
          ),
          const SizedBox(height: TreeTheme.space8),
          Row(
            children: [
              _actionTile(context, Icons.swap_vert, _tr(context, hasChildren ? 'collapseAll' : 'expandAll'), AppColors.textSecondary, () {
                Navigator.pop(context);
                ref.read(financialTreeProvider.notifier).toggleCollapsed(current.id);
              }),
              if (!current.isRoot)
                _actionTile(context, Icons.delete_outline, _tr(context, 'delete'), AppColors.danger, () {
                  Navigator.pop(context);
                  onDelete?.call();
                }),
              const Spacer(),
            ],
          ),
          const SizedBox(height: TreeTheme.space8),
        ],
      ),
    );
  }

  Widget _actionTile(BuildContext context, IconData icon, String label, Color color, VoidCallback onTap) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
          child: InkWell(
            borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.w600, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _converted(BuildContext context, WidgetRef ref, double amount, String from) {
    final tree = ref.read(financialTreeProvider).currentTree;
    if (tree == null || from == tree.currency) return '';
    try {
      final engine = ref.read(currencyEngineProvider);
      final converted = engine.convert(amount, from, tree.currency);
      if (converted == 0) return '';
      return '${fmtNum(converted)} ${currencySymbol(tree.currency)}';
    } catch (_) {
      return '';
    }
  }
}
