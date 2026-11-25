import 'dart:math' as math;

import 'sara_insight_engine.dart';

// ─────────────────────────────────────────────────────────────
// SaraNoticeComposer — turns a SaraAnalysis into ONE short, friendly
// notification (title + 1–2 lines) in Sara's voice. Pure: the l10n
// lookup and the money formatter are injected, so tests run without
// Flutter. All copy lives in the ARB files (saraNotif* keys).
//
// Tidy-by-design rules:
//  - one digest per day, a single primary topic, picked by priority;
//  - warnings (budget / high spend / tight budget) only in the first
//    upcoming slot (fresh data) and never the same warning again within
//    the cooldown (the caller owns the persisted cooldown map);
//  - no goals → never a goal suggestion; nothing worth saying → null.
// ─────────────────────────────────────────────────────────────

typedef SaraTr = String Function(String key, [Map<String, dynamic>? params]);
typedef SaraMoney = String Function(double amount, String currency);

class SaraNotice {
  /// plan | tight | budget | spendHigh | spendLow | log | encourage |
  /// bigExpense | budgetOver | bill | debt | collect | projection |
  /// goalDue | payday | subscription | noSpend
  final String kind;
  final String title;
  final String body;

  /// Absolute app route opened on tap (NotificationRouter passes it as-is).
  final String route;

  /// Cooldown identity for warnings / encouragement (null = no cooldown).
  final String? cooldownKey;

  const SaraNotice({
    required this.kind,
    required this.title,
    required this.body,
    required this.route,
    this.cooldownKey,
  });
}

class SaraRoutes {
  SaraRoutes._();
  static String goal(String id) => '/personal/savings-detail/$id';
  static const String goals = '/personal/savings';
  static String budget(String id) => '/personal/budget/detail?id=$id';
  static const String spendingReport =
      '/personal/reports/view?kind=categories&period=week';
  static const String quickAddExpense = '/personal/quick-add?type=expense';
  static const String transactions = '/personal/transactions';
  static String recurring(String id) => '/personal/recurring/detail?id=$id';
  static String debt(String id) => '/personal/debts?debtId=$id';
  static const String monthReport =
      '/personal/reports/view?kind=cashflow&period=month';
  static const String recurringList = '/personal/recurring';
  static const String banks = '/personal/banks';
}

/// Day keys for cooldown identities (yyyymmdd).
class SaraDailyKeys {
  SaraDailyKeys._();
  static String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
}

class SaraNoticeComposer {
  SaraNoticeComposer._();

  static String _pct(double ratio) => (ratio * 100).round().abs().toString();

  static DateTime _d(DateTime d) => DateTime(d.year, d.month, d.day);

  /// «today» / «tomorrow» / «in 2 days» / «in N days», or the overdue days.
  static String _when(DateTime due, DateTime now, SaraTr tr) {
    final n = _d(due).difference(_d(now)).inHours ~/ 24;
    if (n <= 0) return tr('saraNotifWhenToday');
    if (n == 1) return tr('saraNotifWhenTomorrow');
    if (n == 2) return tr('saraNotifWhenTwoDays');
    return tr('saraNotifWhenDays', {'n': n});
  }

  static String _ym(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}';

