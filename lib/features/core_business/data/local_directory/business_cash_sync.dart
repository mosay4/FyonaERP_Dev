part of 'directory_database.dart';

enum BusinessCashDecision {
  accepted,
  insufficientBalance,
  permissionChanged,
  unavailableResource,
  amountOutOfRange,
  staleMeasurement,
}

typedef BusinessCashCheckpoint = ({int sequence, String digest});

/// Separate Business outbox for the first shared resource. Bank descriptions,
/// party names, and the device's available balance are not sent for arbitration.
/// A directory-only grant never starts transport for this outbox.
final class BusinessCashSync {
  BusinessCashSync._(this._ledger);

  final BusinessLedger _ledger;
  DirectoryDatabase get _db => _ledger._directory;

  static const _accounts = 'business_shared_cash';
  static const _queue = 'business_cash_outbox';
  static const _decisions = 'business_cash_decisions';
  static const _conflictReads = 'business_cash_conflict_reads';
  static const _replicas = 'business_cash_replica';

  Future<BusinessCashCheckpoint?> replicaCheckpoint(
    BusinessLedgerAccess access,
    String sessionId,
  ) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._read((db) async {
      final row = await _binding(db, branch);
      if (row == null) return null;
      if (row['session_id'] != sessionId) throw const DirectoryAccessDenied();
      return (
        sequence: row['checkpoint_sequence'] as int,
        digest: row['checkpoint_digest'] as String,
      );
    });
  }

  /// Establishes the connection between a fresh, reconciled local checkpoint
  /// and a server-admitted session. Never imports or overwrites a balance.
  Future<void> bindReplica(
    BusinessLedgerAccess access, {
    required String sessionId,
    required BusinessCashCheckpoint checkpoint,
    bool settlementProtocol = false,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    if (access.cashSessionId != sessionId ||
        !isDirectoryId(sessionId) ||
        sessionId != sessionId.toLowerCase() ||
        checkpoint.sequence < 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checkpoint.digest)) {
      throw const DirectoryAccessDenied();
    }
    return _db._transaction(
      (txn) => _bindInside(
        txn,
        access,
        branch,
        sessionId,
        checkpoint,
        settlementProtocol,
      ),
      exclusive: true,
    );
  }

  Future<void> _bindInside(
    Transaction txn,
    BusinessLedgerAccess access,
    String branch,
    String sessionId,
    BusinessCashCheckpoint checkpoint,
    bool settlementProtocol,
  ) async {
    final approved = await _syncApprovalUs(txn, branch);
    if (approved == null && await _isRecoveredLedger(txn, branch)) {
      // Restoration never authorizes sync; only an explicit owner approval
      // does, and even then only for a fresh session and checkpoint.
      throw const DirectoryAccessDenied();
    }
    final existing = await _binding(txn, branch);
    if (existing != null) {
      if (existing['session_id'] == sessionId &&
          existing['checkpoint_sequence'] == checkpoint.sequence &&
          existing['checkpoint_digest'] == checkpoint.digest &&
          ((await _cashObserved(txn, branch)) != null) == settlementProtocol)
        return;
      // Do not rebind a local outbox to a fresh session on login/reinstall.
      throw const DirectoryAccessDenied();
    }
    if (approved == null) {
      for (final table in [_queue, _decisions, _cashEqualizations]) {
        if ((await txn.query(
          table,
          columns: ['command_id'],
          where: 'branch_id = ?',
          whereArgs: [branch],
          limit: 1,
        )).isNotEmpty)
          throw const DirectoryAccessDenied();
      }
    } else if ((await txn.query(
      _queue,
      columns: ['command_id'],
      where: 'branch_id = ?',
      whereArgs: [branch],
      limit: 1,
    )).isNotEmpty) {
      // The sealed past is already moved aside; only a fresh command blocks.
      throw const DirectoryAccessDenied();
    }
    final accounts = await txn.rawQuery(
      '''
        SELECT s.account_id, a.currency, a.balance_minor, s.allow_negative
        FROM $_accounts s JOIN ${BusinessLedger._accounts} a
          ON a.branch_id = s.branch_id AND a.id = s.account_id
        WHERE s.branch_id = ? AND a.is_active = 1 AND a.closed_us IS NULL
        ORDER BY s.account_id
      ''',
      [branch],
    );
    if (accounts.isEmpty) throw const DirectoryAccessDenied();
    final bytes = utf8.encode(
      jsonEncode([
        'fyona.cash.checkpoint.v2',
        access.directory.workspace.organizationId,
        branch,
        checkpoint.sequence,
        [
          for (final row in accounts)
            [
              row['account_id'],
              row['currency'],
              row['balance_minor'],
              row['allow_negative'] == 1,
            ],
        ],
      ]),
    );
    if (sha256.convert(bytes).toString() != checkpoint.digest) {
      throw const DirectoryAccessDenied();
    }
    await txn.insert(_replicas, {
      'branch_id': branch,
      'session_id': sessionId,
      'checkpoint_sequence': checkpoint.sequence,
      'checkpoint_digest': checkpoint.digest,
    });
    if (settlementProtocol) {
      await txn.insert(_cashV3Replicas, {
        'branch_id': branch,
        'observed_through': checkpoint.sequence,
      });
    }
  }

  Future<Map<String, Object?>?> _binding(
    DatabaseExecutor db,
    String branch,
  ) async => (await db.query(
    _replicas,
    where: 'branch_id = ?',
    whereArgs: [branch],
  )).singleOrNull;

  Future<void> provision(
    BusinessLedgerAccess access,
    String accountId, {
    required int grantVersion,
    required bool allowNegative,
  }) async {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    if (grantVersion < 1) throw ArgumentError('Invalid cash grant version');
    await _db._transaction((txn) async {
      await _ledger._account(txn, branch, accountId);
      final previous = await _config(txn, branch, accountId);
      if (previous != null &&
          previous['grant_version'] == grantVersion &&
          previous['allow_negative'] == (allowNegative ? 1 : 0))
        return;
      if (previous != null &&
          (previous['grant_version'] as int) >= grantVersion) {
        throw const DirectoryAccessDenied();
      }
      if (await _binding(txn, branch) != null &&
          (previous == null ||
              previous['allow_negative'] != (allowNegative ? 1 : 0))) {
        // Once bound, a resource or policy change requires reconciliation,
        // not a local change to the authority's checkpoint.
        throw const DirectoryAccessDenied();
      }
      final values = {
        'grant_version': grantVersion,
        'allow_negative': allowNegative ? 1 : 0,
      };
      if (previous == null) {
        // This account must have been provisioned from its reconciled opening
        // snapshot. Do not let enabling the queue silently adopt old movements.
        final posts = await txn.query(
          BusinessLedger._legs,
          columns: ['sequence'],
          limit: 1,
          where:
              "branch_id = ? AND account_id = ? AND kind <> 'opening_balance'",
          whereArgs: [branch, accountId],
        );
        if (posts.isNotEmpty) throw const DirectoryAccessDenied();
        await txn.insert(_accounts, {
          'branch_id': branch,
          'account_id': accountId,
          ...values,
        });
      } else {
        await txn.update(
          _accounts,
          values,
          where: 'branch_id = ? AND account_id = ?',
          whereArgs: [branch, accountId],
        );
      }
    }, exclusive: true);
  }

  Future<Map<String, Object?>> withdraw(
    BusinessLedgerAccess access, {
    required String commandId,
    required String accountId,
    required int amountMinor,
    String? description,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.moveMoney);
    BusinessLedger._amount(amountMinor);
    final note = DirectoryDatabase._optional(description) ?? 'سحب';
    return _ledger._commit(
      branch,
      commandId,
      ['shared_withdrawal', accountId, amountMinor, note],
      (txn, now) async {
        final account = await _ledger._account(txn, branch, accountId);
        final config = await _requireConfig(txn, branch, accountId);
        return _stageWithdrawal(
          txn,
          branch,
          access.cashSessionId,
          commandId,
          accountId,
          now,
          account,
          config,
          amountMinor,
          description: note,
        );
      },
    );
  }

  Future<Map<String, Object?>> _stageWithdrawal(
    Transaction txn,
    String branch,
    String? sessionId,
    String commandId,
    String accountId,
    DateTime now,
    Map<String, Object?> account,
    Map<String, Object?> config,
    int amountMinor, {
    required String description,
    String? expenseCategory,
  }) async {
    if (!await _sessionMatches(txn, branch, sessionId)) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.sharedCashRequiresArbitration,
      );
    }
    if (await _hasQueuedEqualization(txn, branch)) {
      // Don't introduce a provisional withdrawal while this device awaits
      // the exact before/after delta from its equalization decision.
      throw const BusinessCashEqualizationPending();
    }
    final next = BusinessLedger._balance(account, -amountMinor);
    if (next < 0 && config['allow_negative'] != 1) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.insufficientBalance,
      );
    }
    await _ledger._post(
      txn,
      branch,
      commandId,
      accountId,
      now,
      kind: 'withdrawal',
      delta: -amountMinor,
      next: next,
      description: description,
      expenseCategory: expenseCategory,
    );
    await txn.insert(_queue, {
      'branch_id': branch,
      'command_id': commandId,
      'account_id': accountId,
      'amount_minor': amountMinor,
      'currency': account['currency'],
      'grant_version': config['grant_version'],
    });
    return {'id': commandId, 'balance_minor': next};
  }

  Future<List<Map<String, Object?>>> pending(BusinessLedgerAccess access) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._read(
      (db) => db.rawQuery(
        '''
      SELECT q.command_id, q.account_id, q.amount_minor, q.currency, q.grant_version
      FROM $_queue q
      JOIN ${BusinessLedger._legs} l ON l.branch_id = q.branch_id
        AND l.command_id = q.command_id AND l.account_id = q.account_id
      WHERE q.branch_id = ? ORDER BY l.sequence LIMIT 100
    ''',
        [branch],
      ),
    );
  }

  /// Persistent inputs for the Business notification center. The decision
  /// only becomes visible in the same commit as the reversal, and a resend
  /// cannot create a duplicate notification. No Personal notification store.
  Future<List<Map<String, Object?>>> conflicts(BusinessLedgerAccess access) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._read(
      (db) => db.rawQuery(
        '''
      SELECT d.command_id, d.decision, d.amount_minor, d.currency, d.blocked_by,
             d.sequence, l.created_us, r.command_id IS NOT NULL AS seen
      FROM $_decisions d LEFT JOIN $_conflictReads r
        ON r.branch_id = d.branch_id AND r.command_id = d.command_id
      JOIN ${BusinessLedger._legs} l ON l.branch_id = d.branch_id
        AND l.command_id = d.command_id AND l.account_id = d.account_id
      WHERE d.branch_id = ? AND d.decision <> 'accepted'
      ORDER BY d.sequence DESC LIMIT 100
    ''',
        [branch],
      ),
    );
  }

  Future<void> markConflictRead(BusinessLedgerAccess access, String id) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    return _db._transaction((txn) async {
      final row = await _byCommand(txn, _decisions, branch, id);
      if (row == null ||
          row['decision'] == BusinessCashDecision.accepted.name) {
        throw const DirectoryAccessDenied();
      }
      await txn.insert(_conflictReads, {
        'branch_id': branch,
        'command_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  /// Apply a committed authority receipt and remove the outgoing item in one
  /// transaction. Rejecting a save appends exactly one reversal; the original
  /// history and reason survive retries, restarts and disconnection.
  Future<void> decide(
    BusinessLedgerAccess access, {
    required String commandId,
    required int sequence,
    required BusinessCashDecision decision,
    String? blockedBy,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    _validateReceipt(commandId, sequence, blockedBy);
    return _db._transaction((txn) async {
      if (!await _sessionMatches(txn, branch, access.cashSessionId)) {
        throw const DirectoryAccessDenied();
      }
      final recorded = await _byCommand(txn, _decisions, branch, commandId);
      if (recorded != null) {
        if (recorded['decision'] != decision.name ||
            recorded['sequence'] != sequence) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        return;
      }
      final pending = await _byCommand(txn, _queue, branch, commandId);
      if (pending == null) {
        throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
      }
      if (decision != BusinessCashDecision.accepted) {
        final id = const Uuid().v5(commandId, 'fyona.cash.reversal.v1');
        final accountId = pending['account_id'] as String;
        final amount = pending['amount_minor'] as int;
        final account = await _ledger._account(txn, branch, accountId);
        final next = BusinessLedger._balance(account, amount);
        await _writeMarker(txn, branch, id, [
          'cash_reversal',
          commandId,
          sequence,
        ]);
        await _ledger._post(
          txn,
          branch,
          id,
          accountId,
          DateTime.now(),
          kind: 'withdrawal_reversal',
          delta: amount,
          next: next,
          description: 'عكس سحب',
        );
      }
      await _record(txn, branch, pending, sequence, decision, blockedBy);
    }, exclusive: true);
  }

  /// Returns true only once the receipt is durable (including replay).
  /// Push pending spends before pulling: while one exists for the resource,
  /// an unrelated incoming spend would wrongly show a provisional negative
  /// amount. In that case retain it on the relay, without an acknowledgment.
  Future<bool> applyWithdrawal(
    BusinessLedgerAccess access, {
    required String commandId,
    required String accountId,
    required int sequence,
    required String currency,
    required int amountMinor,
  }) {
    final branch = _ledger._branch(access, BusinessLedgerAction.syncCash);
    _validateReceipt(commandId, sequence, null);
    BusinessLedger._amount(amountMinor);
    final cur = businessCurrency(currency);
    return _db._transaction((txn) async {
      if (!await _sessionMatches(txn, branch, access.cashSessionId)) {
        throw const DirectoryAccessDenied();
      }
      await _requireConfig(txn, branch, accountId);
      final entry = {
        'command_id': commandId,
        'account_id': accountId,
        'currency': cur,
        'amount_minor': amountMinor,
      };
      final recorded = await _byCommand(txn, _decisions, branch, commandId);
      if (recorded != null) {
        _matchPayload(recorded, entry);
        if (recorded['decision'] != BusinessCashDecision.accepted.name ||
            recorded['sequence'] != sequence) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        return true;
      }
      final outgoing = await _byCommand(txn, _queue, branch, commandId);
      if (outgoing != null) {
        _matchPayload(outgoing, entry);
        await _record(
          txn,
          branch,
          entry,
          sequence,
          BusinessCashDecision.accepted,
          null,
        );
        return true;
      }
      final unsettled = await txn.query(
        _queue,
        columns: ['command_id'],
        limit: 1,
        where: 'branch_id = ? AND account_id = ?',
        whereArgs: [branch, accountId],
      );
      if (unsettled.isNotEmpty) return false;
      final account = await _ledger._account(txn, branch, accountId);
      if (account['currency'] != cur) {
        throw const BusinessLedgerError(BusinessLedgerProblem.currencyMismatch);
      }
      final next = BusinessLedger._balance(account, -amountMinor);
      await _writeMarker(txn, branch, commandId, [
        'cash_inbound',
        sequence,
        accountId,
        cur,
        amountMinor,
      ]);
      await _ledger._post(
        txn,
        branch,
        commandId,
        accountId,
        DateTime.now(),
        kind: 'withdrawal',
        delta: -amountMinor,
        next: next,
        description: 'سحب',
      );
      await _record(
        txn,
        branch,
        entry,
        sequence,
        BusinessCashDecision.accepted,
        null,
      );
      return true;
    }, exclusive: true);
  }

  Future<void> _record(
    Transaction txn,
    String branch,
    Map<String, Object?> entry,
    int sequence,
    BusinessCashDecision decision,
    String? blockedBy,
  ) async {
    final id = entry['command_id'];
    await txn.insert(_decisions, {
      'branch_id': branch,
      'command_id': id,
      'account_id': entry['account_id'],
      'amount_minor': entry['amount_minor'],
      'currency': entry['currency'],
      'sequence': sequence,
      'decision': decision.name,
      'blocked_by': blockedBy,
    });
    await txn.delete(
      _queue,
      where: 'branch_id = ? AND command_id = ?',
      whereArgs: [branch, id],
    );
  }

  Future<void> _requirePrivate(
    DatabaseExecutor db,
    String branch,
    String id,
  ) async {
    if (await _config(db, branch, id) != null) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.sharedCashRequiresArbitration,
      );
    }
  }

  Future<Map<String, Object?>> _requireConfig(
    DatabaseExecutor db,
    String branch,
    String id,
  ) async {
    final config = await _config(db, branch, id);
    if (config == null) throw const DirectoryAccessDenied();
    return config;
  }

  Future<Map<String, Object?>?> _config(
    DatabaseExecutor db,
    String branch,
    String id,
  ) async {
    final rows = await db.query(
      _accounts,
      where: 'branch_id = ? AND account_id = ?',
      whereArgs: [branch, id],
    );
    return rows.singleOrNull;
  }

  Future<bool> _sessionMatches(
    DatabaseExecutor db,
    String branch,
    String? sessionId,
  ) async =>
      sessionId != null &&
      (await _binding(db, branch))?['session_id'] == sessionId;

  static Future<Map<String, Object?>?> _byCommand(
    DatabaseExecutor db,
    String table,
    String branch,
    String id,
  ) async {
    final rows = await db.query(
      table,
      where: 'branch_id = ? AND command_id = ?',
      whereArgs: [branch, id],
    );
    return rows.singleOrNull;
  }

  static Future<void> _writeMarker(
    Transaction txn,
    String branch,
    String id,
    List<Object> fields,
  ) async {
    final digest = sha256.convert(utf8.encode(jsonEncode(fields))).toString();
    await txn.insert(BusinessLedger._commands, {
      'branch_id': branch,
      'id': id,
      'fingerprint': digest,
      'result': jsonEncode({'id': id}),
    });
  }

  static void _matchPayload(Map<String, Object?> a, Map<String, Object?> b) {
    if (a['account_id'] != b['account_id'] ||
        a['amount_minor'] != b['amount_minor'] ||
        a['currency'] != b['currency']) {
      throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
    }
  }

  static void _validateReceipt(String id, int sequence, String? blockedBy) {
    if (!isDirectoryId(id) ||
        id != id.toLowerCase() ||
        sequence <= 0 ||
        (blockedBy != null && !isDirectoryId(blockedBy))) {
      throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
    }
  }
}
