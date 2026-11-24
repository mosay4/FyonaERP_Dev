import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_directory/all_branches_ledger.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_ledger/business_relay_identity.dart';
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/providers/business_all_branches_provider.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../employees/data/employee_permissions.dart';
import '../../../employees/presentation/providers/employee_providers.dart';

/// A navigation target, not a REST account identifier.
final class LocalBankAccountTarget {
  const LocalBankAccountTarget(this.scope, this.id);

  static const path = '/banks/account/local';
  final DirectoryAccess scope;
  final String id;

  bool allows(DirectoryAccess? selected) =>
      isDirectoryId(id) &&
      !BranchScope.readOnly &&
      scope.financialCutover &&
      selected?.financialCutover == true &&
      sameDirectoryScope(scope, selected);
}

final localBusinessBankingProvider = Provider<LocalBusinessBanking?>((ref) {
  ref.watch(branchEpochProvider);
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  if (scope == null) return null;
  final store = ref.watch(directoryPilotStoreProvider);
  final secure = businessCashRelayEnabled
      ? ref.watch(secureStorageProvider)
      : null;
  final container = ref.container;
  final branch = BranchScope.branchId;
  final org = BranchScope.organizationId;
  var alive = true;
  ref.onDispose(() => alive = false);
  return LocalBusinessBanking._(
    store,
    scope,
    () =>
        alive &&
            !BranchScope.readOnly &&
            branch == BranchScope.branchId &&
            org == BranchScope.organizationId
        ? container.read(businessLocalLedgerScopeProvider)
        : null,
    (permission) => alive && container.read(employeeCanProvider(permission)),
    () =>
        alive &&
        (container.read(employeeWorkspaceCompanyProvider) == null ||
            employeeHasFullAccess(container.read(employeePermissionsProvider))),
    () {
      if (alive) container.read(businessBankRevisionProvider.notifier).state++;
    },
    () => secure == null
        ? Future<String?>.value()
        : readBusinessCashSession(secure, scope.workspace.accountId),
  );
});

/// One branch, one source. A retained form cannot fall back to the API when
/// selection, account or rights change while its database is opening.
final class LocalBusinessBanking {
  LocalBusinessBanking._(
    this._store,
    this.scope,
    this._current,
    this._can,
    this._fullAccess,
    this._changed,
    this._session,
  );

  final DirectoryPilotStore _store;
  final DirectoryAccess scope;
  final DirectoryAccess? Function() _current;
  final bool Function(String) _can;
  final bool Function() _fullAccess;
  final void Function() _changed;
  final Future<String?> Function() _session;

  bool get isCurrent {
    final current = _current();
    return scope.financialCutover &&
        current?.financialCutover == true &&
        sameDirectoryScope(scope, current);
  }

