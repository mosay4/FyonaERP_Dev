part of 'directory_database.dart';

const _reconciliationRecords = 'business_reconciliations';

Future<void> _createBusinessReconciliations(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE $_reconciliationRecords (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      rtype TEXT NOT NULL CHECK (rtype IN ('bank', 'inventory')),
      status TEXT NOT NULL CHECK (status IN ('draft', 'checked', 'approved')),
      created_us INTEGER NOT NULL,
      ref_code TEXT NOT NULL,
      request_digest TEXT NOT NULL,
      approval_digest TEXT,
      snapshot TEXT NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE INDEX business_reconciliations_archive ON $_reconciliationRecords
      (branch_id, rtype, created_us DESC, id DESC)
  ''');
}

typedef BusinessBankMeasurement = ({
  String accountId,
  int actualMinor,
  int? expectedMinor,
});

final class BusinessReconciliationChanged implements Exception {
  const BusinessReconciliationChanged();
}

final class BusinessReconciliationInvalid implements Exception {
  const BusinessReconciliationInvalid();
}

extension BusinessBankReconciliation on BusinessLedger {
  Future<List<Map<String, dynamic>>> reconciliationAccounts(
    BusinessLedgerAccess access,
  ) async {
    _branch(access, BusinessLedgerAction.readBankReconciliation);
    final rows = await accounts(
      BusinessLedgerAccess(access.directory, {BusinessLedgerAction.readBank}),
    );
    return [
      for (final row in rows)
        {
          for (final key in [
            'id',
            'branch_id',
            'bank_name',
            'account_name',
            'account_number',
            'currency',
            'account_type',
          ])
            key: row[key],
          'balance': _reconMoney(row['balance_minor'] as int),
          'is_cash': _isLedgerCash(row['bank_name'] as String),
        },
    ];
  }

  Future<Map<String, dynamic>> checkBankReconciliation(
    BusinessLedgerAccess access, {
    required String id,
    required List<BusinessBankMeasurement> entries,
    String? notes,
    String? periodStart,
    String? periodEnd,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.checkBankReconciliation,
    );
    if (!isDirectoryId(id)) throw const BusinessReconciliationInvalid();
    final counts = _reconMeasurements(entries);
    final start = _reconDate(periodStart), end = _reconDate(periodEnd);
    if (start != null && end != null && start.isAfter(end)) {
      throw const BusinessReconciliationInvalid();
    }
    final note = _reconNotes(notes);
    final digest = _reconDigest([
      'bank',
      note,
      start?.toIso8601String(),
      end?.toIso8601String(),
      for (final e in counts) [e.accountId, e.actualMinor],
    ]);
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final existing = await _storedReconciliation(txn, branch, id, 'bank');
      if (existing != null) {
        if (existing['request_digest'] != digest) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        _requireReconciliation(access, allowed);
        return _bankReconciliationView(txn, branch, _reconciliationPayload(existing));
      }
      final lines = <Map<String, Object?>>[];
      final stamps = <String, Object?>{};
      if (await cashSync._sessionMatches(txn, branch, access.cashSessionId) &&
          !await _hasCashOutbox(txn, branch) &&
          !await _hasQueuedEqualization(txn, branch)) {
        stamps['@cash_head'] = await _cashObserved(txn, branch);
      }
      final grantVersions = <String, Object?>{};
      var allCash = true;
      for (final e in counts) {
        final account = await _account(txn, branch, e.accountId);
        final bank = account['bank_name'] as String;
        final before = account['balance_minor'] as int;
        final diff = e.actualMinor - before;
        allCash = allCash && _isLedgerCash(bank);
        stamps[e.accountId] = await _bankStamp(txn, branch, account);
        if (stamps['@cash_head'] != null) {
          final config = await cashSync._config(txn, branch, e.accountId);
          if (config != null) grantVersions[e.accountId] = config['grant_version'];
        }
        lines.add({
          'account_id': e.accountId,
          'name': account['account_name'],
          'bank_name': bank,
          'currency': account['currency'],
          'account_type': account['account_type'],
          'system': _reconMoney(before),
          'actual': _reconMoney(e.actualMinor),
          'diff': _reconMoney(diff),
          'status': diff == 0
              ? 'match'
              : diff < 0
              ? 'short'
              : 'surplus',
        });
      }
      if (grantVersions.isNotEmpty) stamps['@cash_grants'] = grantVersions;
      final now = DateTime.now().toUtc();
      final refCode =
          'RCN-${BusinessLedger._date(now).replaceAll('-', '')}'
          '-${id.substring(0, 8).toUpperCase()}';
      final record = <String, dynamic>{
        'id': id,
        'ref_code': refCode,
        'rtype': 'bank',
        'scope': 'accounts',
        'scope_json': {
          'account_ids': [for (final e in counts) e.accountId],
          'kind': allCash ? 'cash' : 'bank',
        },
        'branch_id': branch,
        'status': 'checked',
        'period_start': start?.toIso8601String(),
        'period_end': end?.toIso8601String(),
        'notes': note,
        'lines': lines,
        'has_diff': lines.any((row) => row['status'] != 'match'),
        'lines_count': lines.length,
        'settlements': [],
        'result': {},
        'measured_at': now.toIso8601String(),
        'created_at': now.toIso8601String(),
        'created_by': access.directory.workspace.accountId,
      };
      await txn.insert(_reconciliationRecords, {
        'branch_id': branch,
        'id': id,
        'rtype': 'bank',
        'status': 'checked',
        'created_us': now.microsecondsSinceEpoch,
        'ref_code': refCode,
        'request_digest': digest,
        'snapshot': jsonEncode(stamps),
        'payload': jsonEncode(record),
      });
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  /// A private approval commits immediately. If every changed account is
  /// shared and admitted, this saves one exact request, not an approval.
  Future<Map<String, dynamic>> approveBankReconciliation(
    BusinessLedgerAccess access, {
    required String id,
    required List<BusinessBankMeasurement> entries,
    String? notes,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.approveBankReconciliation,
    );
    final ordered = _reconMeasurements(entries);
    final note = _reconNotes(notes);
    final digest = _reconDigest([
      note,
      for (final e in ordered) [e.accountId, e.actualMinor, e.expectedMinor],
    ]);
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final row = await _storedReconciliation(txn, branch, id, 'bank');
      if (row == null) throw const BusinessReconciliationInvalid();
      final record = _reconciliationPayload(row);
      if (row['status'] == 'approved') {
        if (row['approval_digest'] != digest) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        _requireReconciliation(access, allowed);
        return record;
      }
      if (row['status'] != 'checked')
        throw const BusinessReconciliationInvalid();
      final queued = (await txn.query(_cashEqualizations,
        columns: ['approval_digest'],
        where: 'branch_id = ? AND recon_id = ?', whereArgs: [branch, id],
      )).singleOrNull;
      if (queued != null) {
        if (queued['approval_digest'] != digest) {
          throw const BusinessLedgerError(BusinessLedgerProblem.commandConflict);
        }
        _requireReconciliation(access, allowed);
        return _bankReconciliationView(txn, branch, record);
      }
      final snapshots = jsonDecode(row['snapshot'] as String) as Map;
      final lines = {
        for (final line in (record['lines'] as List).cast<Map>())
          line['account_id']: line,
      };
      final changedIds = {
        for (final line in lines.values)
          if (line['status'] != 'match') line['account_id'] as String,
      };
      final sharedConfigs = <String, Map<String, Object?>>{};
      for (final accountId in changedIds) {
        final config = await cashSync._config(txn, branch, accountId);
        if (config != null) sharedConfigs[accountId] = config;
      }
      final changes = <BusinessBankMeasurement>[];
      final shared = <BusinessCashEqualizationLine>[];
      final grants = <int>{};
      for (final e in ordered) {
        final line = lines[e.accountId];
        if (line == null ||
            e.expectedMinor != BusinessMoney.minor('${line['system']}') ||
            e.actualMinor != BusinessMoney.minor('${line['actual']}')) {
          throw const BusinessReconciliationInvalid();
        }
        final account = await _account(txn, branch, e.accountId);
        if (snapshots[e.accountId] != await _bankStamp(txn, branch, account)) {
          throw const BusinessReconciliationChanged();
        }
        if (e.actualMinor == e.expectedMinor) continue;
        changes.add(e);
        final config = sharedConfigs[e.accountId];
        if (config != null) {
          final version = config['grant_version'] as int;
          if (snapshots['@cash_head'] != null &&
              (snapshots['@cash_grants'] as Map?)?[e.accountId] != version) {
            throw const BusinessReconciliationChanged();
          }
          grants.add(version);
          shared.add((accountId: e.accountId, currency: account['currency'] as String,
            expectedMinor: e.expectedMinor!, actualMinor: e.actualMinor));
        }
      }
      if (changes.isEmpty) throw const BusinessReconciliationInvalid();
      final approval = _BankApproval(branch, id, record, digest, note,
        access.directory.workspace.accountId);
      if (sharedConfigs.isNotEmpty) {
        if (sharedConfigs.length != changedIds.length) {
          // No private-only partial submission may approve a mixed check.
          if (snapshots['@cash_head'] == null) {
            throw const BusinessLedgerError(BusinessLedgerProblem.sharedCashRequiresArbitration);
          }
          throw const BusinessCashEqualizationMixed();
        }
        if (await _hasCashOutbox(txn, branch) || await _hasQueuedEqualization(txn, branch)) {
          throw const BusinessCashEqualizationPending();
        }
        if (snapshots['@cash_head'] == null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.sharedCashRequiresArbitration);
        }
        if (grants.length != 1 || shared.length != changedIds.length) {
          throw const BusinessReconciliationInvalid();
        }
        await _stageCashEqualization(txn, approval,
          cash: cashSync, access: access, observed: snapshots['@cash_head'] as int?,
          grantVersion: grants.single, lines: shared);
      } else {
        final now = DateTime.now().toUtc();
        for (final e in changes) {
          await _postBankAdjustment(txn, branch, id, e.accountId,
            e.expectedMinor!, e.actualMinor, now,
            digest: digest, refCode: record['ref_code'] as String, reconId: id,
          );
        }
        await approval.finish(txn, now, ordered);
      }
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  Future<void> _postBankAdjustment(
    Transaction txn, String branch, String rootId, String accountId,
    int before, int after, DateTime now, {
    required String digest, required String? refCode, required String? reconId,
  }) async {
    final delta = after - before;
    final command = _bankAdjustmentId(rootId, accountId);
    await _post(txn, branch, command, accountId, now,
      kind: delta > 0 ? 'reconciliation_increase' : 'reconciliation_decrease',
      delta: delta, next: after,
      description: refCode == null ? 'تسوية مطابقة' : 'تسوية مطابقة $refCode',
      reference: refCode,
    );
    await txn.insert(BusinessLedger._commands, {
      'branch_id': branch, 'id': command, 'fingerprint': digest,
      'result': jsonEncode(reconId == null ? {'id': command} : {'reconciliation_id': reconId}),
    });
  }

  Future<Map<String, dynamic>> bankReconciliationDetail(
    BusinessLedgerAccess access,
    String id,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readBankReconciliation);
    return _directory._read((db) async {
      final row = await _storedReconciliation(db, branch, id, 'bank');
      if (row == null) throw const BusinessReconciliationInvalid();
      return _bankReconciliationView(db, branch, _reconciliationPayload(row));
    });
  }

  Future<List<Map<String, dynamic>>> bankReconciliationArchive(
    BusinessLedgerAccess access, {
    String rtype = 'bank',
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    int page = 1,
  }) {
    if (rtype != 'bank' && rtype != 'inventory') {
      throw const BusinessReconciliationInvalid();
    }
    final branch = _branch(
      access,
      rtype == 'inventory'
          ? BusinessLedgerAction.readInventoryReconciliation
          : BusinessLedgerAction.readBankReconciliation,
    );
    final since = _reconDate(dateFrom);
    final to = _reconDate(dateTo);
    final dateOnly = to != null && dateTo!.length == 10;
    final until = dateOnly ? DateTime(to.year, to.month, to.day + 1) : to;
    final needle = search?.trim().toLowerCase() ?? '';
    if (page < 1 || page > 1000000) throw const BusinessReconciliationInvalid();
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT payload FROM $_reconciliationRecords
        WHERE branch_id = ? AND rtype = ?
        ${status == null || status.isEmpty ? '' : 'AND status = ?'}
        ${since == null ? '' : 'AND created_us >= ?'}
        ${until == null
            ? ''
            : dateOnly
            ? 'AND created_us < ?'
            : 'AND created_us <= ?'}
        ${needle.isEmpty ? '' : '''
          AND (INSTR(LOWER(ref_code), ?) > 0
               OR INSTR(LOWER(COALESCE(json_extract(payload, '\$.notes'), '')), ?) > 0)
        '''}
        ORDER BY created_us DESC, id DESC LIMIT 50 OFFSET ?
      ''',
        [
          branch,
          rtype,
          if (status != null && status.isNotEmpty) status,
          ?since?.microsecondsSinceEpoch,
          ?until?.microsecondsSinceEpoch,
          if (needle.isNotEmpty) ...[needle, needle],
          (page - 1) * 50,
        ],
      );
      final records = rows.map(_reconciliationPayload).toList();
      for (final record in records) {
        if (await _requestSuspended(db, branch, record)) {
          record['authority_state'] = 'suspended';
        }
      }
      return records;
    });
  }
}

