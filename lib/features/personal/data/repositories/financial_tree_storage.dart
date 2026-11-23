import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/financial_tree_models.dart';

const _kTreesKey = 'financial_trees_v1';
const _kReportsKey = 'financial_tree_reports_v1';

/// Local persistence for user-built financial trees and saved report snapshots.
class FinancialTreeStorage {
  Future<List<FinancialTree>> loadTrees() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTreesKey);
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('financial_tree_nodes_$treeId');
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
    final prefs = await SharedPreferences.getInstance();
    final trees = await loadTrees();
    final index = trees.indexWhere((t) => t.id == tree.id);
    if (index >= 0) {
      trees[index] = tree;
    } else {
      trees.insert(0, tree);
    }
    await prefs.setString(_kTreesKey, jsonEncode(trees.map((t) => t.toJson()).toList()));
  }

  Future<void> saveNodes(FinancialTree tree, List<FinancialTreeNode> nodes) async {
    final prefs = await SharedPreferences.getInstance();
    await saveTree(tree);
    await prefs.setString(
      'financial_tree_nodes_${tree.id}',
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
  }

  Future<void> deleteTree(String treeId) async {
    final prefs = await SharedPreferences.getInstance();
    final trees = await loadTrees();
    trees.removeWhere((t) => t.id == treeId);
    await prefs.setString(_kTreesKey, jsonEncode(trees.map((t) => t.toJson()).toList()));
    await prefs.remove('financial_tree_nodes_$treeId');
  }

  Future<List<FinancialTreeReportSnapshot>> loadReports() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kReportsKey);
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
    final prefs = await SharedPreferences.getInstance();
    final reports = await loadReports();
    reports.removeWhere((r) => r.reportId == report.reportId);
    reports.insert(0, report);
    while (reports.length > 100) {
      reports.removeLast();
    }
    await prefs.setString(_kReportsKey, jsonEncode(reports.map((r) => r.toJson()).toList()));
  }

  Future<void> deleteReport(String reportId) async {
    final prefs = await SharedPreferences.getInstance();
    final reports = await loadReports();
    reports.removeWhere((r) => r.reportId == reportId);
    await prefs.setString(_kReportsKey, jsonEncode(reports.map((r) => r.toJson()).toList()));
  }
}
