import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/di/providers.dart' show apiClientProvider, secureStorageProvider;
import '../../../../core/network/api_client.dart';
import '../../branches/data/branch_epoch.dart';
import '../../branches/data/branch_scope.dart';
import '../../core_business/data/local_directory/directory_database.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_money.dart';
import '../../core_business/data/local_ledger/business_relay_identity.dart';
import '../../core_business/presentation/providers/business_ledger_session.dart';
import '../../employees/presentation/providers/employee_providers.dart';

final localBankReconciliationAllowedProvider = Provider<bool>((ref) {
  final bank = ref.watch(employeeCanProvider('reconciliation.bank'));
  final balances = ref.watch(employeeCanProvider('banks.balances'));
  return bank && balances;
});

final localInventoryReconciliationAllowedProvider = Provider<bool>((ref) {
  final recon = ref.watch(employeeCanProvider('reconciliation.inventory'));
  final counting = ref.watch(employeeCanProvider('inventory.count'));
  return recon && counting;
});

final reconciliationApiProvider = Provider<ReconciliationApi>((ref) {
  ref.watch(branchEpochProvider);
  final local = ref.watch(businessLocalLedgerScopeProvider);
  if (local == null) return ReconciliationApi(ref.watch(apiClientProvider));
  final container = ref.container;
  var active = true;
  ref.onDispose(() => active = false);
  return ReconciliationApi._device(
    _DeviceBankReconciliation(
      local,
      ref.watch(directoryPilotStoreProvider),
      (action) =>
          active &&
              !BranchScope.allMode &&
              BranchScope.organizationId == local.workspace.organizationId &&
              BranchScope.branchId == local.branchId &&
              (switch (action) {
                BusinessLedgerAction.readInventoryReconciliation ||
                BusinessLedgerAction.checkInventoryReconciliation ||
                BusinessLedgerAction.approveInventoryReconciliation =>
                  container.read(localInventoryReconciliationAllowedProvider),
                _ => container.read(localBankReconciliationAllowedProvider),
              }) &&
              ((!const {
                    BusinessLedgerAction.approveBankReconciliation,
                    BusinessLedgerAction.approveInventoryReconciliation,
                  }.contains(action)) ||
                  container.read(
                    employeeCanProvider('reconciliation.equalize'),
                  ))
          ? container.read(businessLocalLedgerScopeProvider)
          : null,
      () => container.read(businessBankRevisionProvider.notifier).state++,
      () => container.read(businessOperationsRevisionProvider.notifier).state++,
      () => businessCashRelayEnabled && container.read(employeeCanProvider('banks.details'))
          ? readBusinessCashSession(container.read(secureStorageProvider), local.workspace.accountId)
          : Future<String?>.value(null),
    ),
  );
});

/// A device id only travels with its source in memory, never in a REST route.
final class LocalReconciliationLink {
  const LocalReconciliationLink(
    this.source,
    this.ids, {
    this.rtype = 'bank',
  });
  final ReconciliationApi source;
  final String ids;
  final String rtype;

  bool matches(ReconciliationApi current) =>
      identical(source, current) &&
      (rtype == 'inventory'
          ? source.canReadDeviceInventory
          : source.canReadDeviceBank);
}

final class ReconciliationNotOnDevice implements Exception {
  const ReconciliationNotOnDevice();
}

final class _DeviceBankReconciliation {
  _DeviceBankReconciliation(
    this.scope,
    this.store,
    this.current,
    this.balancesChanged,
    this.stockChanged,
    this.cashSession,
  );
  final DirectoryAccess scope;
  final DirectoryPilotStore store;
  final DirectoryAccess? Function(BusinessLedgerAction) current;
  final void Function() balancesChanged;
  final void Function() stockChanged;
  final Future<String?> Function() cashSession;

  bool allowed(BusinessLedgerAction action) {
    final selected = current(action);
    return selected?.financialCutover == true &&
        sameDirectoryScope(scope, selected);
  }

