part of 'directory_database.dart';

// A local, revocable delegation of ledger actions to one employee identity.
// It is a device fact: no request, id or receipt is sent to any connected API.
const _employeeGrants = 'business_employee_grants';

/// Actions an owner may delegate. Money movement, deletions, the negative
/// policy, backup management, debt sharing, cash sync and every arbitration
/// decision (reconciliation checks and approvals) stay with the owner.
const businessEmployeeDelegableActions = <BusinessLedgerAction>{
  BusinessLedgerAction.readBank,
  BusinessLedgerAction.readBankHistory,
  BusinessLedgerAction.readOperations,
  BusinessLedgerAction.readManualMovements,
  BusinessLedgerAction.readDebt,
  BusinessLedgerAction.createDebt,
  BusinessLedgerAction.settleDebt,
  BusinessLedgerAction.readSaleInvoice,
  BusinessLedgerAction.readPurchaseInvoice,
  BusinessLedgerAction.readReturns,
  BusinessLedgerAction.readInventory,
  BusinessLedgerAction.readDebtReport,
  BusinessLedgerAction.readMoneyReport,
  BusinessLedgerAction.readSalesReport,
  BusinessLedgerAction.readOverviewReport,
  BusinessLedgerAction.readEmployeeFinance,
  BusinessLedgerAction.payEmployeeSalary,
  BusinessLedgerAction.createEmployeeDebt,
  BusinessLedgerAction.settleEmployeeDebt,
};

/// The identity a delegated ledger call speaks for. The version is the one
/// issued by the grant; a revoked or re-granted delegation leaves older
/// versions unusable, including for calls already in flight.
final class BusinessEmployeeDelegation {
  const BusinessEmployeeDelegation(this.employeeId, this.version);

  final String employeeId;
  final int version;
}

Future<void> _createBusinessEmployeeDelegation(DatabaseExecutor db) =>
    db.execute('''
      CREATE TABLE IF NOT EXISTS $_employeeGrants (
        branch_id TEXT NOT NULL,
        employee_id TEXT NOT NULL,
        version INTEGER NOT NULL CHECK (version > 0),
        actions TEXT NOT NULL,
        granted_us INTEGER NOT NULL,
        expires_us INTEGER,
        revoked_us INTEGER,
        PRIMARY KEY (branch_id, employee_id)
      )
    ''');

extension BusinessEmployeeDelegationLedger on BusinessLedger {
  String _employeeId(String employeeId) {
    if (!isDirectoryId(employeeId) || employeeId != employeeId.toLowerCase()) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    return employeeId;
  }

  /// A delegated call may never speak for another employee, and can never
  /// delegate further. Only the owner issues, replaces or revokes grants.
  String _employeeScope(
    BusinessLedgerAccess access,
    String employeeId, {
    bool ownerOnly = false,
  }) {
    final id = _employeeId(employeeId);
    final actor = access.employee;
    if (ownerOnly ? actor != null : (actor != null && actor.employeeId != id)) {
      throw const DirectoryAccessDenied();
    }
    return id;
  }

  Future<void> _requireDelegation(
    DatabaseExecutor db,
    String branch,
    BusinessLedgerAccess access,
    BusinessLedgerAction action,
  ) async {
    final actor = access.employee;
    if (actor == null) return;
    final rows = await db.query(
      _employeeGrants,
      where:
          'branch_id = ? AND employee_id = ? AND version = ? '
          'AND revoked_us IS NULL',
      whereArgs: [branch, actor.employeeId, actor.version],
    );
    if (rows.length != 1) throw const DirectoryAccessDenied();
    final grant = rows.single;
    final expires = grant['expires_us'] as int?;
    if (expires != null &&
        expires <= DateTime.now().microsecondsSinceEpoch) {
      throw const DirectoryAccessDenied();
    }
    final actions =
        ((jsonDecode(grant['actions'] as String) as List)
            .whereType<String>()
            .toSet());
    if (!actions.contains(action.name)) throw const DirectoryAccessDenied();
  }