/// A restored request is never re-authorized: it stays suspended even after
/// the owner approves the ledger for sync again.
Future<bool> _requestSuspended(
  DatabaseExecutor db,
  String branch,
  Map<String, dynamic> record,
) async =>
    record['authority_state'] == 'queued' &&
    (await _syncFrozen(db, branch) ||
        await _hasSuspendedCommand(db, branch, '${record['id']}'));

Future<Map<String, dynamic>> _bankReconciliationView(
  DatabaseExecutor db, String branch, Map<String, dynamic> record,
) async {
  if (await _requestSuspended(db, branch, record)) {
    record['authority_state'] = 'suspended';
  }
  return record;
}

String _bankAdjustmentId(String id, String account) =>
    const Uuid().v5(id, 'fyona.reconciliation.bank.approve.v1:$account');

final class _BankApproval {
  const _BankApproval(this.branch, this.id, this.record, this.digest, this.notes, this.actor);
  final String branch, id, digest, actor;
  final Map<String, dynamic> record;
  final String? notes;

  Future<void> update(Transaction txn, Map<String, Object?> changes, {bool approved = false}) async {
    record.addAll(changes);
    await txn.update(_reconciliationRecords, {
      'payload': jsonEncode(record),
      if (approved) ...{'status': 'approved', 'approval_digest': digest},
    }, where: 'branch_id = ? AND id = ?', whereArgs: [branch, id]);
  }

