import 'dart:math';

/// Generic node kinds a user can build a financial tree from.
enum FinancialTreeNodeType {
  root('root', 'fnRoot', 0xFFA01530),
  income('income', 'fnIncome', 0xFF2E7D32),
  expense('expense', 'fnExpense', 0xFFC62828),
  asset('asset', 'fnAsset', 0xFF1565C0),
  investment('investment', 'fnInvestment', 0xFF8E24AA),
  debt('debt', 'fnDebt', 0xFFE65100),
  liability('liability', 'fnLiability', 0xFFAD1457),
  transfer('transfer', 'fnTransfer', 0xFF0288D1),
  saving('saving', 'fnSaving', 0xFF00897B),
  payment('payment', 'fnPayment', 0xFF6D4C41),
  receivable('receivable', 'fnReceivable', 0xFF43A047),
  custom('custom', 'fnCustom', 0xFF9E9E9E);

  final String id;
  final String labelKey;
  final int color;
  const FinancialTreeNodeType(this.id, this.labelKey, this.color);

  static FinancialTreeNodeType fromId(String? id) =>
      values.firstWhere((t) => t.id == id, orElse: () => FinancialTreeNodeType.custom);

  static FinancialTreeNodeType fromName(String name) =>
      values.firstWhere((t) => t.name == name, orElse: () => FinancialTreeNodeType.custom);

  bool get isDebtLike => this == FinancialTreeNodeType.debt || this == FinancialTreeNodeType.liability;
  bool get isReceivableLike => this == FinancialTreeNodeType.receivable;
}

enum NodePaymentStatus {
  paid('paid', 'fnPaymentPaid'),
  pending('pending', 'fnPaymentPending'),
  overdue('overdue', 'fnPaymentOverdue');

  final String id;
  final String labelKey;
  const NodePaymentStatus(this.id, this.labelKey);

  static NodePaymentStatus fromId(String? id) =>
      values.firstWhere((s) => s.id == id, orElse: () => NodePaymentStatus.pending);
}

class NodePayment {
  final String id;
  final double amount;
  final String currency;
  final DateTime date;
  final NodePaymentStatus status;
  final String notes;

  const NodePayment({
    required this.id,
    required this.amount,
    this.currency = 'SAR',
    required this.date,
    this.status = NodePaymentStatus.paid,
    this.notes = '',
  });

  NodePayment copyWith({
    double? amount,
    String? currency,
    DateTime? date,
    NodePaymentStatus? status,
    String? notes,
  }) => NodePayment(
    id: id,
    amount: amount ?? this.amount,
    currency: currency ?? this.currency,
    date: date ?? this.date,
    status: status ?? this.status,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'currency': currency,
    'date': date.toIso8601String(),
    'status': status.id,
    'notes': notes,
  };

  factory NodePayment.fromJson(Map<String, dynamic> json) => NodePayment(
    id: json['id'] as String? ?? _newId(),
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    date: DateTime.tryParse(json['date']?.toString() ?? '') ?? DateTime.now(),
    status: NodePaymentStatus.fromId(json['status'] as String?),
    notes: json['notes'] as String? ?? '',
  );
}

class FinancialTreeNode {
  final String id;
  final String treeId;
  final String? parentId;
  final String name;
  final FinancialTreeNodeType type;
  final double amount;
  final String currency;
  final String notes;
  final List<NodePayment> payments;
  final int sortOrder;
  final bool collapsed;
  final DateTime createdAt;
  final DateTime updatedAt;