  Future<T> run<T>(
    BusinessLedgerAction action,
    String permission,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) execute, {
    bool changesBank = false,
    bool requireBalances = false,
    bool requireFullAccess = false,
  }) async {
    bool allowed() =>
        isCurrent &&
        _can(permission) &&
        (!requireBalances || _can('banks.balances')) &&
        (!requireFullAccess || _fullAccess());
    final session = action == BusinessLedgerAction.moveMoney
        ? await _session()
        : null;
    final grant = BusinessLedgerAccess(scope, {action}, cashSessionId: session);
    final result = await _store.withLedger(
      grant,
      () => allowed() ? _current() : null,
      (ledger) => execute(ledger, grant),
    );
    if (changesBank) {
      if (isCurrent) _changed();
    } else if (!allowed()) {
      throw const DirectoryAccessDenied();
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> accounts({
    bool requireBalances = false,
  }) async {
    final showBalances = _can('banks.balances');
    final accounts = await run(
      BusinessLedgerAction.readBank,
      'banks',
      (ledger, grant) =>
          ledger.managedBankAccounts(grant, includeBalances: showBalances),
      requireBalances: requireBalances,
    );
    final includeBalances = showBalances && _can('banks.balances');
    return [
      for (final row in accounts)
        {
          ...(Map<String, dynamic>.from(row)..remove('balance_minor')),
          'balance': includeBalances
              ? BusinessMoney.display(row['balance_minor'] as int)
              : 0,
          'is_active': row['is_active'] == 1,
          'group_key':
              'branch:${scope.branchId}:name:'
              '${(row['bank_name'] as String).trim().toLowerCase().split(RegExp(r'\s+')).join(' ')}',
        },
    ];
  }

  Future<List<Map<String, dynamic>>> history(Iterable<String> ids) async {
    final showBalances = _can('banks.balances');
    final rows = await run(
      BusinessLedgerAction.readBankHistory,
      'banks.details',
      (ledger, grant) =>
          ledger.bankHistory(grant, ids, includeBalances: showBalances),
    );
    if (showBalances && !_can('banks.balances')) {
      for (final row in rows) {
        row.remove('running_balance');
      }
    }
    return rows;
  }

  Future<Set<String>> cashCurrencies() => run(
    BusinessLedgerAction.readBank,
    'banks',
    (ledger, grant) => ledger.cashCurrencies(grant),
  );

  Future<void> saveCashCurrencies(
    Set<String> expected,
    Set<String> selected,
    String command,
  ) => run(
    BusinessLedgerAction.manageBank,
    'banks.add_delete',
    (ledger, grant) => ledger.customizeCashCurrencies(
      grant,
      commandId: command,
      currencies: selected,
      expected: expected,
    ),
    changesBank: true,
    requireFullAccess: true,
  );

  Future<bool?> overdraft() => run(
    BusinessLedgerAction.changeNegativePolicy,
    'banks',
    (ledger, grant) => ledger.savedAllowNegative(grant),
  );

  Future<void> setOverdraft(bool value) => run(
    BusinessLedgerAction.changeNegativePolicy,
    'banks',
    (ledger, grant) => ledger.setAllowNegative(grant, value),
    changesBank: true,
    requireFullAccess: true,
  );
}

/// «جميع الفروع»: the banks of every branch merged (same bank → one bank,
/// same currency → one summed balance, an extra currency → one more currency
/// of that bank). Read-only; null outside the merged view.
final allBranchesBankingProvider = Provider<AllBranchesBanking?>((ref) {
  final all = ref.watch(businessAllBranchesProvider);
  return all == null ? null : AllBranchesBanking(all);
});

final class AllBranchesBanking {
  AllBranchesBanking(this.all);
  final BusinessAllBranches all;

  /// merged account id → its original accounts (branch, id).
  final Map<String, List<(String, String)>> _members = {};

  bool get isCurrent => all.isCurrent;

  Future<List<Map<String, dynamic>>> accounts({
    bool requireBalances = false,
  }) async {
    final reads = await all.each(
      {BusinessLedgerAction.readBank},
      (ledger, grant) => ledger.managedBankAccounts(grant, includeBalances: true),
    );
    final merged = mergeAllBranchesBanks(reads, includeBalances: true);
    if (!isCurrent) throw const DirectoryAccessDenied();
    _members
      ..clear()
      ..addAll({
        for (final row in merged)
          '${row['id']}': [
            for (final m in (row['merged_accounts'] as List).cast<Map>())
              ('${m['branch_id']}', '${m['id']}'),
          ],
      });
    return merged;
  }

  /// One statement for a merged account: every original account's movements
  /// (each naming its branch), newest first.
  Future<List<Map<String, dynamic>>> history(Iterable<String> ids) async {
    if (_members.isEmpty) await accounts();
    final byBranch = <String, Set<String>>{};
    final mergedOf = <String, String>{};
    var several = false;
    for (final id in ids) {
      final members = _members[id] ?? const [];
      several = several || members.length > 1;
      for (final (branch, account) in members) {
        byBranch.putIfAbsent(branch, () => {}).add(account);
        mergedOf[account] = id;
      }
    }
    if (byBranch.isEmpty) return const [];
    final names = await all.branches();
    final reads = await all.each(
      {BusinessLedgerAction.readBankHistory},
      (ledger, grant) => ledger.bankHistory(
        grant,
        byBranch[grant.directory.branchId] ?? const <String>{},
        includeBalances: !several,
      ),
      only: byBranch.keys,
    );
    final rows = [
      for (final read in reads)
        for (final row in read.value)
          {
            ...row,
            'bank_account_id':
                mergedOf['${row['bank_account_id']}'] ?? row['bank_account_id'],
            'branch_id': read.branchId,
            'branch_name': names[read.branchId] ?? read.branchName,
            if (several) 'running_balance': null,
          }..removeWhere((key, value) => key == 'running_balance' && value == null),
    ];
    rows.sort((a, b) => '${b['date'] ?? ''}'.compareTo('${a['date'] ?? ''}'));
    return rows;
  }
}
