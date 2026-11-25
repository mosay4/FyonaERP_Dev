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

  static SaraInsightInput build({
    required DateTime now,
    required String baseCurrency,
    required List<PersonalTransaction> transactions,
    required List<SavingsGoal> goals,
    List<PersonalBudget> budgets = const [],
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

    return SaraInsightInput(
      now: now,
      baseCurrency: baseCurrency,
      transactions: txs,
      goals: gs,
      budgets: bs,
      liquidBalance: liquidBalance,
    );
  }
}