  const FinancialTreeNode({
    required this.id,
    required this.treeId,
    required this.parentId,
    required this.name,
    required this.type,
    this.amount = 0,
    this.currency = 'SAR',
    this.notes = '',
    this.payments = const [],
    this.sortOrder = 0,
    this.collapsed = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isRoot => parentId == null;

  double get paidAmount {
    double sum = 0;
    for (final p in payments) {
      if (p.currency == currency) sum += p.amount;
    }
    return sum;
  }

  double get remainingAmount => (amount - paidAmount).clamp(0, double.infinity);

  FinancialTreeNode copyWith({
    String? parentId,
    String? name,
    FinancialTreeNodeType? type,
    double? amount,
    String? currency,
    String? notes,
    List<NodePayment>? payments,
    int? sortOrder,
    bool? collapsed,
    DateTime? updatedAt,
  }) => FinancialTreeNode(
    id: id,
    treeId: treeId,
    parentId: parentId ?? this.parentId,
    name: name ?? this.name,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    currency: currency ?? this.currency,
    notes: notes ?? this.notes,
    payments: payments ?? this.payments,
    sortOrder: sortOrder ?? this.sortOrder,
    collapsed: collapsed ?? this.collapsed,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'treeId': treeId,
    if (parentId != null) 'parentId': parentId,
    'name': name,
    'type': type.id,
    'amount': amount,
    'currency': currency,
    'notes': notes,
    'payments': payments.map((p) => p.toJson()).toList(),
    'sortOrder': sortOrder,
    'collapsed': collapsed,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory FinancialTreeNode.fromJson(Map<String, dynamic> json) => FinancialTreeNode(
    id: json['id'] as String? ?? _newId(),
    treeId: json['treeId'] as String? ?? '',
    parentId: json['parentId'] as String?,
    name: json['name'] as String? ?? '',
    type: FinancialTreeNodeType.fromId(json['type'] as String?),
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    notes: json['notes'] as String? ?? '',
    payments: (json['payments'] as List<dynamic>? ?? [])
        .map((e) => NodePayment.fromJson(e as Map<String, dynamic>))
        .toList(),
    sortOrder: json['sortOrder'] as int? ?? 0,
    collapsed: json['collapsed'] as bool? ?? false,
    createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
  );
}

class FinancialTree {
  final String id;
  final String name;
  final String clientName;
  final double baseAmount;
  final String currency;
  final String notes;
  final String rootNodeId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const FinancialTree({
    required this.id,
    required this.name,
    this.clientName = '',
    this.baseAmount = 0,
    this.currency = 'SAR',
    this.notes = '',
    required this.rootNodeId,
    required this.createdAt,
    required this.updatedAt,
  });

  FinancialTree copyWith({
    String? name,
    String? clientName,
    double? baseAmount,
    String? currency,
    String? notes,
    DateTime? updatedAt,
  }) => FinancialTree(
    id: id,
    name: name ?? this.name,
    clientName: clientName ?? this.clientName,
    baseAmount: baseAmount ?? this.baseAmount,
    currency: currency ?? this.currency,
    notes: notes ?? this.notes,
    rootNodeId: rootNodeId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'clientName': clientName,
    'baseAmount': baseAmount,
    'currency': currency,
    'notes': notes,
    'rootNodeId': rootNodeId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory FinancialTree.fromJson(Map<String, dynamic> json) => FinancialTree(
    id: json['id'] as String? ?? _newId(),
    name: json['name'] as String? ?? '',
    clientName: json['clientName'] as String? ?? '',
    baseAmount: (json['baseAmount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    notes: json['notes'] as String? ?? '',
    rootNodeId: json['rootNodeId'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
  );
}

/// Immutable snapshot of a tree at export time so saved reports never change.
class FinancialTreeReportSnapshot {
  final String reportId;
  final String treeId;
  final FinancialTree tree;
  final List<FinancialTreeNode> nodes;
  final TreeComputation computation;
  final DateTime createdAt;

  const FinancialTreeReportSnapshot({
    required this.reportId,
    required this.treeId,
    required this.tree,
    required this.nodes,
    required this.computation,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'reportId': reportId,
    'treeId': treeId,
    'tree': tree.toJson(),
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'computation': computation.toJson(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory FinancialTreeReportSnapshot.fromJson(Map<String, dynamic> json) =>
      FinancialTreeReportSnapshot(
        reportId: json['reportId'] as String? ?? '',
        treeId: json['treeId'] as String? ?? '',
        tree: FinancialTree.fromJson(json['tree'] as Map<String, dynamic>),
        nodes: (json['nodes'] as List<dynamic>? ?? [])
            .map((e) => FinancialTreeNode.fromJson(e as Map<String, dynamic>))
            .toList(),
        computation: TreeComputation.fromJson(json['computation'] as Map<String, dynamic>),
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      );
}

/// Aggregated live results computed from the tree structure.
class TreeComputation {
  final double baseBalance;
  final double allocated;
  final double available;
  final double totalAssets;
  final double totalIncome;
  final double totalExpenses;
  final double totalInvestments;
  final double totalSavings;
  final double totalReceivable;
  final double totalPayable;
  final double netWorth;
  final double totalPaid;
  final double totalRemaining;
  final double cashIn;
  final double cashOut;
  final bool overAllocated;
  final List<String> warnings;
  final Map<String, double> distribution;
  final DateTime? computedAt;

  const TreeComputation({
    required this.baseBalance,
    required this.allocated,
    required this.available,
    required this.totalAssets,
    required this.totalIncome,
    required this.totalExpenses,
    required this.totalInvestments,
    this.totalSavings = 0,
    required this.totalReceivable,
    required this.totalPayable,
    required this.netWorth,
    required this.totalPaid,
    required this.totalRemaining,
    this.cashIn = 0,
    this.cashOut = 0,
    this.overAllocated = false,
    this.warnings = const [],
    required this.distribution,
    required this.computedAt,
  });

  Map<String, double> get chartDistribution =>
      Map.fromEntries(distribution.entries.where((e) => e.key != 'root' && e.value > 0));

  Map<String, dynamic> toJson() => {
    'baseBalance': baseBalance,
    'allocated': allocated,
    'available': available,
    'totalAssets': totalAssets,
    'totalIncome': totalIncome,
    'totalExpenses': totalExpenses,
    'totalInvestments': totalInvestments,
    'totalSavings': totalSavings,
    'totalReceivable': totalReceivable,
    'totalPayable': totalPayable,
    'netWorth': netWorth,
    'totalPaid': totalPaid,
    'totalRemaining': totalRemaining,
    'cashIn': cashIn,
    'cashOut': cashOut,
    'overAllocated': overAllocated,
    'warnings': warnings,
    'distribution': distribution,
    if (computedAt != null) 'computedAt': computedAt!.toIso8601String(),
  };

  factory TreeComputation.fromJson(Map<String, dynamic> json) => TreeComputation(
    baseBalance: (json['baseBalance'] as num?)?.toDouble() ?? 0,
    allocated: (json['allocated'] as num?)?.toDouble() ?? 0,
    available: (json['available'] as num?)?.toDouble() ?? 0,
    totalAssets: (json['totalAssets'] as num?)?.toDouble() ?? 0,
    totalIncome: (json['totalIncome'] as num?)?.toDouble() ?? 0,
    totalExpenses: (json['totalExpenses'] as num?)?.toDouble() ?? 0,
    totalInvestments: (json['totalInvestments'] as num?)?.toDouble() ?? 0,
    totalSavings: (json['totalSavings'] as num?)?.toDouble() ?? 0,
    totalReceivable: (json['totalReceivable'] as num?)?.toDouble() ?? 0,
    totalPayable: (json['totalPayable'] as num?)?.toDouble() ?? 0,
    netWorth: (json['netWorth'] as num?)?.toDouble() ?? 0,
    totalPaid: (json['totalPaid'] as num?)?.toDouble() ?? 0,
    totalRemaining: (json['totalRemaining'] as num?)?.toDouble() ?? 0,
    cashIn: (json['cashIn'] as num?)?.toDouble() ?? 0,
    cashOut: (json['cashOut'] as num?)?.toDouble() ?? 0,
    overAllocated: json['overAllocated'] as bool? ?? false,
    warnings: (json['warnings'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    distribution: (json['distribution'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, (v as num?)?.toDouble() ?? 0)),
    computedAt: DateTime.tryParse(json['computedAt']?.toString() ?? '') ?? DateTime.now(),
  );
}

String _newId() {
  final r = Random();
  return '${DateTime.now().microsecondsSinceEpoch}_${r.nextInt(1 << 32)}';
}

String newNodeId() => _newId();
