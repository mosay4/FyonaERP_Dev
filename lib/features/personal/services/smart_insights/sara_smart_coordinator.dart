import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/services/notification_service.dart';
import '../../presentation/providers/personal_providers.dart';
import 'sara_daily_planner.dart';
import 'sara_input_builder.dart';
import 'sara_insight_engine.dart';
import 'sara_notice_composer.dart';
import 'sara_smart_scheduler.dart';
import 'sara_smart_settings.dart';

// ─────────────────────────────────────────────────────────────
// SaraSmartCoordinator — silent background glue (never a screen).
//
// Re-plans Sara's daily digest whenever the app starts / resumes and
// whenever Personal data changes (debounced), because a scheduled
// notification's text is frozen when it is scheduled. Also raises the
// instant heads-up right after a just-added expense is unusually big or
// pushes a budget over its limit.
//
// 100% on-device and deterministic — no AI model / network calls.
// ─────────────────────────────────────────────────────────────

final saraSmartCoordinatorProvider = Provider<SaraSmartCoordinator>((ref) {
  final c = SaraSmartCoordinator(ref);
  ref.listen<PersonalFinanceState>(personalFinanceProvider, (_, _) => c.poke());
  ref.listen<BudgetState>(budgetProvider, (_, _) => c.poke());
  ref.listen<RecurringState>(recurringProvider, (_, _) => c.poke());
  ref.listen<String>(currentUserIdProvider, (prev, next) {
    if (prev == next) return;
    // Logout / account switch: the previous user's digests must not fire.
    if ((prev ?? '').isNotEmpty) unawaited(SaraSmartScheduler.cancelAll());
    c.onUserChanged();
  });
  ref.listen<SaraSmartSettings>(saraSmartSettingsProvider, (prev, next) {
    if (prev == null ||
        prev.enabled != next.enabled ||
        prev.minutes != next.minutes) {
      c.poke(delay: const Duration(milliseconds: 300));
    }
  });
  ref.onDispose(c.dispose);
  return c;
});

class SaraSmartCoordinator {
  final Ref _ref;
  SaraSmartCoordinator(this._ref);

  static const Duration debounce = Duration(seconds: 2);

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;
  String? _seenUid;

  /// Tx ids known at the previous run (null = first run this session:
  /// everything already there is history, never "just added").
  Set<String>? _knownTxIds;
  Set<String> _knownOverKeys = {};
  DateTime? _lastNewSpendAt;
  InsightTx? _lastNewSpend;

  /// Called once from the app shell after the first frame.
  void start() {
    if (_started) return;
    _started = true;
    unawaited(SaraSmartScheduler.rescheduleAll());
    poke(delay: const Duration(seconds: 2));
  }

  /// App came back to the foreground.
  void onResume() {
    unawaited(SaraSmartScheduler.rescheduleAll());
    poke(delay: const Duration(seconds: 1));
  }

  void onUserChanged() {
    _knownTxIds = null;
    _knownOverKeys = {};
    _lastNewSpend = null;
    _lastNewSpendAt = null;
    poke(delay: const Duration(milliseconds: 500));
  }

