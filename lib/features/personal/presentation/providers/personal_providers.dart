import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../../../../core/services/sync_engine.dart';
import '../../data/models/personal_models.dart';
import '../../di/personal_providers.dart';
import '../../domain/services/budget_aggregation.dart';
import '../../domain/services/personal_finance_service.dart';
import '../../services/recurring_reminder_service.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../shared/providers/platform_controls_provider.dart';

class _AccountTypesStore {
  static const _key = 'bank_account_types_v3';

  static Future<Map<String, String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    final Map<String, dynamic> decoded = jsonDecode(raw);
    return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  static Future<void> save(String accountId, String type) async {
    final map = await load();
    map[accountId] = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(map));
  }

  static Future<void> remove(String accountId) async {
    final map = await load();
    map.remove(accountId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(map));
  }

  static List<PersonalBankAccount> apply(List<PersonalBankAccount> accounts, Map<String, String> localTypes) {
    if (localTypes.isEmpty) return accounts;
    return accounts.map((a) {
      final localType = localTypes[a.id];
      if (localType != null && localType != a.accountType) {
        return PersonalBankAccount(id: a.id, bankName: a.bankName, balance: a.balance, currency: a.currency, notes: a.notes, accountType: localType);
      }
      return a;
    }).toList();
  }
}

class PersonalFinanceState {
  final bool isLoading;
  final String? error;
  final bool isOfflineError;
  final double totalBalance;
  final String walletCurrency;
  final double walletTotalBalance;
  final double totalPayableConverted;
  final double totalReceivableConverted;
  final List<PersonalBankAccount> bankAccounts;
  final List<PersonalTransaction> transactions;
  final List<SavingsGoal> savingsGoals;
  final List<PersonalDebt> debts;
  final Map<String, double> spendingAnalytics;
  final List<ExchangeRate> exchangeRates;
  final int transactionMonth;
  final int transactionYear;
  /// Backend UUID of the selected account filter, or null for all accounts.
  final String? transactionAccountId;

  PersonalFinanceState({
    this.isLoading = false,
    this.error,
    this.isOfflineError = false,
    this.totalBalance = 0,
    // Display currency defaults to USD always (user-changeable via
    // setWalletCurrency, persisted in prefs).
    this.walletCurrency = 'USD',
    this.walletTotalBalance = 0,
    this.totalPayableConverted = 0,
    this.totalReceivableConverted = 0,
    this.bankAccounts = const [],
    this.transactions = const [],
    this.savingsGoals = const [],
    this.debts = const [],
    this.spendingAnalytics = const {},
    this.exchangeRates = const [],
    this.transactionMonth = 0,
    this.transactionYear = 0,
    this.transactionAccountId,
  });

  PersonalFinanceState copyWith({
    bool? isLoading,
    String? error,
    bool? isOfflineError,
    double? totalBalance,
    String? walletCurrency,
    double? walletTotalBalance,
    double? totalPayableConverted,
    double? totalReceivableConverted,
    List<PersonalBankAccount>? bankAccounts,
    List<PersonalTransaction>? transactions,
    List<SavingsGoal>? savingsGoals,
    List<PersonalDebt>? debts,
    Map<String, double>? spendingAnalytics,
    List<ExchangeRate>? exchangeRates,
    int? transactionMonth,
    int? transactionYear,
    String? transactionAccountId,
  }) {
    return PersonalFinanceState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isOfflineError: isOfflineError ?? false,
      totalBalance: totalBalance ?? this.totalBalance,
      walletCurrency: walletCurrency ?? this.walletCurrency,
      walletTotalBalance: walletTotalBalance ?? this.walletTotalBalance,
      totalPayableConverted: totalPayableConverted ?? this.totalPayableConverted,
      totalReceivableConverted: totalReceivableConverted ?? this.totalReceivableConverted,
      bankAccounts: bankAccounts ?? this.bankAccounts,
      transactions: transactions ?? this.transactions,
      savingsGoals: savingsGoals ?? this.savingsGoals,
      debts: debts ?? this.debts,
      spendingAnalytics: spendingAnalytics ?? this.spendingAnalytics,
      exchangeRates: exchangeRates ?? this.exchangeRates,
      transactionMonth: transactionMonth ?? this.transactionMonth,
      transactionYear: transactionYear ?? this.transactionYear,
      transactionAccountId: transactionAccountId ?? this.transactionAccountId,
    );
  }

  /// Raw debt totals WITHOUT currency conversion.
  /// For converted totals, use PersonalFinanceNotifier.totalPayable/totalReceivable.
  double get totalPayableRaw => debts.where((d) => d.type == 'payable' && d.status != 'paid').fold<double>(0, (sum, d) => sum + d.remaining);
  double get totalReceivableRaw => debts.where((d) => d.type == 'receivable' && d.status != 'paid').fold<double>(0, (sum, d) => sum + d.remaining);
  double get netDebt => totalPayableConverted - totalReceivableConverted;
  double get netWorth => walletTotalBalance - totalPayableConverted + totalReceivableConverted;
}

class PersonalFinanceNotifier extends StateNotifier<PersonalFinanceState> {
  final Ref _ref;
  PersonalFinanceNotifier(this._ref) : super(PersonalFinanceState()) {
    _loadWalletCurrency();
    _watchSyncSettled();
  }

  /// Generation guard: every new read intent (load / filtered reload /
  /// post-add refresh / post-sync refresh) invalidates older in-flight work,
  /// so a slow snapshot started before a mutation can never overwrite the
  /// fresh publish (read-your-write). Mirrors BudgetNotifier._loadGen.
  int _loadGen = 0;
  StreamSubscription<String>? _syncSub;

  /// Best-effort refresh once a sync cycle settles: the mirror converged by
  /// then, so a silent re-read heals any transient staleness without the
  /// user having to pull-to-refresh. Local mirror read only — it enqueues
  /// nothing, so it can never trigger another sync cycle.
  void _watchSyncSettled() {
    if (_syncSub != null) return;
    try {
      final engine = _ref.read(syncEngineProvider);
      _syncSub = engine.onStatusChanged.listen((status) {
        if (status == SyncState.synced) {
          unawaited(_refreshAfterSync());
        }
      });
    } catch (_) {}
  }

  Future<void> _refreshAfterSync() async {
    final gen = ++_loadGen;
    try {
      final txs = await _ref
          .read(personalFinanceServiceProvider)
          .getTransactions();
      if (gen != _loadGen) return;
      state = state.copyWith(transactions: txs);
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _syncSub?.cancel();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadWalletCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('wallet_currency') ?? 'USD';
    if (state.walletCurrency != saved) {
      state = state.copyWith(walletCurrency: saved);
    }
  }

  Future<void> setWalletCurrency(String currency) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wallet_currency', currency);
    state = state.copyWith(walletCurrency: currency);
    _recalcWalletTotal();
  }

  double? _findRate(String from, String to, List<ExchangeRate> rates) {
    if (from == to) return 1.0;
    try {
      final engine = _ref.read(currencyEngineProvider);
      final rate = engine.getRate(from, to);
      if (rate != null) return rate;
    } catch (_) {}
    for (final r in rates) {
      if (r.fromCurrency == from && r.toCurrency == to) return r.rate;
    }
    for (final r in rates) {
      if (r.fromCurrency == to && r.toCurrency == from && r.rate != 0) return 1.0 / r.rate;
    }
    return null;
  }

