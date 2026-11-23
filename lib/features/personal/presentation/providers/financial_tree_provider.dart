import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../data/models/financial_tree_models.dart';
import '../../data/repositories/financial_tree_storage.dart';
import '../../domain/financial_engine.dart';

final financialTreeStorageProvider = Provider<FinancialTreeStorage>(
  (ref) => FinancialTreeStorage(),
);

class FinancialTreeState {
  final bool isLoading;
  final String? error;
  final List<FinancialTree> trees;
  final String? currentTreeId;
  final FinancialTree? currentTree;
  final List<FinancialTreeNode> nodes;
  final TreeComputation computation;
  final bool isDirty;

  const FinancialTreeState({
    this.isLoading = false,
    this.error,
    this.trees = const [],
    this.currentTreeId,
    this.currentTree,
    this.nodes = const [],
    this.computation = const TreeComputation(
      baseBalance: 0,
      allocated: 0,
      available: 0,
      totalAssets: 0,
      totalIncome: 0,
      totalExpenses: 0,
      totalInvestments: 0,
      totalReceivable: 0,
      totalPayable: 0,
      netWorth: 0,
      totalPaid: 0,
      totalRemaining: 0,
      distribution: {},
      computedAt: null,
    ),
    this.isDirty = false,
  });

  FinancialTreeState copyWith({
    bool? isLoading,
    String? error,
    List<FinancialTree>? trees,
    String? currentTreeId,
    FinancialTree? currentTree,
    List<FinancialTreeNode>? nodes,
    TreeComputation? computation,
    bool? isDirty,
  }) => FinancialTreeState(
    isLoading: isLoading ?? this.isLoading,
    error: error,
    trees: trees ?? this.trees,
    currentTreeId: currentTreeId ?? this.currentTreeId,
    currentTree: currentTree ?? this.currentTree,
    nodes: nodes ?? this.nodes,
    computation: computation ?? this.computation,
    isDirty: isDirty ?? this.isDirty,
  );
}

/// Converts amounts to the tree currency using the shared currency engine.
class TreeCurrency {
  final CurrencyEngine engine;
  final String target;
  TreeCurrency(this.engine, this.target);

  double convert(String from, double amount) {
    if (amount == 0) return 0;
    if (from == target) return amount;
    final converted = engine.convert(amount, from, target);
    return converted;
  }
}

TreeComputation computeTree({
  required FinancialTree tree,
  required List<FinancialTreeNode> nodes,
  required TreeCurrency currency,
}) {
  return FinancialEngine.computeTree(
    tree: tree,
    nodes: nodes,
    convert: (from, to, amount) => currency.convert(from, amount),
  );
}

class FinancialTreeNotifier extends StateNotifier<FinancialTreeState> {
  final Ref _ref;
  FinancialTreeNotifier(this._ref) : super(const FinancialTreeState()) {
    _init();
  }

  FinancialTreeStorage get _storage => _ref.read(financialTreeStorageProvider);

