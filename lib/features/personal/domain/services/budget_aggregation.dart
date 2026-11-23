// ─────────────────────────────────────────────────────────────
// BudgetAggregation — the SINGLE source of truth for budget statistics.
// Reads ONLY the backend aggregation endpoint (IDs + period + dedup).
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
