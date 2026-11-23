import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Move node dialog with hierarchical parent selection.
class TreeMoveDialog extends ConsumerStatefulWidget {
  final FinancialTreeNode node;
  const TreeMoveDialog({super.key, required this.node});

  @override
  ConsumerState<TreeMoveDialog> createState() => _TreeMoveDialogState();
}

class _TreeMoveDialogState extends ConsumerState<TreeMoveDialog> {
  String _searchQuery = '';

  String _tr(String key) => AppLocalizations.of(context).translate(key);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(financialTreeProvider);
    final nodes = state.nodes;

    final excluded = <String>{widget.node.id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final n in nodes) {
        if (n.parentId != null && excluded.contains(n.parentId) && !excluded.contains(n.id)) {
          excluded.add(n.id);
          changed = true;
        }
      }
    }

    final query = _searchQuery.toLowerCase();
    final candidates = nodes.where((n) => !excluded.contains(n.id) && n.name.toLowerCase().contains(query)).toList();

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusXl)),
      child: Padding(
        padding: const EdgeInsets.all(TreeTheme.space20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_tr('moveNode'), style: TreeTheme.headingMd),
            const SizedBox(height: TreeTheme.space12),
            FyonaTextField(
              autofocus: true,
              style: const TextStyle(fontFamily: 'Cairo'),
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: TreeTheme.inputDecoration(_tr('searchParent')),
            ),
            const SizedBox(height: TreeTheme.space12),
            SizedBox(
              height: 300,
              child: ListView(
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.account_tree, color: AppColors.primary, size: 20),
                    title: Text(_tr('moveToRoot'), style: TreeTheme.bodyMd),
                    onTap: () {
                      Navigator.pop(context);
                      ref.read(financialTreeProvider.notifier).moveNode(widget.node.id, null);
                    },
                  ),
                  const Divider(height: 1),
                  ..._buildTiles(candidates, null, 0),
                ],
              ),
            ),
            const SizedBox(height: TreeTheme.space8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('cancel')),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTiles(List<FinancialTreeNode> all, String? parentId, int depth) {
    final children = all.where((n) => n.parentId == parentId).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return children.expand((n) => [
      Padding(
        padding: EdgeInsets.only(left: 16.0 + depth * 24),
        child: ListTile(
          dense: true,
          leading: Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: Color(n.type.color), shape: BoxShape.circle),
          ),
          title: Text(n.name, style: TreeTheme.bodyMd),
          subtitle: Text(_tr(n.type.labelKey), style: TreeTheme.caption),
          onTap: () {
            Navigator.pop(context);
            ref.read(financialTreeProvider.notifier).moveNode(widget.node.id, n.id);
          },
        ),
      ),
      ..._buildTiles(all, n.id, depth + 1),
    ]).toList();
  }
}
