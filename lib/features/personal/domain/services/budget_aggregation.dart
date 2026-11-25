// ─────────────────────────────────────────────────────────────
// BudgetAggregation — the SINGLE source of truth for budget statistics.
// Computed on the device from the Personal ledger by
// [computeBudgetAggregation], a port of the server's
// GET /personal/finance/budgets/{id}/aggregation (IDs + period + dedup).
// No name matching anywhere. Currency conversion is delegated to the
// existing CurrencyEngine and is never reimplemented here.
// ─────────────────────────────────────────────────────────────
import '../../data/models/personal_models.dart';

/// Local budget membership — mirrors the budget rule so the budget list,
/// the budget detail, and the server always count the SAME operations
/// (one true number, online and offline):
/// - tx.budget_id == budget, OR
/// - tx.budget_category_id is a manually-added category of this budget.
///
/// (Debt/goal links are NOT counted: that linking was removed — budgets
/// carry only user-added categories, or none at all.)
bool budgetTxBelongs({
  required PersonalTransaction t,
  required String budgetId,
  required Set<String> categoryIds,
}) {
  if ((t.budgetId ?? '') == budgetId) return true;
  final bc = t.budgetCategoryId;
  if (bc != null && bc.isNotEmpty && categoryIds.contains(bc)) return true;
  return false;
}

class BudgetCategoryStat {
  final String categoryId;
  final String budgetId;
  final String name;
  final String type;
  final double allocated;
  final double used;
  final double remaining;
  final String currency;
  final String? goalId;
  final String? debtId;

  const BudgetCategoryStat({
    required this.categoryId,
    required this.budgetId,
    required this.name,
    required this.type,
    required this.allocated,
    required this.used,
    required this.remaining,
    required this.currency,
    this.goalId,
    this.debtId,
  });

