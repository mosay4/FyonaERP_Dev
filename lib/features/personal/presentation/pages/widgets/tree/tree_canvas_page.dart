import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../shared/widgets/dots_loader.dart';
import '../../../../../../core/utils/storage_util.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import '../../../providers/financial_tree_provider.dart';
import '../../../providers/receipt_design_models.dart';
import '../../../providers/receipt_design_provider.dart';
import '../../financial_tree_report_pdf.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';
import 'tree_node_card.dart';
import 'tree_edge_painter.dart';
import 'tree_node_form_sheet.dart';
import 'tree_node_details_sheet.dart';
import 'tree_move_dialog.dart';
import 'tree_settings_sheet.dart';
import 'tree_kpi_dashboard.dart';
import 'tree_search_overlay.dart';
import 'tree_action_bar.dart';

const double _hUnit = 190;
const double _vGap = 128;
const double _pad = 48;

class _LayoutResult {
  final Map<String, Offset> positions;
  final double width;
  final double height;
  const _LayoutResult(this.positions, this.width, this.height);
}

_LayoutResult _computeLayout(List<FinancialTreeNode> nodes) {
  final visible = <String>{};
  final roots = nodes.where((n) => n.isRoot).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  void walk(String? parentId) {
    final children = nodes.where((c) => c.parentId == parentId).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final c in children) {
      visible.add(c.id);
      if (!c.collapsed) walk(c.id);
    }
  }

  for (final r in roots) {
    visible.add(r.id);
    if (!r.collapsed) walk(r.id);
  }

  final leafCount = <String, int>{};
  int leaves(String id) {
    if (leafCount.containsKey(id)) return leafCount[id]!;
    final children = nodes.where((c) => c.parentId == id && visible.contains(c.id)).toList();
    if (children.isEmpty) return leafCount[id] = 1;
    var s = 0;
    for (final c in children) {
      s += leaves(c.id);
    }
    return leafCount[id] = s;
  }

  final positions = <String, Offset>{};
  var cursorX = 0.0;
  var maxDepth = 0;

  void place(String id, int depth) {
    final lc = leaves(id);
    final cx = (cursorX + lc / 2.0) * _hUnit;
    final cy = depth * _vGap + _pad;
    final isRoot = nodes.where((n) => n.id == id).firstOrNull?.type == FinancialTreeNodeType.root;
    final cw = isRoot ? TreeNodeCard.cardWidth + 16 : TreeNodeCard.cardWidth;
    positions[id] = Offset(cx - cw / 2, cy);
    cursorX += lc;
    if (depth > maxDepth) maxDepth = depth;
  }

  void placeTree(String? parentId, int depth) {
    final children = nodes.where((c) => c.parentId == parentId && visible.contains(c.id)).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final c in children) {
      place(c.id, depth);
      placeTree(c.id, depth + 1);
    }
  }

  for (final r in roots) {
    place(r.id, 0);
    placeTree(r.id, 1);
  }

  final width = cursorX * _hUnit + 2 * _pad;
  final height = (maxDepth + 1) * _vGap + TreeNodeCard.cardHeight + _pad + 40;
  return _LayoutResult(positions, width, height);
}

class TreeCanvasPage extends ConsumerStatefulWidget {
  const TreeCanvasPage({super.key});

  @override
  ConsumerState<TreeCanvasPage> createState() => _TreeCanvasPageState();
}

class _TreeCanvasPageState extends ConsumerState<TreeCanvasPage> {
  final TransformationController _controller = TransformationController();
  bool _searching = false;
  bool _legendOpen = false;
  String _selectedId = '';
  String _highlightId = '';
  Timer? _highlightTimer;
  Size _viewportSize = const Size(400, 700);
  _LayoutResult? _layout;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _tr(String key) => AppLocalizations.of(context).translate(key);

  void _zoom(double factor) {
    final current = _controller.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(0.25, 3.0);
    final size = _viewportSize;
    final center = Offset(size.width / 2, size.height / 2);
    final scene = _controller.toScene(center);
    final m = Matrix4.identity()
      ..multiply(Matrix4.translationValues(center.dx - scene.dx * next, center.dy - scene.dy * next, 0))
      ..multiply(Matrix4.diagonal3Values(next, next, 1));
    _controller.value = m;
  }

  void _resetView() {
    _controller.value = Matrix4.identity();
  }