  Future<T> run<T>(
    BusinessLedgerAction action,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess, bool Function())
    load,
  ) async {
    if (!allowed(action)) throw const DirectoryAccessDenied();
    final session = (action == BusinessLedgerAction.checkBankReconciliation ||
        action == BusinessLedgerAction.approveBankReconciliation) ? await cashSession() : null;
    if (!allowed(action)) throw const DirectoryAccessDenied();
    final grant = BusinessLedgerAccess(scope, {action}, cashSessionId: session);
    final result = await store.withLedger(
      grant,
      () => current(action),
      (ledger) => load(ledger, grant, () => allowed(action)),
    );
    if (!allowed(action)) throw const DirectoryAccessDenied();
    return result;
  }
}

/// Business Reconciliation API (قسم المطابقة).
/// One source for the entire flow. An enrolled branch never uses the old
/// writer, even when a type of settlement is not yet supported locally.
class ReconciliationApi {
  final ApiClient? _client;
  final _DeviceBankReconciliation? _device;
  ReconciliationApi(ApiClient client) : _client = client, _device = null;
  ReconciliationApi._device(this._device) : _client = null;

  bool get isDeviceLedger => _device != null;
  bool get canReadDeviceBank =>
      _device?.allowed(BusinessLedgerAction.readBankReconciliation) == true;
  bool get canReadDeviceInventory =>
      _device?.allowed(BusinessLedgerAction.readInventoryReconciliation) ==
      true;

  ApiClient get _connected {
    final client = _client;
    if (client == null) throw const ReconciliationNotOnDevice();
    return client;
  }

  /// Stable for one confirmation and all duplicate deliveries of that request.
  static String newOperationId() => const Uuid().v4();

  List<BusinessBankMeasurement> _measurements(
    List<Map<String, dynamic>> entries,
  ) => [
    for (final row in entries)
      (
        accountId: '${row['account_id']}',
        actualMinor: BusinessMoney.minor('${row['actual']}'),
        expectedMinor: row['expected_system'] == null
            ? null
            : BusinessMoney.minor('${row['expected_system']}'),
      ),
  ];

  dynamic _data(dynamic body) {
    if (body is Map<String, dynamic> && body.containsKey('data')) {
      return body['data'];
    }
    return body;
  }

  Map<String, dynamic> _map(dynamic body) =>
      _data(body) is Map ? Map<String, dynamic>.from(_data(body) as Map) : {};

