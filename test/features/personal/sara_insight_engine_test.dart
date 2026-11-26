import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_daily_planner.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_input_builder.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_insight_engine.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_notice_composer.dart';

// Deterministic fixtures: "today" is 2026-11-25 10:00 local.
final now = DateTime(2026, 11, 25, 10);
DateTime day(int offset, [int hour = 12]) =>
    DateTime(now.year, now.month, now.day + offset, hour);

String tr(String key, [Map<String, dynamic>? p]) =>
    p == null ? key : '$key${p.entries.map((e) => '|${e.key}=${e.value}').join()}';
String money(double a, String c) => '$c ${a.toStringAsFixed(2)}';

int _seq = 0;
InsightTx tx(String type, double amount, DateTime date,
        {String cat = 'Food', DateTime? created, bool toGoal = false}) =>
    InsightTx(
      id: 't${_seq++}',
      type: type,
      amount: amount,
      category: cat,
      date: date,
      createdAt: created ?? date,
      toGoal: toGoal,
    );

/// Salary 9000 on the 1st of Sep/Oct/Nov + 150/day food until yesterday.
List<InsightTx> regularHistory({double daily = 150, int untilOffset = -1}) {
  final out = <InsightTx>[
    tx('income', 9000, DateTime(2026, 9, 1, 9), cat: 'Salary'),
    tx('income', 9000, DateTime(2026, 10, 1, 9), cat: 'Salary'),
    tx('income', 9000, DateTime(2026, 11, 1, 9), cat: 'Salary'),
  ];
  for (var d = DateTime(2026, 9, 1);
      !d.isAfter(day(untilOffset));
      d = d.add(const Duration(days: 1))) {
    out.add(tx('expense', daily, DateTime(d.year, d.month, d.day, 21)));
  }
  return out;
}

InsightGoal goal(String id, double remaining,
        {int? deadlineInDays,
        String currency = 'SAR',
        double nativePerBase = 1,
        double target = 0,
        double current = 0}) =>
    InsightGoal(
      id: id,
      name: 'Goal $id',
      currency: currency,
      remainingBase: remaining,
      remainingNative: remaining * nativePerBase,
      targetNative: target,
      currentNative: current,
      deadline: deadlineInDays == null
          ? null
          : DateTime(now.year, now.month, now.day + deadlineInDays),
    );

SaraInsightInput input({
  List<InsightTx>? txs,
  List<InsightGoal> goals = const [],
  List<InsightBudget> budgets = const [],
  double? liquid,
}) =>
    SaraInsightInput(
      now: now,
      baseCurrency: 'SAR',
      transactions: txs ?? regularHistory(),
      goals: goals,
      budgets: budgets,
      liquidBalance: liquid,
    );