  void _recalcWalletTotal() {
    final accounts = state.bankAccounts;
    final rates = state.exchangeRates;
    final target = state.walletCurrency;
    state = state.copyWith(
      walletTotalBalance: _convertAccountsTotal(accounts, target, rates),
      totalPayableConverted: _convertDebtTotal('payable', target, rates),
      totalReceivableConverted: _convertDebtTotal('receivable', target, rates),
    );
  }

  double _convertDebtTotal(String type, String target, List<ExchangeRate> rates) {
    final engine = _ref.read(currencyEngineProvider);
    double total = 0;
    for (final d in state.debts) {
      if (d.type != type || d.status == 'paid') continue;
      final currency = d.currency.trim();
      if (currency.isEmpty || currency == target) {
        if (currency.isNotEmpty) total += d.remaining;
        continue;
      }
      final converted = engine.convert(d.remaining, currency, target);
      if (converted != 0) {
        total += converted;
        continue;
      }
      final rate = _findRate(currency, target, rates);
      if (rate != null) {
        total += d.remaining * rate;
      }
    }
    return total;
  }

  double _convertAccountsTotal(List<PersonalBankAccount> accounts, String target, List<ExchangeRate> rates) {
    final engine = _ref.read(currencyEngineProvider);
    double total = 0;
    for (final a in accounts) {
      if (a.currency == target) {
        total += a.balance;
      } else {
        final converted = engine.convert(a.balance, a.currency, target);
        if (converted != 0) {
          total += converted;
        } else {
          final rate = _findRate(a.currency, target, rates);
          if (rate != null) total += a.balance * rate;
        }
      }
    }
    return total;
  }

  bool get hasMissingRates {
    final target = state.walletCurrency;
    for (final a in state.bankAccounts) {
      if (a.currency != target && _findRate(a.currency, target, state.exchangeRates) == null) return true;
    }
    return false;
  }

  int get missingRatesCount {
    int count = 0;
    final target = state.walletCurrency;
    for (final a in state.bankAccounts) {
      if (a.currency != target && _findRate(a.currency, target, state.exchangeRates) == null) count++;
    }
    return count;
  }

  double get totalPayable => _convertDebtTotal('payable', state.walletCurrency, state.exchangeRates);

  double get totalReceivable => _convertDebtTotal('receivable', state.walletCurrency, state.exchangeRates);
  double get netDebt => totalPayable - totalReceivable;
  int get overdueCount => state.debts.where((d) => d.isOverdue).length;
  int get activeDebtCount => state.debts.where((d) => d.status != 'paid').length;

  int get convertedAccountsCount {
    int count = 0;
    final target = state.walletCurrency;
    for (final a in state.bankAccounts) {
      if (_findRate(a.currency, target, state.exchangeRates) != null) count++;
    }
    return count;
  }

  double convertAccountsToWallet(List<PersonalBankAccount> accounts) {
    double total = 0;
    final engine = _ref.read(currencyEngineProvider);
    for (final a in accounts) {
      total += engine.convert(a.balance, a.currency, state.walletCurrency);
    }
    return total;
  }

  /// فحص صيانة مركزي — يمنع أي عملية كتابة داخل قسم متوقف حتى لو كانت
  /// الصفحة مفتوحة مسبقاً. يطبق الهرمية APP > PERSONAL > FEATURE
  bool _isMaintenanceBlocked(String featureKey) {
    try {
      final ctrl = _ref.read(platformControlsProvider).valueOrNull;
      if (ctrl == null) return false;
      if (ctrl.isAppMaintenance) return true;
      final route = featureKey.startsWith('/') ? featureKey : '/$featureKey';
      return ctrl.isRouteUnderMaintenance(route);
    } catch (_) {
      return false;
    }
  }

  bool _guardMaintenance(String featureKey) {
    if (_isMaintenanceBlocked(featureKey)) {
      state = state.copyWith(error: AppLocalizations.t('maintenanceFeatureBlocked'), isOfflineError: false);
      return true;
    }
    return false;
  }

  /// Attaches a no-op error handler the instant a parallel fetch future is
  /// created, so a fast failure can never surface as an unhandled async
  /// error while a slower sibling is still in flight. The guarded awaits
  /// below still observe every outcome (errors flow into noteError).
  static void _pin(Future<dynamic> future) {
    unawaited(future.then((_) {}, onError: (_) {}));
  }

  Future<void> load() async {
    final gen = ++_loadGen;
    final service = _ref.read(personalFinanceServiceProvider);
    // Instant-open: publish held rows (even empty) synchronously
    // so navigation never shows a spinner — data fills in below, first run
    // shows the empty state instead of blocking on a network fetch.
    state = state.copyWith(error: null, isOfflineError: false);
    bool anyFailed = false;
    bool anyOffline = false;
    void noteError(Object e) {
      anyFailed = true;
      if (_isOfflineError(e)) anyOffline = true;
    }
    try {
      // Load each entity independently so a failure in one doesn't wipe
      // the cached results of the others (critical for offline-first).
      // All reads start together (were 6 sequential awaits); each keeps its
      // own error handling below — error semantics are unchanged.
      final fAccounts = service.getBankAccounts();
      final fTxs = service.getTransactions();
      final fGoals = service.getSavingsGoals();
      final fDebts = service.getDebts();
      final fAnalytics = service.getSpendingAnalytics();
      final fRates = service.getExchangeRates();
      _pin(fAccounts);
      _pin(fTxs);
      _pin(fGoals);
      _pin(fDebts);
      _pin(fAnalytics);
      _pin(fRates);

      List<PersonalBankAccount> accounts = state.bankAccounts;
      List<PersonalTransaction> txs = state.transactions;
      List<SavingsGoal> goals = state.savingsGoals;
      List<PersonalDebt> debtsList = state.debts;
      Map<String, double> analytics = state.spendingAnalytics;
      List<ExchangeRate> rates = state.exchangeRates;

      // Phase 1a — instant paint: accounts (+ local-only rates) publish the
      // moment THEY resolve, never gated on txs/goals/debts. An empty mirror
      // in any of those types triggers a blocking network fetch while online
      // (yet fails fast offline) — gating the cards on it is what painted
      // the empty state + zero totals for seconds on every entry.
      // getExchangeRates is pure local SQLite: always fast, never network.
      try { accounts = await fAccounts; } catch (e) { noteError(e); }
      try { rates = await fRates; } catch (e) { noteError(e); }
      final localTypes = await _AccountTypesStore.load();
      final patchedAccounts = _AccountTypesStore.apply(accounts, localTypes);
      state = state.copyWith(
        isLoading: false,
        totalBalance: patchedAccounts.fold<double>(0, (sum, a) => sum + a.balance),
        bankAccounts: patchedAccounts,
        exchangeRates: rates,
        walletTotalBalance: _convertAccountsTotal(patchedAccounts, state.walletCurrency, rates),
      );

      // Phase 1b — the rest fills in as each resolves; the cards above are
      // already painted and never flicker back to empty.
      // NOTE: transactions are ALWAYS fetched unfiltered here. Every page
      // filters client-side (transactions page, bank detail, dashboard
      // recent). Server-side narrowing with stale account/month filters used
      // to hide cash ops and other rows from the shared list.
      try { txs = await fTxs; } catch (e) { noteError(e); }
      try { goals = await fGoals; } catch (e) { noteError(e); }
      try { debtsList = await fDebts; } catch (e) { noteError(e); }
      if (gen != _loadGen) return;
      state = state.copyWith(
        isLoading: false,
        transactions: txs,
        savingsGoals: goals,
        debts: debtsList,
      );

      // Phase 2 — refresh rates/totals (may use the network) and report.
      try { await _ref.read(currencyEngineProvider).load(); } catch (e) { noteError(e); }
      try { await service.migrateCashWallet(); } catch (_) {}
      try { analytics = await fAnalytics; } catch (e) { noteError(e); }
      try { rates = await fRates; } catch (e) { noteError(e); }

      if (gen != _loadGen) return;
      state = state.copyWith(
        isLoading: false,
        spendingAnalytics: analytics,
        exchangeRates: rates,
        walletTotalBalance: _convertAccountsTotal(patchedAccounts, state.walletCurrency, rates),
        error: anyOffline ? AppLocalizations.t('noInternet') : (anyFailed ? AppLocalizations.t('personalErrLoadData') : null),
        isOfflineError: anyOffline,
      );
      _recalcWalletTotal();
      // NOTE: no auto-backup trigger here on purpose — load() is a READ
      // path (every screen open calls it). Mutations trigger explicitly,
      // and every SQLite write additionally fans out via
      // DatabaseHelper.onDataChanged, so no write can slip through.
    } catch (e) {
      if (gen != _loadGen) return;
      final isOffline = e is DioException &&
          (e.type == DioExceptionType.connectionError ||
           e.type == DioExceptionType.connectionTimeout ||
           e.type == DioExceptionType.sendTimeout ||
           e.type == DioExceptionType.receiveTimeout ||
           (e.message?.contains('SocketException') ?? false) ||
           (e.message?.contains('Connection refused') ?? false) ||
            (e.message?.contains('Connection reset') ?? false));
      final msg = isOffline
          ? AppLocalizations.t('noInternet')
          : AppLocalizations.t('personalErrLoadData');
      state = state.copyWith(isLoading: false, error: msg, isOfflineError: isOffline);
    }
  }

