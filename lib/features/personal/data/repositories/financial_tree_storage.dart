import 'dart:convert';
import '../ledger/personal_ledger.dart';
import '../models/financial_tree_models.dart';

const _kTreesKey = 'financial_trees_v1';
const _kReportsKey = 'financial_tree_reports_v1';

/// Local persistence for user-built financial trees and saved report snapshots.
///
/// Stored in the signed-in user's encrypted Personal ledger (same keys the
/// old SharedPreferences entries used; those are moved over once).
class FinancialTreeStorage {
  Future<List<FinancialTree>> loadTrees() async {
    final raw = await PersonalLedgerKv.getString(_kTreesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => FinancialTree.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<FinancialTreeNode>> loadNodes(String treeId) async {
    final raw = await PersonalLedgerKv.getString('financial_tree_nodes_$treeId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => FinancialTreeNode.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveTree(FinancialTree tree) async {
    final trees = await loadTrees();
    final index = trees.indexWhere((t) => t.id == tree.id);
    if (index >= 0) {
      trees[index] = tree;
    } else {
      trees.insert(0, tree);
    }
    await PersonalLedgerKv.setString(_kTreesKey, jsonEncode(trees.map((t) => t.toJson()).toList()));
  }

  Future<void> saveNodes(FinancialTree tree, List<FinancialTreeNode> nodes) async {
    await saveTree(tree);
    await PersonalLedgerKv.setString(
      'financial_tree_nodes_${tree.id}',
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
  }

  Future<void> deleteTree(String treeId) async {
    final trees = await loadTrees();
    trees.removeWhere((t) => t.id == treeId);
    await PersonalLedgerKv.setString(_kTreesKey, jsonEncode(trees.map((t) => t.toJson()).toList()));
    await PersonalLedgerKv.remove('financial_tree_nodes_$treeId');
  }

  Future<List<FinancialTreeReportSnapshot>> loadReports() async {
    final raw = await PersonalLedgerKv.getString(_kReportsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => FinancialTreeReportSnapshot.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveReport(FinancialTreeReportSnapshot report) async {
    final reports = await loadReports();
    reports.removeWhere((r) => r.reportId == report.reportId);
    reports.insert(0, report);
    while (reports.length > 100) {
      reports.removeLast();
    }
    await PersonalLedgerKv.setString(_kReportsKey, jsonEncode(reports.map((r) => r.toJson()).toList()));
  }

  Future<void> deleteReport(String reportId) async {
    final reports = await loadReports();
    reports.removeWhere((r) => r.reportId == reportId);
    await PersonalLedgerKv.setString(_kReportsKey, jsonEncode(reports.map((r) => r.toJson()).toList()));
  }
}