  /// Daily digest for one slot. [firstSlot] = the next notification to
  /// fire (built from fresh data); later slots are pre-scheduled backups
  /// so Sara still shows up if the app is not opened, and only carry
  /// plan / log reminder / encouragement content.
  static SaraNotice? digest(
    SaraAnalysis a, {
    required bool firstSlot,
    required bool Function(String cooldownKey) allowed,
    required SaraTr tr,
    required SaraMoney money,
  }) {
    final base = a.baseCurrency;
    SaraNotice? primary;

    if (firstSlot) {
      // 1. A bill the balance cannot cover before payday — most useful.
      final risk = a.billRisk;
      if (risk != null) {
        final o = risk.obligation;
        final k = 'bill:${o.kind}:${o.id}:${SaraDailyKeys.day(o.due)}';
        if (allowed(k)) {
          primary = SaraNotice(
            kind: 'bill',
            title: tr('saraNotifBillTitle'),
            body: tr('saraNotifBillShort', {
              'name': o.name,
              'amount': money(o.amountNative, o.currency),
              'when': _when(o.due, a.now, tr),
              'short': money(_roundUp(risk.shortBy), base),
            }),
            route: o.kind == 'recurring'
                ? SaraRoutes.recurring(o.id)
                : SaraRoutes.debt(o.id),
            cooldownKey: k,
          );
        }
      }
      // 2. A debt to pay (due soon / overdue) the user set no reminder for.
      if (primary == null) {
        for (final o in a.debtsDue) {
          final overdue = _d(a.now).difference(_d(o.due)).inHours ~/ 24;
          final k = overdue > 0
              ? 'debt:late:${o.id}'
              : 'debt:due:${o.id}:${SaraDailyKeys.day(o.due)}';
          if (!allowed(k)) continue;
          primary = SaraNotice(
            kind: 'debt',
            title: tr('saraNotifDebtTitle'),
            body: overdue > 0
                ? tr('saraNotifDebtOverdue', {
                    'name': o.name,
                    'amount': money(o.amountNative, o.currency),
                    'n': overdue,
                  })
                : tr('saraNotifDebtDue', {
                    'name': o.name,
                    'amount': money(o.amountNative, o.currency),
                    'when': _when(o.due, a.now, tr),
                  }),
            route: SaraRoutes.debt(o.id),
            cooldownKey: k,
          );
          break;
        }
      }
      if (primary == null) {
        for (final b in a.budgetAlerts) {
          if (!allowed(b.key)) continue;
          primary = _budget(b, tr, money);
          break;
        }
      }
      // 3. Month-end outlook: heading for a shortfall.
      final p = a.projection;
      if (primary == null && p != null && p.net < 0 && p.daysLeft > 0) {
        final gap = -p.net;
        final k = 'proj:short:${_ym(a.now)}';
        if (gap >= p.expectedIncome * 0.03 && allowed(k)) {
          primary = SaraNotice(
            kind: 'projection',
            title: tr('saraNotifProjTitle'),
            body: tr('saraNotifProjShort', {
              'amount': money(_roundUp(gap), base),
              'daily': money(_roundUp(gap / p.daysLeft), base),
            }),
            route: SaraRoutes.monthReport,
            cooldownKey: k,
          );
        }
      }
      // 4. A goal whose deadline is close.
      final dg = a.deadlineGoal;
      if (primary == null && dg != null) {
        final k = 'goal:due:${dg.id}';
        final left = _d(dg.deadline!).difference(_d(a.now)).inHours ~/ 24;
        if (allowed(k)) {
          final perDay = dg.remainingNative / math.max(1, left + 1);
          primary = SaraNotice(
            kind: 'goalDue',
            title: tr('saraNotifGoalDueTitle'),
            body: tr(left <= 0 ? 'saraNotifGoalDueToday' : 'saraNotifGoalDue', {
              'goal': dg.name,
              'n': left,
              'amount': money(dg.remainingNative, dg.currency),
              'daily': money(_roundUp(perDay), dg.currency),
            }),
            route: SaraRoutes.goal(dg.id),
            cooldownKey: k,
          );
        }
      }
      if (primary == null &&
          a.spendLevel == SpendLevel.high &&
          allowed('spend:high')) {
        final params = {
          'amount': money(a.recentWeekExpense, base),
          'pct': _pct(a.spendDelta),
          'category': a.topCategory ?? '',
        };
        primary = SaraNotice(
          kind: 'spendHigh',
          title: tr('saraNotifSpendHighTitle'),
          body: (a.topCategory ?? '').isNotEmpty
              ? tr('saraNotifSpendHighCat', params)
              : tr('saraNotifSpendHigh', params),
          route: SaraRoutes.spendingReport,
          cooldownKey: 'spend:high',
        );
      }
    }

    // Payday: pay yourself first (also on a predicted payday ahead).
    if (primary == null && a.isPayday && a.paydaySave > 0) {
      final k = 'payday:${SaraDailyKeys.day(a.now)}';
      if (allowed(k)) {
        final g = _topGoalName(a);
        primary = SaraNotice(
          kind: 'payday',
          title: tr('saraNotifPaydayTitle'),
          body: g != null
              ? tr('saraNotifPaydayGoals', {
                  'amount': money(
                      SaraInsightEngine.niceFloor(a.paydaySave * g.nativePerBase),
                      g.currency),
                  'goal': g.name,
                })
              : tr('saraNotifPaydayNoGoal',
                  {'amount': money(a.paydaySave, base)}),
          route: g != null ? SaraRoutes.goal(g.id) : SaraRoutes.goals,
          cooldownKey: k,
        );
      }
    }

    if (primary == null && a.allocations.isNotEmpty) {
      primary = _plan(a.allocations, tr, money);
    }

    // A forgotten repeat charge (subscription) — rare, once a season.
    if (primary == null && firstSlot) {
      for (final h in a.subscriptions) {
        final k = 'subs:${h.signature}';
        if (!allowed(k)) continue;
        primary = SaraNotice(
          kind: 'subscription',
          title: tr('saraNotifSubsTitle'),
          body: tr('saraNotifSubsBody', {
            'name': h.label,
            'amount': (h.originalAmount != null &&
                    (h.originalCurrency ?? '').isNotEmpty)
                ? money(h.originalAmount!, h.originalCurrency!)
                : money(h.amountBase, base),
          }),
          route: SaraRoutes.recurringList,
          cooldownKey: k,
        );
        break;
      }
    }

    if (primary == null &&
        firstSlot &&
        a.hasActiveGoals &&
        a.confident &&
        a.affordableToday <= 0 &&
        a.avgDailyExpense > 0 &&
        allowed('tight')) {
      final top = _topGoalName(a);
      primary = SaraNotice(
        kind: 'tight',
        title: tr('saraNotifTightTitle'),
        body: tr('saraNotifTightBody', {'goal': top?.name ?? ''}),
        route: top != null ? SaraRoutes.goal(top.id) : SaraRoutes.goals,
        cooldownKey: 'tight',
      );
    }

    // Money owed to the user is due: a gentle "collect" nudge.
    if (primary == null && firstSlot) {
      for (final o in a.collectDue) {
        final k = 'collect:${o.id}:${SaraDailyKeys.day(o.due)}';
        if (!allowed(k)) continue;
        primary = SaraNotice(
          kind: 'collect',
          title: tr('saraNotifCollectTitle'),
          body: tr('saraNotifCollectDue', {
            'name': o.name,
            'amount': money(o.amountNative, o.currency),
            'when': _when(o.due, a.now, tr),
          }),
          route: SaraRoutes.debt(o.id),
          cooldownKey: k,
        );
        break;
      }
    }

    if (primary == null && !a.loggedToday) {
      return SaraNotice(
        kind: 'log',
        title: tr('saraNotifLogTitle'),
        body: tr('saraNotifLogBody'),
        route: SaraRoutes.quickAddExpense,
      );
    }

    if (primary == null &&
        firstSlot &&
        a.spendLevel == SpendLevel.low &&
        allowed('spend:low')) {
      primary = SaraNotice(
        kind: 'spendLow',
        title: tr('saraNotifSpendLowTitle'),
        body: tr('saraNotifSpendLow', {'pct': _pct(a.spendDelta)}),
        route: SaraRoutes.spendingReport,
        cooldownKey: 'spend:low',
      );
    }

    if (primary == null &&
        firstSlot &&
        a.noSpendDays >= 2 &&
        allowed('nospend')) {
      primary = SaraNotice(
        kind: 'noSpend',
        title: tr('saraNotifNoSpendTitle'),
        body: tr('saraNotifNoSpendBody', {'n': a.noSpendDays}),
        route: SaraRoutes.transactions,
        cooldownKey: 'nospend',
      );
    }

    final proj = a.projection;
    if (primary == null &&
        firstSlot &&
        proj != null &&
        a.now.day >= 20 &&
        proj.net >= proj.expectedIncome * 0.05 &&
        allowed('proj:good:${_ym(a.now)}')) {
      primary = SaraNotice(
        kind: 'projection',
        title: tr('saraNotifProjTitle'),
        body: tr('saraNotifProjGood',
            {'amount': money(SaraInsightEngine.niceFloor(proj.net), base)}),
        route: a.hasActiveGoals ? SaraRoutes.goals : SaraRoutes.monthReport,
        cooldownKey: 'proj:good:${_ym(a.now)}',
      );
    }

    if (primary == null &&
        firstSlot &&
        a.savedThisWeek > 0 &&
        allowed('enc:saved')) {
      primary = SaraNotice(
        kind: 'encourage',
        title: tr('saraNotifEncourageTitle'),
        body: tr('saraNotifEncourageSaved',
            {'amount': money(a.savedThisWeek, base)}),
        route: SaraRoutes.goals,
        cooldownKey: 'enc:saved',
      );
    }

    if (primary == null &&
        firstSlot &&
        a.loggingStreak >= 3 &&
        allowed('enc:streak')) {
      primary = SaraNotice(
        kind: 'encourage',
        title: tr('saraNotifEncourageTitle'),
        body: tr('saraNotifEncourageStreak', {'n': a.loggingStreak}),
        route: SaraRoutes.transactions,
        cooldownKey: 'enc:streak',
      );
    }

    if (primary == null) return null;

    // Gentle second line: the log reminder rides along with friendly
    // content instead of becoming a second notification.
    if (!a.loggedToday &&
        (primary.kind == 'plan' ||
            primary.kind == 'tight' ||
            primary.kind == 'payday' ||
            primary.kind == 'encourage')) {
      return SaraNotice(
        kind: primary.kind,
        title: primary.title,
        body: '${primary.body}\n${tr('saraNotifLogSuffix')}',
        route: primary.route,
        cooldownKey: primary.cooldownKey,
      );
    }
    return primary;
  }