  List<dynamic> _list(dynamic body) {
    final data = _data(body);
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  /// Dio 409 conflict payload: {message, fresh} — surface both to the caller.
  Map<String, dynamic>? conflictFresh(DioException e) {
    final detail = e.response?.data;
    Map<String, dynamic>? detailMap;
    if (detail is Map) {
      detailMap = detail['detail'] is Map
          ? Map<String, dynamic>.from(detail['detail'] as Map)
          : null;
      if (detailMap == null && detail['fresh'] is Map) {
        detailMap = Map<String, dynamic>.from(detail['fresh'] as Map);
      }
    }
    return detailMap?['fresh'] is Map
        ? Map<String, dynamic>.from(detailMap!['fresh'] as Map)
        : null;
  }

  Future<List<Map<String, dynamic>>> accounts() async {
    final device = _device;
    if (device != null) {
      return device.run(
        BusinessLedgerAction.readBankReconciliation,
        (ledger, grant, _) => ledger.reconciliationAccounts(grant),
      );
    }
    final r = await _connected.get('/reconciliation/accounts');
    return [
      for (final e in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(e),
    ];
  }

  Future<Map<String, dynamic>> bankCheck({
    required List<Map<String, dynamic>> entries,
    String? notes,
    String? periodStart,
    String? periodEnd,
    String? idempotencyKey,
  }) async {
    final device = _device;
    if (device != null) {
      return device.run(
        BusinessLedgerAction.checkBankReconciliation,
        (ledger, grant, allowed) => ledger.checkBankReconciliation(
          grant,
          id: idempotencyKey ?? newOperationId(),
          entries: _measurements(entries),
          notes: notes,
          periodStart: periodStart,
          periodEnd: periodEnd,
          allowed: allowed,
        ),
      );
    }
    final r = await _connected.post(
      '/reconciliation/bank/check',
      data: {
        'entries': entries,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (periodStart != null) 'period_start': periodStart,
        if (periodEnd != null) 'period_end': periodEnd,
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> bankApprove({
    required String reconId,
    required List<Map<String, dynamic>> entries,
    String? notes,
  }) async {
    final device = _device;
    if (device != null) {
      final result = await device.run(
        BusinessLedgerAction.approveBankReconciliation,
        (ledger, grant, allowed) => ledger.approveBankReconciliation(
          grant,
          id: reconId,
          entries: _measurements(entries),
          notes: notes,
          allowed: allowed,
        ),
      );
      device.balancesChanged();
      return result;
    }
    final r = await _connected.post(
      '/reconciliation/bank/$reconId/approve',
      data: {
        'entries': entries,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return _map(r.data);
  }

  int _qtyMilli(Object? qty) {
    final match = RegExp(r'^(\d{1,11})(?:\.(\d{1,3})0*)?$').firstMatch('$qty');
    if (match == null) {
      throw const BusinessReconciliationInvalid();
    }
    return int.parse(match[1]!) * 1000 + int.parse((match[2] ?? '').padRight(3, '0'));
  }

  List<BusinessInventoryCount> _counts(List<Map<String, dynamic>> counts) => [
    for (final row in counts)
      (
        productId: '${row['product_id']}',
        // The linked counting UI sends only `parts`; a lone `qty` remains
        // supported for the plain single-box entry.
        qtyMilli: row['qty'] == null && row['parts'] is List && (row['parts'] as List).isNotEmpty
            ? 0 : _qtyMilli(row['qty']),
        unitId: row['unit_id'] == null ? null : '${row['unit_id']}',
        parts: row['parts'] is! List
            ? null
            : [
                for (final part in (row['parts'] as List).cast<Map>())
                  (
                    qtyMilli: _qtyMilli(part['qty']),
                    unitId: part['unit_id'] == null
                        ? null
                        : '${part['unit_id']}',
                    unitName: part['unit_name'] == null
                        ? null
                        : '${part['unit_name']}',
                  ),
              ],
      ),
  ];

  List<BusinessInventorySettlement> _settlements(
    List<Map<String, dynamic>> settlements,
  ) => [
    for (final row in settlements)
      (
        productId: '${row['product_id']}',
        expectedMilli: _qtyMilli(row['expected_system']),
        newMilli: _qtyMilli(row['new_qty']),
      ),
  ];

  Future<Map<String, dynamic>> inventoryStart({
    required String scope,
    String? productId,
    String? categoryId,
    String? branchId,
    String? notes,
    String? idempotencyKey,
  }) async {
    final device = _device;
    if (device != null) {
      if (branchId != null && branchId != device.scope.branchId) {
        throw const DirectoryAccessDenied();
      }
      return device.run(
        BusinessLedgerAction.checkInventoryReconciliation,
        (ledger, grant, allowed) => ledger.inventoryReconciliationStart(
          grant,
          id: idempotencyKey ?? newOperationId(),
          scope: scope,
          productId: productId,
          categoryId: categoryId,
          notes: notes,
          allowed: allowed,
        ),
      );
    }
    final r = await _connected.post(
      '/reconciliation/inventory/start',
      data: {
        'scope': scope,
        if (productId != null) 'product_id': productId,
        if (categoryId != null) 'category_id': categoryId,
        if (branchId != null) 'branch_id': branchId,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      },
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> inventorySave({
    required String reconId,
    required List<Map<String, dynamic>> counts,
  }) async {
    final device = _device;
    if (device != null) {
      return device.run(
        BusinessLedgerAction.checkInventoryReconciliation,
        (ledger, grant, allowed) => ledger.inventoryReconciliationSave(
          grant,
          id: reconId,
          counts: _counts(counts),
          allowed: allowed,
        ),
      );
    }
    final r = await _connected.post(
      '/reconciliation/inventory/$reconId/save',
      data: {'counts': counts},
    );
    return _map(r.data);
  }

  Future<String?> inventoryCountPhoto(String id, String productId) {
    final device = _device;
    if (device == null) throw const ReconciliationNotOnDevice();
    return device.run(
      BusinessLedgerAction.readInventoryReconciliation,
      (ledger, grant, _) =>
          ledger.inventoryReconciliationPhoto(grant, id: id, productId: productId),
    );
  }

  Future<Map<String, dynamic>> inventoryCheck({required String reconId}) async {
    final device = _device;
    if (device != null) {
      return device.run(
        BusinessLedgerAction.checkInventoryReconciliation,
        (ledger, grant, allowed) => ledger.inventoryReconciliationCheck(
          grant,
          id: reconId,
          allowed: allowed,
        ),
      );
    }
    final r = await _connected.post(
      '/reconciliation/inventory/$reconId/check',
      data: {},
    );
    return _map(r.data);
  }

  Future<Map<String, dynamic>> inventoryApprove({
    required String reconId,
    required List<Map<String, dynamic>> settlements,
    String? branchId,
    String? notes,
  }) async {
    final device = _device;
    if (device != null) {
      if (branchId != null && branchId != device.scope.branchId) {
        throw const DirectoryAccessDenied();
      }
      final result = await device.run(
        BusinessLedgerAction.approveInventoryReconciliation,
        (ledger, grant, allowed) => ledger.inventoryReconciliationApprove(
          grant,
          id: reconId,
          settlements: _settlements(settlements),
          notes: notes,
          allowed: allowed,
        ),
      );
      device.stockChanged();
      return result;
    }
    final r = await _connected.post(
      '/reconciliation/inventory/$reconId/approve',
      data: {
        'settlements': settlements,
        if (branchId != null) 'branch_id': branchId,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return _map(r.data);
  }

  Future<List<Map<String, dynamic>>> archive({
    String? rtype,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    int page = 1,
  }) async {
    final device = _device;
    if (device != null) {
      final inventory = rtype == 'inventory';
      if (rtype != null &&
          rtype.isNotEmpty &&
          rtype != 'bank' &&
          !inventory) {
        throw const ReconciliationNotOnDevice();
      }
      return device.run(
        inventory
            ? BusinessLedgerAction.readInventoryReconciliation
            : BusinessLedgerAction.readBankReconciliation,
        (ledger, grant, _) => ledger.bankReconciliationArchive(
          grant,
          rtype: inventory ? 'inventory' : 'bank',
          status: status,
          dateFrom: dateFrom,
          dateTo: dateTo,
          search: search,
          page: page,
        ),
      );
    }
    final r = await _connected.get(
      '/reconciliation',
      queryParameters: {
        'page': '$page',
        'per_page': '50',
        if (rtype != null && rtype.isNotEmpty) 'rtype': rtype,
        if (status != null && status.isNotEmpty) 'status': status,
        if (dateFrom != null && dateFrom.isNotEmpty) 'date_from': dateFrom,
        if (dateTo != null && dateTo.isNotEmpty) 'date_to': dateTo,
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    return [
      for (final e in _list(r.data).whereType<Map>())
        Map<String, dynamic>.from(e),
    ];
  }

  Future<Map<String, dynamic>> detail(String reconId) async {
    final device = _device;
    if (device != null) {
      if (device.allowed(BusinessLedgerAction.readInventoryReconciliation)) {
        try {
          return await device.run(
            BusinessLedgerAction.readInventoryReconciliation,
            (ledger, grant, _) =>
                ledger.inventoryReconciliationDetail(grant, reconId),
          );
        } on BusinessReconciliationInvalid {
          // Fall through: the id may belong to a bank record.
        }
      }
      return device.run(
        BusinessLedgerAction.readBankReconciliation,
        (ledger, grant, _) => ledger.bankReconciliationDetail(grant, reconId),
      );
    }
    final r = await _connected.get('/reconciliation/$reconId');
    return _map(r.data);
  }
}