  Future<void> finish(
    Transaction txn, DateTime now, List<BusinessBankMeasurement> entries, {
    String? commandRoot,
  }) {
    final lines = {
      for (final line in (record['lines'] as List).cast<Map>())
        line['account_id']: line,
    };
    final settlements = <Map<String, Object?>>[];
    var posted = 0;
    for (final e in entries) {
      final line = lines[e.accountId];
      if (line == null) throw const BusinessReconciliationInvalid();
      final delta = e.actualMinor - e.expectedMinor!;
      if (delta != 0) posted++;
      settlements.add({
        'account_id': e.accountId,
        for (final field in ['name', 'bank_name', 'account_type', 'currency']) field: line[field],
        'before': _reconMoney(e.expectedMinor!),
        'after': _reconMoney(e.actualMinor),
        'diff': _reconMoney(delta),
        'bank_tx_id': delta == 0 ? null : _bankAdjustmentId(commandRoot ?? id, e.accountId),
        'applied': delta != 0,
      });
    }
    return update(txn, {
      'status': 'approved', 'approved_by': actor, 'approved_at': now.toIso8601String(),
      if (record['authority_state'] == 'queued') 'authority_state': 'accepted',
      if (notes != null) 'notes': notes,
      'settlements': settlements,
      'result': {'settled': posted, 'untouched': lines.length - posted, 'ref_code': record['ref_code']},
    }, approved: true);
  }
}

