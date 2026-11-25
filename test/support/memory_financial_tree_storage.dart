import 'package:fyona_flutter/features/personal/data/models/financial_tree_models.dart';
import 'package:fyona_flutter/features/personal/data/repositories/financial_tree_storage.dart';

/// Widget tests run under fake async, where the real (encrypted ledger)
/// storage's background I/O never completes: keep trees in memory there.
class MemoryFinancialTreeStorage extends FinancialTreeStorage {
  final trees = <FinancialTree>[];
  final nodes = <String, List<FinancialTreeNode>>{};
  final reports = <FinancialTreeReportSnapshot>[];

  @override
  Future<List<FinancialTree>> loadTrees() async => [...trees];

  @override
  Future<List<FinancialTreeNode>> loadNodes(String treeId) async =>
      [...?nodes[treeId]];

  @override
  Future<void> saveTree(FinancialTree tree) async {
    final i = trees.indexWhere((t) => t.id == tree.id);
    if (i >= 0) {
      trees[i] = tree;
    } else {
      trees.insert(0, tree);
    }
  }

  @override
  Future<void> saveNodes(FinancialTree tree, List<FinancialTreeNode> list) async {
    await saveTree(tree);
    nodes[tree.id] = [...list];
  }

  @override
  Future<void> deleteTree(String treeId) async {
    trees.removeWhere((t) => t.id == treeId);
    nodes.remove(treeId);
  }

  @override
  Future<List<FinancialTreeReportSnapshot>> loadReports() async => [...reports];

  @override
  Future<void> saveReport(FinancialTreeReportSnapshot report) async {
    reports.removeWhere((r) => r.reportId == report.reportId);
    reports.insert(0, report);
  }

  @override
  Future<void> deleteReport(String reportId) async =>
      reports.removeWhere((r) => r.reportId == reportId);
}
