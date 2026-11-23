part of 'directory_database.dart';

// Explicit owner re-approval of a recovered ledger. Restoration never grants
// sync: only this approval does, and it only seals the past — restored
// requests are moved here and can never be transmitted or re-decided.
const _syncApprovals = 'business_sync_approvals';
const _cashSuspended = 'business_cash_suspended';

Future<void> _createBusinessSyncReapproval(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncApprovals (
      branch_id TEXT PRIMARY KEY,
      command_id TEXT NOT NULL,
      approved_us INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_cashSuspended (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('withdrawal', 'equalization')),
      account_id TEXT,
      recon_id TEXT,
      amount_minor INTEGER,
      currency TEXT,
      payload TEXT NOT NULL,
      sealed_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id)
    )
  ''');
}

Future<int?> _syncApprovalUs(DatabaseExecutor db, String branch) async =>
    (await db.query(
      _syncApprovals,
      columns: ['approved_us'],
      where: 'branch_id = ?',
      whereArgs: [branch],
    )).singleOrNull?['approved_us'] as int?;

/// A recovered ledger is frozen for publishing until its own approval. An
/// approval never revives anything: it only permits the next fresh admission.
Future<bool> _syncFrozen(DatabaseExecutor db, String branch) async =>
    await _syncApprovalUs(db, branch) == null &&
    await _isRecoveredLedger(db, branch);

Future<bool> _hasSuspendedCommand(
  DatabaseExecutor db,
  String branch,
  String? reconId,
) async {
  if (reconId == null) return false;
  return (await db.query(
    _cashSuspended,
    columns: ['command_id'],
    where: 'branch_id = ? AND recon_id = ?',
    whereArgs: [branch, reconId],
    limit: 1,
  )).isNotEmpty;
}

extension BusinessSyncReapproval on BusinessLedger {
  /// One owner decision per recovered ledger. The result is the receipt: it
  /// names every restored request that becomes permanently unservable.
  Future<Map<String, Object?>> approveRecoveredSync(
    BusinessLedgerAccess access, {
    required String commandId,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.syncCash);
    return _commit(
      branch,
      commandId,
      ['recovered_sync_reapproval'],
      (txn, now) async {
        if (!await _isRecoveredLedger(txn, branch) ||
            await _syncApprovalUs(txn, branch) != null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.noChanges);
        }
        final sealed = <Map<String, Object?>>[];
        final withdrawals = (await txn.query(
          BusinessCashSync._queue,
          where: 'branch_id = ?',
          whereArgs: [branch],
        )).toList();
        for (final row in withdrawals) {
          sealed.add({
            'command_id': row['command_id'],
            'kind': 'withdrawal',
            'account_id': row['account_id'],
            'amount_minor': row['amount_minor'],
            'currency': row['currency'],
          });
          await txn.insert(_cashSuspended, {
            'branch_id': branch,
            'command_id': row['command_id'],
            'kind': 'withdrawal',
            'account_id': row['account_id'],
            'recon_id': null,
            'amount_minor': row['amount_minor'],
            'currency': row['currency'],
            'payload': jsonEncode(row),
            'sealed_us': now.microsecondsSinceEpoch,
          });
          await txn.delete(
            BusinessCashSync._queue,
            where: 'branch_id = ? AND command_id = ?',
            whereArgs: [branch, row['command_id']],
          );
        }
        final equalizations = (await txn.query(
          _cashEqualizations,
          where: "branch_id = ? AND decision = 'queued'",
          whereArgs: [branch],
        )).toList();
        for (final row in equalizations) {
          sealed.add({
            'command_id': row['command_id'],
            'kind': 'equalization',
            'recon_id': row['recon_id'],
          });
          await txn.insert(_cashSuspended, {
            'branch_id': branch,
            'command_id': row['command_id'],
            'kind': 'equalization',
            'account_id': null,
            'recon_id': row['recon_id'],
            'amount_minor': null,
            'currency': null,
            'payload': jsonEncode(row),
            'sealed_us': now.microsecondsSinceEpoch,
          });
          await txn.delete(
            _cashEqualizations,
            where: 'branch_id = ? AND command_id = ?',
            whereArgs: [branch, row['command_id']],
          );
        }
        await txn.insert(_syncApprovals, {
          'branch_id': branch,
          'command_id': commandId,
          'approved_us': now.microsecondsSinceEpoch,
        });
        return {
          'approved_us': now.microsecondsSinceEpoch,
          'sealed_count': sealed.length,
          'sealed': sealed,
        };
      },
      allowed: allowed,
    );
  }

  /// The sealed past: never delivered, never re-decided, always visible.
  Future<List<Map<String, Object?>>> suspendedRequests(
    BusinessLedgerAccess access,
  ) async {
    final branch = _branch(access, BusinessLedgerAction.syncCash);
    return _directory._read((db) async {
      final rows = await db.query(
        _cashSuspended,
        where: 'branch_id = ?',
        whereArgs: [branch],
        orderBy: 'sealed_us, command_id',
      );
      return [
        for (final row in rows)
          {...Map<String, Object?>.from(row), 'payload': jsonDecode(row['payload'] as String)},
      ];
    });
  }
}
