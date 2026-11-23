import 'package:flutter/material.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'app_tree_theme.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Premium search overlay for the tree canvas.
class TreeSearchOverlay extends StatefulWidget {
  final List<FinancialTreeNode> nodes;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onNodeSelected;
  final VoidCallback onClose;

  const TreeSearchOverlay({
    super.key,
    required this.nodes,
    required this.onQueryChanged,
    required this.onNodeSelected,
    required this.onClose,
  });

  @override
  State<TreeSearchOverlay> createState() => _TreeSearchOverlayState();
}

class _TreeSearchOverlayState extends State<TreeSearchOverlay> {
  final _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final matches = _query.trim().isEmpty
        ? <FinancialTreeNode>[]
        : widget.nodes.where((n) => n.name.toLowerCase().contains(_query.trim().toLowerCase())).take(5).toList();

    return Positioned(
      left: TreeTheme.space12,
      right: TreeTheme.space12,
      top: TreeTheme.space8,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
        elevation: 8,
        shadowColor: Colors.black.withAlpha(60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                   Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.search, size: 20, color: AppColors.textSecondary),
                  ),
                  Expanded(
                    child: FyonaTextField(
                      controller: _ctrl,
                      autofocus: true,
                      style:  TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                      onChanged: (v) {
                        setState(() => _query = v);
                        widget.onQueryChanged(v);
                      },
                      decoration: InputDecoration(
                        hintText: l10n.translate('searchTree'),
                        border: InputBorder.none,
                        hintStyle: const TextStyle(fontFamily: 'Cairo', color: AppColors.textPlaceholder),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      widget.onClose();
                      _ctrl.clear();
                      setState(() => _query = '');
                    },
                  ),
                ],
              ),
              if (_query.trim().isNotEmpty && matches.isNotEmpty)
                ...matches.map((n) {
                  final color = Color(n.type.color);
                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: color.withAlpha(20),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.account_tree, size: 16, color: color),
                    ),
                    title: Text(n.name, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                    trailing: const Icon(Icons.center_focus_strong, size: 16, color: AppColors.primary),
                    onTap: () => widget.onNodeSelected(n.id),
                  );
                }),
              if (_query.trim().isNotEmpty && matches.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(l10n.translate('noSearchResults'), style: TreeTheme.bodySm),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
