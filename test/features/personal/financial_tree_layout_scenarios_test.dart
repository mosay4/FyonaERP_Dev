import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/financial_tree_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/financial_tree_report_pdf.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/receipt_design_models.dart';

FinancialTreeNode _n({
  required String id,
  String? parentId,
  required String name,
  required FinancialTreeNodeType type,
  double amount = 0,
  String currency = 'SAR',
  int sortOrder = 0,
}) =>
    FinancialTreeNode(
      id: id,
      treeId: 'tree1',
      parentId: parentId,
      name: name,
      type: type,
      amount: amount,
      currency: currency,
      notes: '',
      payments: const [],
      sortOrder: sortOrder,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 10),
    );

FinancialTree _tree(String name) => FinancialTree(
      id: 'tree1',
      name: name,
      clientName: 'عميل تجريبي',
      baseAmount: 1000000,
      currency: 'SAR',
      rootNodeId: 'root',
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 10),
    );

TreeComputation _comp(List<FinancialTreeNode> ns) => TreeComputation(
      baseBalance: 1000000,
      allocated: ns.fold<double>(0, (s, n) => n.isRoot ? s : s + n.amount),
      available: 1000000,
      totalAssets: 250000,
      totalIncome: 0,
      totalExpenses: 0,
      totalInvestments: 50000,
      totalReceivable: 0,
      totalPayable: 0,
      netWorth: 1190000,
      totalPaid: 0,
      totalRemaining: 0,
      distribution: const {'asset': 100.0},
      computedAt: DateTime(2026, 8, 10, 12),
    );

/// أبعاد صفحات الـ PDF المستخرجة من /MediaBox
List<({double w, double h})> _pageSizes(Uint8List bytes) {
  final body = String.fromCharCodes(bytes);
  final re = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]');
  return re
      .allMatches(body)
      .map((m) => (w: double.parse(m[1]!), h: double.parse(m[2]!)))
      .toList();
}

