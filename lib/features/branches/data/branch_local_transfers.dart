import 'package:uuid/uuid.dart';

import '../../core_business/data/local_directory/directory_database.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_money.dart';

/// The transfers screen writes and reads through the device store instead of
/// the connected writer. Both branches must be kept here; a branch missing
/// from this device is refused with a clear message and nothing moves.
final class BranchLocalTransfers {
  BranchLocalTransfers({
    required DirectoryAccess? Function() scope,
    required DirectoryPilotStore Function() store,
    required bool Function() allowed,
    required bool Function(String) can,
    void Function()? changed,
    Future<Map<String, String>> Function()? ownerBranches,
    Map<String, Object?> Function()? actor,
  }) : _scope = scope,
       _store = store,
       _allowed = allowed,
       _can = can,
       _changed = changed,
       _ownerBranches = ownerBranches,
       _actor = actor;

  final DirectoryAccess? Function() _scope;
  final DirectoryPilotStore Function() _store;
  final bool Function() _allowed;
  final bool Function(String) _can;
  final void Function()? _changed;
  final Future<Map<String, String>> Function()? _ownerBranches;
  final Map<String, Object?> Function()? _actor;

  /// The branches a transfer may name: the signed list for a session, and
  /// for the owner every branch of the organization this device knows
  /// (also the ones created offline). An employee keeps the signed list.
  Future<Map<String, String>> _peers(DirectoryAccess scope) async {
    final names = <String, String>{...scope.transferBranches};
    if (!scope.member && _ownerBranches != null) {
      try {
        for (final entry in (await _ownerBranches()).entries) {
          if (!isDirectoryId(entry.key)) continue;
          final known = names[entry.key] ?? '';
          names[entry.key] = entry.value.trim().isEmpty ? known : entry.value;
        }
      } catch (_) {
        // A missing saved list only narrows the choice to the signed one.
      }
    }
    return names;
  }

  Map<String, Object?>? _actorInfo() {
    try {
      final info = _actor?.call();
      if (info == null) return null;
      return {
        for (final entry in info.entries)
          if (entry.value != null) entry.key: entry.value,
      };
    } catch (_) {
      return null;
    }
  }

  /// Names for branches the device's tables do not name (e.g. born here).
  static List<Map<String, Object?>> _named(
    List<Map<String, Object?>> rows,
    Map<String, String> peers,
  ) => [for (final row in rows) _nameRow(row, peers)];

  static Map<String, Object?> _nameRow(
    Map<String, Object?> row,
    Map<String, String> peers,
  ) {
    final out = Map<String, Object?>.from(row);
    for (final side in ['from', 'to']) {
      final name = '${out['${side}_branch_name'] ?? ''}'.trim();
      final known = peers['${out['${side}_branch']}'] ?? '';
      if ((name.isEmpty || name == 'null') && known.trim().isNotEmpty) {
        out['${side}_branch_name'] = known;
      }
    }
    return out;
  }

  static const _uuid = Uuid();

  static String newCommandId() => _uuid.v4();

  static Never _explain(Object error) {
    if (error is BusinessLedgerError) {
      final message = switch (error.problem) {
        BusinessLedgerProblem.insufficientStock =>
          'الكمية المطلوبة غير متوفرة في الفرع المُرسِل',
        BusinessLedgerProblem.insufficientBalance => 'الرصيد في الحساب ما يكفي',
        BusinessLedgerProblem.currencyMismatch =>
          'التحويل يتم بنفس العملة فقط على هذا الجهاز',
        BusinessLedgerProblem.invalidProduct =>
          'المنتج غير موجود في أحد الفرعين',
        BusinessLedgerProblem.invalidAmount =>
          'الكمية تحتاج تقريبًا؛ اختر كمية تنقسم بدون فاقد',
        _ => 'تعذر إتمام التحويل؛ لم تُغيّر أي كمية أو رصيد',
      };
      throw Exception(message);
    }
    throw error;
  }

