import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/financial_tree_models.dart';
import 'package:fyona_flutter/features/personal/domain/financial_engine.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/financial_tree_provider.dart';

import '../../test_utils.dart';

FinancialTreeNode _node({
  required String id,
  String? parentId,
  required String name,
  required FinancialTreeNodeType type,
  double amount = 0,
  String currency = 'SAR',
  String notes = '',
  List<NodePayment> payments = const [],
}) =>
    FinancialTreeNode(
      id: id,
      treeId: 'tree1',
      parentId: parentId,
      name: name,
      type: type,
      amount: amount,
      currency: currency,
      notes: notes,
      payments: payments,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

FinancialTree _tree() => FinancialTree(
  id: 'tree1',
  name: 'My Tree',
  clientName: 'Client',
  baseAmount: 1000,
  currency: 'SAR',
  rootNodeId: 'root',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  // FinancialEngine builds every warning/issue message via AppLocalizations.t,
  // which returns the raw key when no ARB table is cached — preload so the
  // Arabic assertions below see real text.
  setUpAll(() => ensureTestLocalization());

  group('FinancialTreeNodeType', () {
    test('fromId maps ids and falls back to custom', () {
      expect(FinancialTreeNodeType.fromId('income'), FinancialTreeNodeType.income);
      expect(FinancialTreeNodeType.fromId('unknown'), FinancialTreeNodeType.custom);
      expect(FinancialTreeNodeType.fromId(null), FinancialTreeNodeType.custom);
    });

    test('every type has a label key and color', () {
      for (final t in FinancialTreeNodeType.values) {
        expect(t.labelKey, isNotEmpty);
        expect(t.color, greaterThan(0));
      }
    });
  });

  group('NodePaymentStatus', () {
    test('fromId maps ids and falls back to pending', () {
      expect(NodePaymentStatus.fromId('paid'), NodePaymentStatus.paid);
      expect(NodePaymentStatus.fromId('overdue'), NodePaymentStatus.overdue);
      expect(NodePaymentStatus.fromId('nope'), NodePaymentStatus.pending);
    });
  });

  group('FinancialTreeNode payments', () {
    test('paidAmount sums only matching currency payments', () {
      final node = _node(
        id: 'n1',
        parentId: 'root',
        name: 'Debt',
        type: FinancialTreeNodeType.debt,
        amount: 100,
        payments: [
          NodePayment(id: 'p1', amount: 30, date: DateTime(2026, 1, 2)),
          NodePayment(id: 'p2', amount: 20, date: DateTime(2026, 1, 3)),
          NodePayment(id: 'p3', amount: 10, currency: 'USD', date: DateTime(2026, 1, 4)),
        ],
      );
      expect(node.paidAmount, 50);
      expect(node.remainingAmount, 50);
    });

    test('remainingAmount never negative', () {
      final node = _node(
        id: 'n1',
        parentId: 'root',
        name: 'Overpaid',
        type: FinancialTreeNodeType.expense,
        amount: 10,
        payments: [NodePayment(id: 'p1', amount: 99, date: DateTime(2026, 1, 2))],
      );
      expect(node.remainingAmount, 0);
    });

    test('json round-trip preserves data', () {
      final node = _node(
        id: 'n1',
        parentId: 'root',
        name: 'Car',
        type: FinancialTreeNodeType.asset,
        amount: 5000,
        notes: 'used',
        payments: [
          NodePayment(
            id: 'p1',
            amount: 500,
            status: NodePaymentStatus.paid,
            notes: 'down',
            date: DateTime(2026, 1, 5),
          ),
        ],
      );
      final restored = FinancialTreeNode.fromJson(node.toJson());
      expect(restored.id, node.id);
      expect(restored.parentId, 'root');
      expect(restored.name, 'Car');
      expect(restored.type, FinancialTreeNodeType.asset);
      expect(restored.amount, 5000);
      expect(restored.notes, 'used');
      expect(restored.payments.single.status, NodePaymentStatus.paid);
      expect(restored.payments.single.notes, 'down');
    });
  });

  group('computeTree', () {
    TreeCurrency currency(String target) => TreeCurrency(CurrencyEngine(), target);

    test('aggregates KPIs, distribution, paid and remaining', () {
      final root = _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000);
      final nodes = [
        root,
        _node(id: 'n1', parentId: 'root', name: 'Salary', type: FinancialTreeNodeType.income, amount: 500),
        _node(id: 'n2', parentId: 'root', name: 'Rent', type: FinancialTreeNodeType.expense, amount: 200),
        _node(id: 'n3', parentId: 'root', name: 'House', type: FinancialTreeNodeType.asset, amount: 300),
        _node(
          id: 'n4',
          parentId: 'root',
          name: 'Loan',
          type: FinancialTreeNodeType.debt,
          amount: 100,
          payments: [NodePayment(id: 'p1', amount: 40, date: DateTime(2026, 1, 2))],
        ),
        _node(
          id: 'n5',
          parentId: 'root',
          name: 'Owed',
          type: FinancialTreeNodeType.receivable,
          amount: 50,
          payments: [NodePayment(id: 'p2', amount: 20, date: DateTime(2026, 1, 3))],
        ),
      ];

      final c = computeTree(tree: _tree(), nodes: nodes, currency: currency('SAR'));

      expect(c.baseBalance, 1000);
      expect(c.allocated, 600); // مصروف 200 + أصل 300 + دَين 100 (لا دخل ولا مستحقات)
      expect(c.available, 900); // 1000 أساس + 500 دخل − 600 مخصص
      expect(c.overAllocated, isFalse);
      expect(c.totalIncome, 500);
      expect(c.totalExpenses, 200);
      expect(c.totalAssets, 300);
      expect(c.totalInvestments, 0);
      expect(c.totalSavings, 0);
      expect(c.totalReceivable, 30);
      expect(c.totalPayable, 60);
      expect(c.totalPaid, 60);
      expect(c.totalRemaining, 1090);
      expect(c.cashIn, 520); // دخل 500 + مقبوض مستحق 20
      expect(c.cashOut, 40); // دفعة الدَين المدفوعة
      expect(c.netWorth, 1170); // 900 نقد حر + 300 أصل + 30 مستحق − 60 دَين
      expect(c.distribution['income'], isNull);
      expect(c.distribution['expense'], 200);
      expect(c.distribution['asset'], 300);
      expect(c.distribution['debt'], 100);
      expect(c.chartDistribution.containsKey('root'), isFalse);
      expect(c.computedAt, isNotNull);
    });

    test('root amount wins over tree.baseAmount', () {
      final root = _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 700);
      final c = computeTree(tree: _tree(), nodes: [root], currency: currency('SAR'));
      expect(c.baseBalance, 700);
      expect(c.allocated, 0);
      expect(c.available, 700);
    });

    test('snapshot json round-trip preserves computation', () {
      final c = computeTree(tree: _tree(), nodes: const [], currency: currency('SAR'));
      final snapshot = FinancialTreeReportSnapshot(
        reportId: 'r1',
        treeId: 'tree1',
        tree: _tree(),
        nodes: const [],
        computation: c,
        createdAt: DateTime(2026, 1, 2),
      );
      final restored = FinancialTreeReportSnapshot.fromJson(snapshot.toJson());
      expect(restored.reportId, 'r1');
      expect(restored.tree.name, 'My Tree');
      expect(restored.computation.baseBalance, c.baseBalance);
      expect(restored.computation.available, c.available);
      expect(restored.computation.computedAt, isNotNull);
    });
  });

  group('FinancialEngine — سيناريو المرحلة 0 (DoD)', () {
    double identity(String from, String to, double amount) => amount;

    test('شراء سيارة من نقد مع دَين بأقساط: صافي ثروة 850K وليس 1.3M', () {
      final root = _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000000);
      final nodes = [
        root,
        _node(id: 'car', parentId: 'root', name: 'سيارة', type: FinancialTreeNodeType.asset, amount: 300000),
        _node(
          id: 'loan',
          parentId: 'root',
          name: 'دَين السيارة',
          type: FinancialTreeNodeType.debt,
          amount: 100000,
          payments: [NodePayment(id: 'i1', amount: 50000, date: DateTime(2026, 1, 2))],
        ),
      ];

      final c = FinancialEngine.computeTree(tree: _tree(), nodes: nodes, convert: identity);

      expect(c.baseBalance, 1000000);
      expect(c.allocated, 400000); // سيارة 300K + دَين 100K
      expect(c.available, 600000);
      expect(c.totalPayable, 50000); // قسط واحد متبقي من أصل 100K
      expect(c.totalPaid, 50000);
      expect(c.cashOut, 50000);
      expect(c.netWorth, 850000); // 600K نقد حر + 300K سيارة − 50K دين متبقي
      expect(c.overAllocated, isFalse);
    });

    test('تحويل داخلي لا يغيّر النقد ولا الصافي', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 't1', parentId: 'root', name: 'تحويل', type: FinancialTreeNodeType.transfer, amount: 400),
      ];
      final c = FinancialEngine.computeTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(c.allocated, 0);
      expect(c.available, 1000);
      expect(c.netWorth, 1000);
      expect(c.distribution, isEmpty);
    });

    test('مدخرات واستثمارات تزيد الصافي وتستهلك نقدًا', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 's1', parentId: 'root', name: 'ادخار', type: FinancialTreeNodeType.saving, amount: 200),
        _node(id: 'v1', parentId: 'root', name: 'أسهم', type: FinancialTreeNodeType.investment, amount: 300),
        _node(id: 'l1', parentId: 'root', name: 'التزام', type: FinancialTreeNodeType.liability, amount: 100),
      ];
      final c = FinancialEngine.computeTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(c.totalSavings, 200);
      expect(c.totalInvestments, 300);
      expect(c.totalPayable, 100);
      expect(c.allocated, 600);
      expect(c.available, 400);
      expect(c.netWorth, 400 + 200 + 300 - 100);
    });

    test('عقدة دفعة تستهلك النقد ولا تؤثر على الصافي', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 'p1', parentId: 'root', name: 'دفعة', type: FinancialTreeNodeType.payment, amount: 250),
      ];
      final c = FinancialEngine.computeTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(c.allocated, 250);
      expect(c.available, 750);
      expect(c.cashOut, 250);
      expect(c.netWorth, 750);
    });

    test('عملات متعددة تُحوَّل إلى عملة الشجرة', () {
      final root = _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000);
      final nodes = [
        root,
        _node(id: 'usd', parentId: 'root', name: 'عقار', type: FinancialTreeNodeType.asset, amount: 100, currency: 'USD'),
      ];
      final c = FinancialEngine.computeTree(
        tree: _tree(),
        nodes: nodes,
        convert: (from, to, amount) => from == to ? amount : amount * 3.75,
      );
      expect(c.totalAssets, 375);
      expect(c.allocated, 375);
      expect(c.available, 625);
      expect(c.netWorth, 1000); // شراء الأصل لا يغيّر الصافي (نقد ← أصل)
    });

    test('over-allocation: freeCash سالب و available مصفّر مع تحذير', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 100),
        _node(id: 'e1', parentId: 'root', name: 'مصروف', type: FinancialTreeNodeType.expense, amount: 80),
        _node(id: 'e2', parentId: 'root', name: 'مصروف آخر', type: FinancialTreeNodeType.expense, amount: 50),
      ];
      final c = FinancialEngine.computeTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(c.allocated, 130);
      expect(c.available, 0);
      expect(c.overAllocated, isTrue);
      expect(c.warnings.any((w) => w.contains('Over-allocation')), isTrue);
    });
  });

  group('FinancialEngine — validateTree', () {
    double identity(String from, String to, double amount) => amount;

    test('يقبل شجرة صالحة بلا مشاكل', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 'n1', parentId: 'root', name: 'أصل', type: FinancialTreeNodeType.asset, amount: 300),
      ];
      final issues = FinancialEngine.validateTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(issues, isEmpty);
    });

    test('يمنع الجذور المتعددة', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 'root2', parentId: null, name: 'Root2', type: FinancialTreeNodeType.root, amount: 500),
      ];
      final issues = FinancialEngine.validateTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(issues.any((i) => i.message.contains('أكثر من جذر')), isTrue);
    });

    test('يكشف العقد اليتيمة (بلا أب)', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 'ghost', parentId: 'missing', name: 'يتيم', type: FinancialTreeNodeType.expense, amount: 50),
      ];
      final issues = FinancialEngine.validateTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(issues.any((i) => i.message.contains('يتيم')), isTrue);
    });

    test('يكشف over-payment', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(
          id: 'e1',
          parentId: 'root',
          name: 'مصروف',
          type: FinancialTreeNodeType.expense,
          amount: 10,
          payments: [NodePayment(id: 'p1', amount: 99, date: DateTime(2026, 1, 2))],
        ),
      ];
      final issues = FinancialEngine.validateTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(issues.any((i) => i.message.contains('تتجاوز')), isTrue);
    });

    test('يكشف أبناء يتجاوزون مبلغ الأب', () {
      final nodes = [
        _node(id: 'root', parentId: null, name: 'Root', type: FinancialTreeNodeType.root, amount: 1000),
        _node(id: 'a1', parentId: 'root', name: 'تقسيم', type: FinancialTreeNodeType.asset, amount: 500),
        _node(id: 'a2', parentId: 'a1', name: 'جزء', type: FinancialTreeNodeType.expense, amount: 600),
      ];
      final issues = FinancialEngine.validateTree(tree: _tree(), nodes: nodes, convert: identity);
      expect(issues.any((i) => i.message.contains('أبناء')), isTrue);
    });
  });
}