  void poke({Duration delay = debounce}) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(run()));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  String _tr(String key, [Map<String, dynamic>? params]) =>
      AppLocalizations.t(key, params);

  String _money(double amount, String currency) =>
      formatAmount(amount, currency);

  Future<void> run() async {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      await _runOnce();
    } catch (_) {
      // Never let a planning hiccup surface to the user.
    } finally {
      _running = false;
      if (_again && !_disposed) {
        _again = false;
        poke();
      }
    }
  }

  Future<void> _runOnce() async {
    final uid = _ref.read(currentUserIdProvider);
    if (uid.isEmpty) {
      // Only an actual logout cancels: at cold start the session is not
      // restored yet and the pending digests must survive.
      if (_seenUid != null) {
        _seenUid = null;
        await SaraSmartScheduler.cancelAll();
      }
      return;
    }
    _seenUid = uid;
    final settings = await SaraSmartSettingsStore.load(uid);
    if (!settings.enabled) {
      await SaraSmartScheduler.cancelAll();
      _knownTxIds = null;
      return;
    }
    final pf = _ref.read(personalFinanceProvider);
    // Personal data not loaded in this session yet: keep what is already
    // scheduled (it was planned from the last known data).
    if (pf.transactions.isEmpty && pf.savingsGoals.isEmpty) return;

    final engine = _ref.read(currencyEngineProvider);
    final budgets = _ref.read(budgetProvider).budgets;
    final recurring = _ref.read(recurringProvider).recurring;
    final now = DateTime.now();
    final input = SaraInsightInputBuilder.build(
      now: now,
      baseCurrency: pf.walletCurrency,
      transactions: pf.transactions,
      goals: pf.savingsGoals,
      budgets: budgets,
      recurring: recurring,
      debts: pf.debts,
      liquidBalance: pf.bankAccounts.isEmpty ? null : pf.walletTotalBalance,
      convert: (a, f, t) => engine.convertSafe(a, f, t),
    );
    final analysis = SaraInsightEngine.analyze(input);
    try {
      await _ref
          .read(saraSmartSettingsProvider.notifier)
          .notePeakHour(analysis.peakHour);
    } catch (_) {
      await SaraSmartSettingsStore.savePeakHour(uid, analysis.peakHour);
    }

    var cooldown = await SaraSmartScheduler.loadCooldown();
    cooldown = await _maybeInstant(input, analysis, now, cooldown);

    final lastFired = await SaraSmartScheduler.lastFiredDay(now: now);
    final slots = SaraDailyPlanner.plan(
      input: input,
      now: now,
      minutesOfDay: settings.minutes ?? analysis.peakHour * 60,
      lastFiredDay: lastFired,
      cooldown: cooldown,
      tr: _tr,
      money: _money,
    );
    await SaraSmartScheduler.apply(slots);
    cooldown = SaraDailyPlanner.reserve(cooldown, slots,
        now: now, lastFiredDay: lastFired);
    await SaraSmartScheduler.saveCooldown(cooldown);
  }

  bool _isFresh(InsightTx t, DateTime now) {
    final c = t.createdAt;
    if (c != null) return now.difference(c).inMinutes.abs() <= 30;
    final d = t.date;
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  Future<Map<String, SaraCooldownEntry>> _maybeInstant(
    SaraInsightInput input,
    SaraAnalysis analysis,
    DateTime now,
    Map<String, SaraCooldownEntry> cooldown,
  ) async {
    final ids = input.transactions.map((t) => t.id).toSet();
    final over = analysis.budgetAlerts
        .where((a) => a.level == BudgetAlertLevel.over)
        .toList();
    final overKeys = over.map((a) => a.key).toSet();
    final known = _knownTxIds;
    final knownOver = _knownOverKeys;
    _knownTxIds = ids;
    _knownOverKeys = overKeys;
    if (known == null) return cooldown; // first look: all of it is history

    final fresh = input.transactions
        .where((t) => !known.contains(t.id) && t.isSpending && _isFresh(t, now))
        .toList()
      ..sort((a, b) => (b.createdAt ?? b.date).compareTo(a.createdAt ?? a.date));
    if (fresh.isNotEmpty) {
      _lastNewSpend = fresh.first;
      _lastNewSpendAt = now;
    }
    // Budgets re-aggregate a moment after the expense lands: a budget
    // that turns "over" within 2 minutes of a new expense still counts.
    final recent = _lastNewSpend;
    if (recent == null ||
        _lastNewSpendAt == null ||
        now.difference(_lastNewSpendAt!).inMinutes > 2) {
      return cooldown;
    }
    final newlyOver = over.where((a) => !knownOver.contains(a.key)).toList();
    if (fresh.isEmpty && newlyOver.isEmpty) return cooldown;

    final alert = SaraInsightEngine.detectInstant(
      input: input,
      tx: fresh.isNotEmpty ? fresh.first : recent,
      newlyOverBudgets: newlyOver,
    );
    if (alert == null) return cooldown;
    // A big-expense alert is only for the expense that was JUST added.
    if (alert.kind == 'bigExpense' && fresh.isEmpty) return cooldown;

    final today = SaraDailyPlanner.dayKey(now);
    final cdKey = alert.budgetAlert?.key ?? alert.key;
    if (!SaraDailyPlanner.cooldownAllows(cooldown, cdKey, today)) {
      return cooldown;
    }
    if (!await NotificationService.tryClaimTrayKey('sara:${alert.key}')) {
      return cooldown;
    }
    if (!await SaraSmartScheduler.claimInstantSlot(today)) return cooldown;
    final notice = SaraNoticeComposer.instant(
      alert,
      baseCurrency: input.baseCurrency,
      tr: _tr,
      money: _money,
    );
    final shown = await SaraSmartScheduler.showNow(notice, alert.key);
    if (!shown) {
      await NotificationService.releaseTrayKey('sara:${alert.key}');
      return cooldown;
    }
    _lastNewSpend = null; // one heads-up per expense
    return {
      ...cooldown,
      cdKey: SaraCooldownEntry(today, 'instant'),
    };
  }
}