  Future<T> _run<T>(
    Future<T> Function(
      BusinessLedger,
      BusinessLedgerAccess,
      bool Function(),
      Map<String, String>,
    )
    run, {
    String? permission,
    List<String> branches = const [],
    bool changed = false,
  }) async {
    final scope = _scope();
    if (scope == null) throw const DirectoryAccessDenied();
    final peers = await _peers(scope);
    bool valid() {
      final live = _scope();
      return live?.financialCutover == true &&
          sameDirectoryScope(scope, live) &&
          live!.writerSession == scope.writerSession &&
          live.transferBranches.keys.toSet().containsAll(
            scope.transferBranches.keys,
          ) &&
          (live.transferExpiry?.isAfter(DateTime.now()) ?? true) &&
          _allowed() &&
          _can('branches.transfer') &&
          (permission == null
              ? _can('banks.transfer') || _can('inventory.transfer')
              : _can(permission)) &&
          branches.every(peers.containsKey);
    }

    if (!valid()) {
      throw Exception('ما عندك صلاحية التحويل الآن');
    }
    // The owner's verified branches (see _peers) are this access's transfer
    // list; an employee's session keeps exactly the signed one.
    final directory = scope.member
        ? scope
        : DirectoryAccess(
            workspace: scope.workspace,
            branchId: scope.branchId,
            readable: DirectoryPartyKind.values
                .where(scope.canRead)
                .toSet(),
            writable: DirectoryPartyKind.values
                .where(scope.canCreate)
                .toSet(),
            financialCutover: scope.financialCutover,
            writerSession: scope.writerSession,
            transferExpiry: scope.transferExpiry,
            cashLinkId: scope.cashLinkId,
            transferBranches: peers,
          );
    final access = BusinessLedgerAccess(directory, {
      BusinessLedgerAction.transfer,
      BusinessLedgerAction.readInventory,
      if (_can('inventory_cost')) BusinessLedgerAction.readInventoryCost,
    });
    try {
      final result = await _store().withLedger(
        access,
        () => valid() ? _scope() : null,
        (ledger) => run(ledger, access, valid, peers),
      );
      if (!valid()) throw const DirectoryAccessDenied();
      if (changed) _changed?.call();
      return result;
    } catch (e) {
      _explain(e);
    }
  }

  Future<Map<String, Object?>> transferOptions(
    String branchId, {
    String? search,
    bool includeZero = false,
  }) => _run(
    (ledger, access, _, _) async => {
      if (_can('banks.transfer') && _can('banks.details'))
        'accounts': [
          for (final account in await ledger.transferAccounts(access, branchId))
            if (_can('banks.balances'))
              account
            else
              (Map.of(account)..remove('balance')),
        ],
      if (_can('inventory.transfer'))
        'products': await ledger.transferProductOptions(
          access,
          branchId,
          search: search,
          includeZero: includeZero,
          canReadCost: _can('inventory_cost'),
        ),
      'categories': const [],
    },
    branches: [branchId],
  );

  Future<Map<String, Object?>> productMatch({
    required String fromProductId,
    required String toBranchId,
    String? fromUnitId,
    String? fromBranchId,
  }) async => _run(
    (ledger, access, _, _) => ledger.transferProductMatch(
      access,
      fromProduct: fromProductId,
      targetBranch: toBranchId,
      sourceBranch: fromBranchId,
      canReadCost: _can('inventory_cost'),
    ),
    branches: [toBranchId, ?fromBranchId],
    permission: 'inventory.transfer',
  );

  Future<Map<String, Object?>> unitConversion({
    required String fromProductId,
    required String toProductId,
    String? fromUnitId,
    String? toBranchId,
    String? fromBranchId,
  }) async => _run(
    (ledger, access, _, _) async {
      final target = toBranchId ?? access.directory.branchId;
      return ledger.transferUnitInfo(
        access,
        fromProduct: fromProductId,
        toProduct: toProductId,
        fromUnitId: fromUnitId,
        targetBranch: target,
        sourceBranch: fromBranchId,
      );
    },
    branches: [?fromBranchId, ?toBranchId],
    permission: 'inventory.transfer',
  );

  Future<Map<String, Object?>> financialTransfer({
    required String fromBranchId,
    required String toBranchId,
    required String fromAccountId,
    required String toAccountId,
    required num amount,
    num? exchangeRate,
    bool allowNegative = false,
    String? notes,
    String? commandId,
  }) async => _run(
    (ledger, access, current, _) async {
      if (allowNegative) {
        // The device store never moves money it does not hold.
        throw Exception('التحويل على هذا الجهاز لا يقبل السحب بالسالب');
      }
      if (!_can('banks.details')) throw const DirectoryAccessDenied();
      Future<String?> currencyOf(String branch, String id) async {
        for (final row in await ledger.transferAccounts(access, branch)) {
          if ('${row['id']}' == id) return '${row['currency']}';
        }
        return null;
      }

      final from = await currencyOf(fromBranchId, fromAccountId);
      final to = await currencyOf(toBranchId, toAccountId);
      if (from == null || to == null) {
        throw Exception('الحساب غير موجود على هذا الجهاز');
      }
      return ledger.transferBetweenBranches(
        access,
        commandId: commandId ?? newCommandId(),
        fromBranch: fromBranchId,
        toBranch: toBranchId,
        fromAccountId: fromAccountId,
        toAccountId: toAccountId,
        amountMinor: _scaled(amount, 2),
        rate: exchangeRate == null || from == to
            ? null
            : BusinessRate(from, to, '$exchangeRate'),
        notes: notes,
        allowed: () => current() && _can('banks.details'),
        actor: _actorInfo(),
      );
    },
    branches: [fromBranchId, toBranchId],
    permission: 'banks.transfer',
    changed: true,
  );

