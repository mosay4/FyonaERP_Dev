import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/utils/document_number.dart';
import '../local_ledger/business_money.dart';
import '../local_ledger/business_report_fx.dart';
import 'directory_party.dart';
import 'directory_scope.dart';

part 'business_ledger.dart';
part 'business_ledger_schema.dart';
part 'business_employee_delegation.dart';
part 'business_employee_finance.dart';
part 'business_employee_read_cache.dart';
part 'business_branch_transfers.dart';
part 'business_stock_transfer.dart';
part 'business_sync_reapproval.dart';
part 'business_cash_sync.dart';
part 'business_cash_admission.dart';
part 'business_cash_equalization.dart';
part 'business_cutover_archive.dart';
part 'business_opening_debt.dart';
part 'business_bank_accounts.dart';
part 'business_bank_cutover.dart';
part 'business_opening_cutover.dart';
part 'business_commerce_schema.dart';
part 'business_commerce_cutover.dart';
part 'business_commerce_reads.dart';
part 'business_commerce_stock.dart';
part 'business_commerce_sales.dart';
part 'business_commerce_products.dart';
part 'business_inventory_catalog.dart';
part 'business_inventory_batches.dart';
part 'business_product_statistics.dart';
part 'business_operations.dart';
part 'business_party_shares.dart';
part 'business_backup_archive.dart';
part 'business_debt_report.dart';
part 'business_sales_report.dart';
part 'business_report_cost.dart';
part 'business_inventory_report.dart';
part 'business_inventory_reconciliation.dart';
part 'business_bank_reconciliation.dart';
part 'business_money_report.dart';
part 'business_sync_engine.dart';
part 'business_employees_local.dart';

abstract interface class DirectoryKeyStore {
  Future<String?> read(String workspaceId);
  Future<void> write(String workspaceId, String key);
}

final class DirectoryKeyUnavailable implements Exception {
  const DirectoryKeyUnavailable();
}

/// Business-only SQLCipher store. No calls to a network client, business REST
/// repository, Personal database/factory, or synchronization queue.
final class DirectoryDatabase {
  DirectoryDatabase._(this.workspace, this._db, this._io);

  static final _opening = Lock();
  // FFI handles share an isolate; a busy second BEGIN must not block that
  // isolate while the first connection is waiting to send its COMMIT.
  static final _ioLanes = List.generate(32, (_) => Lock());
  static final _factory = createDatabaseFactoryFfi();
  static const _schemaVersion = 19;
  static const _table = 'directory_parties';
  static const _groupTable = 'business_debt_groups';
  static const _deleted = 'business_deleted_directory_parties';
  static const _visibleParty =
      '''
    NOT EXISTS (SELECT 1 FROM $_deleted tombstone
      WHERE tombstone.branch_id = $_table.branch_id AND tombstone.kind = $_table.kind
        AND tombstone.party_id = $_table.id)
  ''';

  final DirectoryWorkspace workspace;
  final Database _db;
  final Lock _io;

  /// In-development Business ledger. UI selection must only expose it after
  /// the branch's financial writers have been cut over, not on qa_directory.
  late final BusinessLedger ledger = BusinessLedger._(this);

  static String filePath(Directory root, DirectoryWorkspace workspace) =>
      p.join(root.path, '${workspace.storageId}.sqlite');

