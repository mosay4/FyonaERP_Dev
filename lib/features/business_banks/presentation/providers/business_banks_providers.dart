import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/services/currency/business_currency_scope.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/business_bank_models.dart';
import '../../data/business_banks_api.dart';
import 'local_business_banking.dart';

final businessBanksApiProvider = Provider<BusinessBanksApi>(
  (ref) => BusinessBanksApi(ref.watch(apiClientProvider)),
);

final businessBankBalanceReadProvider = Provider<bool>(
  (ref) => ref.watch(employeeCanProvider('banks.balances')),
);

/// Business cash vault: balances stashed here when a cash currency is
/// removed, restored when it is re-added. Per-user keys, fully separate
/// from the Personal vault.
class BizCashService {
  final BusinessBanksApi _api;
  final bool Function()? _canUse;
  BizCashService(this._api, {bool Function()? canUse}) : _canUse = canUse;
  bool get _current => _canUse?.call() ?? true;

  String _vaultKey(String userId, String currency) =>
      'biz_cash_vault_${userId.isEmpty ? 'global' : userId}_$currency';

  /// Ensure a cash row exists for every [wanted] currency that is also in
  /// [enabled]. Never resurrects removed currencies, never duplicates.
  Future<void> ensureCashAccounts(
    List<String> wanted, {
    Set<String>? enabled,
    String userId = '',
  }) async {
    if (!_current) return;
    try {
      final raw = await _api.listAccounts();
      if (!_current) return;
      final existing = {
        for (final a in raw.whereType<Map>())
          if ((a['bank_name']?.toString() ?? '') == 'كاش' ||
              isBizCashAccount((a['bank_name']?.toString() ?? '')))
            (a['currency']?.toString().toUpperCase() ?? ''),
      };
      for (final code in wanted.map((e) => e.toUpperCase()).toSet()) {
        if (!_current) return;
        if (existing.contains(code)) continue;
        if (enabled != null && !enabled.contains(code)) continue;
        double opening = 0;
        try {
          final prefs = await SharedPreferences.getInstance();
          if (!_current) return;
          opening = prefs.getDouble(_vaultKey(userId, code)) ?? 0;
          if (opening > 0) {
            await prefs.remove(_vaultKey(userId, code));
          }
        } catch (_) {}
        if (!_current) return;
        await _api.createAccount(
          bankName: 'كاش',
          accountName: 'حساب الكاش',
          accountNumber: 'CASH',
          currency: code,
          balance: opening,
        );
      }
    } catch (_) {}
  }

  Future<double?> takeStashedCashBalance(
    String currency, {
    String userId = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_current) return null;
      final v = prefs.getDouble(_vaultKey(userId, currency.toUpperCase()));
      if (v != null && v > 0) {
        await prefs.remove(_vaultKey(userId, currency.toUpperCase()));
        return v;
      }
    } catch (_) {}
    return null;
  }

  Future<void> stashCashBalance(
    String currency,
    double balance, {
    String userId = '',
  }) async {
    if (balance <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_current) return;
      await prefs.setDouble(_vaultKey(userId, currency.toUpperCase()), balance);
    } catch (_) {}
  }
}

final bizCashServiceProvider = Provider<BizCashService>((ref) {
  ref.watch(branchEpochProvider);
  final branch = BranchScope.branchId;
  final org = BranchScope.organizationId;
  var alive = true;
  ref.onDispose(() => alive = false);
  return BizCashService(
    ref.watch(businessBanksApiProvider),
    canUse: () =>
        alive &&
        !BranchScope.readOnly &&
        branch == BranchScope.branchId &&
        org == BranchScope.organizationId &&
        ref.read(businessLocalLedgerScopeProvider) == null,
  );
});

class BusinessBanksState {
  final bool isLoading;
  final List<BusinessBankAccount> accounts;
  final double walletTotal;
  final String walletCurrency;
  final String? error;
  const BusinessBanksState({
    this.isLoading = false,
    this.accounts = const [],
    this.walletTotal = 0,
    this.walletCurrency = 'USD',
    this.error,
  });
  BusinessBanksState copyWith({
    bool? isLoading,
    List<BusinessBankAccount>? accounts,
    double? walletTotal,
    String? walletCurrency,
    String? error,
  }) => BusinessBanksState(
    isLoading: isLoading ?? this.isLoading,
    accounts: accounts ?? this.accounts,
    walletTotal: walletTotal ?? this.walletTotal,
    walletCurrency: walletCurrency ?? this.walletCurrency,
    error: error,
  );
}

class BusinessBanksNotifier extends StateNotifier<BusinessBanksState> {
  final BusinessBanksApi? _api;
  final LocalBusinessBanking? _local;
  final bool Function()? _connectedScope;
  CurrencyEngine _engine;
  int _readGeneration = 0;
  bool _opened = false;