  static bool _isOfflineError(Object e) {
    if (e is DioException) {
      return e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          (e.message?.contains('SocketException') ?? false) ||
          (e.message?.contains('Connection refused') ?? false) ||
          (e.message?.contains('Connection reset') ?? false);
    }
    final s = e.toString().toLowerCase();
    return s.contains('socket') || s.contains('connectionrefused') || s.contains('connection reset');
  }

  void _triggerAutoSync() {
    try {
      final backupService = _ref.read(backupServiceProvider);
      backupService.onDataChanged();
    } catch (_) {}
  }

  Future<void> addDebt(PersonalDebt debt) async {
    if (_guardMaintenance('personal/debts')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.addDebt(debt);
      final debtsList = await service.getDebts();
      state = state.copyWith(debts: debtsList);
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrAddDebt'));
    }
  }

  Future<void> updateDebt(PersonalDebt debt) async {
    if (_guardMaintenance('personal/debts')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.updateDebt(debt);
      final debtsList = await service.getDebts();
      state = state.copyWith(debts: debtsList);
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrUpdateDebt'));
    }
  }

  /// Returns true only when the debt is actually gone (mirrors
  /// [deleteTransaction]): callers must not show success on false.
  Future<bool> deleteDebt(String id) async {
    if (_guardMaintenance('personal/debts')) return false;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.deleteDebt(id);
      final debtsList = await service.getDebts();
      state = state.copyWith(debts: debtsList);
      _triggerAutoSync();
      return true;
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrDeleteDebt'));
      return false;
    }
  }

  /// Deletes a transaction and refreshes every affected list (transactions,
  /// accounts, goals, debts) so balances revert visibly. Returns true only
  /// when the transaction is actually gone.
  Future<bool> deleteTransaction(String id) async {
    if (_guardMaintenance('personal/transactions')) return false;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final ok = await service.deleteTransaction(id);
      if (!ok) {
        state = state.copyWith(error: AppLocalizations.t('personalErrDeleteTx'));
        return false;
      }
      var txs = state.transactions;
      var accounts = state.bankAccounts;
      var goals = state.savingsGoals;
      var debts = state.debts;
      try { txs = await service.getTransactions(); } catch (_) {}
      try {
        accounts = await service.getBankAccounts();
        final localTypes = await _AccountTypesStore.load();
        accounts = _AccountTypesStore.apply(accounts, localTypes);
      } catch (_) {}
      try { goals = await service.getSavingsGoals(); } catch (_) {}
      try { debts = await service.getDebts(); } catch (_) {}
      state = state.copyWith(
        transactions: txs,
        bankAccounts: accounts,
        totalBalance: accounts.fold<double>(0, (sum, a) => sum + a.balance),
        savingsGoals: goals,
        debts: debts,
      );
      _recalcWalletTotal();
      _triggerAutoSync();
      // SWR: budget spent refreshes in the background — delete success
      // never waits for it.
      Future<void>(() async {
        try {
          await _ref.read(budgetProvider.notifier).load();
        } catch (_) {}
      });
      return true;
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrDeleteTx'));
      return false;
    }
  }

  /// Records a debt payment. The backend creates the payment record AND the
  /// linked transaction (debt_id + budget_id copied from the debt) by real IDs.
  Future<void> payDebt(String id, double amount, DateTime date, {String method = 'cash', String? bankAccountId, String? notes, String? clientOperationId, String? currency, double? debtAmount}) async {
    if (_guardMaintenance('personal/debts')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.payDebt(id, amount, date, method: method, bankAccountId: bankAccountId, notes: notes, clientOperationId: clientOperationId, currency: currency, debtAmount: debtAmount);

      // After successful payment, do a silent background refresh. Each
      // entity refreshes independently so one flaky endpoint can never wipe
      // the whole update (debts + balances must land even if analytics fails).
      var debtsList = state.debts;
      var accounts = state.bankAccounts;
      var rates = state.exchangeRates;
      var txs = state.transactions;
      var goals = state.savingsGoals;
      var analytics = state.spendingAnalytics;
      try { debtsList = await service.getDebts(); } catch (_) {}
      try { accounts = await service.getBankAccounts(); } catch (_) {}
      try { rates = await service.getExchangeRates(); } catch (_) {}
      try { txs = await service.getTransactions(); } catch (_) {}
      try { goals = await service.getSavingsGoals(); } catch (_) {}
      try { analytics = await service.getSpendingAnalytics(); } catch (_) {}
      try {
        final localTypes = await _AccountTypesStore.load();
        final patchedAccounts = _AccountTypesStore.apply(accounts, localTypes);
        state = state.copyWith(
          debts: debtsList,
          bankAccounts: patchedAccounts,
          totalBalance: patchedAccounts.fold<double>(0, (sum, a) => sum + a.balance),
          transactions: txs,
          savingsGoals: goals,
          spendingAnalytics: analytics,
          exchangeRates: rates,
          walletTotalBalance: _convertAccountsTotal(patchedAccounts, state.walletCurrency, rates),
        );
        _recalcWalletTotal();
        _triggerAutoSync();
        // SWR: budget spent refreshes in the background — payment success
        // never waits for it.
        Future<void>(() async {
          try {
            await _ref.read(budgetProvider.notifier).load();
          } catch (_) {}
        });
      } catch (_) {
        // Silent refresh failed — keep optimistic update, user can pull-to-refresh
      }
    } catch (e) {
      debugPrint('PersonalFinanceNotifier.payDebt error: $e');
      state = state.copyWith(error: AppLocalizations.t('personalErrPayDebt'));
      rethrow;
    }
  }

  Future<List<PersonalDebtPayment>> getDebtPayments(String debtId) async {
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      return await service.getDebtPayments(debtId);
    } catch (_) {
      return [];
    }
  }

  Future<void> loadTransactions({String? accountId, int month = 0, int year = 0}) async {
    // Instant-open: keep current rows on screen (no spinner); the filtered
    // list replaces them when ready.
    final gen = ++_loadGen;
    state = state.copyWith(
      transactionMonth: month,
      transactionYear: year,
      transactionAccountId: accountId,
    );
    final service = _ref.read(personalFinanceServiceProvider);
    try {
      final txs = await service.getTransactions(accountId: accountId, month: month, year: year);
      if (gen != _loadGen) return;
      state = state.copyWith(isLoading: false, transactions: txs);
    } catch (_) {
      if (gen != _loadGen) return;
      state = state.copyWith(isLoading: false);
    }
  }

  Future<String?> addTransaction({
    required String type,
    required double amount,
    required String category,
    String? description,
    String? paymentMethod,
    required DateTime date,
    String? accountId,
    String currency = 'SAR',
    String? budgetId,
    String? budgetCategoryId,
    String? goalId,
    String? debtId,
    String? clientOperationId,
  }) async {
    if (_guardMaintenance(type == 'income' ? 'personal/transactions/add-income' : 'personal/transactions/add-expense')) {
      return AppLocalizations.t('maintenanceFeatureBlocked');
    }
    // A mutation is itself a newer read intent: invalidate any in-flight
    // load() NOW so its stale snapshot can never overwrite the fresh
    // publish below (read-your-write).
    final gen = ++_loadGen;
    final service = _ref.read(personalFinanceServiceProvider);
    // ── Phase 1: the create itself. Only its failure is a real error. ──
    try {
      final ok = await service.addTransaction(
        type: type,
        amount: amount,
        category: category,
        description: description,
        paymentMethod: paymentMethod,
        date: date,
        accountId: accountId,
        currency: currency,
        budgetId: budgetId,
        budgetCategoryId: budgetCategoryId,
        goalId: goalId,
        debtId: debtId,
        clientOperationId: clientOperationId,
      );
      if (!ok) return AppLocalizations.t('personalErrAddTx');
    } catch (e) {
      final message = _extractApiErrorMessage(e);
      state = state.copyWith(error: message);
      return message;
    }
    // ── Phase 2: refresh (best-effort, independent). A slow/failed refresh
    // must never block the success notice nor report a phantom error. ──
    var txs = state.transactions;
    var accounts = state.bankAccounts;
    var rates = state.exchangeRates;
    try { txs = await service.getTransactions(); } catch (_) {}
    try { accounts = await service.getBankAccounts(); } catch (_) {}
    try { rates = await service.getExchangeRates(); } catch (_) {}
    try {
      final localTypes = await _AccountTypesStore.load();
      final patchedAccounts = _AccountTypesStore.apply(accounts, localTypes);
      if (gen != _loadGen) return null;
      state = state.copyWith(
        transactions: txs,
        bankAccounts: patchedAccounts,
        totalBalance: patchedAccounts.fold<double>(0, (sum, a) => sum + a.balance),
        exchangeRates: rates,
        walletTotalBalance: _convertAccountsTotal(patchedAccounts, state.walletCurrency, rates),
      );
      _recalcWalletTotal();
    } catch (_) {}
    _triggerAutoSync();
    // SWR: budget spent refreshes in the background — the sheet closes on
    // the success notice above without waiting for it.
    Future<void>(() async {
      try {
        await _ref.read(budgetProvider.notifier).load();
      } catch (_) {}
    });
    return null;
  }

  static String _extractApiErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final message = data['message'];
        if (message is String && message.trim().isNotEmpty) return message;
        final detail = data['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail;
      }
    }
    // Local balance guards throw plain Exceptions with an exact Arabic
    // message ("لا يوجد رصيد كافٍ ..."): surface it as-is so the user reads
    // "insufficient balance" instead of a generic "operation failed".
    final raw = error.toString();
    if (raw.contains('رصيد') ||
        raw.toLowerCase().contains('insufficient') ||
        raw.toLowerCase().contains('balance')) {
      return raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
    }
    return AppLocalizations.t('personalErrAddTx');
  }

  Future<void> addSavingsGoal(SavingsGoal goal) async {
    if (_guardMaintenance('personal/savings')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.addSavingsGoal(goal);
      final goals = await service.getSavingsGoals();
      state = state.copyWith(savingsGoals: goals);
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrAddGoal'));
    }
  }

  Future<void> updateSavingsGoal(SavingsGoal goal) async {
    if (_guardMaintenance('personal/savings')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.updateSavingsGoal(goal);
      final goals = await service.getSavingsGoals();
      state = state.copyWith(savingsGoals: goals);
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrUpdateGoal'));
    }
  }

  /// Returns true only when the goal is actually gone (mirrors
  /// [deleteTransaction]): callers must not show success on false.
  Future<bool> deleteSavingsGoal(String id) async {
    if (_guardMaintenance('personal/savings')) return false;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.deleteSavingsGoal(id);
      final goals = await service.getSavingsGoals();
      state = state.copyWith(savingsGoals: goals);
      _triggerAutoSync();
      return true;
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrDeleteGoal'));
      return false;
    }
  }

  /// Contributes to a goal in ONE backend call (deduct + credit + linked tx).
  /// No separate expense transaction — that would double-count and deduct twice.
  Future<void> contributeToGoal(
    String id,
    double amount, {
    double? goalAmount,
    String? currency,
    String? bankAccountId,
    String? paymentMethod,
    String? category,
    String? description,
    String? clientOperationId,
  }) async {
    if (_guardMaintenance('personal/savings')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.contributeToGoal(
        id,
        amount,
        goalAmount: goalAmount,
        currency: currency,
        bankAccountId: bankAccountId,
        paymentMethod: paymentMethod,
        category: category,
        description: description,
        clientOperationId: clientOperationId,
      );
      final goals = await service.getSavingsGoals();
      final txs = await service.getTransactions();
      final accounts = await service.getBankAccounts();
      final localTypes = await _AccountTypesStore.load();
      final patchedAccounts = _AccountTypesStore.apply(accounts, localTypes);
      state = state.copyWith(
        savingsGoals: goals,
        transactions: txs,
        bankAccounts: patchedAccounts,
        totalBalance: patchedAccounts.fold<double>(0, (sum, a) => sum + a.balance),
      );
      _recalcWalletTotal();
      _triggerAutoSync();
      // SWR: budget spent refreshes in the background — contribution success
      // never waits for it.
      Future<void>(() async {
        try {
          await _ref.read(budgetProvider.notifier).load();
        } catch (_) {}
      });
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrContributeGoal'));
    }
  }

  Future<void> addBankAccount({
    required String bankName,
    required String currency,
    required double openingBalance,
    String? notes,
    String accountType = 'checking',
  }) async {
    if (_guardMaintenance('personal/banks')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final knownIds = {for (final a in state.bankAccounts) a.id};
      await service.addBankAccount(
        bankName: bankName,
        currency: currency,
        openingBalance: openingBalance,
        notes: notes,
        accountType: accountType,
      );
      final accounts = await service.getBankAccounts();
      final localTypes = await _AccountTypesStore.load();
      final patchedAccounts = _AccountTypesStore.apply(accounts, localTypes);
      // The same bank may already hold this currency (e.g. USD جاري + USD
      // توفير): identify the NEW row by id, never by bank + currency, so the
      // chosen type is never stamped onto the existing sibling account.
      final sameBankCur = [
        for (final a in patchedAccounts)
          if (a.bankName == bankName && a.currency == currency) a
      ];
      PersonalBankAccount? newAcc;
      for (final a in sameBankCur.reversed) {
        if (!knownIds.contains(a.id)) { newAcc = a; break; }
      }
      if (newAcc == null && sameBankCur.length == 1) newAcc = sameBankCur.first;
      if (newAcc != null) {
        await _AccountTypesStore.save(newAcc.id, accountType);
      }
      final rates = await service.getExchangeRates();
      state = state.copyWith(
        bankAccounts: patchedAccounts,
        totalBalance: patchedAccounts.fold<double>(0, (sum, a) => sum + a.balance),
        exchangeRates: rates,
        walletTotalBalance: _convertAccountsTotal(patchedAccounts, state.walletCurrency, rates),
      );
      _recalcWalletTotal();
      _triggerAutoSync();
    } catch (e) {
      debugPrint('PersonalFinanceNotifier.addBankAccount error: $e');
      state = state.copyWith(error: AppLocalizations.t('personalErrAddBank'));
    }
  }

  Future<void> updateBankAccount(String accountId, {String? bankName, String? currency, double? balance, String? notes, String? accountType}) async {
    if (_guardMaintenance('personal/banks')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.updateBankAccount(accountId, bankName: bankName, currency: currency, balance: balance, notes: notes, accountType: accountType);
      if (accountType != null) {
        await _AccountTypesStore.save(accountId, accountType);
      }
      await load();
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrUpdateBank'));
    }
  }

  Future<void> updateBankBalance(String accountId, double newBalance) async {
    if (_guardMaintenance('personal/banks')) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.updateBankBalance(accountId, newBalance);
      await load();
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrUpdateBalance'));
    }
  }

  Future<bool> transferBetweenAccounts({required String fromId, required String toId, required double amount, required String fromCurrency, required String toCurrency, required double rate}) async {
    if (_guardMaintenance('personal/banks')) return false;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final ok = await service.transferBetweenAccounts(fromId: fromId, toId: toId, amount: amount, fromCurrency: fromCurrency, toCurrency: toCurrency, rate: rate);
      if (!ok) {
        state = state.copyWith(error: AppLocalizations.t('personalErrTransfer'));
        return false;
      }
      await load();
      _triggerAutoSync();
      return true;
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrTransfer'));
      return false;
    }
  }

  Future<void> deleteBankAccount(String accountId) async {
    if (_guardMaintenance('personal/banks')) return;
    final current = state.bankAccounts;
    if (!current.any((a) => a.id == accountId)) return;
    state = state.copyWith(bankAccounts: current.where((a) => a.id != accountId).toList());
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.deleteBankAccount(accountId);
      _triggerAutoSync();
    } catch (_) {}
  }

  Future<void> deleteBankAccountsBatch(List<String> accountIds) async {
    if (_guardMaintenance('personal/banks')) return;
    if (accountIds.isEmpty) return;
    final ids = accountIds.toSet();
    final current = state.bankAccounts;
    state = state.copyWith(bankAccounts: current.where((a) => !ids.contains(a.id)).toList());
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await Future.wait(accountIds.map((id) => service.deleteBankAccount(id)));
      _triggerAutoSync();
    } catch (_) {}
  }

  Future<void> addExchangeRate({
    required String fromCurrency,
    required String toCurrency,
    required double rate,
  }) async {
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final ok = await service.addExchangeRate(
        fromCurrency: fromCurrency,
        toCurrency: toCurrency,
        rate: rate,
      );
      if (!ok) {
        state = state.copyWith(error: AppLocalizations.t('personalErrAddRate'));
        return;
      }
      await load();
      _triggerAutoSync();
    } catch (e) {
      state = state.copyWith(error: AppLocalizations.t('personalErrAddRate'));
    }
  }

  Future<void> fetchAutoRates() async {
    try {
      final engine = _ref.read(currencyEngineProvider);
      await engine.load(forceRefresh: true);
      await load();
    } catch (_) {
      await load();
    }
  }
}

