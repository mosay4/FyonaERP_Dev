import 'dart:math' as math;

import '../../../data/models/personal_models.dart';

/// Converts [amount] from [from] into the report currency, or `null` when no
/// approved rate is saved on this device for that pair.
typedef PersonalReportRate = double? Function(String from, String to);

/// The report kinds offered in Personal › التقارير.
const personalReportKinds = [
  'overview',
  'cashflow',
  'categories',
  'budgets',
  'goals',
  'debts',
  'banks',
];

/// Inclusive date window of a report period (same choices as Business).
class PersonalReportWindow {
  const PersonalReportWindow(this.period, this.from, this.to);
  final String period;
  final DateTime from; // start of the first day
  final DateTime to; // end of the last day (exclusive bound)

  int get days => math.max(1, to.difference(from).inHours ~/ 24);

  bool contains(DateTime d) => !d.isBefore(from) && d.isBefore(to);

  /// The equal-length window just before this one (for «vs previous»).
  PersonalReportWindow get previous {
    final length = to.difference(from);
    return PersonalReportWindow('previous', from.subtract(length), from);
  }

  static PersonalReportWindow of(
    String period, {
    DateTime? now,
    DateTime? customFrom,
    DateTime? customTo,
  }) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final tomorrow = DateTime(n.year, n.month, n.day + 1);
    switch (period) {
      case 'today':
        return PersonalReportWindow(period, today, tomorrow);
      case 'week':
        return PersonalReportWindow(
          period,
          DateTime(n.year, n.month, n.day - 6),
          tomorrow,
        );
      case 'year':
        return PersonalReportWindow(period, DateTime(n.year), tomorrow);
      case 'custom':
        final f = customFrom ?? today.subtract(const Duration(days: 29));
        final t = customTo ?? today;
        return PersonalReportWindow(
          period,
          DateTime(f.year, f.month, f.day),
          DateTime(t.year, t.month, t.day + 1),
        );
      case 'month':
      default:
        return PersonalReportWindow(
          'month',
          DateTime(n.year, n.month),
          tomorrow,
        );
    }
  }
}

class PersonalReportSlice {
  const PersonalReportSlice(this.label, this.amount, this.count);
  final String label;
  final double amount;
  final int count;
}

class PersonalReportBucket {
  const PersonalReportBucket(this.start, this.income, this.spending);
  final DateTime start;
  final double income;
  final double spending;
}

class PersonalReportOperation {
  const PersonalReportOperation({
    required this.date,
    required this.category,
    required this.description,
    required this.amount,
    required this.originalAmount,
    required this.originalCurrency,
  });
  final DateTime date;
  final String category;
  final String description;
  final double amount; // in the report currency
  final double originalAmount;
  final String originalCurrency;
}

class PersonalReportBank {
  const PersonalReportBank({
    required this.name,
    required this.currency,
    required this.balance,
    required this.converted,
    required this.accountType,
  });
  final String name;
  final String currency;
  final double balance; // as recorded
  final double? converted; // null = no rate
  final String accountType;
}

class PersonalReportGoal {
  const PersonalReportGoal({
    required this.name,
    required this.saved,
    required this.target,
    required this.deadline,
    required this.completed,
    required this.currency,
  });
  final String name;
  final double saved;
  final double target;
  final String? deadline;
  final bool completed;
  final String currency; // original currency of the goal
  double get progress => target > 0 ? (saved / target).clamp(0.0, 1.0) : 0;
  double get remaining => math.max(0, target - saved);
}

class PersonalReportBudget {
  const PersonalReportBudget({
    required this.name,
    required this.spent,
    required this.total,
    required this.period,
    required this.daysLeft,
    required this.currency,
  });
  final String name;
  final double spent;
  final double total;
  final String period;
  final int daysLeft;
  final String currency;
  double get usage => total > 0 ? spent / total : 0;
  bool get over => spent > total && total > 0;
  double get remaining => math.max(0, total - spent);
}