  static Future<DirectoryDatabase> open({
    required Directory root,
    required DirectoryWorkspace workspace,
    required DirectoryKeyStore keys,
    DatabaseFactory? factory,
  }) => _opening.synchronized(() async {
    final path = p.normalize(p.absolute(filePath(root, workspace)));
    final io = _ioLanes[path.hashCode % _ioLanes.length];
    var key = await keys.read(workspace.storageId);
    if (key == null) {
      // A missing/invalid key is not a request to reset an existing workspace.
      if (await File(path).exists()) throw const DirectoryKeyUnavailable();
      final random = Random.secure();
      key = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await keys.write(workspace.storageId, key);
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const DirectoryKeyUnavailable();
    }
    final rawKey = key;
    await root.create(recursive: true);
    final db = await io.synchronized(
      () => (factory ?? _factory).openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          singleInstance: false,
          onConfigure: (db) async {
            // Fail closed if the build does not contain the expected cipher.
            if ((await db.rawQuery('PRAGMA cipher_version')).isEmpty) {
              throw const DirectoryKeyUnavailable();
            }
            // SQLCipher requires a literal here. rawKey is exactly 64 hex chars.
            await db.execute('PRAGMA key = "x\'$rawKey\'"');
            await db.rawQuery('SELECT count(*) FROM sqlite_master');
            await db.execute('PRAGMA temp_store = MEMORY');
            await db.execute('PRAGMA busy_timeout = 3000');
            await db.rawQuery('PRAGMA journal_mode = DELETE');
            await db.execute('PRAGMA synchronous = FULL');
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE $_table (
              kind TEXT NOT NULL CHECK (kind IN ('customer', 'supplier')),
              id TEXT NOT NULL,
              branch_id TEXT NOT NULL,
              name TEXT NOT NULL,
              folded_name TEXT NOT NULL,
              phone TEXT,
              email TEXT,
              folded_email TEXT,
              created_us INTEGER NOT NULL,
              origin TEXT NOT NULL CHECK (origin IN ('device', 'fixture')),
              PRIMARY KEY (kind, id)
            )
          ''');
            await db.execute('''
            CREATE INDEX directory_branch_order ON $_table
              (branch_id, kind, created_us DESC, id)
          ''');
            await db.execute('''
            CREATE INDEX directory_branch_name ON $_table
              (branch_id, kind, folded_name)
          ''');
            await db.execute('''
            CREATE INDEX directory_branch_phone ON $_table
              (branch_id, kind, phone)
          ''');
            await db.execute('''
            CREATE TABLE directory_fixtures (
              branch_id TEXT NOT NULL,
              snapshot_id TEXT NOT NULL,
              PRIMARY KEY (branch_id, snapshot_id)
            )
          ''');
            await _createDebtGroups(db);
            await _createBusinessLedger(db);
            await _createBusinessCutoverArchive(db);
            await _createCashConflictReads(db);
            await _createBusinessBankManagement(db);
            await _createOpeningCutoverProjection(db);
            await _createBusinessCommerce(db);
            await _upgradeInventoryBatches(db);
            await _createBusinessPartyShares(db);
            await _createBusinessCashReplica(db);
             await _createBusinessBackupRecoveries(db);
             await _createBusinessReconciliations(db);
             await _createBusinessInventoryCatalog(db);
             await _createBusinessCashEqualization(db);
             await _createBusinessEmployeeDelegation(db);
             await _createBusinessEmployeeFinance(db);
             await _createBusinessBranchTransfers(db);
             await _createBusinessStockTransfer(db);
              await _createBusinessSyncReapproval(db);
              await _createCashLinkPrepares(db);
              await _createBusinessSync(db);
              await _createBusinessEmployees(db);
              await _upgradeUnitImages(db);
              await _upgradeCashierNames(db);
          },
          onDowngrade: (_, _, _) =>
              throw StateError('Unsupported directory schema'),
          onUpgrade: (db, from, to) async {
            if (from < 1 || from >= to || to != _schemaVersion) {
              throw StateError('Missing directory schema migration');
            }
            if (from == 1) await _createDebtGroups(db);
            if (from < 3) {
              await _createBusinessLedger(db);
            } else if (from == 3) {
              await _upgradeLedgerDebts(db);
            }
            if (from < 4) {
              await _createBusinessCutoverArchive(db);
              await _createCashConflictReads(db);
            }
            if (from < 5) await _createBusinessBankManagement(db);
            if (from < 6) await _createOpeningCutoverProjection(db);
            if (from < 7) await _createBusinessCommerce(db);
            if (from < 8) {
              await _upgradeInventoryBatches(db);
              await _createBusinessPartyShares(db);
            }
            if (from < 9) await _createBusinessCashReplica(db);
             if (from < 10) await _createBusinessBackupRecoveries(db);
             if (from < 11) await _createBusinessReconciliations(db);
             if (from < 12) await _createBusinessInventoryCatalog(db);
             if (from < 13) await _createBusinessCashEqualization(db);
              if (from < 14) {
               await _createBusinessEmployeeDelegation(db);
               await _createBusinessEmployeeFinance(db);
               await _createBusinessBranchTransfers(db);
               await _createBusinessStockTransfer(db);
               await _createBusinessSyncReapproval(db);
              }
              if (from < 15) await _createCashLinkPrepares(db);
              if (from < 16) await _createBusinessSync(db);
              if (from < 17) await _createBusinessEmployees(db);
              if (from < 18) await _upgradeUnitImages(db);
              if (from < 19) await _upgradeCashierNames(db);
          },
          onOpen: (db) async {
            await _createBusinessSync(db);
            await _createBusinessEmployees(db);
            await _installBusinessSyncTriggers(db);
          },
        ),
      ),
    );
    return DirectoryDatabase._(workspace, db, io);
  });

  Future<void> close() => _io.synchronized(_db.close);


  Future<T> _read<T>(Future<T> Function(DatabaseExecutor) read) =>
      _io.synchronized(() => read(_db));

  /// The single Business write path: the write and the operation that will
  /// carry it to the other devices commit together.
  Future<T> _transaction<T>(
    Future<T> Function(Transaction) run, {
    bool exclusive = false,
  }) async {
    final op = const Uuid().v4();
    var made = false;
    final result = await _io.synchronized(
      () => _db.transaction((txn) async {
        await _syncBegin(txn, op);
        final result = await run(txn);
        made = await _syncSeal(txn, op);
        return result;
      }, exclusive: exclusive),
    );
    // Committed: let it leave the device at once.
    if (made) businessSyncLocalWrites.add(op);
    return result;
  }

  static Future<void> _createDebtGroups(DatabaseExecutor db) async {
    await db.execute('''
      CREATE UNIQUE INDEX directory_party_scope ON $_table (branch_id, kind, id)
    ''');
    await db.execute('''
      CREATE TABLE $_groupTable (
        id TEXT PRIMARY KEY,
        branch_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        party_id TEXT NOT NULL,
        name TEXT NOT NULL,
        created_us INTEGER NOT NULL,
        FOREIGN KEY (branch_id, kind, party_id)
          REFERENCES $_table (branch_id, kind, id)
      )
    ''');
    await db.execute('''
      CREATE INDEX business_debt_groups_by_party ON $_groupTable
      (branch_id, kind, party_id, created_us DESC, id)
    ''');
  }

  void _check(
    DirectoryAccess access,
    DirectoryPartyKind kind, {
    bool write = false,
  }) {
    if (access.workspace.storageId != workspace.storageId ||
        !(write ? access.canCreate(kind) : access.canRead(kind))) {
      throw const DirectoryAccessDenied();
    }
  }

  Future<List<DirectoryParty>> search(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String query,
  ) async {
    _check(access, kind);
    final search = '%${query.toLowerCase()}%';
    final extra = query.isEmpty
        ? ''
        : r'''
      AND (folded_name LIKE ? ESCAPE '\' OR phone LIKE ? ESCAPE '\'
        OR folded_email LIKE ? ESCAPE '\')
    ''';
    final rows = await _read(
      (db) => db.query(
        _table,
        where: 'branch_id = ? AND kind = ? AND $_visibleParty $extra',
        whereArgs: [
          access.branchId,
          kind.name,
          if (query.isNotEmpty) ...[search, search, search],
        ],
        orderBy: 'created_us DESC, id',
        limit: 20, // Same first page as the current lists.
      ),
    );
    return rows.map((row) => _party(row, kind)).toList(growable: false);
  }

  Future<DirectoryParty> find(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String id,
  ) async {
    _check(access, kind);
    return _party(
      await _read((db) => _scopedParty(db, access, kind, id)),
      kind,
    );
  }

  Future<void> update(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String id, {
    String? name,
    String? phone,
  }) async {
    _check(access, kind, write: true);
    final cleanName = _optional(name);
    final cleanPhone = _optional(phone);
    // Match the current edit dialog: an empty field is not a change. The
    // directory's duplicate rules apply to creation, not to legacy edits.
    if (cleanName != null && cleanName.runes.length > 200) {
      throw const DirectoryValidation(DirectoryValidationProblem.nameLength);
    }
    if (cleanPhone != null && cleanPhone.runes.length > 50) {
      throw const DirectoryValidation(DirectoryValidationProblem.phoneLength);
    }
    await _transaction((txn) async {
      await _scopedParty(txn, access, kind, id);
      if (cleanName == null && cleanPhone == null) return;
      await txn.update(
        _table,
        {
          if (cleanName != null) 'name': cleanName,
          if (cleanName != null) 'folded_name': cleanName.toLowerCase(),
          if (cleanPhone != null) 'phone': cleanPhone,
        },
        where: 'branch_id = ? AND kind = ? AND id = ?',
        whereArgs: [access.branchId, kind.name, id],
      );
    }, exclusive: true);
  }

  Future<List<Map<String, dynamic>>> groups(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String partyId,
  ) async {
    _check(access, kind);
    return _transaction((txn) async {
      await _scopedParty(txn, access, kind, partyId);
      return txn.rawQuery(
        '''
         SELECT g.id, g.name, g.group_kind AS kind, g.period,
           (SELECT COUNT(*) FROM ${BusinessLedger._debts} d
             WHERE d.branch_id = g.branch_id AND d.kind = g.kind
               AND d.party_id = g.party_id AND d.group_id = g.id AND d.cancelled_us IS NULL)
           + (SELECT COUNT(*) FROM $_commerceInvoices i
             JOIN $_commerceBalances b ON b.branch_id = i.branch_id AND b.invoice_id = i.id
             WHERE i.branch_id = g.branch_id AND i.party_kind = g.kind
               AND i.party_id = g.party_id AND i.group_id = g.id
               AND i.deleted_us IS NULL AND i.status NOT IN ('draft','cancelled')) AS count
         FROM $_groupTable g
         WHERE g.branch_id = ? AND g.kind = ? AND g.party_id = ?
        ORDER BY g.created_us DESC, g.id
      ''',
        [access.branchId, kind.name, partyId],
      );
    });
  }

  Future<void> createGroup(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String partyId,
    String name, {
    String? commandId,
  }) async {
    _check(access, kind, write: true);
    final clean = _groupName(name);
    final id = commandId ?? const Uuid().v4();
    if (!isDirectoryId(id)) throw ArgumentError('Invalid debt group id');
    await _transaction((txn) async {
      await _scopedParty(txn, access, kind, partyId);
      final prior = await txn.query(
        _groupTable,
        where: 'id = ?',
        whereArgs: [id],
      );
      if (prior.isNotEmpty) {
        final row = prior.single;
        if (row['branch_id'] != access.branchId ||
            row['kind'] != kind.name ||
            row['party_id'] != partyId ||
            row['name'] != clean) {
          throw const DirectoryImportConflict();
        }
        return;
      }
      await txn.insert(_groupTable, {
        'id': id,
        'branch_id': access.branchId,
        'kind': kind.name,
        'party_id': partyId,
        'name': clean,
        'created_us': DateTime.now().toUtc().microsecondsSinceEpoch,
      });
    }, exclusive: true);
  }

  Future<void> renameGroup(
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String partyId,
    String groupId,
    String name,
  ) async {
    _check(access, kind, write: true);
    final updated = await _read(
      (db) => db.update(
        _groupTable,
        {'name': _groupName(name)},
        where: 'branch_id = ? AND kind = ? AND party_id = ? AND id = ?',
        whereArgs: [access.branchId, kind.name, partyId, groupId],
      ),
    );
    if (updated != 1) throw const DirectoryPartyNotFound();
  }

  static String _groupName(String name) {
    final clean = name.trim();
    if (clean.isEmpty || clean.runes.length > 100) {
      throw const DirectoryValidation(
        DirectoryValidationProblem.groupNameLength,
      );
    }
    return clean;
  }

  Future<Map<String, Object?>> _scopedParty(
    DatabaseExecutor executor,
    DirectoryAccess access,
    DirectoryPartyKind kind,
    String id,
  ) async {
    if (!isDirectoryId(id)) throw const DirectoryPartyNotFound();
    final rows = await executor.query(
      _table,
      where: 'branch_id = ? AND kind = ? AND id = ? AND $_visibleParty',
      whereArgs: [access.branchId, kind.name, id],
      limit: 1,
    );
    if (rows.isEmpty) throw const DirectoryPartyNotFound();
    return rows.single;
  }

  Future<DirectoryParty> create(
    DirectoryAccess access,
    DirectoryPartyKind kind, {
    required String name,
    String? phone,
    String? id,
  }) async {
    _check(access, kind, write: true);
    final party = _newParty(access, kind, name: name, phone: phone, id: id);
    return _transaction((txn) async {
      final existing = await _existing(txn, party);
      if (existing != null) {
        if (existing['origin'] != 'device' ||
            existing['branch_id'] != party.branchId ||
            existing['name'] != party.name ||
            existing['phone'] != party.phone) {
          throw const DirectoryImportConflict();
        }
        return _party(existing, kind);
      }
      await _insert(txn, party, 'device');
      return party;
    }, exclusive: true);
  }

  DirectoryParty _newParty(
    DirectoryAccess access,
    DirectoryPartyKind kind, {
    required String name,
    String? phone,
    String? id,
    DateTime? time,
  }) {
    final cleanName = name.trim();
    final cleanPhone = _optional(phone);
    if (cleanName.runes.length < 2 || cleanName.runes.length > 200) {
      throw const DirectoryValidation(DirectoryValidationProblem.nameLength);
    }
    if (cleanPhone != null && cleanPhone.runes.length > 50) {
      throw const DirectoryValidation(DirectoryValidationProblem.phoneLength);
    }
    final party = DirectoryParty(
      id: id ?? const Uuid().v4(),
      kind: kind,
      branchId: access.branchId,
      organizationId: workspace.organizationId,
      name: cleanName,
      phone: cleanPhone,
      createdAt: (time ?? DateTime.now()).toUtc(),
    );
    if (!isDirectoryId(party.id)) throw ArgumentError('Invalid party id');
    return party;
  }

  /// Import an explicitly scoped, synthetic Phase 1 directory snapshot. Same
  /// fixture may be applied repeatedly; a conflicting ID or any invalid row
  /// rolls back the entire import. No server call or implicit branch mapping.
  Future<void> importFixture(
    DirectoryAccess access,
    Iterable<DirectoryParty> parties, {
    String? snapshotId,
  }) async {
    if (snapshotId != null && !isDirectoryId(snapshotId)) {
      throw ArgumentError('Invalid directory snapshot id');
    }
    final rows = parties.toList(growable: false);
    for (final row in rows) {
      _check(access, row.kind, write: true);
      if (row.organizationId != workspace.organizationId ||
          row.branchId != access.branchId) {
        throw const DirectoryAccessDenied();
      }
      if (!isDirectoryId(row.id) || row.name.trim().isEmpty) {
        throw const DirectoryImportConflict();
      }
    }
    await _transaction((txn) async {
      for (final party in rows) {
        final old = await _existing(txn, party);
        if (old != null) {
          if (old['origin'] != 'fixture' ||
              old['branch_id'] != party.branchId ||
              old['name'] != party.name ||
              old['phone'] != party.phone ||
              old['email'] != party.email ||
              old['created_us'] != party.createdAt.microsecondsSinceEpoch) {
            throw const DirectoryImportConflict();
          }
        } else {
          // Imported data can contain pre-existing duplicates (e.g. after
          // legacy edits). Keep both original IDs, never coalesce them.
          await _insert(txn, party, 'fixture');
        }
      }
      if (snapshotId != null) {
        await txn.insert('directory_fixtures', {
          'branch_id': access.branchId,
          'snapshot_id': snapshotId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }, exclusive: true);
  }

  Future<bool> hasFixture(DirectoryAccess access, String snapshotId) async {
    if (!DirectoryPartyKind.values.any(access.canRead)) {
      throw const DirectoryAccessDenied();
    }
    final visibleKind = DirectoryPartyKind.values.firstWhere(access.canRead);
    _check(access, visibleKind);
    return (await _read(
      (db) => db.query(
        'directory_fixtures',
        where: 'branch_id = ? AND snapshot_id = ?',
        whereArgs: [access.branchId, snapshotId],
        limit: 1,
      ),
    )).isNotEmpty;
  }

  Future<Map<String, Object?>?> _existing(
    Transaction txn,
    DirectoryParty party,
  ) async {
    final rows = await txn.query(
      _table,
      where: 'kind = ? AND id = ?',
      whereArgs: [party.kind.name, party.id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _insert(
    Transaction txn,
    DirectoryParty party,
    String origin,
  ) async {
    final scopedArgs = [party.branchId, party.kind.name];
    final foldedName = party.name.toLowerCase();
    if (origin == 'device') {
      final sameName = await txn.query(
        _table,
        columns: ['id'],
        where:
            'branch_id = ? AND kind = ? AND folded_name = ? AND $_visibleParty',
        whereArgs: [...scopedArgs, foldedName],
        limit: 1,
      );
      if (sameName.isNotEmpty) {
        throw const DirectoryValidation(
          DirectoryValidationProblem.duplicateName,
        );
      }
      if (_optional(party.phone) != null) {
        final samePhone = await txn.query(
          _table,
          columns: ['id'],
          where: 'branch_id = ? AND kind = ? AND phone = ? AND $_visibleParty',
          whereArgs: [...scopedArgs, party.phone],
          limit: 1,
        );
        if (samePhone.isNotEmpty) {
          throw const DirectoryValidation(
            DirectoryValidationProblem.duplicatePhone,
          );
        }
      }
    }
    await txn.insert(_table, {
      'kind': party.kind.name,
      'id': party.id,
      'branch_id': party.branchId,
      'name': party.name,
      'folded_name': foldedName,
      'phone': party.phone,
      'email': party.email,
      'folded_email': party.email?.toLowerCase(),
      'created_us': party.createdAt.microsecondsSinceEpoch,
      'origin': origin,
    });
  }

  DirectoryParty _party(Map<String, Object?> row, DirectoryPartyKind kind) =>
      DirectoryParty(
        id: row['id'] as String,
        kind: kind,
        organizationId: workspace.organizationId,
        branchId: row['branch_id'] as String,
        name: row['name'] as String,
        phone: row['phone'] as String?,
        email: row['email'] as String?,
        createdAt: DateTime.fromMicrosecondsSinceEpoch(
          row['created_us'] as int,
          isUtc: true,
        ),
      );

  static String? _optional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