final personalFinanceProvider = StateNotifierProvider<PersonalFinanceNotifier, PersonalFinanceState>((ref) {
  return PersonalFinanceNotifier(ref);
});

// ── Budget ──

class BudgetState {
  final bool isLoading;
  final String? error;
  final bool isOfflineError;
  final List<PersonalBudget> budgets;
  final double monthlyIncome;
  final double monthlyExpenses;
  final Map<String, double> expensesByCategory;
  final String walletCurrency;
  final CurrencyEngine? _engine;
  final List<String> availableCategories;

  CurrencyEngine? get engine => _engine;

  BudgetState({
    this.isLoading = false,
    this.error,
    this.isOfflineError = false,
    this.budgets = const [],
    this.monthlyIncome = 0,
    this.monthlyExpenses = 0,
    this.expensesByCategory = const {},
    // Display currency defaults to USD always (user-changeable).
    this.walletCurrency = 'USD',
    CurrencyEngine? engine,
    this.availableCategories = const [],
  }) : _engine = engine;

  BudgetState copyWith({
    bool? isLoading,
    String? error,
    bool? isOfflineError,
    List<PersonalBudget>? budgets,
    double? monthlyIncome,
    double? monthlyExpenses,
    Map<String, double>? expensesByCategory,
    String? walletCurrency,
    CurrencyEngine? engine,
    List<String>? availableCategories,
  }) {
    return BudgetState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isOfflineError: isOfflineError ?? false,
      budgets: budgets ?? this.budgets,
      monthlyIncome: monthlyIncome ?? this.monthlyIncome,
      monthlyExpenses: monthlyExpenses ?? this.monthlyExpenses,
      expensesByCategory: expensesByCategory ?? this.expensesByCategory,
      walletCurrency: walletCurrency ?? this.walletCurrency,
      engine: engine ?? _engine,
      availableCategories: availableCategories ?? this.availableCategories,
    );
  }

  bool get hasBudgets => budgets.isNotEmpty;
  List<PersonalBudget> get sortedBudgets {
    return List<PersonalBudget>.from(budgets)
      ..sort((a, b) {
        if (a.isOverBudget && !b.isOverBudget) return -1;
        if (!a.isOverBudget && b.isOverBudget) return 1;
        if (a.daysRemaining < b.daysRemaining) return -1;
        return b.progress.compareTo(a.progress);
      });
  }
}