  Future<void> _init() async {
    final trees = await _storage.loadTrees();
    state = state.copyWith(trees: trees);
    if (trees.isNotEmpty) {
      await openTree(trees.first.id);
    } else {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> refresh() async {
    final trees = await _storage.loadTrees();
    state = state.copyWith(trees: trees, isLoading: false);
  }

  Future<FinancialTree> createTree({
    required String name,
    String clientName = '',
    double baseAmount = 0,
    String currency = 'SAR',
    String notes = '',
  }) async {
    final now = DateTime.now();
    final treeId = newNodeId();
    final rootId = newNodeId();
    final tree = FinancialTree(
      id: treeId,
      name: name.trim(),
      clientName: clientName.trim(),
      baseAmount: baseAmount,
      currency: currency,
      notes: notes.trim(),
      rootNodeId: rootId,
      createdAt: now,
      updatedAt: now,
    );
    final root = FinancialTreeNode(
      id: rootId,
      treeId: treeId,
      parentId: null,
      name: name.trim(),
      type: FinancialTreeNodeType.root,
      amount: baseAmount,
      currency: currency,
      notes: notes.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await _storage.saveNodes(tree, [root]);
    final trees = await _storage.loadTrees();
    state = state.copyWith(trees: trees);
    await openTree(treeId);
    return tree;
  }

  /// ينشئ شجرة تجريبية جاهزة بأمثلة واقعية ليتعلم المستخدم الاستخدام بسرعة.
  Future<FinancialTree> createDemoTree() async {
    final now = DateTime.now();
    final treeId = newNodeId();
    final rootId = newNodeId();
    final tree = FinancialTree(
      id: treeId,
      name: AppLocalizations.t('demoTreeName'),
      clientName: '',
      baseAmount: 100000,
      currency: 'SAR',
      notes: AppLocalizations.t('demoTreeNotes'),
      rootNodeId: rootId,
      createdAt: now,
      updatedAt: now,
    );
    FinancialTreeNode node(
      String name,
      FinancialTreeNodeType type,
      double amount, {
      String? parentId,
      int sortOrder = 0,
      List<NodePayment> payments = const [],
    }) =>
        FinancialTreeNode(
          id: newNodeId(),
          treeId: treeId,
          parentId: parentId,
          name: name,
          type: type,
          amount: amount,
          currency: 'SAR',
          createdAt: now,
          updatedAt: now,
          sortOrder: sortOrder,
          payments: payments,
        );
    final demo = <FinancialTreeNode>[
      FinancialTreeNode(
        id: rootId,
        treeId: treeId,
        parentId: null,
        name: AppLocalizations.t('demoTreeName'),
        type: FinancialTreeNodeType.root,
        amount: 100000,
        currency: 'SAR',
        createdAt: now,
        updatedAt: now,
      ),
      node(AppLocalizations.t('demoNodeSalary'), FinancialTreeNodeType.income, 15000, parentId: rootId, sortOrder: 0),
      node(AppLocalizations.t('demoNodeRent'), FinancialTreeNodeType.expense, 4000, parentId: rootId, sortOrder: 1),
      node(AppLocalizations.t('demoNodeBills'), FinancialTreeNodeType.expense, 2500, parentId: rootId, sortOrder: 2),
      node(AppLocalizations.t('demoNodeCar'), FinancialTreeNodeType.asset, 60000, parentId: rootId, sortOrder: 3),
      node(AppLocalizations.t('demoNodeEmergency'), FinancialTreeNodeType.saving, 15000, parentId: rootId, sortOrder: 4),
      node(
        AppLocalizations.t('demoNodeLoan'),
        FinancialTreeNodeType.debt,
        20000,
        parentId: rootId,
        sortOrder: 5,
        payments: [NodePayment(id: newNodeId(), amount: 5000, date: now)],
      ),
      node(AppLocalizations.t('demoNodeReceivable'), FinancialTreeNodeType.receivable, 8000, parentId: rootId, sortOrder: 6),
    ];
    await _storage.saveNodes(tree, demo);
    final trees = await _storage.loadTrees();
    state = state.copyWith(trees: trees);
    await openTree(treeId);
    return tree;
  }

  Future<void> updateTreeMeta({
    required String name,
    required String clientName,
    double baseAmount = 0,
    required String currency,
    String notes = '',
  }) async {
    final tree = state.currentTree;
    if (tree == null) return;
    final updated = tree.copyWith(
      name: name.trim(),
      clientName: clientName.trim(),
      baseAmount: baseAmount,
      currency: currency,
      notes: notes.trim(),
      updatedAt: DateTime.now(),
    );
    // Keep the root node in sync with the base amount.
    var nodes = state.nodes;
    final rootIndex = nodes.indexWhere((n) => n.isRoot);
    if (rootIndex >= 0) {
      final root = nodes[rootIndex];
      nodes = [...nodes];
      nodes[rootIndex] = root.copyWith(
        name: name.trim(),
        amount: baseAmount,
        currency: currency,
        notes: notes.trim(),
        updatedAt: DateTime.now(),
      );
    }
    await _storage.saveNodes(updated, nodes);
    final trees = await _storage.loadTrees();
    state = state.copyWith(
      trees: trees,
      currentTree: updated,
      nodes: nodes,
      computation: computeTree(tree: updated, nodes: nodes, currency: TreeCurrency(_ref.read(currencyEngineProvider), currency)),
      isDirty: false,
    );
  }

  Future<void> openTree(String treeId) async {
    final trees = await _storage.loadTrees();
    final tree = trees.where((t) => t.id == treeId).firstOrNull;
    if (tree == null) {
      state = state.copyWith(trees: trees, currentTreeId: null, currentTree: null, nodes: const []);
      return;
    }
    final nodes = await _storage.loadNodes(treeId);
    state = state.copyWith(
      isLoading: false,
      trees: trees,
      currentTreeId: treeId,
      currentTree: tree,
      nodes: nodes,
      computation: computeTree(tree: tree, nodes: nodes, currency: TreeCurrency(_ref.read(currencyEngineProvider), tree.currency)),
      isDirty: false,
    );
  }

  Future<void> deleteTree(String treeId) async {
    await _storage.deleteTree(treeId);
    final trees = await _storage.loadTrees();
    state = state.copyWith(
      trees: trees,
      currentTreeId: trees.isNotEmpty ? trees.first.id : null,
      currentTree: trees.isNotEmpty ? trees.first : null,
      nodes: trees.isNotEmpty ? await _storage.loadNodes(trees.first.id) : const [],
    );
  }

  List<FinancialTreeNode> _sortedChildren(List<FinancialTreeNode> nodes, String? parentId) {
    final children = nodes.where((n) => n.parentId == parentId).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return children;
  }

  List<FinancialTreeNode> _recomputeSortOrders(List<FinancialTreeNode> nodes) {
    final result = <FinancialTreeNode>[];
    void visit(String? parentId) {
      final children = _sortedChildren(nodes, parentId);
      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        final updated = child.sortOrder == i ? child : child.copyWith(sortOrder: i, updatedAt: child.updatedAt);
        result.add(updated);
        visit(child.id);
      }
    }

    final roots = _sortedChildren(nodes, null);
    for (var i = 0; i < roots.length; i++) {
      final root = roots[i];
      final updated = root.sortOrder == i ? root : root.copyWith(sortOrder: i, updatedAt: root.updatedAt);
      result.add(updated);
      visit(root.id);
    }
    return result;
  }

  Future<String?> addNode({
    required String parentId,
    required String name,
    required FinancialTreeNodeType type,
    double amount = 0,
    String currency = 'SAR',
    String notes = '',
  }) async {
    final tree = state.currentTree;
    if (tree == null) return null;
    final now = DateTime.now();
    final siblings = state.nodes.where((n) => n.parentId == parentId).length;
    final node = FinancialTreeNode(
      id: newNodeId(),
      treeId: tree.id,
      parentId: parentId,
      name: name.trim(),
      type: type,
      amount: amount,
      currency: currency,
      notes: notes.trim(),
      sortOrder: siblings,
      createdAt: now,
      updatedAt: now,
    );
    final nodes = [...state.nodes, node];
    // Expanding the parent so the new node is visible.
    final parentIndex = nodes.indexWhere((n) => n.id == parentId);
    if (parentIndex >= 0 && nodes[parentIndex].collapsed) {
      nodes[parentIndex] = nodes[parentIndex].copyWith(collapsed: false);
    }
    await _persistAndSet(nodes);
    return node.id;
  }

  Future<void> updateNode(FinancialTreeNode node) async {
    final nodes = [...state.nodes];
    final index = nodes.indexWhere((n) => n.id == node.id);
    if (index < 0) return;
    nodes[index] = node;
    await _persistAndSet(nodes);
  }

  Future<void> deleteNode(String nodeId) async {
    final tree = state.currentTree;
    if (tree == null) return;
    final nodes = state.nodes.where((n) => n.id == nodeId).toList();
    if (nodes.isNotEmpty && nodes.first.isRoot) return;
    final toRemove = <String>{nodeId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final n in state.nodes) {
        if (n.parentId != null && toRemove.contains(n.parentId) && !toRemove.contains(n.id)) {
          toRemove.add(n.id);
          changed = true;
        }
      }
    }
    final filtered = state.nodes.where((n) => !toRemove.contains(n.id)).toList();
    await _persistAndSet(_recomputeSortOrders(filtered));
  }

  Future<void> addPayment(String nodeId, NodePayment payment) async {
    final index = state.nodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final nodes = [...state.nodes];
    final node = nodes[index];
    nodes[index] = node.copyWith(payments: [...node.payments, payment], updatedAt: DateTime.now());
    await _persistAndSet(nodes);
  }

  Future<void> updatePayment(String nodeId, NodePayment payment) async {
    final index = state.nodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final nodes = [...state.nodes];
    final node = nodes[index];
    final payments = node.payments.map((p) => p.id == payment.id ? payment : p).toList();
    nodes[index] = node.copyWith(payments: payments, updatedAt: DateTime.now());
    await _persistAndSet(nodes);
  }

  Future<void> deletePayment(String nodeId, String paymentId) async {
    final index = state.nodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final nodes = [...state.nodes];
    final node = nodes[index];
    nodes[index] = node.copyWith(
      payments: node.payments.where((p) => p.id != paymentId).toList(),
      updatedAt: DateTime.now(),
    );
    await _persistAndSet(nodes);
  }

  Future<void> setAllCollapsed(bool collapsed) async {
    final changed = state.nodes.where((n) => n.collapsed != collapsed).toList();
    if (changed.isEmpty) return;
    final nodes = [...state.nodes]
        .map((n) => n.collapsed == collapsed ? n : n.copyWith(collapsed: collapsed))
        .toList();
    await _persistAndSet(nodes, recomputeLayoutOnly: true);
  }

  Future<void> toggleCollapsed(String nodeId) async {
    final index = state.nodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final nodes = [...state.nodes];
    final node = nodes[index];
    nodes[index] = node.copyWith(collapsed: !node.collapsed, updatedAt: node.updatedAt);
    await _persistAndSet(nodes, recomputeLayoutOnly: true);
  }

  Future<void> reorderChild(String? parentId, int oldIndex, int newIndex) async {
    final siblings = _sortedChildren(state.nodes, parentId);
    if (siblings.length <= 1) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= siblings.length) newIndex = siblings.length - 1;
    if (oldIndex == newIndex) return;
    final reordered = [...siblings];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final nodes = [...state.nodes];
    for (var i = 0; i < reordered.length; i++) {
      final idx = nodes.indexWhere((n) => n.id == reordered[i].id);
      if (idx >= 0) {
        nodes[idx] = nodes[idx].copyWith(sortOrder: i);
      }
    }
    await _persistAndSet(nodes);
  }