  /// Owner-issued, revocable, versioned. Re-granting replaces the set with a
  /// new version; it never revives an older one.
  Future<Map<String, Object?>> grantEmployeeDelegation(
    BusinessLedgerAccess access, {
    required String commandId,
    required String employeeId,
    required Set<BusinessLedgerAction> actions,
    DateTime? expiresAt,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.delegateEmployee);
    final employee = _employeeScope(access, employeeId, ownerOnly: true);
    if (actions.isEmpty ||
        actions.any((action) => !businessEmployeeDelegableActions.contains(action))) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    final now = DateTime.now();
    final expiry = expiresAt?.toUtc();
    if (expiry != null && !expiry.isAfter(now)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    final names = (actions.map((action) => action.name).toList()..sort());
    final expiresUs = expiry?.microsecondsSinceEpoch;
    return _commit(
      branch,
      commandId,
      ['employee_delegation', employee, names, expiresUs],
      (txn, time) async {
        final existing = await txn.query(
          _employeeGrants,
          where: 'branch_id = ? AND employee_id = ?',
          whereArgs: [branch, employee],
        );
        final version = existing.isEmpty
            ? 1
            : (existing.single['version'] as int) + 1;
        final values = {
          'branch_id': branch,
          'employee_id': employee,
          'version': version,
          'actions': jsonEncode(names),
          'granted_us': time.microsecondsSinceEpoch,
          'expires_us': expiresUs,
          'revoked_us': null,
        };
        if (existing.isEmpty) {
          await txn.insert(_employeeGrants, values);
        } else {
          await txn.update(
            _employeeGrants,
            values,
            where: 'branch_id = ? AND employee_id = ?',
            whereArgs: [branch, employee],
          );
        }
        return {
          'employee_id': employee,
          'version': version,
          'actions': names,
          'expires_us': expiresUs,
          'granted_us': time.microsecondsSinceEpoch,
          'revoked_us': null,
        };
      },
      allowed: allowed,
    );
  }

  /// Durable revocation receipt. The row is kept as history and its version
  /// is consumed, so no earlier grant can be replayed or resumed.
  Future<Map<String, Object?>> revokeEmployeeDelegation(
    BusinessLedgerAccess access, {
    required String commandId,
    required String employeeId,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.delegateEmployee);
    final employee = _employeeScope(access, employeeId, ownerOnly: true);
    return _commit(
      branch,
      commandId,
      ['employee_revocation', employee],
      (txn, time) async {
        final existing = await txn.query(
          _employeeGrants,
          where: 'branch_id = ? AND employee_id = ? AND revoked_us IS NULL',
          whereArgs: [branch, employee],
        );
        if (existing.isEmpty) {
          throw const BusinessLedgerError(BusinessLedgerProblem.noChanges);
        }
        final grant = existing.single;
        final version = (grant['version'] as int) + 1;
        final revoked = time.microsecondsSinceEpoch;
        await txn.update(
          _employeeGrants,
          {'version': version, 'revoked_us': revoked},
          where: 'branch_id = ? AND employee_id = ?',
          whereArgs: [branch, employee],
        );
        return {
          'employee_id': employee,
          'version': version,
          'revoked_us': revoked,
          'granted_us': grant['granted_us'],
          'actions': jsonDecode(grant['actions'] as String),
        };
      },
      allowed: allowed,
    );
  }

  /// A delegated caller sees only its own grant; the owner sees the branch's
  /// grants. Revoked grants stay listed as history.
  Future<List<Map<String, Object?>>> employeeDelegations(
    BusinessLedgerAccess access,
  ) async {
    final actor = access.employee;
    final String branch;
    if (actor == null) {
      branch = _branch(access, BusinessLedgerAction.delegateEmployee);
    } else {
      branch = _branch(access, BusinessLedgerAction.readEmployeeFinance);
    }
    return _directory._read((db) async {
      await _requireDelegation(
        db,
        branch,
        access,
        actor == null
            ? BusinessLedgerAction.delegateEmployee
            : BusinessLedgerAction.readEmployeeFinance,
      );
      final rows = await db.query(
        _employeeGrants,
        where: 'branch_id = ?${actor == null ? '' : ' AND employee_id = ?'}',
        whereArgs: [branch, if (actor != null) actor.employeeId],
        orderBy: 'granted_us DESC, employee_id',
      );
      final now = DateTime.now().microsecondsSinceEpoch;
      return [
        for (final row in rows)
          {
            'employee_id': row['employee_id'],
            'version': row['version'],
            'actions': jsonDecode(row['actions'] as String),
            'granted_us': row['granted_us'],
            'expires_us': row['expires_us'],
            'revoked_us': row['revoked_us'],
            'active':
                row['revoked_us'] == null &&
                ((row['expires_us'] as int?) ?? now + 1) > now,
          },
      ];
    });
  }
}
