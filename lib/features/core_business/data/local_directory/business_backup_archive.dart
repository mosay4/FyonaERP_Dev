part of 'directory_database.dart';

const _backupRecovery = 'business_backup_recoveries';
const _archive = 'business_snapshot';
const _manifestTable = 'fyona_business_backup_manifest';
const _archiveFormat = 'fyona.business-backup.v1';
// Live admission reservations are not exported. The archive wire shape is v14.
const _archiveVersion = 14;
/// Cap for a branch archive file chosen by the user (an untrusted file).
const businessBackupMaxBytes = 64 * 1024 * 1024;

/// Cap for the archive the app itself makes from a backup set it has just
/// rebuilt and verified (continuous backup restore). SQLite copies it page
/// by page on disk — nothing is held in memory — so the only limit needed
/// is a sanity ceiling against a runaway file.
const businessBackupRebuildMaxBytes = 64 * 1024 * 1024 * 1024;

// A backup includes every persisted branch fact, including replay markers,
// balances, pending commands and archived source rows. A replica admission,
// auth/vault state and the recovery receipt are never copied as live state.
const _archiveV10Tables = [
  DirectoryDatabase._table,
  'directory_fixtures',
  DirectoryDatabase._groupTable,
  DirectoryDatabase._deleted,
  BusinessLedger._commands,
  'business_ledger_policy',
  BusinessLedger._accounts,
  BusinessLedger._legs,
  _bankEdits,
  BusinessCashSync._accounts,
  BusinessCashSync._queue,
  BusinessCashSync._decisions,
  BusinessCashSync._conflictReads,
  BusinessLedger._debts,
  BusinessLedger._parts,
  'business_opening_debt_edits',
  'business_imported_opening_payments',
  'business_cutover_archives',
  'business_cutover_rows',
  _bankProjections,
  _openingProjectionReceipts,
  _commerceBranches,
  _commerceProducts,
  _commerceUnits,
  _commerceBarcodes,
  _commercePrices,
  _commerceStock,
  _commerceInvoices,
  _commerceLines,
  _commerceEdits,
  _commercePayments,
  _commerceBalances,
  _commerceReturns,
  _commerceReturnLines,
  _commerceLots,
  _commerceConsumptions,
  _commerceMovements,
  _commerceReceipts,
  _partyShares,
];
const _archiveV11Tables = [..._archiveV10Tables, _reconciliationRecords];
const _archiveV12Tables = [..._archiveV11Tables, ..._inventoryCatalogTables];
const _archiveV13Tables = [..._archiveV12Tables, _cashEqualizations];
const _employeeLedgerTables = [
  _employeeGrants,
  _employeePayroll,
  _employeeDebts,
  _employeeDebtLegs,
  _employeeReceipts,
];
// A sealed request is a persisted fact and travels with the branch; the
// re-approval itself is live authorization state and never does.
const _archiveTables = [
  ..._archiveV13Tables,
  ..._employeeLedgerTables,
  _branchTransfers,
  _branchTransferLines,
  _cashSuspended,
];

Future<void> _createBusinessBackupRecoveries(DatabaseExecutor db) =>
    db.execute('''
  CREATE TABLE $_backupRecovery (
    branch_id TEXT PRIMARY KEY,
    snapshot_id TEXT NOT NULL,
    ciphertext_digest TEXT NOT NULL CHECK (length(ciphertext_digest) = 64),
    source_cash TEXT,
    restored_us INTEGER NOT NULL
  )
''');

Future<bool> _isRecoveredLedger(DatabaseExecutor db, String branch) async =>
    (await db.query(
      _backupRecovery,
      columns: ['branch_id'],
      where: 'branch_id = ?',
      whereArgs: [branch],
      limit: 1,
    )).isNotEmpty;

enum BusinessBackupProblem {
  invalidArchive,
  notEmpty,
  tooLarge,
  nothingToBackUp,
}

final class BusinessBackupRejected implements Exception {
  const BusinessBackupRejected(this.problem);
  final BusinessBackupProblem problem;
}

const _badBackup = BusinessBackupRejected(BusinessBackupProblem.invalidArchive);

/// A fresh, uniformly random key per archive. It is not the app PIN, the
/// login password or the workspace encryption key. Do not persist or log it.
final class BusinessBackupCode {
  factory BusinessBackupCode.generate() {
    final random = Random.secure();
    return BusinessBackupCode._(
      Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
    );
  }

  factory BusinessBackupCode.parse(String input) {
    final text = input.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text)) throw _badBackup;
    final bytes = base64Url.decode(base64Url.normalize(text));
    if (bytes.length != 32 ||
        base64Url.encode(bytes).substring(0, 43) != text) {
      throw _badBackup;
    }
    return BusinessBackupCode._(bytes);
  }

  BusinessBackupCode._(this._bytes);
  final Uint8List _bytes;
  String get text => base64Url.encode(_bytes).substring(0, 43);
  String get _sqlCipherKey =>
      "x'${_bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'";
}