  /// Moves [nodeId] under a new parent (drag & drop re-parenting).
  Future<void> moveNode(String nodeId, String? newParentId) async {
    final node = state.nodes.where((n) => n.id == nodeId).firstOrNull;
    if (node == null || node.isRoot) return;
    if (newParentId == nodeId) return;
    // Prevent cycles.
    var parent = newParentId;
    while (parent != null) {
      if (parent == nodeId) return;
      parent = state.nodes.where((n) => n.id == parent).firstOrNull?.parentId;
    }
    final nodes = [...state.nodes];
    final index = nodes.indexWhere((n) => n.id == nodeId);
    final siblings = _sortedChildren(nodes, newParentId).length;
    nodes[index] = node.copyWith(
      parentId: newParentId,
      sortOrder: siblings,
      updatedAt: DateTime.now(),
    );
    if (newParentId != null) {
      final pi = nodes.indexWhere((n) => n.id == newParentId);
      if (pi >= 0 && nodes[pi].collapsed) {
        nodes[pi] = nodes[pi].copyWith(collapsed: false);
      }
    }
    await _persistAndSet(_recomputeSortOrders(nodes));
  }

  Future<void> _persistAndSet(List<FinancialTreeNode> nodes, {bool recomputeLayoutOnly = false}) async {
    final tree = state.currentTree;
    if (tree == null) return;
    final updated = tree.copyWith(updatedAt: DateTime.now());
    await _storage.saveNodes(updated, nodes);
    state = state.copyWith(
      currentTree: updated,
      nodes: nodes,
      computation: computeTree(tree: updated, nodes: nodes, currency: TreeCurrency(_ref.read(currencyEngineProvider), updated.currency)),
      isDirty: true,
    );
    unawaited(refreshTreesOnly());
  }

