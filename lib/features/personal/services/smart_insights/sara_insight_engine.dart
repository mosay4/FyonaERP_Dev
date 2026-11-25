import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────
// SaraInsightEngine — the on-device brain behind Sara's smart daily
// notifications (Personal section). PURE Dart: no Flutter, no plugins,
// no network and NO AI model calls. Every number here is computed from
// the user's own transactions, goals and budgets, deterministically, so
// it works offline and is fully unit-testable.
//
// Inputs are normalised by the caller (see SaraInsightInputBuilder):
// every transaction / goal amount is already converted into ONE base
// currency (the Personal wallet currency) so all maths is apples-to-
// apples, while each goal keeps its native currency for display.
// ─────────────────────────────────────────────────────────────

/// One normalised transaction. [amount] is in the BASE currency (> 0).
class InsightTx {
  final String id;

  /// 'income' | 'expense' (transfers are filtered out by the builder).
  final String type;
  final double amount;
  final String category;

  /// Local accounting date (may be backdated).
  final DateTime date;

  /// Local execution time (when the user actually logged it), if known.
  final DateTime? createdAt;

  /// Expense that was credited to a savings goal (a deposit, not spending).
  final bool toGoal;

  /// Amount / currency as the user entered it (display only).
  final double? originalAmount;
  final String? originalCurrency;

  /// Free-text description / merchant (used to spot repeat charges).
  final String? note;

  const InsightTx({
    required this.id,
    required this.type,
    required this.amount,
    required this.category,
    required this.date,
    this.createdAt,
    this.toGoal = false,
    this.originalAmount,
    this.originalCurrency,
    this.note,
  });

  bool get isIncome => type == 'income';
  bool get isSpending => type == 'expense' && !toGoal;
}

/// One active savings goal. [remainingBase] drives the maths,
/// [remainingNative] + [currency] drive the display.
class InsightGoal {
  final String id;
  final String name;
  final String currency;
  final double remainingBase;
  final double remainingNative;
  final double targetNative;
  final double currentNative;
  final DateTime? deadline;

  const InsightGoal({
    required this.id,
    required this.name,
    required this.currency,
    required this.remainingBase,
    required this.remainingNative,
    this.targetNative = 0,
    this.currentNative = 0,
    this.deadline,
  });

  double get progress =>
      targetNative > 0 ? (currentNative / targetNative).clamp(0.0, 1.0) : 0;

  /// base → native factor (1 when the goal is in the base currency).
  double get nativePerBase =>
      remainingBase > 0 ? remainingNative / remainingBase : 1.0;
}

class InsightBudgetCategory {
  final String id;
  final String name;
  final double allocated;
  final double spent;
  const InsightBudgetCategory({
    required this.id,
    required this.name,
    required this.allocated,
    required this.spent,
  });
}

/// One expense budget, amounts in the budget's own currency.
class InsightBudget {
  final String id;
  final String name;
  final String currency;
  final double total;
  final double spent;
  final DateTime? start;
  final DateTime? end;
  final List<InsightBudgetCategory> categories;
  const InsightBudget({
    required this.id,
    required this.name,
    required this.currency,
    required this.total,
    required this.spent,
    this.start,
    this.end,
    this.categories = const [],
  });
}

/// One active recurring rule (amounts in BASE currency).
class InsightRecurring {
  final String id;
  final String name;
  final String category;
  final bool isIncome;

  /// One occurrence.
  final double amountBase;

  /// Monthly equivalent (weekly × 4.35, yearly ÷ 12, …).
  final double monthlyBase;
  const InsightRecurring({
    required this.id,
    required this.name,
    required this.category,
    required this.isIncome,
    required this.amountBase,
    required this.monthlyBase,
  });
}

/// A dated money commitment: the next occurrence(s) of a recurring bill
/// ('recurring'), a debt the user must pay ('debt') or a debt owed TO the
/// user ('debtIn'). [amountBase] drives the maths, native for display.
class InsightObligation {
  final String id;
  final String kind;
  final String name;
  final double amountBase;
  final double amountNative;
  final String currency;

  /// Local due day.
  final DateTime due;

  /// The user already set their own reminder for it (Sara stays quiet
  /// unless money is actually short).
  final bool reminded;
  const InsightObligation({
    required this.id,
    required this.kind,
    required this.name,
    required this.amountBase,
    required this.amountNative,
    required this.currency,
    required this.due,
    this.reminded = false,
  });

  bool get isOutflow => kind == 'recurring' || kind == 'debt';
}

/// A scheduled income (recurring income rule occurrence), base currency.
class InsightIncomeEvent {
  final DateTime date;
  final double amountBase;
  const InsightIncomeEvent(this.date, this.amountBase);
}

/// One bank/cash account as the phone holds it (native currency).
class InsightAccount {
  final String id;
  final String name;
  final String currency;
  final double balance;
  const InsightAccount({
    required this.id,
    required this.name,
    required this.currency,
    required this.balance,
  });
}

class SaraInsightInput {
  final DateTime now;
  final String baseCurrency;
  final List<InsightTx> transactions;
  final List<InsightGoal> goals;
  final List<InsightBudget> budgets;

  /// Liquid balance (banks + cash) in base currency, null when unknown.
  final double? liquidBalance;

  /// Active recurring rules (bills and incomes).
  final List<InsightRecurring> recurring;

  /// Upcoming bills / debts (and money owed to the user), absolute dates.
  final List<InsightObligation> obligations;

  /// Upcoming scheduled incomes (recurring income rules).
  final List<InsightIncomeEvent> scheduledIncomes;

  /// The user's accounts with their balances (low-balance heads-up).
  final List<InsightAccount> accounts;

  const SaraInsightInput({
    required this.now,
    required this.baseCurrency,
    this.transactions = const [],
    this.goals = const [],
    this.budgets = const [],
    this.liquidBalance,
    this.recurring = const [],
    this.obligations = const [],
    this.scheduledIncomes = const [],
    this.accounts = const [],
  });