typedef BusinessBackupRestore = ({bool alreadyRestored, bool hasSharedHistory});

extension BusinessBackupLedger on BusinessLedger {
  /// Native SQLCipher copies only rows of the selected branch; no plaintext
  /// export, temporary JSON ledger, file-wide copy or re-executed command.
  Future<void> captureBackup(
    BusinessLedgerAccess access, {
    required String id,
    required File destination,
    required BusinessBackupCode code,
    required bool Function() allowed,
    int maxBytes = businessBackupMaxBytes,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.manageBackup);
    _requireBackupAccess(access, allowed);
    if (!_validBackupId(id) || await destination.exists()) throw _badBackup;
    await _withArchive(_directory, destination, code, restore: false, (
      db,
    ) async {
      final pageSize = int.tryParse(
        '${(await db.rawQuery('PRAGMA $_archive.page_size')).single.values.single}',
      );
      if (pageSize == null || pageSize < 512 || pageSize > 65536)
        throw _badBackup;
      await db.rawQuery(
        'PRAGMA $_archive.max_page_count = ${maxBytes ~/ pageSize}',
      );
      await db.rawQuery('PRAGMA $_archive.journal_mode = DELETE');
      await db.execute('PRAGMA $_archive.synchronous = FULL');
      await db.transaction((txn) async {
        _requireBackupAccess(access, allowed);
        await _requireMainSchema(txn);
        if ((await _cashLinkRow(txn, branch))?['state'] == 'pending') throw _badBackup;
        final counts = <String, int>{};
        for (final table in _archiveTables) {
          await txn.execute(
            '''
            CREATE TABLE $_archive.$table AS
            SELECT * FROM main.$table WHERE branch_id = ?
          ''',
            [branch],
          );
          counts[table] = await _archiveCount(txn, '$_archive.$table');
        }
        if (counts.values.every((count) => count == 0)) {
          throw const BusinessBackupRejected(
            BusinessBackupProblem.nothingToBackUp,
          );
        }
        final replica = (await txn.query(
          BusinessCashSync._replicas,
          columns: ['checkpoint_sequence', 'checkpoint_digest'],
          where: 'branch_id = ?',
          whereArgs: [branch],
        )).singleOrNull;
        final recovered =
            (await txn.query(
                  _backupRecovery,
                  columns: ['source_cash'],
                  where: 'branch_id = ?',
                  whereArgs: [branch],
                )).singleOrNull?['source_cash']
                as String?;
        await txn.execute(
          'CREATE TABLE $_archive.$_manifestTable (payload TEXT NOT NULL)',
        );
        await txn.rawInsert(
          'INSERT INTO $_archive.$_manifestTable (payload) VALUES (?)',
          [
            jsonEncode({
              'format': _archiveFormat,
               'schema': _archiveVersion,
              'id': id,
              'workspace': access.directory.workspace.storageId,
              'branch': branch,
              'counts': counts,
              'cash':
                  replica ?? (recovered == null ? null : jsonDecode(recovered)),
            }),
          ],
        );
        _requireBackupAccess(access, allowed);
      }, exclusive: true);
      await _checkCipherArchive(db);
      _requireBackupAccess(access, allowed);
    });
  }