class PersonalReportDebt {
  const PersonalReportDebt({
    required this.person,
    required this.owedToMe,
    required this.remaining,
    required this.total,
    required this.dueDate,
    required this.overdue,
    required this.currency,
  });
  final String person;
  final bool owedToMe;
  final double remaining;
  final double total;
  final DateTime? dueDate;
  final bool overdue;
  final String currency;
  double get progress =>
      total > 0 ? ((total - remaining) / total).clamp(0.0, 1.0) : 0;
}

/// Everything the Personal reports show, valued in ONE currency.
///
/// Like the Business reports, every amount — each operation, balance, goal,
/// budget and debt — is converted into [currency] before it is added, so a
/// currency switch changes the whole report (cards, charts, lists and the
/// PDF built from the same object). Amounts with no approved rate on the
/// device are never mixed in: they are left out of every total and counted
/// in [unconverted] so the report says so.
class PersonalReportData {
  PersonalReportData._({
    required this.currency,
    required this.window,
    required this.income,
    required this.spending,
    required this.toGoals,
    required this.transfers,
    required this.prevIncome,
    required this.prevSpending,
    required this.operations,
    required this.categories,
    required this.incomeSources,
    required this.buckets,
    required this.months,
    required this.topExpenses,
    required this.banks,
    required this.goals,
    required this.budgets,
    required this.debts,
    required this.unconverted,
  });

  final String currency;
  final PersonalReportWindow window;
  final double income, spending, toGoals;
  final int transfers;
  final double prevIncome, prevSpending;
  final int operations;
  final List<PersonalReportSlice> categories;
  final List<PersonalReportSlice> incomeSources;
  final List<PersonalReportBucket> buckets;
  final List<PersonalReportBucket> months;
  final List<PersonalReportOperation> topExpenses;
  final List<PersonalReportBank> banks;
  final List<PersonalReportGoal> goals;
  final List<PersonalReportBudget> budgets;
  final List<PersonalReportDebt> debts;

  /// Original currency → number of amounts that could not be converted.
  final Map<String, int> unconverted;

  double get net => income - spending - toGoals;
  double get savingsRate =>
      income > 0 ? ((income - spending) / income).clamp(-9.99, 1.0) : 0;
  double get dailySpending => spending / window.days;
  double get balances => banks.fold(0.0, (s, b) => s + (b.converted ?? 0));
  double get owedToMe =>
      debts.where((d) => d.owedToMe).fold(0.0, (s, d) => s + d.remaining);
  double get iOwe =>
      debts.where((d) => !d.owedToMe).fold(0.0, (s, d) => s + d.remaining);
  int get overdueDebts => debts.where((d) => d.overdue).length;
  double get netWorth => balances + owedToMe - iOwe;
  double get goalsSaved => goals.fold(0.0, (s, g) => s + g.saved);
  double get goalsTarget => goals.fold(0.0, (s, g) => s + g.target);
  double get budgetsSpent => budgets.fold(0.0, (s, b) => s + b.spent);
  double get budgetsTotal => budgets.fold(0.0, (s, b) => s + b.total);
  int get unconvertedCount => unconverted.values.fold(0, (s, n) => s + n);
  bool get isEmpty =>
      operations == 0 &&
      banks.isEmpty &&
      goals.isEmpty &&
      budgets.isEmpty &&
      debts.isEmpty;

  /// Change against the previous equal period, as a fraction (null = n/a).
  static double? change(double now, double before) =>
      before.abs() < 0.005 ? null : (now - before) / before.abs();

