import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../shared/widgets/dots_loader.dart';
import '../../../../../../core/utils/currency_formatter.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';
import 'tree_create_page.dart';
import 'tree_canvas_page.dart';

class TreeListPage extends ConsumerWidget {
  const TreeListPage({super.key});

  String _tr(BuildContext context, String key) => AppLocalizations.of(context).translate(key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(financialTreeProvider);
    final trees = state.trees;
    final isLoading = state.isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(_tr(context, 'financialTree'), style: TreeTheme.headingMd),
      ),
      floatingActionButton: trees.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _openCreatePage(context),
              backgroundColor: AppColors.primary,
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(_tr(context, 'createTree'), style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
            )
          : null,
      body: isLoading
          ? const Center(child: DotsLoader())
          : trees.isEmpty
              ? _emptyState(context, ref)
              : _treeList(context, ref, trees),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    return TreeEmptyState(
      icon: Icons.account_tree,
      title: _tr(context, 'emptyStateTitle'),
      subtitle: _tr(context, 'emptyStateSubtitle'),
      buttonLabel: _tr(context, 'createTree'),
      onButtonPressed: () => _openCreatePage(context),
    );
  }

  Widget _treeList(BuildContext context, WidgetRef ref, List<FinancialTree> trees) {
    final notifier = ref.read(financialTreeProvider.notifier);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: trees.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final tree = trees[i];
        final nodeCount = tree.id == ref.watch(financialTreeProvider).currentTreeId
            ? ref.watch(financialTreeProvider).nodes.length
            : 0;

        return Material(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
          child: InkWell(
            borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
            onTap: () {
              notifier.openTree(tree.id);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TreeCanvasPage()));
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(25),
                          borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
                        ),
                        child: const Icon(Icons.account_tree, color: AppColors.primary, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tree.name, style: TreeTheme.headingSm),
                            const SizedBox(height: 2),
                            Text(
                              tree.clientName.isEmpty
                                  ? _tr(context, 'noClient')
                                  : tree.clientName,
                              style: TreeTheme.caption,
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon:  Icon(Icons.more_vert, size: 20, color: AppColors.textSecondary),
                        onSelected: (v) async {
                          switch (v) {
                            case 'edit':
                              _openCreatePage(context);
                              break;
                            case 'delete':
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppColors.surface,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusXl)),
                                  title: Text(_tr(context, 'confirmDeleteTreeTitle'), style: TreeTheme.headingSm),
                                  content: Text('${_tr(context, 'confirmDeleteTree')}: ${tree.name}'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr(context, 'cancel'))),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                                      child: Text(_tr(context, 'delete')),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) await notifier.deleteTree(tree.id);
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(_tr(context, 'editTreeInfo'))),
                          PopupMenuItem(value: 'delete', child: Text(_tr(context, 'delete'), style: const TextStyle(color: AppColors.danger))),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _infoChip(Icons.circle, '${fmtNum(tree.baseAmount)} ${currencySymbol(tree.currency)}', AppColors.textSecondary),
                      _infoChip(Icons.schedule, '${_tr(context, 'lastModified')}: ${_shortDate(tree.updatedAt)}', AppColors.textTertiary),
                      if (nodeCount > 0)
                        _infoChip(Icons.account_tree, '$nodeCount ${_tr(context, 'itemsCount')}', AppColors.textTertiary),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _infoChip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(TreeTheme.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: color)),
        ],
      ),
    );
  }

  String _shortDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  void _openCreatePage(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const TreeCreatePage(),
    ));
  }
}
