import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/di/providers.dart' show apiClientProvider;
import '../../../core/network/api_client.dart';
import '../../../shared/providers/current_user_provider.dart';
import '../../branches/data/branch_epoch.dart';
import '../../branches/data/branch_scope.dart';
import '../../core_business/data/local_directory/all_branches_ledger.dart';
import '../../core_business/data/local_directory/directory_database.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_report_fx.dart';
import '../../core_business/presentation/providers/business_all_branches_provider.dart';
import '../../employees/presentation/providers/employee_providers.dart';
import 'business_report_rates.dart';
import 'report_currency.dart';

final localDebtReportAllowedProvider = Provider<bool>((ref) {
  final report = ref.watch(employeeReportCanProvider('debts'));
  final customers = ref.watch(employeeCanProvider('customers.details'));
  final suppliers = ref.watch(employeeCanProvider('suppliers.details'));
  return report && customers && suppliers;
});

final localMoneyReportAllowedProvider = Provider<bool>((ref) {
  final report = ref.watch(employeeReportCanProvider('money'));
  final income = ref.watch(employeeCanProvider('income'));
  final expenses = ref.watch(employeeCanProvider('expenses'));
  return report && income && expenses;
});

/// The inventory report shows the inventory domain only; cost fields stay
/// hidden per-row (mirroring the connected `inventory_cost` permission).
final localInventoryReportAllowedProvider = Provider<bool>((ref) {
  return ref.watch(employeeReportCanProvider('inventory'));
});

final _localSalesReportAllowedProvider = Provider<bool>(
  (ref) =>
      ref.watch(employeeReportCanProvider('sales')) &&
      ref.watch(employeeCanProvider('customers.details')) &&
      ref.watch(employeeCanProvider('suppliers.details')),
);

final localReportAllowedProvider = Provider.family<bool, String>((ref, kind) {
  return switch (kind) {
    'debts' => ref.watch(localDebtReportAllowedProvider),
    'money' => ref.watch(localMoneyReportAllowedProvider),
    'inventory' => ref.watch(localInventoryReportAllowedProvider),
    'sales' => ref.watch(_localSalesReportAllowedProvider),
    'home' || 'overview' =>
      ref.watch(employeeReportCanProvider(kind)) &&
          ref.watch(localDebtReportAllowedProvider) &&
          ref.watch(localMoneyReportAllowedProvider) &&
          (kind == 'home' || ref.watch(localInventoryReportAllowedProvider)),
    _ => false,
  };
});

final businessReportsApiProvider = Provider<BusinessReportsApi>((ref) {
  ref.watch(branchEpochProvider);
  var active = true;
  ref.onDispose(() => active = false);
  // «جميع الفروع»: each branch's report from the device ledger, merged in
  // the chosen report currency (the same rates as a single branch).
  final all = ref.watch(businessAllBranchesProvider);
  if (all != null) {
    return BusinessReportsApi._withAll(
      _AllBranchReports(
        all,
        ref.watch(businessReportRatesProvider),
        () => active && all.isCurrent,
      ),
    );
  }
  final local = ref.watch(businessLocalLedgerScopeProvider);
  if (local == null) {
    ref.watch(currentUserIdProvider);
    return BusinessReportsApi(
      ref.watch(apiClientProvider),
      active: () => active,
    );
  }
  // Rebuild the source when private fields change, so already-rendered
  // data (and in-flight exports) no longer belong to the current source.
  const fields = ['inventory', 'inventory_cost.read', 'inventory_profit.read'];
  for (final field in fields) {
    ref.watch(employeeCanProvider(field));
  }
  final container = ref.container;
  return BusinessReportsApi._withDevice(
    _LocalReports(
      local,
      ref.watch(directoryPilotStoreProvider),
      ref.watch(businessReportRatesProvider),
      (kind) =>
          active &&
              !BranchScope.allMode &&
              BranchScope.organizationId == local.workspace.organizationId &&
              BranchScope.branchId == local.branchId &&
              container.read(localReportAllowedProvider(kind))
          ? container.read(businessLocalLedgerScopeProvider)
          : null,
      actions: (kind) => switch (kind) {
        'inventory' => {
          BusinessLedgerAction.readInventory,
          if (container.read(employeeCanProvider('inventory_cost.read')))
            BusinessLedgerAction.readInventoryCost,
        },
        'sales' => {
          BusinessLedgerAction.readSalesReport,
          if (container.read(employeeCanProvider('inventory')))
            BusinessLedgerAction.readInventory,
          if (container.read(employeeCanProvider('inventory_profit.read')))
            BusinessLedgerAction.readInvoiceProfit,
        },
        'home' || 'overview' => {
          BusinessLedgerAction.readOverviewReport,
          if (container.read(employeeCanProvider('inventory_profit.read')))
            BusinessLedgerAction.readInvoiceProfit,
          if (kind == 'overview' &&
              container.read(employeeCanProvider('inventory_cost.read')))
            BusinessLedgerAction.readInventoryCost,
        },
        'money' => {BusinessLedgerAction.readMoneyReport},
        'debts' => {BusinessLedgerAction.readDebtReport},
        _ => {},
      },
    ),
  );
});