  /// Bank balances per original currency, valued in the report currency.
  List<PersonalReportSlice> get balancesByCurrency {
    final m = <String, (double, int)>{};
    for (final b in banks) {
      if (b.converted == null) continue;
      final cur = m[b.currency] ?? (0.0, 0);
      m[b.currency] = (cur.$1 + b.converted!, cur.$2 + 1);
    }
    final out = [
      for (final e in m.entries)
        PersonalReportSlice(e.key, e.value.$1, e.value.$2),
    ]..sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  static bool isTransfer(PersonalTransaction t) {
    final c = t.category.trim().toLowerCase();
    return t.type == 'transfer_in' ||
        t.type == 'transfer_out' ||
        c == 'تحويل' ||
        c == 'transfer';
  }

  static PersonalReportData build({
    required String currency,
    required PersonalReportWindow window,
    required PersonalReportRate rate,
    required List<PersonalTransaction> transactions,
    List<PersonalBankAccount> banks = const [],
    List<SavingsGoal> goals = const [],
    List<PersonalBudget> budgets = const [],
    List<PersonalDebt> debts = const [],
    String otherLabel = 'Other',
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final target = currency.trim().toUpperCase();
    final missing = <String, int>{};
    final rates = <String, double?>{};

    double? cv(double amount, String from, {bool count = true}) {
      final code = from.trim().toUpperCase();
      if (code.isEmpty || code == target) return amount;
      final r = rates.putIfAbsent(code, () => rate(code, target));
      if (r == null || !r.isFinite) {
        if (count) missing[code] = (missing[code] ?? 0) + 1;
        return null;
      }
      return amount * r;
    }

    // ── operations in the window (and the previous one, for comparison)
    final prev = window.previous;
    var income = 0.0, spending = 0.0, toGoals = 0.0;
    var prevIncome = 0.0, prevSpending = 0.0;
    var transfers = 0, operations = 0;
    final cats = <String, (double, int)>{};
    final sources = <String, (double, int)>{};
    final expenses = <PersonalReportOperation>[];

    // Trend buckets over the window: days up to 31 days, weeks up to ~3
    // months, then months.
    final days = window.days;
    final unit = days <= 31 ? 'day' : (days <= 98 ? 'week' : 'month');
    DateTime bucketOf(DateTime d) {
      switch (unit) {
        case 'day':
          return DateTime(d.year, d.month, d.day);
        case 'week':
          final i = d.difference(window.from).inDays ~/ 7;
          final s = window.from.add(Duration(days: i * 7));
          return DateTime(s.year, s.month, s.day);
        default:
          return DateTime(d.year, d.month);
      }
    }

    final bucketMap = <DateTime, List<double>>{};
    var cursor = bucketOf(window.from);
    while (cursor.isBefore(window.to)) {
      bucketMap[cursor] = [0, 0];
      cursor = switch (unit) {
        'day' => DateTime(cursor.year, cursor.month, cursor.day + 1),
        'week' => DateTime(cursor.year, cursor.month, cursor.day + 7),
        _ => DateTime(cursor.year, cursor.month + 1),
      };
    }

    // Six calendar months ending with the current one (independent trend).
    final monthMap = <DateTime, List<double>>{
      for (var i = 5; i >= 0; i--)
        DateTime(today.year, today.month - i): [0, 0],
    };
    final firstMonth = monthMap.keys.first;
    final monthEnd = DateTime(today.year, today.month + 1);

    for (final t in transactions) {
      final date = t.date;
      if (date == null) continue;
      if (t.type != 'income' && t.type != 'expense' && !isTransfer(t)) {
        continue;
      }
      final inWindow = window.contains(date);
      final inPrev = prev.contains(date);
      final inMonths = !date.isBefore(firstMonth) && date.isBefore(monthEnd);
      if (!inWindow && !inPrev && !inMonths) continue;
      if (isTransfer(t)) {
        if (inWindow && t.type != 'income') transfers++;
        continue;
      }
      final value = cv(t.amount, t.currency, count: inWindow);
      if (value == null) continue;
      final isIncome = t.type == 'income';
      final isGoal = !isIncome && (t.goalId?.isNotEmpty ?? false);
      if (inMonths && !isGoal) {
        final m = monthMap[DateTime(date.year, date.month)];
        if (m != null) m[isIncome ? 0 : 1] += value;
      }
      if (inPrev) {
        if (isIncome) {
          prevIncome += value;
        } else if (!isGoal) {
          prevSpending += value;
        }
      }
      if (!inWindow) continue;
      operations++;
      final label = t.category.trim().isEmpty ? otherLabel : t.category.trim();
      if (isIncome) {
        income += value;
        final s = sources[label] ?? (0.0, 0);
        sources[label] = (s.$1 + value, s.$2 + 1);
        bucketMap[bucketOf(date)]?[0] += value;
      } else if (isGoal) {
        toGoals += value;
      } else {
        spending += value;
        final s = cats[label] ?? (0.0, 0);
        cats[label] = (s.$1 + value, s.$2 + 1);
        bucketMap[bucketOf(date)]?[1] += value;
        expenses.add(
          PersonalReportOperation(
            date: date,
            category: label,
            description: (t.description ?? '').trim(),
            amount: value,
            originalAmount: t.amount,
            originalCurrency: t.currency.trim().toUpperCase(),
          ),
        );
      }
    }

    List<PersonalReportSlice> slices(Map<String, (double, int)> m) => [
      for (final e in m.entries)
        PersonalReportSlice(e.key, e.value.$1, e.value.$2),
    ]..sort((a, b) => b.amount.compareTo(a.amount));

    expenses.sort((a, b) => b.amount.compareTo(a.amount));

    // ── balances, goals, budgets, debts: current values
    final bankRows = <PersonalReportBank>[
      for (final b in banks)
        PersonalReportBank(
          name: b.bankName,
          currency: b.currency.trim().toUpperCase(),
          balance: b.balance,
          converted: cv(b.balance, b.currency),
          accountType: b.accountType,
        ),
    ]..sort((a, b) => (b.converted ?? 0).compareTo(a.converted ?? 0));

    final goalRows = <PersonalReportGoal>[];
    for (final g in goals) {
      final saved = cv(g.currentAmount, g.currency);
      final goalTarget = cv(g.targetAmount, g.currency, count: false);
      if (saved == null || goalTarget == null) continue;
      goalRows.add(
        PersonalReportGoal(
          name: g.name,
          saved: saved,
          target: goalTarget,
          deadline: g.deadline,
          completed:
              g.isCompleted ||
              (g.targetAmount > 0 && g.currentAmount >= g.targetAmount),
          currency: g.currency.trim().toUpperCase(),
        ),
      );
    }
    goalRows.sort((a, b) => b.progress.compareTo(a.progress));

    final budgetRows = <PersonalReportBudget>[];
    for (final b in budgets) {
      final spent = cv(b.totalSpent, b.currency);
      final total = cv(b.totalAmount, b.currency, count: false);
      if (spent == null || total == null) continue;
      budgetRows.add(
        PersonalReportBudget(
          name: b.name,
          spent: spent,
          total: total,
          period: b.periodLabel,
          daysLeft: b.daysRemaining,
          currency: b.currency.trim().toUpperCase(),
        ),
      );
    }
    budgetRows.sort((a, b) => b.usage.compareTo(a.usage));

    final debtRows = <PersonalReportDebt>[];
    for (final d in debts) {
      if (d.status == 'paid' || d.isPaid || d.remaining <= 0) continue;
      final remaining = cv(d.remaining, d.currency);
      final total = cv(d.amount, d.currency, count: false);
      if (remaining == null || total == null) continue;
      debtRows.add(
        PersonalReportDebt(
          person: d.personName,
          owedToMe: d.type == 'receivable',
          remaining: remaining,
          total: total,
          dueDate: d.dueDate,
          overdue: d.dueDate != null && d.dueDate!.isBefore(today),
          currency: d.currency.trim().toUpperCase(),
        ),
      );
    }
    debtRows.sort((a, b) => b.remaining.compareTo(a.remaining));

    return PersonalReportData._(
      currency: target,
      window: window,
      income: income,
      spending: spending,
      toGoals: toGoals,
      transfers: transfers,
      prevIncome: prevIncome,
      prevSpending: prevSpending,
      operations: operations,
      categories: slices(cats),
      incomeSources: slices(sources),
      buckets: [
        for (final e in bucketMap.entries)
          PersonalReportBucket(e.key, e.value[0], e.value[1]),
      ],
      months: [
        for (final e in monthMap.entries)
          PersonalReportBucket(e.key, e.value[0], e.value[1]),
      ],
      topExpenses: expenses.take(6).toList(),
      banks: bankRows,
      goals: goalRows,
      budgets: budgetRows,
      debts: debtRows,
      unconverted: missing,
    );
  }
}