  SaraInsightInput atTime(DateTime t) => SaraInsightInput(
        now: t,
        baseCurrency: baseCurrency,
        transactions: transactions,
        goals: goals,
        budgets: budgets,
        liquidBalance: liquidBalance,
        recurring: recurring,
        obligations: obligations,
        scheduledIncomes: scheduledIncomes,
        accounts: accounts,
      );
}

enum SpendLevel { unknown, low, normal, high }

class GoalAllocation {
  final InsightGoal goal;

  /// Suggested amount for TODAY in base currency (after rounding).
  final double amountBase;

  /// Same amount in the goal's own currency (rounded, what we display).
  final double amountNative;

  /// Pace needed per day to hit the deadline (base).
  final double requiredDaily;
  const GoalAllocation({
    required this.goal,
    required this.amountBase,
    required this.amountNative,
    required this.requiredDaily,
  });
}

enum BudgetAlertLevel { pacing, nearing, over }

class BudgetAlert {
  final InsightBudget budget;

  /// Set when the alert is about one category of the budget.
  final InsightBudgetCategory? category;
  final BudgetAlertLevel level;
  final double usage; // 0..n (1 = 100%)
  const BudgetAlert({
    required this.budget,
    required this.level,
    required this.usage,
    this.category,
  });

  /// Stable identity used for "never repeat the same warning daily".
  String get key => category != null
      ? 'bcat:${budget.id}:${category!.id}:${level.name}'
      : 'budget:${budget.id}:${level.name}';
}

/// The first upcoming bill the balance cannot cover before payday.
class BillRisk {
  final InsightObligation obligation;

  /// How much is missing (base) once usual daily spending is kept.
  final double shortBy;
  const BillRisk(this.obligation, this.shortBy);
}

/// Month-end outlook (base currency).
class MonthProjection {
  final double spentSoFar;
  final double projectedSpend;
  final double expectedIncome;
  final int daysLeft;
  const MonthProjection({
    required this.spentSoFar,
    required this.projectedSpend,
    required this.expectedIncome,
    required this.daysLeft,
  });

  /// Positive = money left at month end, negative = shortfall.
  double get net => expectedIncome - projectedSpend;
}

/// A charge that repeats monthly but is not a recurring rule yet.
class SubscriptionHint {
  final String signature;
  final String label;
  final double amountBase;
  final double? originalAmount;
  final String? originalCurrency;
  final int count;
  const SubscriptionHint({
    required this.signature,
    required this.label,
    required this.amountBase,
    this.originalAmount,
    this.originalCurrency,
    required this.count,
  });
}

class SaraAnalysis {
  final DateTime now;
  final String baseCurrency;
  final int spanDays;
  final bool confident;
  final double avgDailyIncome;
  final double avgDailyExpense;
  final int? incomeCadenceDays;
  final DateTime? nextIncomeDate;
  final int daysUntilNextIncome;

  /// What the user can safely set aside TODAY (base). Never negative.
  final double affordableToday;
  final bool loggedToday;
  final double todayExpense;
  final double recentWeekExpense;
  final double baselineWeekExpense;
  final SpendLevel spendLevel;
  final String? topCategory;
  final double topCategoryExcess;
  final List<BudgetAlert> budgetAlerts;
  final List<GoalAllocation> allocations;
  final bool hasActiveGoals;

  /// The most urgent active goal (deadline / pace), even when nothing is
  /// affordable today — used for the "let's make room" nudge.
  final InsightGoal? focusGoal;
  final double requiredDailyTotal;
  final double savedThisWeek;
  final int loggingStreak;
  final int peakHour;

  /// Usual daily spending WITHOUT the recurring bills' share (base).
  final double discretionaryDaily;

  /// Monthly recurring bills spread per day (base).
  final double recurringDaily;

  /// Bills + payable debts due before the next income (base).
  final double obligationsBeforePayday;
  final BillRisk? billRisk;

  /// Payable debts due within 2 days or overdue (≤ 30 days), earliest
  /// first; only those without the user's own reminder.
  final List<InsightObligation> debtsDue;

  /// Money owed to the user due within 2 days (or overdue ≤ 14 days).
  final List<InsightObligation> collectDue;
  final MonthProjection? projection;
  final List<SubscriptionHint> subscriptions;

  /// Consecutive full days (ending yesterday) without any spending, only
  /// counted for users who usually log daily (else it is missing data).
  final int noSpendDays;

  /// Today is (or is predicted to be) the user's payday.
  final bool isPayday;

  /// "Pay yourself first" amount for today (base), 0 when none.
  final double paydaySave;

  /// Active goal whose deadline is within 14 days and still unfunded.
  final InsightGoal? deadlineGoal;

  const SaraAnalysis({
    required this.now,
    required this.baseCurrency,
    required this.spanDays,
    required this.confident,
    required this.avgDailyIncome,
    required this.avgDailyExpense,
    required this.incomeCadenceDays,
    required this.nextIncomeDate,
    required this.daysUntilNextIncome,
    required this.affordableToday,
    required this.loggedToday,
    required this.todayExpense,
    required this.recentWeekExpense,
    required this.baselineWeekExpense,
    required this.spendLevel,
    required this.topCategory,
    required this.topCategoryExcess,
    required this.budgetAlerts,
    required this.allocations,
    required this.hasActiveGoals,
    this.focusGoal,
    required this.requiredDailyTotal,
    required this.savedThisWeek,
    required this.loggingStreak,
    required this.peakHour,
    this.discretionaryDaily = 0,
    this.recurringDaily = 0,
    this.obligationsBeforePayday = 0,
    this.billRisk,
    this.debtsDue = const [],
    this.collectDue = const [],
    this.projection,
    this.subscriptions = const [],
    this.noSpendDays = 0,
    this.isPayday = false,
    this.paydaySave = 0,
    this.deadlineGoal,
  });