  /// Only an empty branch can be restored, even if its sibling has a ledger.
  /// The exact same ciphertext is idempotent, including after later writes.
  /// A recovered ledger has no permission to publish or resume a relay.
  Future<BusinessBackupRestore> restoreBackup(
    BusinessLedgerAccess access, {
    required File source,
    required BusinessBackupCode code,
    required bool Function() allowed,
    String? expectedId,
    int maxBytes = businessBackupMaxBytes,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.manageBackup);
    _requireBackupAccess(access, allowed);
    final length = await source.length();
    if (length <= 0) throw _badBackup;
    if (length > maxBytes) {
      throw const BusinessBackupRejected(BusinessBackupProblem.tooLarge);
    }
    final digest = (await sha256.bind(source.openRead()).single).toString();
    return _withArchive(_directory, source, code, restore: true, (db) async {
      await _checkCipherArchive(db);
      return db.transaction((txn) async {
        _requireBackupAccess(access, allowed);
        await _requireMainSchema(txn);
        final (version, tables) = await _requireArchiveSchema(txn);
        final manifest = await _readBackupManifest(
          txn,
          access.directory,
          expectedId,
          version,
          tables,
        );
        final counts = manifest['counts'] as Map;
        final hasShared =
            (counts[BusinessCashSync._accounts] as int) != 0 ||
            (counts[_partyShares] as int) != 0;
        final previous = (await txn.query(
          _backupRecovery,
          where: 'branch_id = ?',
          whereArgs: [branch],
        )).singleOrNull;
        if (previous?['snapshot_id'] == manifest['id'] &&
            previous?['ciphertext_digest'] == digest) {
          _requireBackupAccess(access, allowed);
          return (alreadyRestored: true, hasSharedHistory: hasShared);
        }
        if (previous != null) {
          throw const BusinessBackupRejected(BusinessBackupProblem.notEmpty);
        }
        for (final table in [
          ..._archiveTables,
          BusinessCashSync._replicas,
          _cashV3Replicas,
           _syncApprovals,
           _cashLinkPrepares,
        ]) {
          if ((await txn.rawQuery(
            'SELECT 1 FROM main.$table WHERE branch_id = ? LIMIT 1',
            [branch],
          )).isNotEmpty) {
            throw const BusinessBackupRejected(BusinessBackupProblem.notEmpty);
          }
        }
        await txn.execute('PRAGMA defer_foreign_keys = ON');
        for (final table in tables) {
          if (await _archiveCount(txn, '$_archive.$table') != counts[table] ||
              (await txn.rawQuery(
                '''
                SELECT 1 FROM $_archive.$table WHERE branch_id IS NOT ? LIMIT 1
              ''',
                [branch],
              )).isNotEmpty) {
            throw _badBackup;
          }
          // A backup made before a later optional column (see
          // _archiveOptionalColumns) restores with that column empty.
          final archived = (await _columns(txn, _archive, table)).toSet();
          final columns = [
            for (final name in await _columns(txn, 'main', table))
              if (archived.contains(name)) name,
          ];
          if (table == BusinessLedger._legs) {
            // sequence is local to one SQLite file, not a finance ID.
            // Preserve its order without colliding with a sibling's sequence.
            columns.remove('sequence');
          }
          final fields = columns.map((name) => '"$name"').join(',');
          final order = table == BusinessLedger._legs
              ? 'ORDER BY sequence'
              : '';
          await txn.execute(
            '''
            INSERT INTO main.$table ($fields)
            SELECT $fields FROM $_archive.$table WHERE branch_id = ? $order
          ''',
            [branch],
          );
        }
        if ((await txn.rawQuery('PRAGMA main.foreign_key_check')).isNotEmpty)
          throw _badBackup;
        await txn.insert(_backupRecovery, {
          'branch_id': branch,
          'snapshot_id': manifest['id'],
          'ciphertext_digest': digest,
          'source_cash': manifest['cash'] == null
              ? null
              : jsonEncode(manifest['cash']),
          'restored_us': DateTime.now().toUtc().microsecondsSinceEpoch,
        });
        _requireBackupAccess(access, allowed);
        return (alreadyRestored: false, hasSharedHistory: hasShared);
      }, exclusive: true);
    });
  }
}

void _requireBackupAccess(
  BusinessLedgerAccess access,
  bool Function() allowed,
) {
  if (!access.directory.financialCutover || !allowed())
    throw const DirectoryAccessDenied();
}

bool _validBackupId(String id) => id == id.toLowerCase() && isDirectoryId(id);

Future<T> _withArchive<T>(
  DirectoryDatabase directory,
  File file,
  BusinessBackupCode code,
  Future<T> Function(Database) use, {
  required bool restore,
}) => directory._io.synchronized(() async {
  final db = directory._db;
  try {
    // An imported file is data only, never a schema/migration to execute.
    await db.execute('PRAGMA trusted_schema = OFF');
    final path = restore
        ? Uri.file(
            file.absolute.path,
          ).replace(query: 'mode=ro&immutable=1').toString()
        : file.path;
    await db.execute('ATTACH DATABASE ? AS $_archive KEY ?', [
      path,
      code._sqlCipherKey,
    ]);
    try {
      return await use(db);
    } finally {
      await db.execute('DETACH DATABASE $_archive');
    }
  } on DatabaseException {
    // Never return the SQL driver's message, which can contain bound values.
    throw _badBackup;
  }
});

Future<void> _checkCipherArchive(DatabaseExecutor db) async {
  if ((await db.rawQuery(
    'PRAGMA $_archive.cipher_integrity_check',
  )).isNotEmpty) {
    throw _badBackup;
  }
  final integrity = await db.rawQuery('PRAGMA $_archive.quick_check');
  if (integrity.length != 1 || integrity.single.values.single != 'ok')
    throw _badBackup;
}

Future<int> _archiveCount(DatabaseExecutor db, String qualified) async =>
    (await db.rawQuery('SELECT COUNT(*) AS n FROM $qualified')).single['n']
        as int;