class BudgetNotifier extends StateNotifier<BudgetState> {
  final Ref _ref;
  BudgetNotifier(this._ref) : super(BudgetState());

  /// Generation guard: a newer load() (or phase-2 refresh) invalidates older
  /// in-flight background work so stale server data can never overwrite
  /// newer local state.
  int _loadGen = 0;

  /// Pure-local spent computation for one budget (same math as the
  /// aggregation-failure path below; conversion uses the existing engine).
  /// No network — safe for the instant phase-1 publish.
  /// Local spent for one budget (same membership rule as the detail page:
  /// budget_id match or a manually-added category of this budget). Amounts
  /// convert to the budget currency with the existing engine.
  ({double spent, Map<String, double> catSpent}) _localBudgetSpent(
    PersonalBudget b,
    List<PersonalTransaction> txs,
    CurrencyEngine engine,
  ) {
    double spent = 0;
    final catSpent = <String, double>{};
    final catIds = b.categories.map((c) => c.id).toSet();
    for (final t in txs) {
      if (!budgetTxBelongs(
          t: t, budgetId: b.id, categoryIds: catIds)) continue;
      double converted = t.amount;
      if (t.currency != b.currency) {
        try {
          final c = engine.convert(t.amount, t.currency, b.currency);
          if (c > 0) converted = c;
        } catch (_) {}
      }
      if (t.type == 'expense') {
        spent += converted;
      }
      if (t.budgetCategoryId != null && t.budgetCategoryId!.isNotEmpty) {
        catSpent[t.budgetCategoryId!] =
            (catSpent[t.budgetCategoryId!] ?? 0) + converted;
      }
    }
    return (spent: spent, catSpent: catSpent);
  }