  double get allocatedTotal =>
      allocations.fold<double>(0, (s, a) => s + a.amountBase);

  /// Recent week vs baseline, e.g. 0.35 = 35% more than usual.
  double get spendDelta => baselineWeekExpense > 0
      ? (recentWeekExpense - baselineWeekExpense) / baselineWeekExpense
      : 0;
}

/// Event-driven alert raised right after a new expense lands.
class InstantAlert {
  /// 'bigExpense' | 'budgetOver' | 'lowBalance'
  final String kind;
  final InsightTx? tx;
  final BudgetAlert? budgetAlert;
  final InsightAccount? account;
  final double ratio;
  const InstantAlert({
    required this.kind,
    this.tx,
    this.budgetAlert,
    this.account,
    this.ratio = 0,
  });

  String get key {
    if (budgetAlert != null) return 'instant:${budgetAlert!.key}';
    if (account != null) return 'instant:low:${account!.id}';
    // Content-based (not id-based): an offline row re-keyed by the server
    // after sync must never alert twice.
    final t = tx;
    if (t == null) return 'instant:big:';
    final d = t.date;
    return 'instant:big:${t.category}:${t.amount.toStringAsFixed(2)}:'
        '${d.year}-${d.month}-${d.day}';
  }
}

class SaraInsightEngine {
  SaraInsightEngine._();

  static const int windowDays = 90;
  static const int fallbackPeakHour = 20;
  static const int earliestHour = 8;
  static const int latestHour = 22;

  /// Fraction of the free daily cash-flow Sara is willing to suggest; the
  /// rest is a safety buffer so a suggestion is never a stretch.
  static const double flowSafety = 0.8;

  /// Max goals mentioned in one day (keeps the notification short and
  /// stops a tiny budget being shredded into useless crumbs).
  static const int maxGoalsPerDay = 3;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
  static int _daysBetween(DateTime a, DateTime b) =>
      _day(b).difference(_day(a)).inHours ~/ 24;

  // ── Analysis ──────────────────────────────────────────────