  Future<void> refreshTreesOnly() async {
    final trees = await _storage.loadTrees();
    state = state.copyWith(trees: trees);
  }

  // ---- Reports history ----

  Future<List<FinancialTreeReportSnapshot>> loadReports() => _storage.loadReports();

  Future<void> saveReport(FinancialTreeReportSnapshot report) async {
    await _storage.saveReport(report);
  }

  Future<void> deleteReport(String reportId) async {
    await _storage.deleteReport(reportId);
  }

  /// Builds a snapshot from the current tree for export / saved history.
  FinancialTreeReportSnapshot buildSnapshot() {
    final tree = state.currentTree;
    if (tree == null) {
      throw StateError('No tree open');
    }
    return FinancialTreeReportSnapshot(
      reportId: newNodeId(),
      treeId: tree.id,
      tree: tree,
      nodes: List.of(state.nodes),
      computation: state.computation,
      createdAt: DateTime.now(),
    );
  }

  /// Rebuilds the computation for an arbitrary snapshot (used for saved reports).
  TreeComputation computationFor(FinancialTreeReportSnapshot snapshot) =>
      computeTree(
        tree: snapshot.tree,
        nodes: snapshot.nodes,
        currency: TreeCurrency(_ref.read(currencyEngineProvider), snapshot.tree.currency),
      );
}

final financialTreeProvider = StateNotifierProvider<FinancialTreeNotifier, FinancialTreeState>(
  (ref) => FinancialTreeNotifier(ref),
);