Future<Uint8List> _emit(
  String label,
  List<FinancialTreeNode> nodes,
) async {
  final snapshot = FinancialTreeReportSnapshot(
    reportId: 'r1',
    treeId: 'tree1',
    tree: _tree('الثروة الشخصية'),
    nodes: nodes,
    computation: _comp(nodes),
    createdAt: DateTime(2026, 8, 10, 13),
  );
  final preset = const ReceiptDesignPreset(sectionId: 'report')
      .copyWith(primaryColor: const Color(0xFFA01530), footerText: 'FYONA ERP')
      .copyWith(showBrandLogo: false);
  final bytes = await FinancialTreeReportPdfGenerator.generate(
    snapshot: snapshot,
    preset: preset,
    translations: null,
    reportTitle: 'تقرير الشجرة الحسابية',
    periodLabel: 'الفترة: أغسطس 2026',
    showTree: true,
    showKpis: true,
    showCharts: true,
    showPayments: false,
    showNotes: false,
    showChangelog: false,
    landscape: false,
  );
  final dir = Directory('${Directory.systemTemp.path}/fyona_qa');
  dir.createSync(recursive: true);
  File('${dir.path}/scenario_$label.pdf').writeAsBytesSync(bytes);
  // ignore: avoid_print
  print('scenario $label bytes=${bytes.length}');
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('layout scenarios generate with sane page sizes', (tester) async {
    // 0) عقدة واحدة فقط
    await _emit('single', [
      _n(id: 'root', name: 'الثروة', type: FinancialTreeNodeType.root, amount: 500000),
    ]);

    // 1) root + 3 main categories (أوراق مباشرة)
    final cats = await _emit('cats', [
      _n(id: 'root', name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 1000000),
      _n(id: 'inc', parentId: 'root', name: 'الدخل', type: FinancialTreeNodeType.income, amount: 300000, sortOrder: 0),
      _n(id: 'exp', parentId: 'root', name: 'المصروفات', type: FinancialTreeNodeType.expense, amount: -120000, sortOrder: 1),
      _n(id: 'as', parentId: 'root', name: 'الأصول', type: FinancialTreeNodeType.asset, amount: 820000, sortOrder: 2),
    ]);
    var pages = _pageSizes(cats);
    expect(pages, isNotEmpty);
    for (final p in pages) {
      expect(p.w, greaterThan(100));
      expect(p.h, greaterThan(100));
    }

    // 2) 3 فئات × 3 أبناء (9 أوراق → صفحة Landscape)
    final gridNodes = [
      _n(id: 'root', name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 2000000),
    ];
    for (var c = 0; c < 3; c++) {
      final catId = 'cat$c';
      gridNodes.add(_n(
        id: catId,
        parentId: 'root',
        name: c == 0 ? 'الدخل' : (c == 1 ? 'المصروفات' : 'الأصول'),
        type: c == 0
            ? FinancialTreeNodeType.income
            : (c == 1 ? FinancialTreeNodeType.expense : FinancialTreeNodeType.asset),
        amount: 500000,
        sortOrder: c,
      ));
      for (var k = 0; k < 3; k++) {
        gridNodes.add(_n(
          id: '${catId}_$k',
          parentId: catId,
          name: 'بند ${k + 1}',
          type: FinancialTreeNodeType.asset,
          amount: 100000 + k * 5000,
          sortOrder: k,
        ));
      }
    }
    final grid = await _emit('grid', gridNodes);
    pages = _pageSizes(grid);
    expect(pages.any((p) => p.w > p.h), isTrue,
        reason: 'شجرة من 9 أوراق يجب أن تنتج صفحة Landscape');

    // 3) فئة واحدة بـ 8 أبناء → Landscape
    final eight = await _emit('eight', [
      _n(id: 'root', name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 2000000),
      for (var i = 0; i < 8; i++)
        _n(
          id: 'c$i',
          parentId: 'root',
          name: 'فرع ${i + 1}',
          type: i.isEven ? FinancialTreeNodeType.asset : FinancialTreeNodeType.investment,
          amount: 100000 + i * 10000,
          sortOrder: i,
        ),
    ]);
    pages = _pageSizes(eight);
    expect(pages.any((p) => p.w > p.h), isTrue,
        reason: 'شجرة من 8 أوراق يجب أن تنتج صفحة Landscape');

    // 4) أعماق متعددة
    await _emit('deep', [
      _n(id: 'root', name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 1000000),
      _n(id: 'l1', parentId: 'root', name: 'الاستثمارات', type: FinancialTreeNodeType.investment, amount: 500000),
      _n(id: 'l2a', parentId: 'l1', name: 'أسهم', type: FinancialTreeNodeType.asset, amount: 300000),
      _n(id: 'l2b', parentId: 'l1', name: 'سندات', type: FinancialTreeNodeType.asset, amount: 200000),
      _n(id: 'l3', parentId: 'l2a', name: 'محفظة تقنية', type: FinancialTreeNodeType.asset, amount: 100000),
      _n(id: 'l4', parentId: 'l3', name: 'شركة ناشئة', type: FinancialTreeNodeType.investment, amount: 50000),
    ]);

    // 5) أسماء عربية طويلة
    await _emit('long', [
      _n(id: 'root', name: 'الثروة الشخصية الشاملة للمجموعة العائلية الكبرى', type: FinancialTreeNodeType.root, amount: 5000000),
      _n(id: 'a', parentId: 'root', name: 'قرض السيارة المستأجرة من البنك الأهلي', type: FinancialTreeNodeType.debt, amount: 750000),
      _n(id: 'b', parentId: 'root', name: 'محفظة الأسهم والسندات الأمريكية', type: FinancialTreeNodeType.investment, amount: 250000),
    ]);

    // 6) أرقام ضخمة
    await _emit('huge', [
      _n(id: 'root', name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 9876543210),
      _n(id: 'a', parentId: 'root', name: 'عقارات', type: FinancialTreeNodeType.asset, amount: 543210987),
      _n(id: 'b', parentId: 'root', name: 'أسهم', type: FinancialTreeNodeType.asset, amount: 123456789),
    ]);
  });
}