  PersonalBudget _withSpent(
    PersonalBudget b,
    double spent,
    Map<String, double> catSpent,
  ) {
    final cats = b.categories.map((c) {
      final used = catSpent[c.id];
      if (used == null) return c;
      return c.copyWith(spentAmount: used);
    }).toList();
    return b.copyWith(totalSpent: spent, categories: cats);
  }

  bool _isBudgetBlocked() {
    try {
      final ctrl = _ref.read(platformControlsProvider).valueOrNull;
      if (ctrl == null) return false;
      if (ctrl.isAppMaintenance) return true;
      return ctrl.isRouteUnderMaintenance('/personal/budget');
    } catch (_) {
      return false;
    }
  }

  bool _guardBudgetMaintenance() {
    if (_isBudgetBlocked()) {
      state = state.copyWith(error: AppLocalizations.t('maintenanceFeatureBlocked'));
      return true;
    }
    return false;
  }

  /// Loads budgets in two phases (SWR):
  /// Phase 1 — instant: budgets + transactions from the local mirror with
  /// locally computed `totalSpent`, published immediately. `totalSpent` truth
  /// still comes from the backend aggregation endpoint (IDs + period +
  /// dedup) in phase 2 — no name matching anywhere here.
  /// Phase 2 — background: server categories + per-budget aggregations patch
  /// the published rows. Navigation never waits for either network call.
  Future<void> load() async {
    final gen = ++_loadGen;
    // Instant-open: publish held rows (even empty) synchronously — the page
    // opens immediately and phase-1 fills it in below. No await precedes this.
    state = state.copyWith(isLoading: false, error: null);
    final service = _ref.read(personalFinanceServiceProvider);
    final engine = _ref.read(currencyEngineProvider);
    final prefs = await SharedPreferences.getInstance();
    final walletCurrency = prefs.getString('wallet_currency') ?? 'USD';
    // Independent local reads start together (were sequential awaits).
    final fBudgets = service.getAllBudgets();
    final fTxs = service.getTransactions();
    List<PersonalBudget> budgets = state.budgets;
    List<PersonalTransaction> txs = [];
    bool anyFailed = false;
    bool anyOffline = false;
    try {
      budgets = await fBudgets;
    } catch (e) {
      anyFailed = true;
      if (PersonalFinanceNotifier._isOfflineError(e)) anyOffline = true;
      debugPrint('BudgetNotifier.load: getAllBudgets failed: $e');
    }
    try {
      txs = await fTxs;
    } catch (txErr) {
      anyFailed = true;
      if (PersonalFinanceNotifier._isOfflineError(txErr)) anyOffline = true;
      debugPrint('BudgetNotifier.load: getTransactions failed: $txErr');
    }
    if (gen != _loadGen) return;

    double income = 0;
    double expenses = 0;
    final byCat = <String, double>{};
    for (final t in txs) {
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      if (t.type == 'income') {
        income += converted;
      } else if (t.type == 'expense') {
        expenses += converted;
        byCat[t.category] = (byCat[t.category] ?? 0) + converted;
      }
    }

    // Phase-1 publish: local spent per budget (same math as the
    // aggregation-failure path). Server truth patches these in phase 2.
    final localBudgets = <PersonalBudget>[];
    for (final b in budgets) {
      final s = _localBudgetSpent(b, txs, engine);
      localBudgets.add(_withSpent(b, s.spent, s.catSpent));
    }
    final showError = localBudgets.isEmpty && anyFailed;
    state = state.copyWith(
      isLoading: false,
      budgets: localBudgets,
      monthlyIncome: income,
      monthlyExpenses: expenses,
      expensesByCategory: byCat,
      walletCurrency: walletCurrency,
      engine: engine,
      error: showError
          ? (anyOffline
              ? AppLocalizations.t('noInternet')
              : AppLocalizations.t('personalErrLoadBudget'))
          : null,
      isOfflineError: showError && anyOffline,
    );

    // Phase 2 — background SWR (never blocks navigation; stale runs never
    // overwrite newer state).
    Future<void>(() async {
      try {
        List<String> categories = state.availableCategories;
        try {
          final cats = await service.getCategories();
          categories = cats.map((c) => c.name).toList();
        } catch (_) {}
        // One aggregation request per budget, in parallel. Each aggregation is
        // computed server-side from real IDs with period filtering and dedup.
        final aggs = await Future.wait(budgets.map((b) async {
          try {
            return await service.getBudgetAggregation(b.id);
          } catch (_) {
            return null;
          }
        }));
        if (gen != _loadGen) return;

        final updatedBudgets = <PersonalBudget>[];
        for (var i = 0; i < budgets.length; i++) {
          final b = budgets[i];
          final agg = aggs[i];
          if (agg == null) {
            // Aggregation failed (offline). Compute spent from local transactions
            // that reference this budget, so progress bars show correct data.
            final s = _localBudgetSpent(b, txs, engine);
            updatedBudgets.add(_withSpent(b, s.spent, s.catSpent));
            continue;
          }
          // Membership comes from the backend aggregation (IDs + period + dedup).
          // Amounts are converted to the budget currency with the existing
          // engine — the conversion mechanism itself is untouched.
          double spent = 0;
          final catSpent = <String, double>{};
          for (final op in agg.operations) {
            double converted = op.amount;
            if (op.currency != b.currency) {
              try {
                final c = engine.convert(op.amount, op.currency, b.currency);
                if (c > 0) converted = c;
              } catch (_) {}
            }
            spent += converted;
            if (op.budgetCategoryId != null && op.budgetCategoryId!.isNotEmpty) {
              catSpent[op.budgetCategoryId!] =
                  (catSpent[op.budgetCategoryId!] ?? 0) + converted;
            }
          }
          updatedBudgets.add(_withSpent(b, spent, catSpent));
        }

        state = state.copyWith(
          isLoading: false,
          budgets: updatedBudgets,
          monthlyIncome: income,
          monthlyExpenses: expenses,
          expensesByCategory: byCat,
          walletCurrency: walletCurrency,
          engine: engine,
          availableCategories: categories,
        );
      } catch (e, stack) {
        debugPrint('BudgetNotifier.load phase-2 error: $e\n$stack');
      }
    });
  }