  BusinessBanksNotifier(
    this._api,
    this._engine, {
    bool Function()? connectedScope,
  }) : _local = null,
       _connectedScope = connectedScope,
       super(const BusinessBanksState());

  BusinessBanksNotifier.local(LocalBusinessBanking local)
    : _api = null,
      _local = local,
      _connectedScope = null,
      _engine = CurrencyEngine(),
      super(const BusinessBanksState());

  bool get isLocal => _local != null;

  bool get isCurrent =>
      mounted && (_local?.isCurrent ?? _connectedScope?.call() ?? true);

  BusinessBanksApi get _connected {
    if (!isCurrent || isLocal) throw const DirectoryAccessDenied();
    return _api!;
  }

  static const walletCurrencyKey = 'biz_wallet_currency';

  Future<void> load() async {
    if (!isCurrent) return;
    _opened = true;
    final generation = ++_readGeneration;
    if (!isLocal) state = state.copyWith(isLoading: true, error: null);
    try {
      final prefs = await SharedPreferences.getInstance();
      final wallet = prefs.getString(walletCurrencyKey) ?? 'USD';
      final raw = _local != null
          ? await _local.accounts()
          : await _connected.listAccounts();
      final accounts = <BusinessBankAccount>[];
      for (final a in raw.whereType<Map>()) {
        final nested = a['accounts'];
        if (nested is List && nested.isNotEmpty) {
          // All-branches aggregate: keep every ORIGINAL account (its own id,
          // branch and balance) so details and statements stay exact.
          for (final n in nested.whereType<Map>()) {
            accounts.add(
              BusinessBankAccount.fromServer(Map<String, dynamic>.from(n)),
            );
          }
        } else {
          accounts.add(
            BusinessBankAccount.fromServer(Map<String, dynamic>.from(a)),
          );
        }
      }
      final engine = isLocal ? CurrencyEngine() : _engine;
      try {
        await engine.load();
      } catch (_) {}
      if (!isCurrent || generation != _readGeneration) return;
      _engine = engine;
      state = state.copyWith(
        isLoading: false,
        accounts: accounts,
        walletCurrency: wallet,
        walletTotal: totalIn(accounts, wallet),
      );
    } catch (e) {
      if (isCurrent && generation == _readGeneration) {
        state = state.copyWith(
          isLoading: false,
          accounts: isLocal ? const [] : null,
          walletTotal: isLocal ? 0 : null,
          error: e.toString(),
        );
      }
    }
  }

  double totalIn(List<BusinessBankAccount> accounts, String target) {
    var sum = 0.0;
    for (final a in accounts) {
      final v = convert(a.balance, a.currency, target);
      sum += v == 0 ? 0 : v;
    }
    return sum;
  }

  double convertAccountsToWallet(List<BusinessBankAccount> accounts) =>
      totalIn(accounts, state.walletCurrency);

  double convert(double amount, String from, String to) =>
      _engine.convert(amount, from, to);

  double? rate(String from, String to) => _engine.getRate(from, to);

  BusinessRate? transferQuote(String from, String to) => from == to
      ? BusinessRate(from, to, '1')
      : businessSavedQuote(_engine, from, to);

  Future<List<Map<String, dynamic>>> history(List<String> ids) async {
    final local = _local;
    if (local != null) return local.history(ids);
    final pages = await Future.wait([
      for (final id in ids) _connected.transactions(id),
    ]);
    if (!isCurrent) throw const DirectoryAccessDenied();
    return [
      for (final page in pages)
        for (final row in page.whereType<Map>()) Map<String, dynamic>.from(row),
    ];
  }