  static int _scaled(Object? amount, int places) {
    final value = '$amount'.trim();
    final match = RegExp(r'^([0-9]{0,12})(?:\.([0-9]*))?$').firstMatch(value);
    final frac = match?[2]?.replaceFirst(RegExp(r'0+$'), '') ?? '';
    if (match == null ||
        (match[1]!.isEmpty && (match[2] ?? '').isEmpty) ||
        frac.length > places) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    return int.parse('0${match[1]}${frac.padRight(places, '0')}');
  }

  Future<Map<String, Object?>> inventoryTransfer({
    required String fromBranchId,
    required String toBranchId,
    required List<Map<String, dynamic>> items,
    String? notes,
    String? commandId,
  }) async => _run(
    (ledger, access, current, _) => ledger.transferStockBetweenBranches(
      access,
      commandId: commandId ?? newCommandId(),
      fromBranch: fromBranchId,
      toBranch: toBranchId,
      notes: notes,
      allowed: current,
      actor: _actorInfo(),
      items: [
        for (final item in items)
          BusinessStockTransferLine(
            fromProduct: '${item['from_product_id']}',
            toProduct: item['to_product_id'] == null
                ? null
                : '${item['to_product_id']}',
            fromUnit: item['from_unit_id'] == null
                ? null
                : '${item['from_unit_id']}',
            toUnit: item['to_unit_id'] == null ? null : '${item['to_unit_id']}',
            quantityMicro: _scaled(item['quantity'], 6),
            conversionFactor4: item['conversion_factor'] == null
                ? null
                : _scaled(item['conversion_factor'], 4),
          ),
      ],
    ),
    branches: [fromBranchId, toBranchId],
    permission: 'inventory.transfer',
    changed: true,
  );

  Future<List<Map<String, Object?>>> transfers({
    String? kind,
    String? branchId,
  }) async => _run(
    (ledger, access, _, peers) async => _named(
      (await ledger.branchTransfers(
        access,
        kind: kind == 'financial' || kind == 'inventory' ? kind : null,
        peers: peers.keys.toSet(),
        everyBranch: !access.directory.member,
      )).where((r) => _allowedKind(r['kind'])).toList(),
      peers,
    ),
    branches: [?branchId],
  );

  Future<Map<String, Object?>> transfer(String id) async =>
      _run((ledger, access, _, peers) async {
        final row = _nameRow(
          await ledger.branchTransferDetail(
            access,
            id,
            peers: peers.keys.toSet(),
            everyBranch: !access.directory.member,
          ),
          peers,
        );
        if (!_allowedKind(row['kind'])) throw const DirectoryAccessDenied();
        if (!_can('inventory_cost')) {
          for (final line in (row['items'] as List).whereType<Map>()) {
            line.remove('allocations');
          }
        }
        return row;
      });

  bool _allowedKind(Object? kind) => kind == 'financial'
      ? _can('banks.transfer') && _can('banks.details')
      : kind == 'inventory' && _can('inventory.transfer');

  Future<void> reverseTransfer(String id, {String? commandId}) async =>
      _run((ledger, access, current, peers) async {
        final kind = (await ledger.branchTransferDetail(
          access,
          id,
          peers: peers.keys.toSet(),
        ))['kind'];
        if (!_allowedKind(kind)) throw const DirectoryAccessDenied();
        await ledger.reverseBranchTransfer(
          access,
          commandId: commandId ?? newCommandId(),
          transferId: id,
          peers: peers.keys.toSet(),
          kinds: {'financial', 'inventory'}.where(_allowedKind).toSet(),
          allowed: () => current() && _allowedKind(kind),
        );
      }, changed: true);

  Future<List<Map<String, Object?>>> transferBranches() async =>
      _run((ledger, access, _, peers) async {
        final names = peers;
        return [
          {
            'organization_id': access.directory.workspace.organizationId,
            'organization_name': null,
            'branches': [
              for (final entry in names.entries)
                {'id': entry.key, 'name': entry.value},
            ],
          },
        ];
      });
}