  /// Rounds UP to a friendly figure (a shortfall is never understated).
  static double _roundUp(double x) {
    if (x.isNaN || x <= 0) return 0;
    final step = x >= 1000
        ? 50.0
        : x >= 200
            ? 10.0
            : x >= 20
                ? 5.0
                : 1.0;
    return (x / step - 1e-9).ceilToDouble() * step;
  }

  static InsightGoal? _topGoalName(SaraAnalysis a) {
    if (a.allocations.isNotEmpty) return a.allocations.first.goal;
    return a.focusGoal;
  }

  static SaraNotice _plan(
      List<GoalAllocation> allocs, SaraTr tr, SaraMoney money) {
    String amt(GoalAllocation x) => money(x.amountNative, x.goal.currency);
    final String body;
    if (allocs.length == 1) {
      body = tr('saraNotifPlanOne',
          {'amount': amt(allocs[0]), 'goal': allocs[0].goal.name});
    } else if (allocs.length == 2) {
      body = tr('saraNotifPlanTwo', {
        'a1': amt(allocs[0]),
        'g1': allocs[0].goal.name,
        'a2': amt(allocs[1]),
        'g2': allocs[1].goal.name,
      });
    } else {
      body = tr('saraNotifPlanThree', {
        'a1': amt(allocs[0]),
        'g1': allocs[0].goal.name,
        'a2': amt(allocs[1]),
        'g2': allocs[1].goal.name,
        'a3': amt(allocs[2]),
        'g3': allocs[2].goal.name,
      });
    }
    return SaraNotice(
      kind: 'plan',
      title: tr('saraNotifPlanTitle'),
      body: body,
      // The goal that gets the most today opens on tap.
      route: SaraRoutes.goal(allocs.first.goal.id),
    );
  }

