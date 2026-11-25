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

class SaraInsightInput {
  final DateTime now;
  final String baseCurrency;
  final List<InsightTx> transactions;
  final List<InsightGoal> goals;
  final List<InsightBudget> budgets;

  /// Liquid balance (banks + cash) in base currency, null when unknown.
  final double? liquidBalance;

  const SaraInsightInput({
    required this.now,
    required this.baseCurrency,
    this.transactions = const [],
    this.goals = const [],
    this.budgets = const [],
    this.liquidBalance,
  });

  SaraInsightInput atTime(DateTime t) => SaraInsightInput(
        now: t,
        baseCurrency: baseCurrency,
        transactions: transactions,
        goals: goals,
        budgets: budgets,
        liquidBalance: liquidBalance,
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
  /// 'bigExpense' | 'budgetOver'
  final String kind;
  final InsightTx? tx;
  final BudgetAlert? budgetAlert;
  final double ratio;
  const InstantAlert({
    required this.kind,
    this.tx,
    this.budgetAlert,
    this.ratio = 0,
  });

  String get key {
    if (budgetAlert != null) return 'instant:${budgetAlert!.key}';
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

    // Income + cadence.
    final incomes = txs.where((t) => t.isIncome).toList();
    final incomeSum = incomes.fold<double>(0, (s, t) => s + t.amount);
    final cadence = incomeCadence(incomes.map((t) => t.date).toList());
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

    DateTime? nextIncome;
    var daysUntilIncome = 30;
    if (incomes.isNotEmpty) {
      final last = incomes
          .map((t) => _day(t.date))
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final step = cadence ?? 30;
      var n = last.add(Duration(days: step));
      while (!n.isAfter(today)) {
        n = n.add(Duration(days: step));
      }
      nextIncome = n;
      daysUntilIncome = math.max(1, _daysBetween(today, n));
    }

    // Today.
    final todayTxs = input.transactions.where((t) =>
        _day(t.date) == today ||
        (t.createdAt != null && _day(t.createdAt!) == today));
    final loggedToday = todayTxs.isNotEmpty;
    final todayExpense = input.transactions
        .where((t) => t.isSpending && _day(t.date) == today)
        .fold<double>(0, (s, t) => s + t.amount);

    // Affordability — the hard ceiling for any goal suggestion.
    final affordable = _affordableToday(
      confident: confident,
      hasIncome: incomes.isNotEmpty,
      avgDailyIncome: avgDailyIncome,
      avgDailyExpense: avgDailyExpense,
      liquid: input.liquidBalance,
      daysUntilIncome: daysUntilIncome,
      todayExpense: todayExpense,
    );

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
    );
  }

  static double _affordableToday({
    required bool confident,
    required bool hasIncome,
    required double avgDailyIncome,
    required double avgDailyExpense,
    required double? liquid,
    required int daysUntilIncome,
    required double todayExpense,
  }) {
    if (!confident) return 0;
    double? flow;
    if (hasIncome) {
      flow = math.max(0, avgDailyIncome - avgDailyExpense) * flowSafety;
    }
    double? cashCap;
    if (liquid != null) {
      final horizon = math.max(daysUntilIncome, 7);
      // Keep enough to cover usual spending until the next income + 10%.
      final reserve = avgDailyExpense * horizon * 1.1;
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