final class _LocalReports {
  _LocalReports(
    this.scope,
    this.store,
    this.rates,
    this.current, {
    required Set<BusinessLedgerAction> Function(String kind) actions,
  }) : _actions = actions;
  final DirectoryAccess scope;
  final DirectoryPilotStore store;
  final BusinessReportRates? rates;
  final DirectoryAccess? Function(String) current;
  final Set<BusinessLedgerAction> Function(String kind) _actions;

  Future<T> read<T>(
    String kind,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) load,
  ) async {
    if (current(kind) == null) throw const DirectoryAccessDenied();
    final actions = _actions(kind);
    DirectoryAccess? checked() {
      final selected = current(kind);
      if (selected == null || selected.writerSession != scope.writerSession) {
        return null;
      }
      final now = _actions(kind);
      return now.length == actions.length && now.containsAll(actions)
          ? selected
          : null;
    }

    if (checked() == null) throw const DirectoryAccessDenied();
    final access = BusinessLedgerAccess(scope, actions);
    final result = await store.withLedger(
      access,
      checked,
      (ledger) => load(ledger, access),
    );
    final selected = checked();
    if (selected?.financialCutover != true ||
        !sameDirectoryScope(scope, selected)) {
      throw const ReportScopeChanged();
    }
    return result;
  }

  Future<T> report<T>(
    String kind,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess, BusinessReportFx)
    load,
  ) async {
    if (current(kind) == null) throw const DirectoryAccessDenied();
    final fx = await rates?.read() ?? const BusinessReportFx.empty();
    final result = await read(
      kind,
      (ledger, access) => load(ledger, access, fx),
    );
    // One report currency everywhere: cards, detail rows and the PDF.
    return result is Map<String, dynamic>
        ? convertReportRows(result, fx) as T
        : result;
  }
}

/// «جميع الفروع» reports: every branch computes its own report in the same
/// report currency, then the reports are merged (sums are exact; each branch
/// keeps its own headline figures in `by_branch`).
final class _AllBranchReports {
  _AllBranchReports(this.all, this.rates, this.current);
  final BusinessAllBranches all;
  final BusinessReportRates? rates;
  final bool Function() current;

  static Set<BusinessLedgerAction> actions(String kind) => switch (kind) {
    'inventory' => {
      BusinessLedgerAction.readInventory,
      BusinessLedgerAction.readInventoryCost,
    },
    'sales' => {
      BusinessLedgerAction.readSalesReport,
      BusinessLedgerAction.readInventory,
      BusinessLedgerAction.readInvoiceProfit,
    },
    'home' || 'overview' => {
      BusinessLedgerAction.readOverviewReport,
      BusinessLedgerAction.readInvoiceProfit,
      if (kind == 'overview') BusinessLedgerAction.readInventoryCost,
    },
    'money' => {BusinessLedgerAction.readMoneyReport},
    'debts' => {BusinessLedgerAction.readDebtReport},
    _ => {},
  };