Future<List<String>> _columns(
  DatabaseExecutor db,
  String schema,
  String table,
) async {
  final rows = await db.rawQuery('PRAGMA $schema.table_xinfo($table)');
  if (rows.isEmpty || rows.any((r) => r['hidden'] != 0)) throw _badBackup;
  return [for (final row in rows) row['name'] as String];
}

Future<void> _requireMainSchema(DatabaseExecutor db) async {
  final tables = await db.rawQuery('''
    SELECT name FROM main.sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
      AND name NOT LIKE '\\_bk\\_%' ESCAPE '\\'
  ''');
  final actual = tables.map((r) => r['name']).toSet();
  final expected = {
    ..._archiveTables,
    BusinessCashSync._replicas,
    _cashV3Replicas,
    _backupRecovery,
    _syncApprovals,
    _cashLinkPrepares,
    // Device-to-device sync bookkeeping: local to this install, never archived.
    _syncOutbox,
    _syncLog,
    _syncChanges,
    _syncRows,
    _syncState,
    _syncNotices,
    _employeesTable,
  };
  if (actual.length != expected.length || !actual.containsAll(expected))
    throw _badBackup;
}

/// Nullable columns added after a backup format: older backups lack them.
const _archiveOptionalColumns = <String, Set<String>>{
  _commerceUnits: {'image'},
  _commerceInvoices: {'created_by_name', 'created_by_role'},
  _commerceReturns: {'created_by_name', 'created_by_role'},
};

Future<(int, List<String>)> _requireArchiveSchema(DatabaseExecutor db) async {
  final schema = await db.rawQuery(
    'SELECT name, type FROM $_archive.sqlite_schema',
  );
  final names = schema.map((row) => row['name']).toSet();
  final (version, tables) = names.contains(_employeeGrants)
      ? (14, _archiveTables)
      : names.contains(_cashEqualizations)
      ? (13, _archiveV13Tables)
      : names.any(_inventoryCatalogTables.contains)
      ? (12, _archiveV12Tables)
      : names.contains(_reconciliationRecords)
      ? (11, _archiveV11Tables)
      : (10, _archiveV10Tables);
  final expected = {...tables, _manifestTable};
  if (schema.length != expected.length ||
      schema.any(
        (row) => row['type'] != 'table' || !expected.contains(row['name']),
      ))
    throw _badBackup;
  final list = await db.rawQuery('PRAGMA $_archive.table_list');
  if (list
          .where(
            (row) => expected.contains(row['name']) && row['type'] == 'table',
          )
          .length !=
      expected.length) {
    throw _badBackup;
  }
  for (final table in tables) {
    final main = await _columns(db, 'main', table);
    final incoming = await _columns(db, _archive, table);
    final missing = main.toSet().difference(incoming.toSet());
    final optional = _archiveOptionalColumns[table] ?? const <String>{};
    if (incoming.length != incoming.toSet().length ||
        !main.toSet().containsAll(incoming) ||
        !optional.containsAll(missing) ||
        !incoming.contains('branch_id'))
      throw _badBackup;
  }
  final header = await _columns(db, _archive, _manifestTable);
  if (header.length != 1 || header.single != 'payload') throw _badBackup;
  return (version, tables);
}

Future<Map<String, dynamic>> _readBackupManifest(
  DatabaseExecutor db,
  DirectoryAccess scope,
  String? expectedId,
  int version,
  List<String> tables,
) async {
  final rows = await db.rawQuery(
    'SELECT payload FROM $_archive.$_manifestTable LIMIT 2',
  );
  if (rows.length != 1 || rows.single['payload'] is! String) throw _badBackup;
  final raw = rows.single['payload'] as String;
  if (raw.length > 8192) throw _badBackup;
  try {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['format'] != _archiveFormat ||
        data['schema'] != version ||
        data['workspace'] != scope.workspace.storageId ||
        data['branch'] != scope.branchId ||
        data['id'] is! String ||
        !_validBackupId(data['id'] as String) ||
        (expectedId != null && data['id'] != expectedId))
      throw _badBackup;
    final counts = data['counts'];
    if (counts is! Map ||
        counts.length != tables.length ||
        tables.any(
          (table) => counts[table] is! int || (counts[table] as int) < 0,
        ) ||
        counts.values.every((count) => count == 0))
      throw _badBackup;
    final cash = data['cash'];
    if (cash != null &&
        (cash is! Map ||
            cash.length != 2 ||
            cash['checkpoint_sequence'] is! int ||
            (cash['checkpoint_sequence'] as int) < 0 ||
            cash['checkpoint_digest'] is! String ||
            !RegExp(
              r'^[0-9a-f]{64}$',
            ).hasMatch(cash['checkpoint_digest'] as String))) {
      throw _badBackup;
    }
    return data;
  } on FormatException {
    throw _badBackup;
  }
}
