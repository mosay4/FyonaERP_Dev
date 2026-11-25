import '../../data/models/personal_models.dart';
import 'sara_insight_engine.dart';

/// Converts [amount] from → to; null when no rate is known.
typedef SaraConvert = double? Function(double amount, String from, String to);

// ─────────────────────────────────────────────────────────────
// SaraInsightInputBuilder — maps the app's Personal models onto the pure
// engine input. Multi-currency aware: everything is converted into the
// wallet (base) currency with the app's CurrencyEngine (injected as
// [SaraConvert]); rows whose currency cannot be converted are skipped
// rather than guessed. Pure (no Flutter / plugins).
// ─────────────────────────────────────────────────────────────
class SaraInsightInputBuilder {
  SaraInsightInputBuilder._();

  static double? _toBase(
      double amount, String currency, String base, SaraConvert convert) {
    final c = currency.trim().isEmpty ? base : currency.trim();
    if (c.toUpperCase() == base.toUpperCase()) return amount;
    try {
      final v = convert(amount, c, base);
      if (v == null || v.isNaN || v.isInfinite) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseDeadline(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final d = DateTime.tryParse(raw.trim());
    if (d == null) return null;
    final l = d.isUtc ? d.toLocal() : d;
    return DateTime(l.year, l.month, l.day);
  }

  static DateTime _localDay(DateTime d) {
    final l = d.isUtc ? d.toLocal() : d;
    return DateTime(l.year, l.month, l.day);
  }

  /// Monthly equivalent of one occurrence.
  static double _perMonth(String frequency, int interval) {
    final n = interval < 1 ? 1 : interval;
    switch (frequency) {
      case 'daily':
        return 30.4 / n;
      case 'weekly':
        return 4.35 / n;
      case 'yearly':
        return 1 / (12 * n);
      case 'monthly':
        return 1 / n;
      default:
        return 30.4 / n;
    }
  }

  /// Occurrences of [r] from its next date up to [until] (inclusive). A
  /// next date already in the past (not executed yet) counts as today.
  static List<DateTime> _occurrences(
      RecurringTransaction r, DateTime today, DateTime until) {
    final first = r.nextDate;
    if (first == null) return const [];
    final out = <DateTime>[];
    var cur = _localDay(first);
    var rule = r;
    for (var i = 0; i < 400 && !cur.isAfter(until); i++) {
      out.add(cur.isBefore(today) ? today : cur);
      rule = rule.copyWith(nextDate: cur);
      final next = _localDay(nextRecurringDate(rule));
      if (!next.isAfter(cur)) break;
      cur = next;
    }
    // Several missed past runs collapse into one "due now".
    final seen = <DateTime>{};
    return out.where(seen.add).toList();
  }

  static SaraInsightInput build({
    required DateTime now,
    required String baseCurrency,
    required List<PersonalTransaction> transactions,
    required List<SavingsGoal> goals,
    List<PersonalBudget> budgets = const [],
    List<RecurringTransaction> recurring = const [],
    List<PersonalDebt> debts = const [],
    double? liquidBalance,
    required SaraConvert convert,
  }) {
    final txs = <InsightTx>[];
    for (final t in transactions) {
      if (t.type != 'income' && t.type != 'expense') continue; // transfers
      final d = t.date;
      if (d == null || t.amount <= 0) continue;
      final base = _toBase(t.amount, t.currency, baseCurrency, convert);
      if (base == null || base <= 0) continue;
      final local = d.isUtc ? d.toLocal() : d;
      final created = t.createdAt == null
          ? null
          : (t.createdAt!.isUtc ? t.createdAt!.toLocal() : t.createdAt!);
      txs.add(InsightTx(
        id: t.id,
        type: t.type,
        amount: base,
        category: t.category,
        date: local,
        createdAt: created,
        toGoal: t.type == 'expense' && (t.goalId ?? '').isNotEmpty,
        originalAmount: t.amount,
        originalCurrency: t.currency,
        note: t.description,
      ));
    }

    final gs = <InsightGoal>[];
    for (final g in goals) {
      if (g.isCompleted) continue;
      final remaining = g.targetAmount - g.currentAmount;
      if (g.targetAmount <= 0 || remaining <= 0) continue;
      final remBase = _toBase(remaining, g.currency, baseCurrency, convert);
      if (remBase == null || remBase <= 0) continue;
      gs.add(InsightGoal(
        id: g.id,
        name: g.name,
        currency: g.currency.trim().isEmpty ? baseCurrency : g.currency,
        remainingBase: remBase,
        remainingNative: remaining,
        targetNative: g.targetAmount,
        currentNative: g.currentAmount,
        deadline: _parseDeadline(g.deadline),
      ));
    }

    final bs = <InsightBudget>[];
    for (final b in budgets) {
      if (!b.budgetTypes.contains('expenses')) continue;
      bs.add(InsightBudget(
        id: b.id,
        name: b.name,
        currency: b.currency,
        total: b.totalAmount,
        spent: b.totalSpent,
        start: b.startDate,
        end: b.endDate,
        categories: b.categories
            .where((c) => c.type == 'expense')
            .map((c) => InsightBudgetCategory(
                  id: c.id,
                  name: c.name,
                  allocated: c.allocatedAmount,
                  spent: c.spentAmount,
                ))
            .toList(),
      ));
    }

    // Recurring rules → monthly load, upcoming bills, scheduled incomes.
    final today = _localDay(now);
    final until = today.add(const Duration(days: 62));
    final rules = <InsightRecurring>[];
    final obligations = <InsightObligation>[];
    final incomes = <InsightIncomeEvent>[];
    for (final r in recurring) {
      if (!r.isActive || r.amount <= 0) continue;
      if (r.type != 'income' && r.type != 'expense') continue;
      final base = _toBase(r.amount, r.currency, baseCurrency, convert);
      if (base == null || base <= 0) continue;
      final isIncome = r.type == 'income';
      rules.add(InsightRecurring(
        id: r.id,
        name: r.name.trim().isNotEmpty ? r.name.trim() : r.category,
        category: r.category,
        isIncome: isIncome,
        amountBase: base,
        monthlyBase: base * _perMonth(r.frequency, r.intervalValue),
      ));
      for (final d in _occurrences(r, today, until)) {
        if (isIncome) {
          incomes.add(InsightIncomeEvent(d, base));
        } else {
          obligations.add(InsightObligation(
            id: r.id,
            kind: 'recurring',
            name: r.name.trim().isNotEmpty ? r.name.trim() : r.category,
            amountBase: base,
            amountNative: r.amount,
            currency: r.currency.trim().isEmpty ? baseCurrency : r.currency,
            due: d,
            reminded: r.executionType == 'reminder',
          ));
        }
      }
    }

    // Debts with a due date (payable → bills, receivable → to collect).
    for (final d in debts) {
      if (d.isPaid || d.status == 'paid' || d.dueDate == null) continue;
      final remaining = d.amount - d.paid;
      if (remaining <= 0) continue;
      if (d.type != 'payable' && d.type != 'receivable') continue;
      final base = _toBase(remaining, d.currency, baseCurrency, convert);
      if (base == null || base <= 0) continue;
      obligations.add(InsightObligation(
        id: d.id,
        kind: d.type == 'payable' ? 'debt' : 'debtIn',
        name: d.personName,
        amountBase: base,
        amountNative: remaining,
        currency: d.currency.trim().isEmpty ? baseCurrency : d.currency,
        due: _localDay(d.dueDate!),
        reminded: d.reminder,
      ));
    }

    return SaraInsightInput(
      now: now,
      baseCurrency: baseCurrency,
      transactions: txs,
      goals: gs,
      budgets: bs,
      liquidBalance: liquidBalance,
      recurring: rules,
      obligations: obligations,
      scheduledIncomes: incomes,
    );
  }
}