  Future<List<BranchRead<T>>> read<T>(
    String kind,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) load,
  ) async {
    if (!current()) throw const ReportScopeChanged();
    final result = await all.each(actions(kind), load);
    if (!current()) throw const ReportScopeChanged();
    return result;
  }

  Future<Map<String, dynamic>> report(
    String kind,
    Future<Map<String, dynamic>> Function(
      BusinessLedger,
      BusinessLedgerAccess,
      BusinessReportFx,
    )
    load,
  ) async {
    final fx = await rates?.read() ?? const BusinessReportFx.empty();
    final reads = await read(kind, (ledger, access) => load(ledger, access, fx));
    return convertReportRows(mergeBranchReports(reads), fx);
  }
}

/// Business reports API (قسم التقارير) — read-only, FX-honest aggregates.
class BusinessReportsApi {
  final ApiClient? _client;
  final _LocalReports? _device;
  final _AllBranchReports? _all;
  final bool Function()? _active;
  BusinessReportsApi(this._client, {bool Function()? active})
    : _device = null,
      _all = null,
      _active = active;
  BusinessReportsApi._withDevice(this._device)
    : _client = null,
      _all = null,
      _active = null;
  BusinessReportsApi._withAll(this._all)
    : _client = null,
      _device = null,
      _active = null;

  /// Device ledger data (one branch, or all branches merged).
  bool get isDeviceLedger => _device != null || _all != null;

  /// The merged «جميع الفروع» view (read-only).
  bool get isAllBranches => _all != null;
  DirectoryAccess? get deviceScope => _device?.scope;

  /// The account whose device holds the reports' data.
  String? get deviceAccountId =>
      _device?.scope.workspace.accountId ?? _all?.all.workspace.accountId;

  /// Stable identity of the data source. Two instances with the same key see
  /// exactly the same facts; only a real scope/source change may clear a page.
  String get scopeKey {
    final scope = deviceScope;
    final all = _all;
    if (all != null) return 'device:${all.all.scopeKey}';
    return scope == null
        ? 'rest:${BusinessReportsApi.scopeIdentity}'
        : 'device:${scope.workspace.storageId}:${scope.branchId}:'
              '${scope.writerSession}';
  }

  Future<Set<String>> deviceCurrencies() async {
    final all = _all;
    if (all != null) {
      return {
        for (final read in await all.read(
          'debts',
          (ledger, access) => ledger.debtReportCurrencies(access),
        ))
          ...read.value,
        for (final read in await all.read(
          'money',
          (ledger, access) => ledger.moneyReportCurrencies(access),
        ))
          ...read.value,
        for (final read in await all.read(
          'inventory',
          (ledger, access) => ledger.inventoryReportCurrencies(access),
        ))
          ...read.value,
      };
    }
    final device = _device;
    if (device == null) return {};
    final codes = <String>{};
    if (device.current('debts') != null) {
      codes.addAll(
        await device.read(
          'debts',
          (ledger, access) => ledger.debtReportCurrencies(access),
        ),
      );
    }
    if (device.current('money') != null) {
      codes.addAll(
        await device.read(
          'money',
          (ledger, access) => ledger.moneyReportCurrencies(access),
        ),
      );
    }
    if (device.current('inventory') != null &&
        device
            ._actions('inventory')
            .contains(BusinessLedgerAction.readInventoryCost)) {
      codes.addAll(
        await device.read(
          'inventory',
          (ledger, access) => ledger.inventoryReportCurrencies(access),
        ),
      );
    }
    if (device.current('sales') != null &&
        // Debt report currencies already include all active invoice currencies.
        device.current('debts') == null) {
      codes.addAll(
        await device.read(
          'sales',
          (ledger, access) => ledger.salesReportCurrencies(access),
        ),
      );
    }
    return codes;
  }

