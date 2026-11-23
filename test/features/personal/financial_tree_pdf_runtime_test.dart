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
  String notes = '',
  List<NodePayment> payments = const [],
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
      notes: notes,
      payments: payments,
      sortOrder: sortOrder,
      createdAt: DateTime(2026, 8, 1),
      updatedAt: DateTime(2026, 8, 10),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tree = FinancialTree(
    id: 'tree1',
    name: 'الثروة الشخصية',
    clientName: 'أحمد العتيبي',
    baseAmount: 1000000,
    currency: 'SAR',
    rootNodeId: 'root',
    createdAt: DateTime(2026, 8, 1),
    updatedAt: DateTime(2026, 8, 10),
  );

  final nodes = [
    _n(id: 'root', parentId: null, name: 'الثروة الشخصية', type: FinancialTreeNodeType.root, amount: 1000000),
    _n(
      id: 'car',
      parentId: 'root',
      name: 'سيارة',
      type: FinancialTreeNodeType.asset,
      amount: 150000,
      notes: 'Toyota Land Cruiser\nشراء من المعرض',
      sortOrder: 0,
      payments: [
        NodePayment(id: 'p1', amount: 50000, date: DateTime(2026, 8, 2), status: NodePaymentStatus.paid, notes: 'دفعة أولى'),
        NodePayment(id: 'p2', amount: 50000, date: DateTime(2026, 8, 5), status: NodePaymentStatus.paid),
        NodePayment(id: 'p3', amount: 25000, date: DateTime(2026, 8, 8), status: NodePaymentStatus.pending),
      ],
    ),
    _n(id: 'house', parentId: 'root', name: 'منزل', type: FinancialTreeNodeType.asset, amount: 100000, sortOrder: 1),
    _n(id: 'inv', parentId: 'root', name: 'استثمار', type: FinancialTreeNodeType.investment, amount: 50000, currency: 'USD', notes: 'محفظة أسهم', sortOrder: 2),
    _n(
      id: 'car_loan',
      parentId: 'car',
      name: 'قرض السيارة',
      type: FinancialTreeNodeType.debt,
      amount: 60000,
      sortOrder: 0,
    ),
  ];

  final computations = <TreeComputation>{};
  TreeComputation compute(List<FinancialTreeNode> ns) {
    return TreeComputation(
      baseBalance: 1000000,
      allocated: ns.fold<double>(0, (s, n) => n.isRoot ? s : s + n.amount),
      available: 1000000,
      totalAssets: 250000,
      totalIncome: 0,
      totalExpenses: 0,
      totalInvestments: 50000,
      totalReceivable: 0,
      totalPayable: 60000,
      netWorth: 1190000,
      totalPaid: 100000,
      totalRemaining: 50000,
      distribution: const {'asset': 250000.0, 'investment': 50000.0, 'debt': 60000.0},
      computedAt: DateTime(2026, 8, 10, 12),
    );
  }

  final snapshot = FinancialTreeReportSnapshot(
    reportId: 'r1',
    treeId: 'tree1',
    tree: tree,
    nodes: nodes,
    computation: compute(nodes),
    createdAt: DateTime(2026, 8, 10, 13),
  );
  computations.add(snapshot.computation);

  testWidgets('generates a real RTL PDF with embedded Cairo fonts', (tester) async {
    final translations = <String, String>{
      'clientName': 'العميل',
      'reportCreatedOn': 'تاريخ الإنشاء',
      'summary': 'الملخص',
      'distributionChart': 'التوزيع حسب النوع',
      'treeSection': 'الشجرة المالية',
      'changelogSection': 'سجل التغييرات',
      'createdAt': 'تاريخ الإنشاء',
      'updatedAt': 'آخر تحديث',
      'nodesCount': 'عدد العقد',
      'paymentsCount': 'عدد الدفعات',
      'exportedOn': 'تم التصدير',
      'paidLabel': 'المسدد',
      'remainingLabel': 'المتبقي',
      'paymentLabel': 'دفعة',
      'noteLabel': 'ملاحظة',
      'totalAssets': 'إجمالي الأصول',
      'totalIncome': 'إجمالي الدخل',
      'totalExpenses': 'إجمالي المصروفات',
      'totalInvestments': 'إجمالي الاستثمارات',
      'totalReceivable': 'ديون لي',
      'totalPayable': 'ديون مستحقة',
      'totalPaidLabel': 'إجمالي المدفوع',
      'totalRemainingLabel': 'إجمالي المتبقي',
      'availableBalance': 'الرصيد المتاح',
      'netWorth': 'صافي الثروة',
      'fnRoot': 'أساسي',
      'fnIncome': 'دخل',
      'fnExpense': 'مصروف',
      'fnAsset': 'أصل',
      'fnInvestment': 'استثمار',
      'fnDebt': 'دين',
      'fnLiability': 'التزام',
      'fnTransfer': 'تحويل',
      'fnSaving': 'ادخار',
      'fnPayment': 'دفعة',
      'fnReceivable': 'مستحق لي',
      'fnCustom': 'مخصص',
      'fnPaymentPaid': 'مسدد',
      'fnPaymentPending': 'معلق',
      'fnPaymentOverdue': 'متأخر',
    };

    final preset = const ReceiptDesignPreset(sectionId: 'report')
        .copyWith(primaryColor: const Color(0xFFA01530), footerText: 'FYONA ERP')
        .copyWith(showBrandLogo: false);

    final bytes = await FinancialTreeReportPdfGenerator.generate(
      snapshot: snapshot,
      preset: preset,
      translations: translations,
      reportTitle: 'تقرير الشجرة الحسابية',
      periodLabel: 'الفترة: أغسطس 2026',
      showTree: true,
      showKpis: true,
      showCharts: true,
      showPayments: true,
      showNotes: true,
      showChangelog: true,
      landscape: false,
    );

    expect(bytes, isA<Uint8List>());
    expect(bytes.length, greaterThan(5000), reason: 'PDF should have meaningful size');

    final header = String.fromCharCodes(bytes.sublist(0, 8));
    expect(header, startsWith('%PDF'));

    final body = String.fromCharCodes(bytes);
    expect(body, contains('/FontFile'), reason: 'Cairo TTF should be embedded');
    expect(body, contains('/Type/Catalog'));
    expect(body, contains('/Type/Page'));

    // Write the real file for further inspection.
    final outDir = Directory(
      '${Directory.systemTemp.path}/fyona_qa',
    );
    outDir.createSync(recursive: true);
    final out = File('${outDir.path}/financial_tree_report.pdf');
    out.writeAsBytesSync(bytes);
    // ignore: avoid_print
    print('PDF bytes=${bytes.length} written to ${out.path}');
  });
}