  Future<void> setWalletCurrency(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(walletCurrencyKey, code);
    } catch (_) {}
    if (!isCurrent) return;
    state = state.copyWith(
      walletCurrency: code,
      walletTotal: totalIn(state.accounts, code),
    );
  }

  /// The branch's cash: one «كاش» account per enabled currency, kept on the
  /// device like every other account. Only missing ones are created; a
  /// currency the user removed is no longer enabled and is not recreated.
  Future<void> ensureLocalCash(Iterable<String> currencies) async {
    final local = _local;
    if (local == null || !isCurrent) return;
    final rows = await local.accounts();
    final existing = {
      for (final a in rows)
        if ('${a['bank_name'] ?? ''}' == 'كاش' || isBizCashAccount('${a['bank_name'] ?? ''}'))
          '${a['currency'] ?? ''}'.toUpperCase(),
    };
    for (final code in {for (final c in currencies) c.trim().toUpperCase()}) {
      if (code.isEmpty || existing.contains(code) || !isCurrent) continue;
      try {
        await addAccount(
          bankName: 'كاش',
          accountName: 'حساب الكاش',
          accountNumber: 'CASH',
          currency: code,
          // One command per branch and currency: two devices (or a retry)
          // never create a second cash account for the same currency.
          commandId: const Uuid().v5(Uuid.NAMESPACE_URL, 'fyona-cash:${local.scope.branchId}:$code'),
        );
      } catch (_) {
        // Recreated on the next visit; the banks list never breaks for it.
      }
    }
  }

  Future<void> addAccount({
    required String bankName,
    required String accountName,
    required String accountNumber,
    String? iban,
    required String currency,
    String accountType = 'checking',
    double balance = 0,
    String? decimalBalance,
    String? commandId,
  }) async {
    final local = _local;
    if (local != null) {
      await local.run(
        BusinessLedgerAction.createBank,
        'banks.add_delete',
        (ledger, grant) => ledger.createAccount(
          grant,
          commandId: commandId ?? const Uuid().v4(),
          bankName: bankName,
          accountName: accountName,
          accountNumber: accountNumber,
          iban: iban,
          currency: currency,
          accountType: accountType,
          openingMinor: BusinessMoney.minor(
            decimalBalance ?? balance.toString(),
          ),
          managed: true,
        ),
        changesBank: true,
      );
      return;
    }
    await _connected.createAccount(
      bankName: bankName,
      accountName: accountName,
      accountNumber: accountNumber,
      iban: iban,
      currency: currency,
      accountType: accountType,
      balance: balance,
    );

    await load();
  }

  Future<void> updateAccount(
    String id, {
    String? bankName,
    String? accountName,
    String? accountNumber,
    String? iban,
    String? currency,
    String? accountType,
    double? balance,
    String? decimalBalance,
    double? originalBalance,
    String? commandId,
  }) async {
    final local = _local;
    if (local != null) {
      await local.run(
        BusinessLedgerAction.manageBank,
        'banks.add_delete',
        (ledger, grant) => ledger.editBankAccount(
          grant,
          accountId: id,
          commandId: commandId ?? const Uuid().v4(),
          bankName: bankName,
          accountName: accountName,
          accountNumber: accountNumber,
          iban: iban,
          currency: currency,
          type: accountType,
          balanceMinor: decimalBalance != null || balance != null
              ? BusinessMoney.minor(decimalBalance ?? balance.toString())
              : null,
          expectedBalanceMinor: originalBalance == null
              ? null
              : BusinessMoney.minor(originalBalance.toString()),
        ),
        changesBank: true,
        requireBalances: decimalBalance != null || balance != null,
      );
      return;
    }
    await _connected.updateAccount(
      id,
      bankName: bankName,
      accountName: accountName,
      accountNumber: accountNumber,
      iban: iban,
      currency: currency,
      accountType: accountType,
      balance: balance,
    );

    await load();
  }

  Future<void> deleteAccount(String id) async {
    if (isLocal) {
      await _closeLocal([id]);
      return;
    }
    await load();
  }

  /// Removes ONE cash currency (vaults its balance for restore). The last
  /// remaining cash row is always protected — cash itself never disappears.
  Future<void> deleteCashCurrency(
    BusinessBankAccount target, {
    String userId = '',
  }) async {
    if (isLocal) {
      await _closeLocal([target.id], onlyCash: true);
      return;
    }
    final cashCount = state.accounts
        .where((a) => isBizCashAccount(a.bankName))
        .length;
    if (cashCount <= 1) {
      throw StateError('last-cash');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      if (target.balance > 0) {
        final scope = userId.trim().isEmpty ? 'global' : userId.trim();
        await prefs.setDouble(
          'biz_cash_vault_${scope}_${target.currency.toUpperCase()}',
          target.balance,
        );
      }
    } catch (_) {}
    await _connected.deleteAccount(target.id);
    await load();
  }

  Future<void> deleteBankCompletely(String bankName, {String? groupKey}) async {
    if (isBizCashAccount(bankName)) {
      throw StateError('last-cash');
    }
    final ids = state.accounts
        .where(
          (a) => isLocal && groupKey != null
              ? a.groupKey == groupKey
              : a.bankName == bankName,
        )
        .map((a) => a.id)
        .toList();
    if (isLocal) {
      await _closeLocal(ids);
      return;
    }
    await Future.wait(ids.map((id) => _connected.deleteAccount(id)));

    await load();
  }

  Future<void> _closeLocal(List<String> ids, {bool onlyCash = false}) =>
      _local!.run(
        BusinessLedgerAction.manageBank,
        'banks.add_delete',
        (ledger, grant) => ledger.closeBankAccounts(
          grant,
          commandId: const Uuid().v4(),
          accountIds: ids,
          onlyCash: onlyCash,
        ),
        changesBank: true,
      );

  /// Bank-to-bank transfer. Cross-currency amounts are converted app-side
  /// with a live rate (same mechanism as Personal); the backend applies
  /// both legs atomically. When the caller already computed a previewed
  /// conversion, pass it explicitly so preview and execution agree exactly.
  Future<bool> transfer({
    required String fromId,
    required String toId,
    required double amount,
    double? toAmount,
    double? rate,
    String? decimalAmount,
    BusinessRate? quote,
    String? commandId,
  }) async {
    final local = _local;
    if (local != null) {
      await local.run(
        BusinessLedgerAction.transfer,
        'banks.transfer',
        (ledger, grant) => ledger.transfer(
          grant,
          commandId: commandId ?? const Uuid().v4(),
          fromId: fromId,
          toId: toId,
          amountMinor: BusinessMoney.minor(decimalAmount ?? amount.toString()),
          rate: quote,
        ),
        changesBank: true,
      );
      return true;
    }
    final from = state.accounts.firstWhere((a) => a.id == fromId);
    final to = state.accounts.firstWhere((a) => a.id == toId);
    double? sendTo = toAmount;
    double? sendRate = rate;
    if (from.currency != to.currency && (sendTo == null || sendRate == null)) {
      final found = _engine.getRate(from.currency, to.currency);
      if (found == null || found <= 0) return false;
      sendRate = found;
      sendTo = amount * found;
    }
    await _connected.transfer(
      fromId: fromId,
      toId: toId,
      amount: amount,
      toAmount: from.currency == to.currency ? null : sendTo,
      rate: from.currency == to.currency ? null : sendRate,
    );

    await load();
    return true;
  }

  Future<void> deposit(String id, double amount, {String? description}) async {
    if (isLocal) {
      await _moveLocal(id, amount, false, description);
      return;
    }
    await _connected.deposit(id, amount, description: description);

    await load();
  }

  Future<void> withdraw(String id, double amount, {String? description}) async {
    if (isLocal) {
      await _moveLocal(id, amount, true, description);
      return;
    }
    await _connected.withdraw(id, amount, description: description);

    await load();
  }

  Future<void> _moveLocal(
    String id,
    double amount,
    bool withdraw,
    String? description,
  ) async {
    await _local!.run(
      BusinessLedgerAction.moveMoney,
      withdraw ? 'expenses' : 'income',
      (ledger, grant) => ledger.move(
        grant,
        commandId: const Uuid().v4(),
        accountId: id,
        amountMinor: BusinessMoney.minor(amount.toString()),
        withdraw: withdraw,
        description: description,
      ),
      changesBank: true,
    );
  }
}