  static SaraAnalysis analyze(SaraInsightInput input) {
    final now = input.now;
    final today = _day(now);
    final windowStart = today.subtract(const Duration(days: windowDays - 1));
    final txs = input.transactions
        .where((t) =>
            t.amount > 0 &&
            !_day(t.date).isBefore(windowStart) &&
            !_day(t.date).isAfter(today))
        .toList();

    // Observed history span (inclusive). A brand-new user with 3 days of
    // data must not have their averages divided by 90.
    var span = 1;
    if (txs.isNotEmpty) {
      final earliest =
          txs.map((t) => _day(t.date)).reduce((a, b) => a.isBefore(b) ? a : b);
      span = _daysBetween(earliest, today) + 1;
    }
    span = span.clamp(1, windowDays);
    final confident = span >= 7 && txs.length >= 3;

    // Income + cadence. The cadence comes from the user's main income
    // stream (the income category with the largest total seen on 2+ days,
    // e.g. «Salary»), so a one-off gift or refund never skews payday.
    final incomes = txs.where((t) => t.isIncome).toList();
    final incomeSum = incomes.fold<double>(0, (s, t) => s + t.amount);
    final payday = _paydayStream(incomes);
    final cadence = incomeCadence(payday.map((t) => t.date).toList()) ??
        incomeCadence(incomes.map((t) => t.date).toList());
    final incomeDays = incomes.map((t) => _day(t.date)).toSet().length;
    // One salary observed in a short history must be spread over a full
    // cycle, never over the few days we happen to have seen.
    final incomeDivisor = incomeDays <= 1
        ? math.max(span, 30)
        : math.max(span, cadence ?? span);
    final avgDailyIncome = incomes.isEmpty ? 0.0 : incomeSum / incomeDivisor;

    final spending = txs.where((t) => t.isSpending).toList();
    final spendSum = spending.fold<double>(0, (s, t) => s + t.amount);
    final avgDailyExpense = spendSum / span;

    // Typical payday amount (median of the main stream).
    final paydayAmounts = payday.map((t) => t.amount).toList()..sort();
    final typicalPay =
        paydayAmounts.isEmpty ? 0.0 : paydayAmounts[paydayAmounts.length ~/ 2];

    // Next income: a scheduled (recurring) income wins over prediction;
    // monthly pay steps by calendar month on the same day-of-month.
    DateTime? nextIncome;
    var paidToday = false;
    final scheduled = input.scheduledIncomes
        .map((e) => _day(e.date))
        .where((d) => !d.isBefore(today))
        .toList()
      ..sort();
    if (scheduled.isNotEmpty && scheduled.first == today) paidToday = true;
    final future = scheduled.where((d) => d.isAfter(today)).toList();
    if (future.isNotEmpty) nextIncome = future.first;
    final stream = payday.isNotEmpty ? payday : incomes;
    if (stream.isNotEmpty) {
      final last = stream
          .map((t) => _day(t.date))
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (last == today) {
        // The main income landed today (a small top-up does not count).
        final todayPay = stream
            .where((t) => _day(t.date) == today)
            .fold<double>(0, (s, t) => s + t.amount);
        if (typicalPay <= 0 || todayPay >= typicalPay * 0.5) paidToday = true;
      }
      final step = cadence ?? 30;
      var k = 1;
      var n = _stepIncome(last, step, k);
      while (!n.isAfter(today) && k < 400) {
        // Predicted payday is today (salary not logged yet).
        if (n == today && cadence != null) paidToday = true;
        k++;
        n = _stepIncome(last, step, k);
      }
      // A scheduled (recurring) income wins over the prediction.
      nextIncome ??= n;
    }
    var daysUntilIncome = 30;
    if (nextIncome != null) {
      daysUntilIncome = math.max(1, _daysBetween(today, nextIncome));
    }

    // Today.
    final todayTxs = input.transactions.where((t) =>
        _day(t.date) == today ||
        (t.createdAt != null && _day(t.createdAt!) == today));
    final loggedToday = todayTxs.isNotEmpty;
    final todayExpense = input.transactions
        .where((t) => t.isSpending && _day(t.date) == today)
        .fold<double>(0, (s, t) => s + t.amount);

    // Recurring bills: their monthly share is already inside the average
    // when the user logs them, so the discretionary pace excludes it (with
    // a floor: the bills may not be logged as transactions at all).
    final recurringDaily = input.recurring
            .where((r) => !r.isIncome)
            .fold<double>(0, (s, r) => s + r.monthlyBase) /
        30.4;
    final discretionary = recurringDaily > 0
        ? math.max(avgDailyExpense - recurringDaily, avgDailyExpense * 0.6)
        : avgDailyExpense;

    // Upcoming outflows (bills + payable debts; overdue debts count now).
    final outflows = input.obligations
        .where((o) =>
            o.isOutflow &&
            o.amountBase > 0 &&
            (!_day(o.due).isBefore(today) ||
                (o.kind == 'debt' && _daysBetween(o.due, today) <= 30)))
        .toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    DateTime dueOf(InsightObligation o) =>
        _day(o.due).isBefore(today) ? today : _day(o.due);
    final horizon = math.max(daysUntilIncome, 7);
    final billsInHorizon = outflows
        .where((o) => _daysBetween(today, dueOf(o)) < horizon)
        .fold<double>(0, (s, o) => s + o.amountBase);
    final beforePayday = outflows
        .where((o) =>
            nextIncome == null || dueOf(o).isBefore(nextIncome))
        .toList();
    final obligationsBeforePayday =
        beforePayday.fold<double>(0, (s, o) => s + o.amountBase);

    // Affordability — the hard ceiling for any goal suggestion.
    final affordable = _affordableToday(
      confident: confident,
      hasIncome: incomes.isNotEmpty,
      avgDailyIncome: avgDailyIncome,
      avgDailyExpense: avgDailyExpense,
      discretionaryDaily: discretionary,
      recurringDaily: recurringDaily,
      liquid: input.liquidBalance,
      daysUntilIncome: daysUntilIncome,
      billsInHorizon: billsInHorizon,
      todayExpense: todayExpense,
    );

    // Bill risk: walk the bills due before payday in date order, keeping
    // the usual daily spending; the first one the balance cannot cover
    // (within the next 7 days, so it is actionable) is flagged.
    BillRisk? billRisk;
    final liquid = input.liquidBalance;
    if (liquid != null && beforePayday.isNotEmpty) {
      var cum = 0.0;
      for (final o in beforePayday) {
        final d = _daysBetween(today, dueOf(o));
        if (d > 7) break;
        cum += o.amountBase;
        final need = cum + (confident ? discretionary * d : 0);
        final short = need - liquid;
        if (short > math.max(1.0, o.amountBase * 0.02)) {
          billRisk = BillRisk(o, short);
          break;
        }
      }
    }

    // Debts: payable due within 2 days (or overdue ≤ 30), without the
    // user's own reminder; money owed to the user due soon.
    bool soon(InsightObligation o, int overdueDays) {
      final d = _daysBetween(today, _day(o.due));
      return d <= 2 && d >= -overdueDays;
    }

    final debtsDue = input.obligations
        .where((o) => o.kind == 'debt' && !o.reminded && soon(o, 30))
        .toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    final collectDue = input.obligations
        .where((o) => o.kind == 'debtIn' && !o.reminded && soon(o, 14))
        .toList()
      ..sort((a, b) => a.due.compareTo(b.due));

    // Month-end outlook: spent so far + usual pace for the days left +
    // bills still due this month, against income received + expected.
    MonthProjection? projection;
    final monthEnd = DateTime(today.year, today.month + 1, 0);
    final daysLeft = _daysBetween(today, monthEnd);
    if (confident &&
        today.day >= 10 &&
        daysLeft >= 3 &&
        (cadence != null || scheduled.isNotEmpty) &&
        incomes.isNotEmpty) {
      final monthStart = DateTime(today.year, today.month, 1);
      bool inMonth(DateTime d) =>
          !_day(d).isBefore(monthStart) && !_day(d).isAfter(today);
      final spentSoFar = input.transactions
          .where((t) => t.isSpending && inMonth(t.date))
          .fold<double>(0, (s, t) => s + t.amount);
      final incomeSoFar = input.transactions
          .where((t) => t.isIncome && inMonth(t.date))
          .fold<double>(0, (s, t) => s + t.amount);
      final billsLeft = outflows
          .where((o) =>
              dueOf(o).isAfter(today) && !dueOf(o).isAfter(monthEnd))
          .fold<double>(0, (s, o) => s + o.amountBase);
      var expected = incomeSoFar;
      final upcomingScheduled = input.scheduledIncomes.where((e) =>
          _day(e.date).isAfter(today) && !_day(e.date).isAfter(monthEnd));
      if (upcomingScheduled.isNotEmpty) {
        expected +=
            upcomingScheduled.fold<double>(0, (s, e) => s + e.amountBase);
      } else if (nextIncome != null && !nextIncome.isAfter(monthEnd)) {
        expected += typicalPay;
      }
      if (expected > 0) {
        projection = MonthProjection(
          spentSoFar: spentSoFar,
          projectedSpend: spentSoFar + discretionary * daysLeft + billsLeft,
          expectedIncome: expected,
          daysLeft: daysLeft,
        );
      }
    }

    // Spending level: last 7 days vs the user's OWN baseline before that.
    final recentStart = today.subtract(const Duration(days: 6));
    final recent =
        spending.where((t) => !_day(t.date).isBefore(recentStart)).toList();
    final base =
        spending.where((t) => _day(t.date).isBefore(recentStart)).toList();
    final baselineDays = span - 7;
    final recentSum = recent.fold<double>(0, (s, t) => s + t.amount);
    var level = SpendLevel.unknown;
    var baselineWeek = 0.0;
    String? topCat;
    var topExcess = 0.0;
    if (baselineDays >= 14 && base.length >= 5) {
      final baseSum = base.fold<double>(0, (s, t) => s + t.amount);
      baselineWeek = baseSum / baselineDays * 7;
      final loggedDays = input.transactions
          .where((t) => !_day(t.date).isBefore(recentStart))
          .map((t) => _day(t.date))
          .toSet()
          .length;
      final excess = recentSum - baselineWeek;
      if (baselineWeek > 0 &&
          recentSum >= baselineWeek * 1.3 &&
          excess >= math.max(avgDailyExpense, 0.01)) {
        level = SpendLevel.high;
      } else if (baselineWeek > 0 &&
          recentSum <= baselineWeek * 0.7 &&
          loggedDays >= 4) {
        // Low only counts when the user actually kept logging — otherwise
        // "low spending" is just missing data.
        level = SpendLevel.low;
      } else {
        level = SpendLevel.normal;
      }
      if (level == SpendLevel.high) {
        final recentByCat = <String, double>{};
        for (final t in recent) {
          recentByCat[t.category] = (recentByCat[t.category] ?? 0) + t.amount;
        }
        final baseByCat = <String, double>{};
        for (final t in base) {
          baseByCat[t.category] = (baseByCat[t.category] ?? 0) + t.amount;
        }
        recentByCat.forEach((cat, v) {
          final usual = (baseByCat[cat] ?? 0) / baselineDays * 7;
          final ex = v - usual;
          if (ex > topExcess && cat.trim().isNotEmpty) {
            topExcess = ex;
            topCat = cat;
          }
        });
      }
    }

    // Goals.
    final activeGoals =
        input.goals.where((g) => g.remainingBase > 0.0001).toList();
    final allocations = allocateGoals(activeGoals, affordable, today);
    final requiredTotal = activeGoals.fold<double>(
        0, (s, g) => s + requiredDaily(g, today));

    final savedThisWeek = input.transactions
        .where((t) => t.toGoal && !_day(t.date).isBefore(recentStart))
        .fold<double>(0, (s, t) => s + t.amount);

    // Payday: "pay yourself first" — a cycle's worth of the goals' pace,
    // capped by what the pay leaves after usual spending and bills (and
    // by the real balance once the salary is logged).
    var paydaySave = 0.0;
    if (paidToday && confident) {
      final cycle = math.max(7, cadence ?? 30);
      final pay = typicalPay > 0 ? typicalPay : avgDailyIncome * cycle;
      final billsCycle = outflows
          .where((o) => _daysBetween(today, dueOf(o)) < cycle)
          .fold<double>(0, (s, o) => s + o.amountBase);
      final free = pay -
          discretionary * cycle * 1.1 -
          math.max(recurringDaily * cycle, billsCycle);
      var cap = free * flowSafety;
      final loggedPay = incomes.any((t) => _day(t.date) == today);
      if (liquid != null && loggedPay) {
        cap = math.min(
            cap, liquid - billsCycle - discretionary * cycle * 1.1);
      }
      final need = activeGoals.isEmpty
          ? pay * 0.1
          : activeGoals.fold<double>(
              0,
              (s, g) => s +
                  math.min(g.remainingBase, requiredDaily(g, today) * cycle));
      paydaySave = niceFloor(math.min(need, cap));
    }

    // Goal with a close deadline that still needs money.
    InsightGoal? deadlineGoal;
    for (final g in activeGoals) {
      final dl = g.deadline;
      if (dl == null) continue;
      final left = _daysBetween(today, dl);
      if (left < 0 || left > 14) continue;
      if (deadlineGoal == null ||
          dl.isBefore(deadlineGoal.deadline!)) {
        deadlineGoal = g;
      }
    }

    // No-spend streak, only for users who usually log spending daily and
    // were active in the app lately (otherwise silence = missing data).
    var noSpend = 0;
    {
      final spendDays = spending.map((t) => _day(t.date)).toSet();
      var d = today.subtract(const Duration(days: 1));
      while (!spendDays.contains(d) && noSpend < 30 && !d.isBefore(windowStart)) {
        noSpend++;
        d = d.subtract(const Duration(days: 1));
      }
      final priorEnd = d;
      final priorStart = priorEnd.subtract(const Duration(days: 27));
      final priorDays = spendDays
          .where((x) => !x.isBefore(priorStart) && !x.isAfter(priorEnd))
          .length;
      final yesterday = today.subtract(const Duration(days: 1));
      final active = input.transactions.any((t) =>
          !_day(t.createdAt ?? t.date).isBefore(yesterday) &&
          !_day(t.createdAt ?? t.date).isAfter(today));
      if (noSpend < 2 || priorDays < 17 || !active) noSpend = 0;
    }

    return SaraAnalysis(
      now: now,
      baseCurrency: input.baseCurrency,
      spanDays: span,
      confident: confident,
      avgDailyIncome: avgDailyIncome,
      avgDailyExpense: avgDailyExpense,
      incomeCadenceDays: cadence,
      nextIncomeDate: nextIncome,
      daysUntilNextIncome: daysUntilIncome,
      affordableToday: affordable,
      loggedToday: loggedToday,
      todayExpense: todayExpense,
      recentWeekExpense: recentSum,
      baselineWeekExpense: baselineWeek,
      spendLevel: level,
      topCategory: topCat,
      topCategoryExcess: topExcess,
      budgetAlerts: budgetAlerts(input.budgets, now),
      allocations: allocations,
      hasActiveGoals: activeGoals.isNotEmpty,
      focusGoal: mostUrgentGoal(activeGoals, today),
      requiredDailyTotal: requiredTotal,
      savedThisWeek: savedThisWeek,
      loggingStreak: loggingStreak(input.transactions, today),
      peakHour: detectPeakHour(input.transactions
          .where((t) => t.createdAt != null)
          .map((t) => t.createdAt!)
          .where((c) => !_day(c).isBefore(windowStart))
          .toList()),
      discretionaryDaily: discretionary,
      recurringDaily: recurringDaily,
      obligationsBeforePayday: obligationsBeforePayday,
      billRisk: billRisk,
      debtsDue: debtsDue,
      collectDue: collectDue,
      projection: projection,
      subscriptions: detectSubscriptions(spending, input.recurring, today),
      noSpendDays: noSpend,
      isPayday: paidToday,
      paydaySave: paydaySave,
      deadlineGoal: deadlineGoal,
    );
  }