  static String get scopeIdentity =>
      '${BranchScope.organizationId}|${BranchScope.allMode}|${BranchScope.branchId}';

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> params,
  ) async {
    if (isDeviceLedger) throw const ReportNotAvailableLocally();
    if (BranchScope.awaitingServerSelection ||
        BranchScope.tokenClaims(BranchScope.token)?['qa_business_ledger'] ==
            true) {
      throw const ReportNotAvailableLocally();
    }
    final scope = BranchScope.selection;
    final token = BranchScope.token;
    final all = BranchScope.allMode;
    final permitted = all
        ? BranchScope.permittedBranchIds.toSet()
        : const <String>{};
    if (all && permitted.isEmpty) throw const ReportNotAvailableLocally();
    bool current() =>
        scope == BranchScope.selection && _active?.call() != false;
    if (!current()) throw const ReportScopeChanged();
    try {
      final response = await _client!.get(
        path,
        queryParameters: params,
        options: Options(
          headers: {'X-Branch-Token': token ?? ''},
          extra: {
            'branchScopeSnapshot': true,
            'branchScopeIdentity': scopeIdentity,
          },
        ),
      );
      if (!current()) throw const ReportScopeChanged();
      final result = _map(response.data);
      if (result['totals_complete'] == false) {
        throw StateError('Incomplete report totals cannot be displayed');
      }
      if (all) {
        final returned = (result['branch_ids'] as List?)
            ?.whereType<String>()
            .toSet();
        if (result['totals_complete'] != true ||
            returned == null ||
            returned.length != permitted.length ||
            !returned.containsAll(permitted)) {
          throw const ReportNotAvailableLocally();
        }
      }
      return result;
    } catch (_) {
      if (!current()) throw const ReportScopeChanged();
      rethrow;
    }
  }

  Map<String, dynamic> _map(dynamic body) {
    final data = body is Map<String, dynamic> && body.containsKey('data')
        ? body['data']
        : body;
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Future<Map<String, dynamic>> home(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    if (_all != null) return _allOverview('home', currency, from, to);
    if (_device != null) return _deviceOverview('home', currency, from, to);
    return _get('/business-reports/home', _params(from, to, currency));
  }

  Future<Map<String, dynamic>> salesPurchases(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    final all = _all;
    if (all != null) {
      return all.report(
        'sales',
        (ledger, access, fx) => ledger.salesReport(
          access,
          currency: currency,
          from: from,
          to: to,
          fx: fx,
        ),
      );
    }
    final device = _device;
    if (device != null) {
      return device.report(
        'sales',
        (ledger, access, fx) => ledger.salesReport(
          access,
          currency: currency,
          from: from,
          to: to,
          fx: fx,
        ),
      );
    }
    return _get(
      '/business-reports/sales-purchases',
      _params(from, to, currency),
    );
  }

  Future<Map<String, dynamic>> money(
    String? from,
    String? to, [
    String currency = 'SAR',
    String? accountId,
  ]) async {
    final all = _all;
    if (all != null) {
      // One account belongs to one branch: the merged report is the branch's
      // own when an account is chosen.
      return all.report('money', (ledger, access, fx) async {
        if (accountId != null &&
            !(await ledger.managedBankAccounts(
              BusinessLedgerAccess(access.directory, {
                BusinessLedgerAction.readBank,
              }),
              includeBalances: false,
            )).any((row) => row['id'] == accountId)) {
          return <String, dynamic>{};
        }
        return ledger.moneyReport(
          access,
          currency: currency,
          from: from,
          to: to,
          accountId: accountId,
          fx: fx,
        );
      });
    }
    final device = _device;
    if (device != null) {
      return device.report(
        'money',
        (ledger, access, fx) => ledger.moneyReport(
          access,
          currency: currency,
          from: from,
          to: to,
          accountId: accountId,
          fx: fx,
        ),
      );
    }
    return _get('/business-reports/money', {
      ..._params(from, to, currency),
      if (accountId != null && accountId.isNotEmpty) 'account_id': accountId,
    });
  }

  Future<Map<String, dynamic>> inventory(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    final all = _all;
    if (all != null) {
      return all.report(
        'inventory',
        (ledger, access, fx) => ledger.inventoryReport(
          access,
          currency: currency,
          from: from,
          to: to,
          fx: fx,
        ),
      );
    }
    final device = _device;
    if (device != null) {
      return device.report(
        'inventory',
        (ledger, access, fx) => ledger.inventoryReport(
          access,
          currency: currency,
          from: from,
          to: to,
          fx: fx,
        ),
      );
    }
    return _get('/business-reports/inventory', _params(from, to, currency));
  }

  Future<Map<String, dynamic>> debts(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    final all = _all;
    if (all != null) {
      return all.report(
        'debts',
        (ledger, access, fx) => ledger.debtReport(
          access,
          from: from,
          to: to,
          currency: currency,
          fx: fx,
        ),
      );
    }
    final device = _device;
    if (device != null) {
      return device.report(
        'debts',
        (ledger, access, fx) => ledger.debtReport(
          access,
          from: from,
          to: to,
          currency: currency,
          fx: fx,
        ),
      );
    }
    return _get('/business-reports/debts', _params(from, to, currency));
  }

  Future<Map<String, dynamic>> overview(
    String? from,
    String? to, [
    String currency = 'SAR',
  ]) async {
    if (_all != null) return _allOverview('overview', currency, from, to);
    if (_device != null) return _deviceOverview('overview', currency, from, to);
    return _get('/business-reports/overview', _params(from, to, currency));
  }

  Future<Map<String, dynamic>> _deviceOverview(
    String kind,
    String currency,
    String? from,
    String? to,
  ) => _device!.report(
    kind,
    (ledger, access, fx) => ledger.overviewReport(
      access,
      currency: currency,
      from: from,
      to: to,
      home: kind == 'home',
      fx: fx,
    ),
  );

  Future<Map<String, dynamic>> _allOverview(
    String kind,
    String currency,
    String? from,
    String? to,
  ) => _all!.report(
    kind,
    (ledger, access, fx) => ledger.overviewReport(
      access,
      currency: currency,
      from: from,
      to: to,
      home: kind == 'home',
      fx: fx,
    ),
  );

  Map<String, String> _params(String? from, String? to, [String? currency]) => {
    'valuation_basis': 'latest_approved',
    if (from != null && from.isNotEmpty) 'from_date': from,
    if (to != null && to.isNotEmpty) 'to_date': to,
    if (currency != null && currency.isNotEmpty) 'currency': currency,
    if (!BranchScope.allMode &&
        BranchScope.branchId != null &&
        BranchScope.branchId!.isNotEmpty)
      'branch_id': BranchScope.branchId!,
  };

  /// Dio error → the server's Arabic detail when available.
  static String serverMessage(Object e) {
    if (e is DioException) {
      final d = e.response?.data;
      final detail = d is Map ? d['detail'] ?? d['message'] : null;
      if (detail is String) return detail;
      if (detail is Map) return '${detail['message'] ?? ''}';
    }
    return '';
  }

  static List<Map<String, dynamic>> missingRates(Object e) {
    if (e is! DioException || e.response?.data is! Map) return const [];
    final d = e.response!.data as Map;
    final detail = d['detail'] ?? d['message'];
    if (detail is! Map || detail['code'] != 'report_fx_missing')
      return const [];
    return ((detail['missing'] as List?) ?? const [])
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  static bool ratesPending(Object e) {
    if (e is! DioException || e.response?.data is! Map) return false;
    final data = e.response!.data as Map;
    final detail = data['detail'] ?? data['message'];
    return detail is Map && detail['code'] == 'report_rates_initializing';
  }

  static bool includesDeviceLedger(Object e) {
    if (e is! DioException || e.response?.data is! Map) return false;
    final detail = (e.response!.data as Map)['detail'];
    return detail is Map && detail['code'] == 'report_device_scope';
  }
}

class ReportScopeChanged implements Exception {
  const ReportScopeChanged();
}

/// The connected totals are not truthful for a branch whose writer is local.
class ReportNotAvailableLocally implements Exception {
  const ReportNotAvailableLocally();
}