  factory BudgetCategoryStat.fromJson(Map<String, dynamic> json) => BudgetCategoryStat(
    categoryId: json['id']?.toString() ?? '',
    budgetId: json['budget_id']?.toString() ?? '',
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'expense',
    allocated: (json['allocated_amount'] as num?)?.toDouble() ?? 0,
    used: (json['used'] as num?)?.toDouble() ?? 0,
    remaining: (json['remaining'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    goalId: json['goal_id']?.toString(),
    debtId: json['debt_id']?.toString(),
  );
}

class BudgetGoalStat {
  final String goalId;
  final String name;
  final double target;
  final double current;
  final double contributedInPeriod;
  final String currency;
  final String? budgetId;

  const BudgetGoalStat({
    required this.goalId,
    required this.name,
    required this.target,
    required this.current,
    required this.contributedInPeriod,
    required this.currency,
    this.budgetId,
  });

  factory BudgetGoalStat.fromJson(Map<String, dynamic> json) => BudgetGoalStat(
    goalId: json['id']?.toString() ?? '',
    name: json['name'] as String? ?? '',
    target: (json['target_amount'] as num?)?.toDouble() ?? 0,
    current: (json['current_amount'] as num?)?.toDouble() ?? 0,
    contributedInPeriod: (json['contributed_in_period'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    budgetId: json['budget_id']?.toString(),
  );
}

class BudgetDebtStat {
  final String debtId;
  final String personName;
  final double amount;
  final double paidInPeriod;
  final String currency;
  final String? budgetId;

  const BudgetDebtStat({
    required this.debtId,
    required this.personName,
    required this.amount,
    required this.paidInPeriod,
    required this.currency,
    this.budgetId,
  });

  factory BudgetDebtStat.fromJson(Map<String, dynamic> json) => BudgetDebtStat(
    debtId: json['id']?.toString() ?? '',
    personName: json['person_name'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    paidInPeriod: (json['paid_in_period'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    budgetId: json['budget_id']?.toString(),
  );
}

/// Result of GET /personal/finance/budgets/{id}/aggregation.
class BudgetAggregation {
  final PersonalBudget budget;
  final double totalAmount;
  final double totalUsed;
  final double remaining;
  final double progress;
  final String currency;
  final List<BudgetCategoryStat> categories;
  final List<BudgetGoalStat> goals;
  final List<BudgetDebtStat> debts;
  final List<PersonalTransaction> operations;

  const BudgetAggregation({
    required this.budget,
    required this.totalAmount,
    required this.totalUsed,
    required this.remaining,
    required this.progress,
    required this.currency,
    required this.categories,
    required this.goals,
    required this.debts,
    required this.operations,
  });

  int get operationsCount => operations.length;

  factory BudgetAggregation.fromJson(Map<String, dynamic> json) {
    final budgetJson = json['budget'];
    final budget = budgetJson is Map
        ? PersonalBudget.fromServer(Map<String, dynamic>.from(budgetJson))
        : PersonalBudget(id: '', name: '');
    List<BudgetCategoryStat> cats = [];
    if (json['categories'] is List) {
      cats = (json['categories'] as List)
          .whereType<Map>()
          .map((e) => BudgetCategoryStat.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    List<BudgetGoalStat> goals = [];
    if (json['goals'] is List) {
      goals = (json['goals'] as List)
          .whereType<Map>()
          .map((e) => BudgetGoalStat.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    List<BudgetDebtStat> debts = [];
    if (json['debts'] is List) {
      debts = (json['debts'] as List)
          .whereType<Map>()
          .map((e) => BudgetDebtStat.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    List<PersonalTransaction> ops = [];
    if (json['operations'] is List) {
      ops = (json['operations'] as List)
          .whereType<Map>()
          .map((e) => PersonalTransaction.fromServer(Map<String, dynamic>.from(e)))
          .toList();
    }
    return BudgetAggregation(
      budget: budget,
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0,
      totalUsed: (json['total_used'] as num?)?.toDouble() ?? 0,
      remaining: (json['remaining'] as num?)?.toDouble() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      currency: json['currency'] as String? ?? budget.currency,
      categories: cats,
      goals: goals,
      debts: debts,
      operations: ops,
    );
  }
}

double? _aggNum(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// Python's `round(x, n)` for the values the server returns.
double _aggRound(double v, int digits) => double.parse(v.toStringAsFixed(digits));

/// Server datetimes without a zone are UTC (Python compares them as UTC).
DateTime? _aggDate(Object? v) {
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  final zoned = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s);
  final hasTime = s.contains('T') || s.contains(' ');
  return DateTime.tryParse(zoned ? s : (hasTime ? '${s}Z' : '${s}T00:00:00Z'));
}

String? _aggId(Object? v) {
  final s = v?.toString() ?? '';
  return s.isEmpty ? null : s;
}

/// The server's budget aggregation, on device rows (same JSON shape, read by
/// [BudgetAggregation.fromJson]). Rules (IDs only, no name matching):
/// - an expense belongs to the budget iff tx.budget_id == budget, or its
///   goal / debt is linked to the budget;
/// - category used += amount iff tx.budget_category_id == category;
/// - only operations inside [start_date, end_date] (open ends unbounded),
///   newest first, each transaction counted once.
Map<String, dynamic> computeBudgetAggregation({
  required Map<String, dynamic> budget,
  required List<Map<String, dynamic>> transactions,
  required List<Map<String, dynamic>> goals,
  required List<Map<String, dynamic>> debts,
}) {
  final budgetId = '${budget['id']}';
  final currency = budget['currency']?.toString() ?? 'SAR';
  bool live(Map<String, dynamic> r) => r['is_deleted'] != true;
  final cats = [
    for (final c in budget['categories'] as List? ?? const [])
      if (c is Map && _aggId(c['id']) != null) Map<String, dynamic>.from(c),
  ];
  final linkedGoals = [
    for (final g in goals)
      if (live(g) && _aggId(g['budget_id']) == budgetId) g,
  ];
  final linkedDebts = [
    for (final d in debts)
      if (live(d) && _aggId(d['budget_id']) == budgetId) d,
  ];
  final goalIds = {for (final g in linkedGoals) '${g['id']}'};
  final debtIds = {for (final d in linkedDebts) '${d['id']}'};
  final catIds = {for (final c in cats) '${c['id']}'};
  final start = _aggDate(budget['start_date']);
  final end = _aggDate(budget['end_date']);

  final txs = [
    for (final t in transactions)
      if (live(t) &&
          (t['tx_type'] ?? t['type'])?.toString() == 'expense' &&
          (_aggId(t['budget_id']) == budgetId ||
              goalIds.contains(_aggId(t['goal_id'])) ||
              debtIds.contains(_aggId(t['debt_id']))))
        t,
  ];
  // ORDER BY date DESC (rows without a date last; they never count).
  txs.sort((a, b) {
    final da = _aggDate(a['date']), db = _aggDate(b['date']);
    if (da == null || db == null) return da == null ? (db == null ? 0 : 1) : -1;
    return db.compareTo(da);
  });

  final seen = <String>{};
  final catUsed = {for (final id in catIds) id: 0.0};
  final goalUsed = {for (final id in goalIds) id: 0.0};
  final debtUsed = {for (final id in debtIds) id: 0.0};
  final operations = <Map<String, dynamic>>[];
  var totalUsed = 0.0;
  for (final t in txs) {
    final tid = '${t['id']}';
    if (seen.contains(tid)) continue;
    final d = _aggDate(t['date']);
    if (d == null) continue;
    if (start != null && d.isBefore(start)) continue;
    if (end != null && d.isAfter(end)) continue;
    seen.add(tid);
    final amount = _aggNum(t['amount']) ?? 0;
    totalUsed += amount;
    operations.add(t);
    final cat = _aggId(t['budget_category_id']);
    if (cat != null && catIds.contains(cat)) catUsed[cat] = catUsed[cat]! + amount;
    final goal = _aggId(t['goal_id']);
    if (goal != null && goalIds.contains(goal)) goalUsed[goal] = goalUsed[goal]! + amount;
    final debt = _aggId(t['debt_id']);
    if (debt != null && debtIds.contains(debt)) debtUsed[debt] = debtUsed[debt]! + amount;
  }
  double nonZero(Object? v) {
    final n = _aggNum(v) ?? 0;
    return n;
  }

  final totalAmount = nonZero(budget['total_amount']) != 0
      ? nonZero(budget['total_amount'])
      : nonZero(budget['amount']);
  return {
    'budget': budget,
    'total_amount': totalAmount,
    'total_used': _aggRound(totalUsed, 2),
    'remaining': _aggRound(totalAmount - totalUsed, 2),
    'progress': _aggRound(totalAmount > 0 ? totalUsed / totalAmount : 0, 4),
    'currency': currency,
    'categories': [
      for (final c in cats)
        {
          'id': '${c['id']}',
          'budget_id': _aggId(c['budget_id']) ?? budgetId,
          'name': c['name'],
          'type': c['type'] ?? 'expense',
          'allocated_amount': _aggNum(c['allocated_amount']) ?? 0.0,
          'used': _aggRound(catUsed['${c['id']}'] ?? 0, 2),
          'remaining': _aggRound(
            (_aggNum(c['allocated_amount']) ?? 0) - (catUsed['${c['id']}'] ?? 0),
            2,
          ),
          'currency': (c['currency']?.toString().isNotEmpty ?? false)
              ? c['currency']
              : currency,
          'goal_id': _aggId(c['goal_id']),
          'debt_id': _aggId(c['debt_id']),
        },
    ],
    'goals': [
      for (final g in linkedGoals)
        {
          'id': '${g['id']}',
          'name': g['name'],
          'target_amount': _aggNum(g['target_amount']) ?? 0.0,
          'current_amount': _aggNum(g['current_amount']) ?? 0.0,
          'contributed_in_period': _aggRound(goalUsed['${g['id']}'] ?? 0, 2),
          'currency': g['currency'],
          'budget_id': _aggId(g['budget_id']),
        },
    ],
    'debts': [
      for (final d in linkedDebts)
        {
          'id': '${d['id']}',
          'person_name': d['person_name'],
          'amount': _aggNum(d['amount']) ?? 0.0,
          'paid_in_period': _aggRound(debtUsed['${d['id']}'] ?? 0, 2),
          'currency': d['currency'],
          'budget_id': _aggId(d['budget_id']),
        },
    ],
    'operations': operations,
    'operations_count': operations.length,
  };
}