void _requireReconciliation(
  BusinessLedgerAccess access,
  bool Function() allowed,
) {
  if (!access.directory.financialCutover || !allowed()) {
    throw const DirectoryAccessDenied();
  }
}

Future<Map<String, Object?>?> _storedReconciliation(
  DatabaseExecutor db,
  String branch,
  String id,
  String type,
) async => (await db.query(
  _reconciliationRecords,
  where: 'branch_id = ? AND id = ? AND rtype = ?',
  whereArgs: [branch, id, type],
  limit: 1,
)).singleOrNull;

Map<String, dynamic> _reconciliationPayload(Map<String, Object?> row) =>
    Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);

String _reconDigest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

Future<String> _bankStamp(
  DatabaseExecutor db,
  String branch,
  Map<String, Object?> account,
) async {
  final latest = await db.query(
    BusinessLedger._legs,
    columns: ['command_id'],
    where: 'branch_id = ? AND account_id = ?',
    whereArgs: [branch, account['id']],
    orderBy: 'sequence DESC',
    limit: 1,
  );
  return _reconDigest([
    account['balance_minor'],
    account['currency'],
    account['bank_name'],
    account['account_name'],
    account['account_type'],
    latest.singleOrNull?['command_id'],
  ]);
}

List<BusinessBankMeasurement> _reconMeasurements(
  List<BusinessBankMeasurement> entries,
) {
  final ids = <String>{};
  if (entries.isEmpty || entries.length > 500)
    throw const BusinessReconciliationInvalid();
  for (final e in entries) {
    if (!isDirectoryId(e.accountId) || !ids.add(e.accountId)) {
      throw const BusinessReconciliationInvalid();
    }
    BusinessLedger._amount(e.actualMinor, zero: true);
    if (e.expectedMinor != null) BusinessMoney.checked(e.expectedMinor!);
  }
  return [...entries]..sort((a, b) => a.accountId.compareTo(b.accountId));
}

String? _reconNotes(String? value) {
  final clean = value?.trim();
  if (clean == null || clean.isEmpty) return null;
  if (clean.length > 4000) throw const BusinessReconciliationInvalid();
  return clean;
}

DateTime? _reconDate(String? text) {
  if (text == null || text.isEmpty) return null;
  final value = DateTime.tryParse(text);
  if (value == null ||
      text.length < 10 ||
      _reportDay(text.substring(0, 10)) == null) {
    throw const BusinessReconciliationInvalid();
  }
  return value;
}

num _reconMoney(int minor) => num.parse(BusinessMoney.display(minor));