  void _fitToScreen() {
    if (_layout == null) return;
    final lw = _layout!.width;
    final lh = _layout!.height;
    final vw = _viewportSize.width;
    final vh = _viewportSize.height;
    if (lw <= 0 || lh <= 0) return;
    final scaleX = vw / lw;
    final scaleY = vh / lh;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.15, 1.0) * 0.9;
    final offsetX = (vw - lw * scale) / 2;
    final offsetY = (vh - lh * scale) / 2;
    _controller.value = Matrix4.translationValues(offsetX, offsetY, 0)
      ..multiply(Matrix4.diagonal3Values(scale, scale, 1));
  }

  void _focusOn(String nodeId) {
    final pos = _layout?.positions[nodeId];
    if (pos == null) return;
    final node = ref.read(financialTreeProvider).nodes.where((n) => n.id == nodeId).firstOrNull;
    final cw = node?.type == FinancialTreeNodeType.root ? TreeNodeCard.cardWidth + 16 : TreeNodeCard.cardWidth;
    final center = Offset(pos.dx + cw / 2, pos.dy + TreeNodeCard.cardHeight / 2);
    final size = _viewportSize;
    const scale = 0.8;
    final m = Matrix4.identity()
      ..multiply(Matrix4.translationValues(size.width / 2 - center.dx * scale, size.height / 2 - center.dy * scale, 0))
      ..multiply(Matrix4.diagonal3Values(scale, scale, 1));
    _controller.value = m;
  }

  void _selectNode(String id) {
    setState(() {
      _selectedId = id;
      _highlightId = '';
    });
  }

  Future<void> _quickAdd() async {
    final state = ref.read(financialTreeProvider);
    final roots = state.nodes.where((n) => n.isRoot).toList();
    if (roots.isEmpty) return;
    final selected = _selectedId.isNotEmpty
        ? state.nodes.where((n) => n.id == _selectedId).firstOrNull
        : null;
    final parentId = selected?.id ?? roots.first.id;
    _openNodeForm(parentId: parentId);
  }

  void _openNodeForm({FinancialTreeNode? node, String? parentId}) {
    showTreeBottomSheet(
      context,
      heightFactor: 0.85,
      child: TreeNodeFormSheet(nodeId: node?.id, parentId: parentId),
    );
  }

  void _openNodeDetails(FinancialTreeNode node) {
    showTreeBottomSheet(
      context,
      heightFactor: 0.75,
      child: TreeNodeDetailsSheet(
        node: node,
        onAddChild: () => _openNodeForm(parentId: node.id),
        onEdit: () => _openNodeForm(node: node),
        onMove: () => _showMoveDialog(node),
        onDelete: () => _confirmDelete(node),
      ),
    );
  }

  void _showMoveDialog(FinancialTreeNode node) {
    showDialog(
      context: context,
      builder: (_) => TreeMoveDialog(node: node),
    );
  }

  Future<void> _confirmDelete(FinancialTreeNode node) async {
    final hasChildren = ref.read(financialTreeProvider).nodes.any((c) => c.parentId == node.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusXl)),
        title: Text(_tr('confirmDeleteNodeTitle'), style: TreeTheme.headingSm),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_tr('confirmDeleteItem'), style: TreeTheme.bodyMd),
            if (hasChildren) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.danger.withAlpha(15),
                  borderRadius: BorderRadius.circular(TreeTheme.radiusSm),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.danger),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_tr('confirmDeleteChildren'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.danger.withAlpha(200)))),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(_tr('delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(financialTreeProvider.notifier).deleteNode(node.id);
      if (mounted) setState(() => _selectedId = '');
    }
  }

  Future<void> _exportTree() async {
    final state = ref.read(financialTreeProvider);
    final tree = state.currentTree;
    if (tree == null) return;
    var preset = ref.read(personalReceiptDesignProvider)['report'] ?? ReceiptDesignPreset.defaults('report');
    if (!preset.showBrandLogo || preset.logoBytes == null) {
      try {
        final logoData = await rootBundle.load('assets/images/logo.png');
        preset = preset.copyWith(showBrandLogo: true, logoBytes: logoData.buffer.asUint8List());
      } catch (_) {}
    }
    if (!mounted) return;
    final translations = _buildTranslations();
    try {
      showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _ExportLoading());
      final snapshot = ref.read(financialTreeProvider.notifier).buildSnapshot();
      final bytes = await FinancialTreeReportPdfGenerator.generate(
        snapshot: snapshot, preset: preset, translations: translations,
        reportTitle: tree.name, periodLabel: '',
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      final dir = await getApplicationDocumentsDirectory();
      final safeName = tree.name.replaceAll(RegExp(r'[^\w\u0600-\u06FF -]'), '_');
      final n = DateTime.now();
      final stamp = '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}_${n.hour.toString().padLeft(2, '0')}${n.minute.toString().padLeft(2, '0')}${n.second.toString().padLeft(2, '0')}';
      final file = File('${dir.path}/${safeName}_$stamp.pdf');
      await file.writeAsBytes(bytes);
      await ref.read(financialTreeProvider.notifier).saveReport(snapshot);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('exportCompleted')), backgroundColor: AppColors.success));
        await StorageUtil.showPdfOptions(context, file, '${safeName}_$stamp.pdf');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_tr('exportFailed')}: $e'), backgroundColor: AppColors.danger));
      }
    }
  }

  Map<String, String> _buildTranslations() {
    final keys = [
      'clientName', 'reportCreatedOn', 'summary', 'distributionChart', 'treeSection',
      'treeSubtitle', 'netFlow', 'savingsRate', 'expenseRate', 'investRate',
      'changelogSection', 'createdAt', 'updatedAt', 'nodesCount', 'paymentsCount',
      'exportedOn', 'paidLabel', 'remainingLabel', 'paymentLabel', 'totalAssets',
      'totalIncome', 'totalExpenses', 'totalInvestments', 'totalReceivable', 'totalPayable',
      'totalPaidLabel', 'totalRemainingLabel', 'availableBalance', 'netWorth',
      ...FinancialTreeNodeType.values.map((t) => t.labelKey),
      ...NodePaymentStatus.values.map((s) => s.labelKey),
    ];
    return {for (final k in keys) k: _tr(k)};
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(financialTreeProvider);
    final tree = state.currentTree;
    final nodes = state.nodes;

    if (tree == null || nodes.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(_tr('financialTree'), style: TreeTheme.headingMd)),
        body: TreeEmptyState(
          icon: Icons.account_tree,
          title: _tr('emptyStateTitle'),
          subtitle: _tr('emptyStateSubtitle'),
          buttonLabel: _tr('createFirstTree'),
          onButtonPressed: () => _quickAdd(),
        ),
      );
    }

    final layout = _computeLayout(nodes);
    _layout = layout;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tree.name, style: TreeTheme.headingSm),
            if (tree.clientName.isNotEmpty)
              Text(tree.clientName, style: TreeTheme.caption),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _tr('treeSettings'),
            icon:  Icon(Icons.settings_outlined, color: AppColors.textSecondary, size: 22),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const TreeSettingsSheet(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          TreeKpiDashboard(computation: state.computation, currency: tree.currency),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _controller,
                        constrained: false,
                        minScale: 0.2,
                        maxScale: 3.0,
                        boundaryMargin: const EdgeInsets.all(4000),
                        child: SizedBox(
                          width: layout.width,
                          height: layout.height,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CustomPaint(painter: TreeEdgePainter(positions: layout.positions, nodes: nodes)),
                              ),
                              for (final n in nodes)
                                if (layout.positions.containsKey(n.id))
                                  Positioned(
                                    left: layout.positions[n.id]!.dx,
                                    top: layout.positions[n.id]!.dy,
                                    child: TreeNodeCard(
                                      node: n,
                                      selected: n.id == _selectedId,
                                      highlighted: n.id == _highlightId,
                                      matched: false,
                                      hasChildren: nodes.any((c) => c.parentId == n.id),
                                      onTap: () {
                                        _selectNode(n.id);
                                        _openNodeDetails(n);
                                      },
                                      onToggleCollapse: () => ref.read(financialTreeProvider.notifier).toggleCollapsed(n.id),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Search overlay
                    if (_searching)
                      TreeSearchOverlay(
                        nodes: nodes,
                        onQueryChanged: (_) {},
                        onNodeSelected: (id) {
                          _selectNode(id);
                          _focusOn(id);
                          setState(() => _searching = false);
                        },
                        onClose: () => setState(() => _searching = false),
                      ),
                    // Legend + unified action bar
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SafeArea(
                        minimum: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_legendOpen) ...[
                              TreeLegendPanel(
                                onClose: () => setState(() => _legendOpen = false),
                              ),
                              const SizedBox(height: 10),
                            ],
                            Center(
                              child: TreeActionBar(
                                onAdd: _quickAdd,
                                onSearch: () => setState(() => _searching = !_searching),
                                onZoomIn: () => _zoom(1.25),
                                onZoomOut: () => _zoom(0.8),
                                onFit: _fitToScreen,
                                onReset: _resetView,
                                onToggleLegend: () => setState(() => _legendOpen = !_legendOpen),
                                legendOpen: _legendOpen,
                                onExpandAll: () => ref.read(financialTreeProvider.notifier).setAllCollapsed(false),
                                onCollapseAll: () => ref.read(financialTreeProvider.notifier).setAllCollapsed(true),
                                onExport: _exportTree,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportLoading extends StatelessWidget {
  const _ExportLoading();
  @override
  Widget build(BuildContext context) {
    final text = AppLocalizations.of(context).translate('exportingReport');
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusXl)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DotsLoader(),
            const SizedBox(height: 16),
            Text(text, style: TreeTheme.bodyMd),
          ],
        ),
      ),
    );
  }
}