void main() {
  group('income + affordability', () {
    test('monthly cadence detected and daily disposable is income - spend', () {
      final a = SaraInsightEngine.analyze(input());
      expect(a.incomeCadenceDays, 30);
      expect(a.confident, isTrue);
      expect(a.avgDailyIncome, closeTo(27000 / 86, 0.01));
      expect(a.avgDailyExpense, closeTo(85 * 150 / 86, 0.01));
      // 80% of the free daily flow — a safety buffer is always kept.
      const flow = (27000 - 85 * 150) / 86;
      expect(a.affordableToday, closeTo(flow * 0.8, 0.01));
      expect(a.nextIncomeDate, DateTime(2026, 12, 1));
    });

    test('weekly cadence snaps to 7', () {
      expect(
        SaraInsightEngine.incomeCadence([
          DateTime(2026, 11, 1),
          DateTime(2026, 11, 8),
          DateTime(2026, 11, 15),
          DateTime(2026, 11, 22),
        ]),
        7,
      );
      expect(SaraInsightEngine.incomeCadence([DateTime(2026, 11, 1)]), isNull);
    });

    test('single salary in a short history is spread over a full cycle', () {
      final txs = [
        tx('income', 6000, day(-9), cat: 'Salary'),
        for (var i = -9; i < 0; i++) tx('expense', 50, day(i)),
      ];
      final a = SaraInsightEngine.analyze(input(txs: txs));
      // 6000 / 30, NOT 6000 / 10.
      expect(a.avgDailyIncome, closeTo(200, 0.01));
    });

    test('spending >= income → nothing affordable, no goal plan', () {
      final a = SaraInsightEngine.analyze(input(
        txs: regularHistory(daily: 400),
        goals: [goal('a', 5000, deadlineInDays: 60)],
      ));
      expect(a.affordableToday, 0);
      expect(a.allocations, isEmpty);
      // Spending above income mid-month: the month-end outlook warns first
      // (on cooldown it falls back to the "make some room" nudge).
      final p = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money);
      expect(p!.kind, 'projection');
      expect(p.route, '/personal/reports/view?kind=cashflow&period=month');
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true,
          allowed: (k) => !k.startsWith('proj:'),
          tr: tr,
          money: money);
      expect(n!.kind, 'tight');
      expect(n.route, '/personal/savings-detail/a');
    });

    test('low liquid balance caps the suggestion (cash reserve kept)', () {
      final rich = SaraInsightEngine.analyze(input(liquid: 1e7));
      final tight = SaraInsightEngine.analyze(input(liquid: 1500));
      final broke = SaraInsightEngine.analyze(input(liquid: 1000));
      // 1500 − (≈148/day × 7 days × 1.1 reserve) leaves ≈51/day.
      expect(tight.affordableToday, lessThan(rich.affordableToday));
      expect(tight.affordableToday, closeTo((1500 - 85 * 150 / 86 * 7 * 1.1) / 7, 0.01));
      // 1000 cannot even cover the reserve until payday → 0.
      expect(broke.affordableToday, 0);
    });

    test('a heavy spending day lowers today\'s suggestion', () {
      final base = SaraInsightEngine.analyze(input());
      final heavy = SaraInsightEngine.analyze(
          input(txs: [...regularHistory(), tx('expense', 200, day(0, 9))]));
      expect(heavy.affordableToday, lessThan(base.affordableToday));
    });

    test('too little history → not confident, no suggestion', () {
      final a = SaraInsightEngine.analyze(input(
        txs: [tx('income', 5000, day(-1)), tx('expense', 20, day(-1))],
        goals: [goal('a', 1000, deadlineInDays: 30)],
      ));
      expect(a.confident, isFalse);
      expect(a.affordableToday, 0);
      expect(a.allocations, isEmpty);
    });
  });

  group('goal allocation', () {
    test('splits across goals, never exceeds affordable nor remaining', () {
      final a = SaraInsightEngine.analyze(input(goals: [
        goal('car', 10000, deadlineInDays: 100),
        goal('trip', 1000, deadlineInDays: 20),
      ]));
      expect(a.allocations.length, 2);
      expect(a.allocatedTotal, lessThanOrEqualTo(a.affordableToday + 1e-9));
      final trip = a.allocations.firstWhere((x) => x.goal.id == 'trip');
      final car = a.allocations.firstWhere((x) => x.goal.id == 'car');
      // Trip is 10× smaller but due 5× sooner: urgency gives it a share
      // well above its pure pace ratio.
      expect(trip.amountBase / car.amountBase,
          greaterThan(trip.requiredDaily / car.requiredDaily));
      for (final x in a.allocations) {
        expect(x.amountBase, lessThanOrEqualTo(x.goal.remainingBase));
      }
    });

    test('affordability cap holds for any budget', () {
      final goals = [
        goal('a', 50000, deadlineInDays: 10),
        goal('b', 20000, deadlineInDays: 5),
      ];
      for (final budget in [0.5, 3.0, 17.0, 88.0, 999.0]) {
        final out = SaraInsightEngine.allocateGoals(goals, budget, now);
        final total = out.fold<double>(0, (s, x) => s + x.amountBase);
        expect(total, lessThanOrEqualTo(budget + 1e-9), reason: '$budget');
      }
    });

    test('does not push beyond 1.5× the needed pace when budget is large', () {
      final g = goal('a', 3000, deadlineInDays: 29); // 100/day needed
      final out = SaraInsightEngine.allocateGoals([g], 10000, now);
      expect(out.single.amountBase, lessThanOrEqualTo(150));
      expect(out.single.amountBase, greaterThanOrEqualTo(100));
    });

    test('small remaining goal is never over-funded', () {
      final g = goal('a', 7, deadlineInDays: 1);
      final out = SaraInsightEngine.allocateGoals([g], 500, now);
      expect(out.single.amountNative, lessThanOrEqualTo(7));
    });

    test('at most 3 goals per day', () {
      final goals = [
        for (var i = 0; i < 6; i++) goal('g$i', 3000, deadlineInDays: 30 + i),
      ];
      final out = SaraInsightEngine.allocateGoals(goals, 1000, now);
      expect(out.length, lessThanOrEqualTo(3));
    });

    test('tiny budget concentrates on the most urgent goal', () {
      final goals = [
        goal('later', 5000, deadlineInDays: 300),
        goal('soon', 5000, deadlineInDays: 10),
        goal('mid', 5000, deadlineInDays: 100),
      ];
      final out = SaraInsightEngine.allocateGoals(goals, 1.2, now);
      expect(out.length, 1);
      expect(out.single.goal.id, 'soon');
    });

    test('overdue goal outranks one with a far deadline', () {
      final out = SaraInsightEngine.allocateGoals([
        goal('far', 1000, deadlineInDays: 200),
        goal('overdue', 1000, deadlineInDays: -3),
      ], 40, now);
      expect(out.first.goal.id, 'overdue');
    });

    test('amounts are rounded down to friendly numbers', () {
      expect(SaraInsightEngine.niceFloor(67.6), 65);
      expect(SaraInsightEngine.niceFloor(1234), 1200);
      expect(SaraInsightEngine.niceFloor(3.7), 3.5);
      expect(SaraInsightEngine.niceFloor(0.37), closeTo(0.3, 1e-9));
      expect(SaraInsightEngine.niceFloor(-5), 0);
    });

    test('goal in another currency is shown in its own currency', () {
      // 1 USD = 3.75 SAR → remaining 3750 SAR = 1000 USD.
      final usd = goal('usd', 3750,
          deadlineInDays: 40, currency: 'USD', nativePerBase: 1 / 3.75);
      final out = SaraInsightEngine.allocateGoals([usd], 100, now);
      final a = out.single;
      expect(a.amountNative, lessThanOrEqualTo(100 / 3.75));
      expect(a.amountBase, closeTo(a.amountNative * 3.75, 1e-6));
    });

    test('no goals → no goal notification', () {
      final a = SaraInsightEngine.analyze(input());
      expect(a.allocations, isEmpty);
      expect(a.hasActiveGoals, isFalse);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money);
      expect(n?.kind, isNot('plan'));
      expect(n?.kind, isNot('tight'));
    });

    test('plan notice lists goals with amounts and opens the top goal', () {
      final a = SaraInsightEngine.analyze(input(goals: [
        goal('car', 10000, deadlineInDays: 100),
        goal('trip', 1000, deadlineInDays: 20),
      ]));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'plan');
      expect(n.body, startsWith('saraNotifPlanTwo'));
      expect(n.route, '/personal/savings-detail/${a.allocations.first.goal.id}');
      // Not logged today → gentle second line.
      expect(n.body, contains('\nsaraNotifLogSuffix'));
    });
  });

  group('spending level', () {
    test('high spending vs own baseline is flagged with the top category', () {
      final txs = [
        ...regularHistory(untilOffset: -8),
        for (var i = -7; i < 0; i++) tx('expense', 150, day(i, 20)),
        for (var i = -7; i < 0; i++)
          tx('expense', 250, day(i, 21), cat: 'Shopping'),
      ];
      final a = SaraInsightEngine.analyze(input(txs: txs));
      expect(a.spendLevel, SpendLevel.high);
      expect(a.topCategory, 'Shopping');
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'spendHigh');
      expect(n.route, SaraRoutes.spendingReport);
      expect(n.body, contains('category=Shopping'));
    });

    test('high spending warning is skipped while on cooldown', () {
      final txs = [
        ...regularHistory(untilOffset: -8),
        for (var i = -7; i < 0; i++) tx('expense', 600, day(i, 20)),
      ];
      final a = SaraInsightEngine.analyze(input(txs: txs));
      expect(a.spendLevel, SpendLevel.high);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true,
          allowed: (k) => k != 'spend:high',
          tr: tr,
          money: money);
      expect(n?.kind, isNot('spendHigh'));
    });

    test('low spending while still logging is praised', () {
      final txs = [
        ...regularHistory(untilOffset: -8),
        for (var i = -7; i <= 0; i++) tx('expense', 40, day(i, 9)),
      ];
      final a = SaraInsightEngine.analyze(input(txs: txs));
      expect(a.spendLevel, SpendLevel.low);
      expect(a.loggedToday, isTrue);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'spendLow');
    });

    test('no logs this week is NOT "low spending"', () {
      final a =
          SaraInsightEngine.analyze(input(txs: regularHistory(untilOffset: -8)));
      expect(a.spendLevel, isNot(SpendLevel.low));
    });

    test('not enough baseline → unknown, never a warning', () {
      final txs = [for (var i = -10; i < 0; i++) tx('expense', 100, day(i))];
      final a = SaraInsightEngine.analyze(input(txs: txs));
      expect(a.spendLevel, SpendLevel.unknown);
    });
  });

  group('log reminder', () {
    test('not logged today → log reminder routes to quick add', () {
      final a = SaraInsightEngine.analyze(input());
      expect(a.loggedToday, isFalse);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'log');
      expect(n.route, '/personal/quick-add?type=expense');
    });

    test('already logged today → no log reminder', () {
      final a = SaraInsightEngine.analyze(
          input(txs: [...regularHistory(), tx('expense', 150, day(0, 9))]));
      expect(a.loggedToday, isTrue);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money);
      expect(n?.kind, isNot('log'));
      expect(n?.body ?? '', isNot(contains('saraNotifLogSuffix')));
    });

    test('a backdated row entered today still counts as logged today', () {
      final a = SaraInsightEngine.analyze(input(txs: [
        ...regularHistory(),
        tx('expense', 10, day(-3), created: day(0, 8)),
      ]));
      expect(a.loggedToday, isTrue);
    });
  });

  group('peak hour', () {
    test('most frequent logging hour wins', () {
      final ts = [
        for (var i = 0; i < 6; i++) DateTime(2026, 11, 1 + i, 21, 15),
        for (var i = 0; i < 2; i++) DateTime(2026, 11, 10 + i, 13),
      ];
      expect(SaraInsightEngine.detectPeakHour(ts), 21);
    });

    test('fewer than 5 samples → 20:00 fallback', () {
      expect(SaraInsightEngine.detectPeakHour([DateTime(2026, 1, 1, 7)]), 20);
    });

    test('night owls are clamped to a polite hour', () {
      final ts = [for (var i = 0; i < 8; i++) DateTime(2026, 11, 1 + i, 3)];
      expect(SaraInsightEngine.detectPeakHour(ts), 8);
      final late = [for (var i = 0; i < 8; i++) DateTime(2026, 11, 1 + i, 23)];
      expect(SaraInsightEngine.detectPeakHour(late), 22);
    });

    test('analysis reads the peak from execution timestamps', () {
      expect(SaraInsightEngine.analyze(input()).peakHour, 21);
    });
  });

  group('budgets', () {
    test('over / nearing / pacing / category over', () {
      final alerts = SaraInsightEngine.budgetAlerts([
        const InsightBudget(
            id: 'over', name: 'Over', currency: 'SAR', total: 100, spent: 120),
        const InsightBudget(
            id: 'near', name: 'Near', currency: 'SAR', total: 100, spent: 92),
        InsightBudget(
          id: 'pace',
          name: 'Pace',
          currency: 'SAR',
          total: 1000,
          spent: 700,
          start: DateTime(2026, 11, 20),
          end: DateTime(2026, 12, 20),
        ),
        const InsightBudget(
          id: 'fine',
          name: 'Fine',
          currency: 'SAR',
          total: 1000,
          spent: 100,
          categories: [
            InsightBudgetCategory(
                id: 'c1', name: 'Cafe', allocated: 50, spent: 80),
          ],
        ),
        InsightBudget(
          id: 'expired',
          name: 'Old',
          currency: 'SAR',
          total: 10,
          spent: 99,
          end: DateTime(2026, 10, 1),
        ),
      ], now);
      final keys = alerts.map((a) => a.key).toList();
      expect(keys, contains('budget:over:over'));
      expect(keys, contains('budget:near:nearing'));
      expect(keys, contains('budget:pace:pacing'));
      expect(keys, contains('bcat:fine:c1:over'));
      expect(keys.any((k) => k.contains('expired')), isFalse);
      expect(alerts.first.level, BudgetAlertLevel.over);
    });

    test('budget warning takes priority and opens the budget page', () {
      final a = SaraInsightEngine.analyze(input(budgets: [
        const InsightBudget(
            id: 'b1', name: 'Monthly', currency: 'SAR', total: 100, spent: 150),
      ]));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'budget');
      expect(n.route, '/personal/budget/detail?id=b1');
      expect(n.cooldownKey, 'budget:b1:over');
    });

    test('warnings only in the first slot (fresh data)', () {
      final a = SaraInsightEngine.analyze(input(budgets: [
        const InsightBudget(
            id: 'b1', name: 'Monthly', currency: 'SAR', total: 100, spent: 150),
      ]));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: false, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, isNot('budget'));
    });
  });

  group('instant alerts', () {
    test('unusually big expense in a category triggers', () {
      final big = tx('expense', 900, day(0, 10));
      final i = input(txs: [...regularHistory(), big]);
      final alert = SaraInsightEngine.detectInstant(input: i, tx: big);
      expect(alert, isNotNull);
      expect(alert!.kind, 'bigExpense');
      final n = SaraNoticeComposer.instant(alert,
          baseCurrency: 'SAR', tr: tr, money: money);
      expect(n.route, SaraRoutes.spendingReport);
      expect(n.title, 'saraNotifBigTitle');
    });

    test('a usual-size expense does not', () {
      final t = tx('expense', 160, day(0, 10));
      final i = input(txs: [...regularHistory(), t]);
      expect(SaraInsightEngine.detectInstant(input: i, tx: t), isNull);
    });

    test('income / goal deposits never trigger', () {
      final dep = tx('expense', 5000, day(0, 10), toGoal: true);
      final i = input(txs: [...regularHistory(), dep]);
      expect(SaraInsightEngine.detectInstant(input: i, tx: dep), isNull);
    });

    test('newly over budget wins and opens the budget', () {
      final t = tx('expense', 160, day(0, 10));
      const b = InsightBudget(
          id: 'b9', name: 'Food', currency: 'SAR', total: 100, spent: 160);
      final alert = SaraInsightEngine.detectInstant(
        input: input(txs: [...regularHistory(), t]),
        tx: t,
        newlyOverBudgets: [
          const BudgetAlert(budget: b, level: BudgetAlertLevel.over, usage: 1.6)
        ],
      )!;
      expect(alert.kind, 'budgetOver');
      final n = SaraNoticeComposer.instant(alert,
          baseCurrency: 'SAR', tr: tr, money: money);
      expect(n.route, '/personal/budget/detail?id=b9');
    });

    test('big-expense key is content based (survives server re-keying)', () {
      final a = InstantAlert(
          kind: 'bigExpense', tx: tx('expense', 900, day(0, 10)));
      final b = InstantAlert(
          kind: 'bigExpense', tx: tx('expense', 900, day(0, 10)));
      expect(a.key, b.key);
    });
  });

  group('input builder (multi-currency)', () {
    test('converts to base, skips transfers + unconvertible rows', () {
      double? convert(double a, String from, String to) =>
          from == 'USD' && to == 'SAR' ? a * 3.75 : null;
      final i = SaraInsightInputBuilder.build(
        now: now,
        baseCurrency: 'SAR',
        transactions: [
          PersonalTransaction(
              id: '1', type: 'expense', amount: 10, category: 'Food',
              currency: 'USD', date: day(-1)),
          PersonalTransaction(
              id: '2', type: 'transfer_out', amount: 99, category: 'x',
              currency: 'SAR', date: day(-1)),
          PersonalTransaction(
              id: '3', type: 'expense', amount: 5, category: 'Food',
              currency: 'EUR', date: day(-1)),
          PersonalTransaction(
              id: '4', type: 'expense', amount: 50, category: 'Goal',
              currency: 'SAR', date: day(-1), goalId: 'g1'),
        ],
        goals: [
          SavingsGoal(
              id: 'g1', name: 'Car', targetAmount: 1000, currentAmount: 200,
              currency: 'USD', deadline: '2027-01-31'),
          SavingsGoal(
              id: 'g2', name: 'Done', targetAmount: 10, currentAmount: 10),
          SavingsGoal(
              id: 'g3', name: 'Euro', targetAmount: 100, currency: 'EUR'),
        ],
        convert: convert,
      );
      expect(i.transactions.map((t) => t.id), ['1', '4']);
      expect(i.transactions.first.amount, 37.5);
      expect(i.transactions.last.toGoal, isTrue);
      expect(i.goals.single.id, 'g1');
      expect(i.goals.single.remainingBase, 3000);
      expect(i.goals.single.remainingNative, 800);
      expect(i.goals.single.deadline, DateTime(2027, 1, 31));
    });
  });

  group('daily planner', () {
    test('one digest per day for the next 3 days at the chosen time', () {
      final slots = SaraDailyPlanner.plan(
        days: 3,
        input: input(goals: [goal('a', 3000, deadlineInDays: 60)]),
        now: now,
        minutesOfDay: 20 * 60 + 30,
        lastFiredDay: null,
        cooldown: const {},
        tr: tr,
        money: money,
      );
      expect(slots.map((s) => s.dayKey), ['20261125', '20261126', '20261127']);
      expect(slots.first.fireAt, DateTime(2026, 11, 25, 20, 30));
      expect(slots.every((s) => s.notice.kind == 'plan'), isTrue);
    });

    test('time already passed today → starts tomorrow', () {
      final slots = SaraDailyPlanner.plan(
        input: input(),
        now: now,
        minutesOfDay: 8 * 60,
        lastFiredDay: null,
        cooldown: const {},
        tr: tr,
        money: money,
      );
      expect(slots.first.dayKey, '20261126');
    });

    test('a day that already fired is never scheduled again', () {
      final slots = SaraDailyPlanner.plan(
        input: input(),
        now: now,
        minutesOfDay: 22 * 60,
        lastFiredDay: '20261125',
        cooldown: const {},
        tr: tr,
        money: money,
      );
      expect(slots.any((s) => s.dayKey == '20261125'), isFalse);
    });

    test('same warning is not repeated within the cooldown', () {
      final budgets = [
        const InsightBudget(
            id: 'b1', name: 'M', currency: 'SAR', total: 100, spent: 150),
      ];
      final cd = {'budget:b1:over': const SaraCooldownEntry('20261124', 'digest')};
      final slots = SaraDailyPlanner.plan(
        input: input(budgets: budgets),
        now: now,
        minutesOfDay: 21 * 60,
        lastFiredDay: '20261124',
        cooldown: cd,
        tr: tr,
        money: money,
      );
      expect(slots.first.notice.kind, isNot('budget'));
      // 3 days later it may come back.
      expect(
          SaraDailyPlanner.cooldownAllows(cd, 'budget:b1:over', '20261127'),
          isTrue);
      // An instant alert today blocks today's digest repeating it.
      expect(
          SaraDailyPlanner.cooldownAllows(
              {'k': const SaraCooldownEntry('20261125', 'instant')},
              'k',
              '20261125'),
          isFalse);
    });

    test('reserve releases un-fired reservations and records new ones', () {
      final slot = SaraSlot(
        fireAt: DateTime(2026, 11, 25, 21),
        dayKey: '20261125',
        notice: const SaraNotice(
            kind: 'budget', title: 't', body: 'b', route: '/r',
            cooldownKey: 'budget:x:over'),
      );
      final out = SaraDailyPlanner.reserve({
        'spend:high': const SaraCooldownEntry('20261125', 'digest'),
        'old': const SaraCooldownEntry('20261001', 'digest'),
        'past': const SaraCooldownEntry('20261123', 'digest'),
      }, [slot], now: now, lastFiredDay: '20261124');
      expect(out.containsKey('spend:high'), isFalse); // re-planned
      expect(out.containsKey('old'), isFalse); // > 30 days
      expect(out['past']?.day, '20261123'); // delivered: kept
      expect(out['budget:x:over']?.day, '20261125');
    });
  });

  group('smarter money nudges', () {
    InsightObligation bill(String id, double amount, int inDays,
            {String kind = 'recurring', bool reminded = false}) =>
        InsightObligation(
          id: id,
          kind: kind,
          name: 'Bill $id',
          amountBase: amount,
          amountNative: amount,
          currency: 'SAR',
          due: DateTime(now.year, now.month, now.day + inDays),
          reminded: reminded,
        );

    SaraInsightInput withExtras({
      List<InsightTx>? txs,
      List<InsightGoal> goals = const [],
      double? liquid,
      List<InsightObligation> obligations = const [],
      List<InsightRecurring> recurring = const [],
      List<InsightIncomeEvent> scheduled = const [],
    }) =>
        SaraInsightInput(
          now: now,
          baseCurrency: 'SAR',
          transactions: txs ?? regularHistory(),
          goals: goals,
          liquidBalance: liquid,
          obligations: obligations,
          recurring: recurring,
          scheduledIncomes: scheduled,
        );

    test('monthly payday steps by calendar month (same day-of-month)', () {
      final txs = [
        for (final m in [8, 9, 10])
          tx('income', 9000, DateTime(2026, m, 26, 9), cat: 'Salary'),
        for (var d = DateTime(2026, 8, 26); d.isBefore(day(0));
            d = d.add(const Duration(days: 1)))
          tx('expense', 150, DateTime(d.year, d.month, d.day, 21)),
      ];
      final a = SaraInsightEngine.analyze(withExtras(txs: txs));
      expect(a.incomeCadenceDays, 30);
      expect(a.nextIncomeDate, DateTime(2026, 11, 26));
      expect(a.daysUntilNextIncome, 1);
    });

    test('one-off small incomes never skew the payday cadence', () {
      final txs = [
        ...regularHistory(),
        for (final d in [5, 10, 15, 20])
          tx('income', 100, DateTime(2026, 11, d, 12), cat: 'Gift'),
      ];
      final a = SaraInsightEngine.analyze(withExtras(txs: txs));
      expect(a.incomeCadenceDays, 30);
      expect(a.nextIncomeDate, DateTime(2026, 12, 1));
    });

    test('a scheduled (recurring) income defines the next payday', () {
      final a = SaraInsightEngine.analyze(withExtras(
          scheduled: [InsightIncomeEvent(DateTime(2026, 11, 28), 9000)]));
      expect(a.nextIncomeDate, DateTime(2026, 11, 28));
      expect(a.daysUntilNextIncome, 3);
    });

    test('bills due before payday reduce what can be saved', () {
      final free = SaraInsightEngine.analyze(withExtras(liquid: 2500));
      final billed = SaraInsightEngine.analyze(
          withExtras(liquid: 2500, obligations: [bill('r1', 1500, 3)]));
      expect(billed.obligationsBeforePayday, 1500);
      expect(billed.affordableToday, lessThan(free.affordableToday));
      expect(billed.billRisk, isNull); // 2500 still covers the bill itself
    });

    test('a bill the balance cannot cover is the top warning', () {
      final a = SaraInsightEngine.analyze(withExtras(
        liquid: 1200,
        goals: [goal('g', 5000, deadlineInDays: 60)],
        obligations: [bill('r1', 1000, 2)],
      ));
      expect(a.billRisk, isNotNull);
      expect(a.billRisk!.obligation.id, 'r1');
      expect(a.affordableToday, 0);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'bill');
      expect(n.title, 'saraNotifBillTitle');
      expect(n.body, contains('when=saraNotifWhenTwoDays'));
      expect(n.route, '/personal/recurring/detail?id=r1');
      expect(n.cooldownKey, 'bill:recurring:r1:20261127');
      // Same bill on cooldown → it is not repeated.
      final again = SaraNoticeComposer.digest(a,
          firstSlot: true,
          allowed: (k) => !k.startsWith('bill:'),
          tr: tr,
          money: money)!;
      expect(again.kind, isNot('bill'));
    });

    test('debt due tomorrow without a reminder → nudge opens the debt', () {
      final a = SaraInsightEngine.analyze(withExtras(
          obligations: [bill('d1', 700, 1, kind: 'debt')]));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'debt');
      expect(n.body, startsWith('saraNotifDebtDue'));
      expect(n.body, contains('when=saraNotifWhenTomorrow'));
      expect(n.route, '/personal/debts?debtId=d1');
      // The user's own debt alarm already covers it → Sara stays quiet.
      final quiet = SaraInsightEngine.analyze(withExtras(
          obligations: [bill('d1', 700, 1, kind: 'debt', reminded: true)]));
      expect(quiet.debtsDue, isEmpty);
    });

    test('overdue debt uses the overdue wording', () {
      final a = SaraInsightEngine.analyze(withExtras(
          obligations: [bill('d2', 300, -4, kind: 'debt')]));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'debt');
      expect(n.body, startsWith('saraNotifDebtOverdue'));
      expect(n.body, contains('n=4'));
      expect(n.cooldownKey, 'debt:late:d2');
    });

    test('month-end outlook praises a healthy month (late in the month)', () {
      final a = SaraInsightEngine.analyze(withExtras(
          txs: [...regularHistory(), tx('expense', 150, day(0, 9))]));
      expect(a.projection, isNotNull);
      expect(a.projection!.net, greaterThan(0));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'projection');
      expect(n.body, startsWith('saraNotifProjGood'));
      expect(n.cooldownKey, 'proj:good:202611');
    });

    test('payday: pay yourself first, capped by the pay after spending', () {
      final txs = [
        for (final m in [8, 9, 10])
          tx('income', 9000, DateTime(2026, m, 25, 9), cat: 'Salary'),
        for (var d = DateTime(2026, 8, 25); d.isBefore(day(0));
            d = d.add(const Duration(days: 1)))
          tx('expense', 150, DateTime(d.year, d.month, d.day, 21)),
      ];
      final a = SaraInsightEngine.analyze(withExtras(
          txs: txs, goals: [goal('g', 5000, deadlineInDays: 60)]));
      expect(a.isPayday, isTrue);
      expect(a.paydaySave, greaterThan(0));
      // Never more than 80% of what the pay leaves after a cycle of spending.
      expect(a.paydaySave, lessThanOrEqualTo((9000 - 150 * 30 * 1.1) * 0.8));
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true, allowed: (_) => true, tr: tr, money: money)!;
      expect(n.kind, 'payday');
      expect(n.body, startsWith('saraNotifPaydayGoals'));
      expect(n.route, '/personal/savings-detail/g');
      expect(n.cooldownKey, 'payday:20261125');
    });

    test('a forgotten monthly charge is spotted unless it is a rule', () {
      InsightTx netflix(DateTime d) => InsightTx(
            id: 'n${d.month}',
            type: 'expense',
            amount: 45,
            category: 'Entertainment',
            date: d,
            note: 'Netflix',
          );
      final txs = [
        ...regularHistory(),
        tx('expense', 150, day(0, 9)),
        for (final m in [9, 10, 11]) netflix(DateTime(2026, m, 10, 8)),
      ];
      final a = SaraInsightEngine.analyze(withExtras(txs: txs));
      expect(a.subscriptions.map((h) => h.label), ['Netflix']);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true,
          allowed: (k) => !k.startsWith('proj:'),
          tr: tr,
          money: money)!;
      expect(n.kind, 'subscription');
      expect(n.route, '/personal/recurring');
      final known = SaraInsightEngine.analyze(withExtras(txs: txs, recurring: [
        const InsightRecurring(
            id: 'r',
            name: 'Netflix',
            category: 'Entertainment',
            isIncome: false,
            amountBase: 45,
            monthlyBase: 45),
      ]));
      expect(known.subscriptions, isEmpty);
    });

    test('no-spend streak only counts for active daily loggers', () {
      final txs = [
        ...regularHistory(untilOffset: -4),
        tx('income', 50, day(0, 9), cat: 'Gift'),
      ];
      final a = SaraInsightEngine.analyze(withExtras(txs: txs));
      expect(a.noSpendDays, 3);
      final n = SaraNoticeComposer.digest(a,
          firstSlot: true,
          allowed: (k) => k == 'nospend',
          tr: tr,
          money: money)!;
      expect(n.kind, 'noSpend');
      expect(n.body, contains('n=3'));
      // Nothing logged lately → silence is missing data, not a streak.
      final idle = SaraInsightEngine.analyze(
          withExtras(txs: regularHistory(untilOffset: -4)));
      expect(idle.noSpendDays, 0);
    });

    test('rare insights have longer quiet periods', () {
      expect(SaraDailyPlanner.cooldownFor('subs:x'), 45);
      expect(SaraDailyPlanner.cooldownFor('proj:short:202611'), 7);
      expect(SaraDailyPlanner.cooldownFor('nospend'), 7);
      expect(SaraDailyPlanner.cooldownFor('budget:x:over'), 3);
      final cd = {'subs:x': const SaraCooldownEntry('20261101', 'digest')};
      expect(SaraDailyPlanner.cooldownAllows(cd, 'subs:x', '20261125'), isFalse);
      expect(SaraDailyPlanner.cooldownAllows(cd, 'subs:x', '20261220'), isTrue);
    });

    test('builder maps recurring bills, incomes and debts (converted)', () {
      double? convert(double a, String from, String to) =>
          from == 'USD' && to == 'SAR' ? a * 3.75 : null;
      final i = SaraInsightInputBuilder.build(
        now: now,
        baseCurrency: 'SAR',
        transactions: const [],
        goals: const [],
        recurring: [
          RecurringTransaction(
              id: 'net', name: 'Internet', type: 'expense', amount: 20,
              category: 'Bills', currency: 'USD',
              nextDate: DateTime(2026, 11, 27)),
          RecurringTransaction(
              id: 'sal', name: 'Salary', type: 'income', amount: 9000,
              category: 'Salary', nextDate: DateTime(2026, 12, 1)),
          RecurringTransaction(
              id: 'off', type: 'expense', amount: 5, category: 'x',
              isActive: false, nextDate: DateTime(2026, 11, 26)),
        ],
        debts: [
          PersonalDebt(
              id: 'd1', type: 'payable', personName: 'Ali', amount: 500,
              paid: 200, dueDate: DateTime(2026, 11, 26)),
          PersonalDebt(
              id: 'd2', type: 'receivable', personName: 'Sami', amount: 80,
              dueDate: DateTime(2026, 11, 25)),
          PersonalDebt(
              id: 'd3', type: 'payable', personName: 'Paid', amount: 80,
              isPaid: true, dueDate: DateTime(2026, 11, 25)),
        ],
        convert: convert,
      );
      expect(i.recurring.map((r) => r.id), ['net', 'sal']);
      final internet = i.obligations.where((o) => o.id == 'net').toList();
      expect(internet.first.amountBase, 75);
      expect(internet.first.due, DateTime(2026, 11, 27));
      expect(internet.length, greaterThanOrEqualTo(2)); // Nov 27 + Dec 27
      expect(i.scheduledIncomes.first.date, DateTime(2026, 12, 1));
      final debt = i.obligations.firstWhere((o) => o.id == 'd1');
      expect(debt.kind, 'debt');
      expect(debt.amountNative, 300);
      expect(i.obligations.firstWhere((o) => o.id == 'd2').kind, 'debtIn');
      expect(i.obligations.any((o) => o.id == 'd3'), isFalse);
    });
  });
}