  /// Single-budget aggregation for the detail page (same backend source).
  Future<BudgetAggregation?> aggregationFor(String budgetId) async {
    if (budgetId.isEmpty) return null;
    try {
      return await _ref.read(personalFinanceServiceProvider).getBudgetAggregation(budgetId);
    } catch (e) {
      debugPrint('BudgetNotifier.aggregationFor error: $e');
      return null;
    }
  }

  void _notifyBackup() {
    try {
      _ref.read(backupServiceProvider).onDataChanged();
    } catch (_) {}
  }

  Future<void> addBudget(PersonalBudget budget) async {
    if (_guardBudgetMaintenance()) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.addBudget(budget);
      await load();
      _notifyBackup();
    } catch (e, stack) {
      debugPrint('BudgetNotifier.addBudget error: $e\n$stack');
      state = state.copyWith(error: AppLocalizations.t('personalErrAddBudget'));
    }
  }

  Future<void> updateBudget(PersonalBudget budget) async {
    if (_guardBudgetMaintenance()) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.updateBudget(budget);
      await load();
      _notifyBackup();
    } catch (e, stack) {
      debugPrint('BudgetNotifier.updateBudget error: $e\n$stack');
      state = state.copyWith(error: AppLocalizations.t('personalErrUpdateBudget'));
    }
  }

  Future<void> deleteBudget(String id) async {
    if (_guardBudgetMaintenance()) return;
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      await service.deleteBudget(id);
      await load();
      _notifyBackup();
    } catch (e, stack) {
      debugPrint('BudgetNotifier.deleteBudget error: $e\n$stack');
      state = state.copyWith(error: AppLocalizations.t('personalErrDeleteBudget'));
    }
  }
}

final budgetProvider = StateNotifierProvider<BudgetNotifier, BudgetState>((ref) {
  return BudgetNotifier(ref);
});

// ── Recurring Transactions ──

/// Result of a manual recurring execution: success, or a localized failure
/// message the page MUST show (never a phantom success).
class RecurringExecOutcome {
  final bool success;
  final String? message;
  const RecurringExecOutcome.success()
      : success = true,
        message = null;
  const RecurringExecOutcome.failure(this.message) : success = false;
}

class RecurringState {
  final bool isLoading;
  final String? error;
  final List<RecurringTransaction> recurring;
  final List<RecurringTransaction> sweepFailures;

  RecurringState({this.isLoading = false, this.error, this.recurring = const [], this.sweepFailures = const []});

  RecurringState copyWith({bool? isLoading, String? error, List<RecurringTransaction>? recurring, List<RecurringTransaction>? sweepFailures}) {
    return RecurringState(isLoading: isLoading ?? this.isLoading, error: error, recurring: recurring ?? this.recurring, sweepFailures: sweepFailures ?? this.sweepFailures);
  }

  int get activeCount => recurring.where((r) => r.isActive).length;
  int get pausedCount => recurring.where((r) => !r.isActive).length;
  int get totalCount => recurring.length;
  double get monthlyTotal => recurring.where((r) => r.isActive && r.frequency == 'monthly').fold<double>(0, (s, r) => s + r.amount);
  int get commitmentCount => recurring.where((r) => r.isActive).length;
  double get estimatedMonthlyTotal => recurring.where((r) => r.isActive).fold<double>(0, (s, r) {
    switch (r.frequency) {
      case 'daily':
        return s + r.amount * 30.4;
      case 'weekly':
        return s + r.amount * 4.33;
      case 'yearly':
        return s + r.amount / 12;
      default:
        return s + r.amount;
    }
  });

  List<RecurringTransaction> get incomeTransactions => recurring.where((r) => r.type == 'income').toList();
  List<RecurringTransaction> get expenseTransactions => recurring.where((r) => r.type == 'expense').toList();
  List<RecurringTransaction> get activeTransactions => recurring.where((r) => r.isActive).toList();
  List<RecurringTransaction> get pausedTransactions => recurring.where((r) => !r.isActive).toList();
}

class RecurringNotifier extends StateNotifier<RecurringState> {
  final Ref _ref;
  RecurringNotifier(this._ref) : super(RecurringState());

  void _notifyBackup() {
    try {
      _ref.read(backupServiceProvider).onDataChanged();
    } catch (_) {}
  }

  Future<void> load() async {
    final service = _ref.read(personalFinanceServiceProvider);
    // Instant-open: publish held rows (even empty) synchronously.
    state = state.copyWith(isLoading: false, error: null);
    try {
      final engine = _ref.read(currencyEngineProvider);
      await engine.load();
      // The sweep executes due automatic rules itself (untouched). The
      // NATIVE alarm is the single notifier — no immediate show() calls
      // here, or every list reload would buzz duplicates.
      await service.processDueRecurring(currencyEngine: engine);
      final failedSweep = service.lastRecurringSweepFailures
          .where((r) => r.type == 'expense')
          .toList(growable: false);
      final list = await service.getRecurring();
      state = state.copyWith(isLoading: false, recurring: list, sweepFailures: failedSweep);
      // Reconcile future native alarms with the fresh list.
      try {
        await RecurringReminderService.reconcile(list);
      } catch (_) {}
    } catch (_) {
      state = state.copyWith(isLoading: false, error: AppLocalizations.t('personalErrLoadRecurring'));
    }
  }

  Future<void> add(RecurringTransaction rt) async {
    try {
      await _ref.read(personalFinanceServiceProvider).addRecurring(rt);
      await load();
      _notifyBackup();
      try {
        await RecurringReminderService.reconcile(state.recurring);
      } catch (_) {}
    }
    catch (_) { state = state.copyWith(error: AppLocalizations.t('personalErrAddRecurring')); }
  }

  Future<void> update(RecurringTransaction rt) async {
    try {
      await _ref.read(personalFinanceServiceProvider).updateRecurring(rt);
      await load();
      _notifyBackup();
      try {
        await RecurringReminderService.reconcile(state.recurring);
      } catch (_) {}
    }
    catch (_) { state = state.copyWith(error: AppLocalizations.t('personalErrUpdateRecurring')); }
  }

