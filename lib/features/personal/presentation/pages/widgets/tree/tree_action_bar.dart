import 'package:flutter/material.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'app_tree_theme.dart';

/// Unified, professional action bar for the tree canvas.
///
/// Replaces the previously scattered floating controls (free-floating zoom
/// column, hint pill, FAB) with one grouped toolbar: a prominent primary "add"
/// action, a tool cluster (search / zoom / fit / reset), a legend toggle and a
/// menu for bulk actions (expand-all / collapse-all / export PDF).
class TreeActionBar extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onSearch;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onReset;
  final VoidCallback onToggleLegend;
  final bool legendOpen;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;
  final VoidCallback onExport;

  const TreeActionBar({
    super.key,
    required this.onAdd,
    required this.onSearch,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onReset,
    required this.onToggleLegend,
    required this.legendOpen,
    required this.onExpandAll,
    required this.onCollapseAll,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: AppColors.gradientDark, begin: Alignment.topCenter, end: Alignment.bottomCenter),
        borderRadius: BorderRadius.circular(TreeTheme.radiusXl),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(140), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
          _toolButton(
            tooltip: l10n.translate('searchTree'),
            icon: Icons.search,
            onTap: onSearch,
          ),
          _toolButton(
            tooltip: l10n.translate('zoomIn'),
            icon: Icons.add,
            onTap: onZoomIn,
          ),
          _toolButton(
            tooltip: l10n.translate('zoomOut'),
            icon: Icons.remove,
            onTap: onZoomOut,
          ),
          _toolButton(
            tooltip: l10n.translate('fitToScreen'),
            icon: Icons.fit_screen,
            onTap: onFit,
          ),
          _toolButton(
            tooltip: l10n.translate('resetView'),
            icon: Icons.center_focus_strong,
            onTap: onReset,
          ),
          _toolButton(
            tooltip: l10n.translate('nodeLegend'),
            icon: Icons.palette_outlined,
            onTap: onToggleLegend,
            highlighted: legendOpen,
          ),
          Container(width: 1, height: 28, color: AppColors.border.withAlpha(180)),
          const SizedBox(width: 4),
          _primaryAddButton(label: l10n.translate('addQuickNode'), onTap: onAdd),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon:  Icon(Icons.more_vert, size: 20, color: AppColors.textPrimary),
            color: AppColors.surfaceVariant,
            onSelected: (v) {
              switch (v) {
                case 'expand': onExpandAll();
                case 'collapse': onCollapseAll();
                case 'export': onExport();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'expand', child: Text(l10n.translate('expandAll'), style: const TextStyle(fontFamily: 'Cairo'))),
              PopupMenuItem(value: 'collapse', child: Text(l10n.translate('collapseAll'), style: const TextStyle(fontFamily: 'Cairo'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'export', child: Text(l10n.translate('exportTreePdf'), style: const TextStyle(fontFamily: 'Cairo'))),
            ],
          ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: highlighted ? AppColors.primary.withAlpha(60) : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, size: 20, color: highlighted ? Colors.white : AppColors.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _primaryAddButton({required String label, required VoidCallback onTap}) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: AppColors.gradientPrimary),
            borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
            boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w800, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact legend showing the color coding of node types on the canvas.
class TreeLegendPanel extends StatelessWidget {
  final VoidCallback onClose;
  const TreeLegendPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final types = FinancialTreeNodeType.values
        .where((t) => t != FinancialTreeNodeType.root)
        .toList();
    return Container(
      width: 220,
      padding: const EdgeInsets.all(TreeTheme.space16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(l10n.translate('legendTitle'), style: TreeTheme.headingSm),
              const Spacer(),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(TreeTheme.radiusSm),
                child:  Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: TreeTheme.space12),
          Wrap(
            spacing: TreeTheme.space8,
            runSpacing: TreeTheme.space8,
            children: types.map((t) {
              final color = Color(t.color);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                  ),
                  const SizedBox(width: 6),
                  Text(l10n.translate(t.labelKey), style: TreeTheme.caption),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}