  static SaraNotice _budget(BudgetAlert b, SaraTr tr, SaraMoney money) {
    final cur = b.budget.currency;
    final String body;
    if (b.category != null) {
      body = tr('saraNotifBudgetCatOver', {
        'category': b.category!.name,
        'budget': b.budget.name,
        'amount': money(b.category!.spent - b.category!.allocated, cur),
      });
    } else {
      switch (b.level) {
        case BudgetAlertLevel.over:
          body = tr('saraNotifBudgetOver', {
            'budget': b.budget.name,
            'amount': money(b.budget.spent - b.budget.total, cur),
          });
          break;
        case BudgetAlertLevel.nearing:
          body = tr('saraNotifBudgetNearing', {
            'budget': b.budget.name,
            'pct': _pct(b.usage),
            'left': money(b.budget.total - b.budget.spent, cur),
          });
          break;
        case BudgetAlertLevel.pacing:
          body = tr('saraNotifBudgetPacing', {
            'budget': b.budget.name,
            'pct': _pct(b.usage),
          });
          break;
      }
    }
    return SaraNotice(
      kind: 'budget',
      title: tr('saraNotifBudgetTitle'),
      body: body,
      route: SaraRoutes.budget(b.budget.id),
      cooldownKey: b.key,
    );
  }

  /// Instant (event-driven) heads-up right after an expense is added.
  static SaraNotice instant(
    InstantAlert alert, {
    required String baseCurrency,
    required SaraTr tr,
    required SaraMoney money,
  }) {
    if (alert.budgetAlert != null) {
      final n = _budget(alert.budgetAlert!, tr, money);
      return SaraNotice(
        kind: 'budgetOver',
        title: n.title,
        body: n.body,
        route: n.route,
        cooldownKey: alert.budgetAlert!.key,
      );
    }
    final account = alert.account;
    if (account != null) {
      return SaraNotice(
        kind: 'lowBalance',
        title: tr('saraNotifLowBalanceTitle'),
        body: tr('saraNotifLowBalanceBody', {
          'account': account.name,
          'amount': money(account.balance, account.currency),
        }),
        route: SaraRoutes.banks,
        cooldownKey: alert.key,
      );
    }
    final tx = alert.tx!;
    final x = alert.ratio >= 10
        ? alert.ratio.round().toString()
        : alert.ratio.toStringAsFixed(1).replaceAll('.0', '');
    return SaraNotice(
      kind: 'bigExpense',
      title: tr('saraNotifBigTitle'),
      body: tr('saraNotifBigBody', {
        'amount': (tx.originalAmount != null &&
                (tx.originalCurrency ?? '').isNotEmpty)
            ? money(tx.originalAmount!, tx.originalCurrency!)
            : money(tx.amount, baseCurrency),
        'category': tx.category,
        'x': x,
      }),
      route: SaraRoutes.spendingReport,
      cooldownKey: alert.key,
    );
  }
}
