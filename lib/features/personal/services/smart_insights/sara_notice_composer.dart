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
  /// bigExpense | budgetOver
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
}

class SaraNoticeComposer {
  SaraNoticeComposer._();

  static String _pct(double ratio) => (ratio * 100).round().abs().toString();

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
      for (final b in a.budgetAlerts) {
        if (!allowed(b.key)) continue;
        primary = _budget(b, tr, money);
        break;
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

    if (primary == null && a.allocations.isNotEmpty) {
      primary = _plan(a.allocations, tr, money);
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