  /// The user's main income stream: the income category with the largest
  /// total among those seen on 2+ distinct days (e.g. the salary). Empty
  /// when no category repeats.
  static List<InsightTx> _paydayStream(List<InsightTx> incomes) {
    final byCat = <String, List<InsightTx>>{};
    for (final t in incomes) {
      byCat.putIfAbsent(t.category.trim().toLowerCase(), () => []).add(t);
    }
    List<InsightTx> best = const [];
    var bestSum = 0.0;
    byCat.forEach((_, list) {
      if (list.map((t) => _day(t.date)).toSet().length < 2) return;
      final sum = list.fold<double>(0, (s, t) => s + t.amount);
      if (sum > bestSum) {
        bestSum = sum;
        best = list;
      }
    });
    return best;
  }

  /// [k]-th income after [last]: calendar months for a monthly cadence
  /// (same day-of-month, clamped to short months), plain days otherwise.
  static DateTime _stepIncome(DateTime last, int cadence, int k) {
    if (cadence == 30) return _addMonths(last, k);
    return _day(last).add(Duration(days: cadence * k));
  }

  static DateTime _addMonths(DateTime d, int months) {
    final total = d.month - 1 + months;
    final y = d.year + total ~/ 12;
    final m = total % 12 + 1;
    final last = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, math.min(d.day, last));
  }

  // ── Repeat charges ────────────────────────────────────────

  static String _norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Charges that repeat about monthly with the SAME amount but are not a
  /// recurring rule yet (forgotten subscriptions). A description match
  /// needs 2 charges; a bare category needs 3 (coincidences are common).
  static List<SubscriptionHint> detectSubscriptions(
    List<InsightTx> spending,
    List<InsightRecurring> recurring,
    DateTime today,
  ) {
    final groups = <String, List<InsightTx>>{};
    for (final t in spending) {
      final note = _norm(t.note ?? '');
      final sig = note.isNotEmpty ? 'n:$note' : 'c:${_norm(t.category)}';
      final amt = (t.originalAmount ?? t.amount).toStringAsFixed(2);
      groups.putIfAbsent('$sig|$amt|${t.originalCurrency ?? ''}', () => []).add(t);
    }
    final out = <SubscriptionHint>[];
    groups.forEach((key, list) {
      final byNote = key.startsWith('n:');
      final days = list.map((t) => _day(t.date)).toSet().toList()..sort();
      if (days.length < (byNote ? 2 : 3)) return;
      for (var i = 1; i < days.length; i++) {
        final g = _daysBetween(days[i - 1], days[i]);
        if (g < 26 || g > 35) return;
      }
      if (_daysBetween(days.last, today) > 35) return; // stopped already
      final t = list.last;
      final label = byNote ? (t.note ?? '').trim() : t.category;
      final known = recurring.any((r) =>
          !r.isIncome &&
          (r.amountBase - t.amount).abs() <= math.max(0.5, t.amount * 0.02) &&
          (_norm(r.name) == _norm(label) ||
              _norm(r.category) == _norm(t.category)));
      if (known) return;
      out.add(SubscriptionHint(
        signature: key,
        label: label,
        amountBase: t.amount,
        originalAmount: t.originalAmount,
        originalCurrency: t.originalCurrency,
        count: days.length,
      ));
    });
    out.sort((a, b) => b.amountBase.compareTo(a.amountBase));
    return out;
  }

  static double _affordableToday({
    required bool confident,
    required bool hasIncome,
    required double avgDailyIncome,
    required double avgDailyExpense,
    required double discretionaryDaily,
    required double recurringDaily,
    required double? liquid,
    required int daysUntilIncome,
    required double billsInHorizon,
    required double todayExpense,
  }) {
    if (!confident) return 0;
    double? flow;
    if (hasIncome) {
      // Bills that are not logged as transactions still cost money.
      final outflow = math.max(avgDailyExpense, recurringDaily);
      flow = math.max(0, avgDailyIncome - outflow) * flowSafety;
    }
    double? cashCap;
    if (liquid != null) {
      final horizon = math.max(daysUntilIncome, 7);
      // Keep enough for usual spending until the next income (+10%) AND
      // every bill / debt that falls due before it.
      final reserve = discretionaryDaily * horizon * 1.1 + billsInHorizon;
      final free = liquid - reserve;
      cashCap = free <= 0 ? 0 : free / horizon;
    }
    double value;
    if (flow == null && cashCap == null) {
      value = 0;
    } else if (flow == null) {
      // No income logged: only a cautious slice of truly free cash.
      value = cashCap! * 0.5;
    } else if (cashCap == null) {
      value = flow;
    } else {
      value = math.min(flow, cashCap);
    }
    // A heavy-spending day lowers today's suggestion.
    final overshoot = math.max(0, todayExpense - avgDailyExpense);
    value -= overshoot;
    if (value.isNaN || value < 0) return 0;
    return value;
  }

  // ── Income cadence ────────────────────────────────────────

  /// Typical days between income days (median gap), snapped to common
  /// cycles (7 / 14 / 30) when close. Null when fewer than 2 income days.
  static int? incomeCadence(List<DateTime> incomeDates) {
    final days = incomeDates.map(_day).toSet().toList()..sort();
    if (days.length < 2) return null;
    final gaps = <int>[];
    for (var i = 1; i < days.length; i++) {
      final g = _daysBetween(days[i - 1], days[i]);
      if (g > 0) gaps.add(g);
    }
    if (gaps.isEmpty) return null;
    gaps.sort();
    final median = gaps[gaps.length ~/ 2];
    for (final cycle in const [7, 14, 30]) {
      if ((median - cycle).abs() <= (cycle == 30 ? 4 : 1)) return cycle;
    }
    return median.clamp(1, 60);
  }

  // ── Goals ─────────────────────────────────────────────────

  /// Daily pace needed to reach a goal by its deadline (base currency).
  /// No deadline → a gentle 6-month horizon; overdue → catch up over 2 weeks.
  static double requiredDaily(InsightGoal g, DateTime today) {
    if (g.remainingBase <= 0) return 0;
    final dl = g.deadline;
    int horizon;
    if (dl == null) {
      horizon = 180;
    } else {
      final left = _daysBetween(today, dl);
      horizon = left < 0 ? 14 : math.max(1, left + 1);
    }
    return g.remainingBase / horizon;
  }

  /// Highest (required pace × urgency) goal, null when none.
  static InsightGoal? mostUrgentGoal(List<InsightGoal> goals, DateTime today) {
    InsightGoal? best;
    var bestW = -1.0;
    for (final g in goals) {
      if (g.remainingBase <= 0) continue;
      final w = requiredDaily(g, today) * _urgency(g, today);
      if (w > bestW) {
        bestW = w;
        best = g;
      }
    }
    return best;
  }

  static double _urgency(InsightGoal g, DateTime today) {
    final dl = g.deadline;
    double u;
    if (dl == null) {
      u = 0.6;
    } else {
      final left = _daysBetween(today, dl);
      if (left < 0) {
        u = 3.0;
      } else if (left <= 14) {
        u = 2.5;
      } else if (left <= 30) {
        u = 2.0;
      } else if (left <= 90) {
        u = 1.4;
      } else {
        u = 1.0;
      }
    }
    // Close to the finish line: a little push to complete it.
    if (g.progress >= 0.8) u += 0.3;
    return u;
  }

  /// Splits [budget] (base) across [goals] for today.
  ///
  /// - Never exceeds [budget] (affordability) nor any goal's remaining.
  /// - Weight = required daily pace × urgency (deadline closeness,
  ///   overdue, near completion), so urgent / large-gap goals get more.
  /// - Each goal is capped at 1.5× its required pace: once every goal is
  ///   on track, Sara does not push the user to over-save.
  /// - At most [maxGoalsPerDay] goals per day; amounts are rounded DOWN
  ///   to friendly numbers in each goal's own currency, and goals whose
  ///   share rounds to nothing are dropped so the rest is concentrated.
  static List<GoalAllocation> allocateGoals(
    List<InsightGoal> goals,
    double budget,
    DateTime today,
  ) {
    if (budget <= 0 || goals.isEmpty) return const [];
    var pool = goals.where((g) => g.remainingBase > 0).toList();
    if (pool.isEmpty) return const [];
    pool.sort((a, b) {
      final wa = requiredDaily(a, today) * _urgency(a, today);
      final wb = requiredDaily(b, today) * _urgency(b, today);
      final c = wb.compareTo(wa);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    if (pool.length > maxGoalsPerDay) pool = pool.sublist(0, maxGoalsPerDay);

    for (var attempt = 0; attempt < maxGoalsPerDay + 1; attempt++) {
      final raw = _waterFill(pool, budget, today);
      final out = <GoalAllocation>[];
      final dropped = <InsightGoal>[];
      for (final g in pool) {
        final base = raw[g.id] ?? 0;
        final native = niceFloor(base * g.nativePerBase);
        final cappedNative = math.min(native, g.remainingNative);
        if (cappedNative <= 0) {
          dropped.add(g);
          continue;
        }
        out.add(GoalAllocation(
          goal: g,
          amountBase: cappedNative / g.nativePerBase,
          amountNative: cappedNative,
          requiredDaily: requiredDaily(g, today),
        ));
      }
      if (dropped.isEmpty || out.isEmpty) {
        if (out.isEmpty && pool.length > 1) {
          // Nothing survived rounding: concentrate on the top goal only.
          pool = [pool.first];
          continue;
        }
        out.sort((a, b) => b.amountBase.compareTo(a.amountBase));
        return out;
      }
      pool = pool.where((g) => !dropped.contains(g)).toList();
    }
    return const [];
  }

  static Map<String, double> _waterFill(
    List<InsightGoal> goals,
    double budget,
    DateTime today,
  ) {
    final cap = <String, double>{};
    final weight = <String, double>{};
    for (final g in goals) {
      final req = requiredDaily(g, today);
      cap[g.id] = math.min(g.remainingBase, req * 1.5);
      weight[g.id] = math.max(req * _urgency(g, today), 1e-9);
    }
    final totalCap = cap.values.fold<double>(0, (s, v) => s + v);
    var remaining = math.min(budget, totalCap);
    final result = <String, double>{};
    var active = goals.map((g) => g.id).toList();
    while (active.isNotEmpty && remaining > 1e-9) {
      final w = active.fold<double>(0, (s, id) => s + weight[id]!);
      final capped = <String>[];
      for (final id in active) {
        final share = remaining * weight[id]! / w;
        if (share >= cap[id]! - 1e-9) capped.add(id);
      }
      if (capped.isEmpty) {
        for (final id in active) {
          result[id] = (result[id] ?? 0) + remaining * weight[id]! / w;
        }
        remaining = 0;
        break;
      }
      for (final id in capped) {
        result[id] = cap[id]!;
        remaining -= cap[id]!;
      }
      active = active.where((id) => !capped.contains(id)).toList();
    }
    return result;
  }

  /// Rounds DOWN to a friendly amount (keeps suggestions within budget).
  static double niceFloor(double x) {
    if (x.isNaN || x <= 0) return 0;
    double step;
    if (x >= 1000) {
      step = 50;
    } else if (x >= 200) {
      step = 10;
    } else if (x >= 20) {
      step = 5;
    } else if (x >= 5) {
      step = 1;
    } else if (x >= 1) {
      step = 0.5;
    } else {
      step = 0.1;
    }
    final v = (x / step + 1e-9).floorToDouble() * step;
    return double.parse(v.toStringAsFixed(2));
  }

  // ── Budgets ───────────────────────────────────────────────

  static List<BudgetAlert> budgetAlerts(
      List<InsightBudget> budgets, DateTime now) {
    final out = <BudgetAlert>[];
    for (final b in budgets) {
      if (b.total <= 0) continue;
      if (b.end != null && now.isAfter(b.end!)) continue;
      if (b.start != null && now.isBefore(b.start!)) continue;
      final usage = b.spent / b.total;
      BudgetAlertLevel? level;
      if (b.spent > b.total) {
        level = BudgetAlertLevel.over;
      } else if (usage >= 0.9) {
        level = BudgetAlertLevel.nearing;
      } else if (b.start != null && b.end != null && usage >= 0.5) {
        final len = b.end!.difference(b.start!).inMinutes;
        if (len > 0) {
          final elapsed = now.difference(b.start!).inMinutes / len;
          if (usage >= elapsed + 0.25) level = BudgetAlertLevel.pacing;
        }
      }
      if (level != null) {
        out.add(BudgetAlert(budget: b, level: level, usage: usage));
      }
      for (final c in b.categories) {
        if (c.allocated > 0 && c.spent > c.allocated) {
          out.add(BudgetAlert(
            budget: b,
            category: c,
            level: BudgetAlertLevel.over,
            usage: c.spent / c.allocated,
          ));
        }
      }
    }
    out.sort((a, b) {
      final c = b.level.index.compareTo(a.level.index);
      return c != 0 ? c : b.usage.compareTo(a.usage);
    });
    return out;
  }

  // ── Habits ────────────────────────────────────────────────

  /// Consecutive days (ending today, or yesterday if nothing yet today)
  /// with at least one logged transaction.
  static int loggingStreak(List<InsightTx> txs, DateTime today) {
    final days = <DateTime>{};
    for (final t in txs) {
      days.add(_day(t.date));
      if (t.createdAt != null) days.add(_day(t.createdAt!));
    }
    var d = _day(today);
    if (!days.contains(d)) d = d.subtract(const Duration(days: 1));
    var n = 0;
    while (days.contains(d) && n < 365) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  /// The hour the user is usually in the app logging money (smoothed
  /// histogram of execution times), clamped to a polite 08:00–22:00.
  /// Fewer than 5 samples → 20:00.
  static int detectPeakHour(List<DateTime> loggedAt) {
    if (loggedAt.length < 5) return fallbackPeakHour;
    final hist = List<double>.filled(24, 0);
    for (final t in loggedAt) {
      hist[t.hour] += 1;
    }
    var best = fallbackPeakHour;
    var bestScore = -1.0;
    for (var h = 0; h < 24; h++) {
      final s =
          hist[h] + 0.5 * hist[(h + 23) % 24] + 0.5 * hist[(h + 1) % 24];
      // Ties resolve to the later hour (end-of-day review feels natural).
      if (s >= bestScore) {
        bestScore = s;
        best = h;
      }
    }
    return best.clamp(earliestHour, latestHour);
  }

  // ── Event-driven ──────────────────────────────────────────

  /// Accounts at or below zero, in a stable order (the device's own
  /// low-balance heads-up; the server no longer reads Personal balances).
  static List<InsightAccount> lowAccounts(SaraInsightInput input) =>
      input.accounts.where((a) => a.balance <= 0).toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  /// Decides whether [tx] (a just-added expense) deserves an instant
  /// heads-up. Budget overruns are reported by the caller through
  /// [newlyOverBudgets]; this adds the "unusually big expense" check.
  static InstantAlert? detectInstant({
    required SaraInsightInput input,
    required InsightTx tx,
    List<BudgetAlert> newlyOverBudgets = const [],
  }) {
    for (final a in newlyOverBudgets) {
      if (a.level == BudgetAlertLevel.over) {
        return InstantAlert(kind: 'budgetOver', budgetAlert: a, tx: tx);
      }
    }
    if (!tx.isSpending) return null;
    final today = _day(input.now);
    final windowStart = today.subtract(const Duration(days: windowDays - 1));
    final prior = input.transactions
        .where((t) =>
            t.isSpending &&
            t.id != tx.id &&
            !_day(t.date).isBefore(windowStart))
        .toList();
    if (prior.length < 5) return null; // not enough history to judge
    final analysis = analyze(input);
    final daily = analysis.avgDailyExpense;
    final sameCat = prior
        .where((t) => t.category == tx.category)
        .map((t) => t.amount)
        .toList()
      ..sort();
    if (sameCat.length >= 3) {
      final median = sameCat[sameCat.length ~/ 2];
      if (median > 0 &&
          tx.amount >= median * 3 &&
          tx.amount >= daily * 2) {
        return InstantAlert(kind: 'bigExpense', tx: tx, ratio: tx.amount / median);
      }
      return null;
    }
    if (daily > 0 && tx.amount >= daily * 4) {
      return InstantAlert(kind: 'bigExpense', tx: tx, ratio: tx.amount / daily);
    }
    return null;
  }
}