  Future<void> toggleActive(String id, bool active) async {
    try {
      await _ref.read(personalFinanceServiceProvider).toggleRecurringActive(id, active);
      if (!active) {
        try {
          await RecurringReminderService.cancelById(id);
        } catch (_) {}
      }
      await load();
      _notifyBackup();
    }
    catch (_) { state = state.copyWith(error: AppLocalizations.t('personalErrToggleRecurring')); }
  }

  Future<void> delete(String id) async {
    try {
      await _ref.read(personalFinanceServiceProvider).deleteRecurring(id);
      try {
        await RecurringReminderService.cancelById(id);
      } catch (_) {}
      await load();
      _notifyBackup();
    }
    catch (_) { state = state.copyWith(error: AppLocalizations.t('personalErrDeleteRecurring')); }
  }

  String _execFailureMessage(Object e) {
    if (e is RecurringExecutionException) {
      switch (e.code) {
        case 'insufficient_balance':
          return AppLocalizations.t('recurringInsufficientBalance');
        case 'fx_unavailable':
          return AppLocalizations.t('recurringFxUnavailable');
        case 'account_unavailable':
          return AppLocalizations.t('recurringAccountUnavailable');
      }
      return e.message;
    }
    if (e.toString().contains('Insufficient balance')) {
      return AppLocalizations.t('personalErrInsufficientBalance');
    }
    return AppLocalizations.t('personalErrExecRecurring');
  }

  void consumeSweepWarnings() {
    if (state.sweepFailures.isEmpty) return;
    state = state.copyWith(sweepFailures: const []);
  }

  Future<RecurringExecOutcome> executeNow(RecurringTransaction rt) async {
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final engine = _ref.read(currencyEngineProvider);
      await engine.load();
      await service.executeRecurringNow(rt, currencyEngine: engine, manual: true);
      await load();
      _notifyBackup();
      return const RecurringExecOutcome.success();
    } catch (e) {
      final msg = _execFailureMessage(e);
      state = state.copyWith(error: msg);
      return RecurringExecOutcome.failure(msg);
    }
  }

  Future<RecurringExecOutcome> executeNowWithBank(RecurringTransaction rt, String bankAccountId, String currency) async {
    try {
      final service = _ref.read(personalFinanceServiceProvider);
      final engine = _ref.read(currencyEngineProvider);
      await engine.load();
      await service.executeRecurringNow(rt, overrideCurrency: currency, overrideBankAccountId: bankAccountId, currencyEngine: engine, manual: true);
      await load();
      _notifyBackup();
      return const RecurringExecOutcome.success();
    } catch (e) {
      final msg = _execFailureMessage(e);
      state = state.copyWith(error: msg);
      return RecurringExecOutcome.failure(msg);
    }
  }

  Future<void> skipOccurrence(RecurringTransaction rt) async {
    try {
      final nextDate = _calculateNextDate(rt);
      await update(rt.copyWith(nextDate: nextDate, lastExecutedAt: DateTime.now()));
    } catch (_) {
      state = state.copyWith(error: AppLocalizations.t('personalErrSkipRecurring'));
    }
  }

  Future<void> postpone(RecurringTransaction rt, DateTime newDate) async {
    try {
      await update(rt.copyWith(nextDate: newDate));
    } catch (_) {
      state = state.copyWith(error: AppLocalizations.t('personalErrPostponeRecurring'));
    }
  }

  DateTime? _calculateNextDate(RecurringTransaction rt) {
    final current = rt.nextDate ?? DateTime.now();
    switch (rt.frequency) {
      case 'daily':
        return current.add(Duration(days: rt.intervalValue));
      case 'weekly':
        return current.add(Duration(days: 7 * rt.intervalValue));
      case 'monthly':
        return _addMonths(current, rt.intervalValue);
      case 'yearly':
        return _addMonths(current, 12 * rt.intervalValue);
      default:
        return current.add(Duration(days: rt.intervalValue));
    }
  }

  DateTime _addMonths(DateTime date, int months) {
    var year = date.year;
    var month = date.month + months;
    while (month > 12) { month -= 12; year++; }
    while (month < 1) { month += 12; year--; }
    final day = date.day.clamp(1, DateTime(year, month + 1, 0).day);
    return DateTime(year, month, day);
  }
}

final recurringProvider = StateNotifierProvider<RecurringNotifier, RecurringState>((ref) {
  return RecurringNotifier(ref);
});

// ── Spending Categories ──

class CategoryState {
  final bool isLoading;
  final String? error;
  final List<SpendingCategory> categories;

  CategoryState({this.isLoading = false, this.error, this.categories = const []});

  CategoryState copyWith({bool? isLoading, String? error, List<SpendingCategory>? categories}) {
    return CategoryState(isLoading: isLoading ?? this.isLoading, error: error, categories: categories ?? this.categories);
  }
}

class CategoryNotifier extends StateNotifier<CategoryState> {
  final Ref _ref;
  CategoryNotifier(this._ref) : super(CategoryState());

  void _notifyBackup() {
    try {
      _ref.read(backupServiceProvider).onDataChanged();
    } catch (_) {}
  }

  /// Cache-first (SWR): instantly publishes locally derived categories,
  /// then refreshes from the server in the background. Spinner ONLY when
  /// nothing is cached yet — the page never waits for the network to open.
  Future<void> load() async {
    final service = _ref.read(personalFinanceServiceProvider);
    // Instant-open: publish held rows (even empty) synchronously.
    state = state.copyWith(isLoading: false, error: null);
    final local = await service.getLocalCategories();
    if (local.isNotEmpty) {
      state = state.copyWith(isLoading: false, categories: local);
    }
    try {
      final list = await service.getCategories();
      state = state.copyWith(isLoading: false, categories: list);
    } catch (_) {
      // Server unreachable: keep the instantly published local rows.
      if (local.isEmpty) {
        state = state.copyWith(isLoading: false, error: AppLocalizations.t('personalErrLoadCategories'));
      } else {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// Category writes return null on success, or the user-facing reason
  /// (duplicate name, category in use...) shown by the screen.
  Future<String?> _write(Future<void> Function(PersonalFinanceService s) op, String fallbackKey) async {
    try {
      await op(_ref.read(personalFinanceServiceProvider));
      // Saved on the device already: the list refreshes (local first, then
      // the server's derived names) without the screen waiting on network.
      unawaited(load());
      _notifyBackup();
      return null;
    } on CategoryException catch (e) {
      final msg = AppLocalizations.currentLanguage == 'en' ? e.messageEn : e.messageAr;
      state = state.copyWith(error: msg);
      return msg;
    } catch (_) {
      final msg = AppLocalizations.t(fallbackKey);
      state = state.copyWith(error: msg);
      return msg;
    }
  }

  Future<String?> add(SpendingCategory cat) => _write((s) => s.addCategory(cat), 'personalErrAddCategory');

  Future<String?> update(SpendingCategory cat) => _write((s) => s.updateCategory(cat), 'personalErrUpdateCategory');

  Future<String?> delete(String id) => _write((s) => s.deleteCategory(id), 'personalErrDeleteCategory');
}

final categoryProvider = StateNotifierProvider<CategoryNotifier, CategoryState>((ref) {
  return CategoryNotifier(ref);
});