final businessBanksProvider =
    StateNotifierProvider<BusinessBanksNotifier, BusinessBanksState>((ref) {
      ref.watch(branchEpochProvider);
      final local = ref.watch(localBusinessBankingProvider);
      if (local != null) {
        final notifier = BusinessBanksNotifier.local(local);
        ref.listen(businessBankRevisionProvider, (_, _) {
          if (notifier._opened) notifier.load();
        });
        ref.listen(employeeCanProvider('banks'), (_, _) {
          if (notifier._opened) notifier.load();
        });
        ref.listen(businessBankBalanceReadProvider, (_, _) {
          if (notifier._opened) notifier.load();
        });
        return notifier;
      }
      final branch = BranchScope.branchId;
      final org = BranchScope.organizationId;
      final all = BranchScope.allMode;
      return BusinessBanksNotifier(
        ref.watch(businessBanksApiProvider),
        ref.watch(currencyEngineProvider),
        connectedScope: () =>
            branch == BranchScope.branchId &&
            org == BranchScope.organizationId &&
            all == BranchScope.allMode &&
            ref.read(localBusinessBankingProvider) == null,
      );
    });


/// Opening a device-ledger branch makes sure its cash exists (one «كاش» per
/// enabled currency), without visiting the banks screen first.
final localCashWarmupProvider = FutureProvider.autoDispose<void>((ref) async {
  ref.watch(branchEpochProvider);
  if (ref.watch(localBusinessBankingProvider) == null ||
      BranchScope.readOnly ||
      ref.watch(employeeWorkspaceCompanyProvider) != null ||
      !ref.watch(employeeCanProvider('banks.add_delete'))) {
    return;
  }
  final notifier = ref.read(businessBanksProvider.notifier);
  final enabled = await loadBizEnabledCurrencies(ref.read(currentUserIdProvider).trim());
  try {
    await notifier.ensureLocalCash(enabled);
    await notifier.load();
  } catch (_) {}
});
