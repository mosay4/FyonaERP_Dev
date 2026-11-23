part of 'directory_database.dart';

const _cashEqualizations = 'business_cash_equalizations';
const _cashV3Replicas = 'business_cash_v3_replicas';

Future<void> _createBusinessCashEqualization(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_cashEqualizations (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      recon_id TEXT,
      approval_digest TEXT,
      observed_through INTEGER,
      grant_version INTEGER,
      request TEXT NOT NULL,
      notes TEXT,
      decision TEXT NOT NULL,
      sequence INTEGER,
      PRIMARY KEY (branch_id, command_id),
      UNIQUE (branch_id, recon_id),
      UNIQUE (branch_id, sequence),
      CHECK (decision IN ('queued', 'accepted', 'staleMeasurement',
          'permissionChanged', 'unavailableResource')),
      CHECK ((recon_id IS NOT NULL AND length(approval_digest) = 64
          AND approval_digest IS NOT NULL AND observed_through >= 0
          AND observed_through IS NOT NULL AND grant_version > 0 AND grant_version IS NOT NULL)
          OR (recon_id IS NULL AND approval_digest IS NULL AND observed_through IS NULL
          AND grant_version IS NULL AND notes IS NULL AND decision = 'accepted')),
      CHECK ((decision = 'queued' AND recon_id IS NOT NULL AND sequence IS NULL)
          OR (decision <> 'queued' AND sequence > 0 AND sequence IS NOT NULL)),
      FOREIGN KEY (branch_id, recon_id) REFERENCES $_reconciliationRecords (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS ${_cashEqualizations}_one_pending
    ON $_cashEqualizations (branch_id) WHERE decision = 'queued'
  ''');
  // This row is a property of the original admitted session, not a
  // ledger fact. Backups never export it or recreate the admission.
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_cashV3Replicas (
      branch_id TEXT PRIMARY KEY NOT NULL,
      observed_through INTEGER NOT NULL CHECK (observed_through >= 0),
      FOREIGN KEY (branch_id) REFERENCES ${BusinessCashSync._replicas} (branch_id)
    )
  ''');
}

final class BusinessCashEqualizationPending implements Exception {
  const BusinessCashEqualizationPending();
}

final class BusinessCashEqualizationMixed implements Exception {
  const BusinessCashEqualizationMixed();
}

typedef BusinessCashEqualizationLine = ({
  String accountId, String currency, int expectedMinor, int actualMinor,
});

Future<int?> _cashObserved(DatabaseExecutor db, String branch) async =>
    (await db.query(_cashV3Replicas, columns: ['observed_through'],
      where: 'branch_id = ?', whereArgs: [branch],
    )).singleOrNull?['observed_through'] as int?;

Future<bool> _hasQueuedEqualization(DatabaseExecutor db, String branch) async =>
    (await db.query(_cashEqualizations, columns: ['command_id'],
      where: "branch_id = ? AND decision = 'queued'", whereArgs: [branch], limit: 1,
    )).isNotEmpty;

Future<bool> _hasCashOutbox(DatabaseExecutor db, String branch) async =>
    (await db.query(BusinessCashSync._queue, columns: ['command_id'],
      where: 'branch_id = ?', whereArgs: [branch], limit: 1,
    )).isNotEmpty;

List<Map<String, Object?>> _cashEqualizationWire(
  Iterable<BusinessCashEqualizationLine> lines,
) => [
  for (final line in lines)
    {'account_id': line.accountId, 'currency': line.currency,
      'expected_minor': line.expectedMinor, 'actual_minor': line.actualMinor},
];

String _encodeEqualization(List<BusinessCashEqualizationLine> lines) {
  if (lines.isEmpty || lines.length > 100) {
    throw const BusinessReconciliationInvalid();
  }
  final ordered = [...lines]..sort((a, b) => a.accountId.compareTo(b.accountId));
  final ids = <String>{};
  for (final line in ordered) {
    final cur = businessCurrency(line.currency);
    BusinessMoney.checked(line.expectedMinor);
    BusinessLedger._amount(line.actualMinor, zero: true);
    BusinessLedger._amount((line.actualMinor - line.expectedMinor).abs());
    if (!isDirectoryId(line.accountId) ||
        line.accountId != line.accountId.toLowerCase() ||
        cur != line.currency || !ids.add(line.accountId)) {
      throw const BusinessReconciliationInvalid();
    }
  }
  return jsonEncode(_cashEqualizationWire(ordered));
}

Future<void> _stageCashEqualization(
  Transaction txn,
  _BankApproval approval, {
  required BusinessCashSync cash,
  required BusinessLedgerAccess access,
  required int? observed,
  required int grantVersion,
  required List<BusinessCashEqualizationLine> lines,
}) async {
  final branch = approval.branch;
  final head = await _cashObserved(txn, branch);
  if (!await cash._sessionMatches(txn, branch, access.cashSessionId) ||
      head == null ||
      await _syncFrozen(txn, branch)) {
    throw const BusinessLedgerError(BusinessLedgerProblem.sharedCashRequiresArbitration);
  }
  if (await _hasQueuedEqualization(txn, branch) || await _hasCashOutbox(txn, branch)) {
    throw const BusinessCashEqualizationPending();
  }
  if (observed != head) {
    throw const BusinessReconciliationChanged();
  }
  final command = const Uuid().v5(approval.id, 'fyona.shared.cash.equalization.v1');
  await txn.insert(_cashEqualizations, {
    'branch_id': branch,
    'recon_id': approval.id,
    'command_id': command,
    'approval_digest': approval.digest,
    'observed_through': observed,
    'grant_version': grantVersion,
    'request': _encodeEqualization(lines),
    'notes': approval.notes,
    'decision': 'queued',
  });
  await approval.update(txn, {'authority_state': 'queued'});
}

extension BusinessCashEqualization on BusinessCashSync {
  Future<bool> supportsEqualization(BusinessLedgerAccess access) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._read((db) async {
      if (!await _sessionMatches(db, branch, access.cashSessionId)) {
        throw const DirectoryAccessDenied();
      }
      return await _cashObserved(db, branch) != null;
    });
  }

  Future<Map<String, Object?>?> pendingEqualization(BusinessLedgerAccess access) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._read((db) async {
      await _requireEqualizationSession(db, branch, access);
      final row = (await db.query(_cashEqualizations,
        where: "branch_id = ? AND decision = 'queued'", whereArgs: [branch],
      )).singleOrNull;
      if (row == null) return null;
      return {'command_id': row['command_id'], 'observed_through': row['observed_through'],
        'grant_version': row['grant_version'], 'entries': jsonDecode(row['request'] as String)};
    });
  }

  /// An empty authoritative page, after acknowledgment of earlier deliveries,
  /// is the only evidence that a measurement may use this head.
  Future<void> observeThrough(BusinessLedgerAccess access, int sequence, {
    required bool Function() allowed,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final old = await _requireEqualizationSession(txn, branch, access);
      if (sequence < old) throw const BusinessReconciliationChanged();
      if (await _hasCashOutbox(txn, branch) || await _hasQueuedEqualization(txn, branch)) return;
      await txn.update(_cashV3Replicas, {'observed_through': sequence},
        where: 'branch_id = ?', whereArgs: [branch]);
      _requireReconciliation(access, allowed);
    });
  }

  Future<void> rejectEqualization(BusinessLedgerAccess access, {
    required String commandId, required int sequence, required BusinessCashDecision decision,
    required bool Function() allowed,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    BusinessCashSync._validateReceipt(commandId, sequence, null);
    if (!const {
      BusinessCashDecision.staleMeasurement,
      BusinessCashDecision.permissionChanged,
      BusinessCashDecision.unavailableResource,
    }.contains(decision)) {
      throw const BusinessReconciliationInvalid();
    }
    return _db._transaction((txn) async {
      _requireReconciliation(access, allowed);
      await _requireEqualizationSession(txn, branch, access);
      final row = await BusinessCashSync._byCommand(txn, _cashEqualizations, branch, commandId);
      if (row == null || row['recon_id'] == null) throw const BusinessReconciliationInvalid();
      if (row['decision'] != 'queued') {
        if (row['decision'] != decision.name || row['sequence'] != sequence) {
          throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
        }
        return;
      }
      final reconId = row['recon_id'] as String;
      final check = await _storedReconciliation(txn, branch, reconId, 'bank');
      if (check?['status'] != 'checked' || sequence <= (row['observed_through'] as int)) {
        throw const BusinessReconciliationInvalid();
      }
      final record = _reconciliationPayload(check!);
      record['authority_state'] = 'rejected';
      record['authority_reason'] = decision.name;
      await txn.update(_reconciliationRecords, {'payload': jsonEncode(record)},
        where: 'branch_id = ? AND id = ?', whereArgs: [branch, reconId]);
      await txn.update(_cashEqualizations, {'decision': decision.name, 'sequence': sequence},
        where: 'branch_id = ? AND command_id = ?', whereArgs: [branch, commandId]);
      _requireReconciliation(access, allowed);
    }, exclusive: true);
  }

  /// The initiating check and all of its ledger legs commit together. Other
  /// replicas receive the ledger movements, not the user's check or notes.
  Future<bool> applyEqualization(BusinessLedgerAccess access, {
    required String commandId, required int sequence,
    required List<BusinessCashEqualizationLine> lines, required bool Function() allowed,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    BusinessCashSync._validateReceipt(commandId, sequence, null);
    final encoded = _encodeEqualization(lines);
    return _db._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final seen = await _requireEqualizationSession(txn, branch, access);
      final row = await BusinessCashSync._byCommand(txn, _cashEqualizations, branch, commandId);
      final queued = row?['decision'] == 'queued';
      if (row != null && (row['request'] != encoded ||
          (!queued && (row['decision'] != 'accepted' || row['sequence'] != sequence)))) {
        throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
      }
      if (row != null && !queued) return true;
      if (sequence <= seen) throw const BusinessReconciliationChanged();
      if (await _hasCashOutbox(txn, branch)) return false;
      final reconId = row?['recon_id'] as String?;
      final check = reconId == null ? null : await _storedReconciliation(txn, branch, reconId, 'bank');
      if (reconId != null &&
          (check?['status'] != 'checked' || sequence != (row!['observed_through'] as int) + 1)) {
        throw const BusinessReconciliationInvalid();
      }
      final record = check == null ? null : _reconciliationPayload(check);
      final now = DateTime.now().toUtc();
      for (final line in lines) {
        await _requireConfig(txn, branch, line.accountId);
        final account = await _ledger._account(txn, branch, line.accountId);
        if (account['currency'] != line.currency || account['balance_minor'] != line.expectedMinor) {
          throw const BusinessReconciliationChanged();
        }
        await _ledger._postBankAdjustment(txn, branch, commandId,
          line.accountId, line.expectedMinor, line.actualMinor, now,
          digest: row?['approval_digest'] as String? ?? _reconDigest([sequence, encoded]),
          refCode: record?['ref_code'] as String?, reconId: reconId,
        );
      }
      if (record != null) {
        final approval = _BankApproval(branch, reconId!, record,
          row!['approval_digest'] as String, row['notes'] as String?,
          access.directory.workspace.accountId);
        await approval.finish(txn, now, [
          for (final line in lines)
            (accountId: line.accountId, expectedMinor: line.expectedMinor, actualMinor: line.actualMinor),
        ], commandRoot: commandId);
        await txn.update(_cashEqualizations, {'decision': 'accepted', 'sequence': sequence},
          where: 'branch_id = ? AND command_id = ?', whereArgs: [branch, commandId]);
      } else {
        await txn.insert(_cashEqualizations, {
          'branch_id': branch, 'command_id': commandId, 'request': encoded,
          'decision': 'accepted', 'sequence': sequence,
        });
      }
      _requireReconciliation(access, allowed);
      return true;
    }, exclusive: true);
  }

  Future<int> _requireEqualizationSession(
    DatabaseExecutor db, String branch, BusinessLedgerAccess access,
  ) async {
    final seen = await _cashObserved(db, branch);
    if (seen == null || !await _sessionMatches(db, branch, access.cashSessionId)) {
      throw const DirectoryAccessDenied();
    }
    return seen;
  }
}
