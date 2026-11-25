import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:synchronized/synchronized.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/tables.dart';

/// Where the per-user Personal ledger keys live (the platform vault in the
/// app; an in-memory/file fixture in tests). Same contract as the Business
/// [DirectoryKeyStore]: a missing key for an existing file is never a reason
/// to start over.
abstract interface class PersonalLedgerKeyStore {
  Future<String?> read(String storageId);
  Future<void> write(String storageId, String key);
}

/// The encrypted Personal ledger cannot be opened (no SQLCipher in the build,
/// key missing for an existing file, vault unavailable, wrong key, no active
/// user, or the one-time move from the old plain storage did not verify).
///
/// Fail closed: Personal reads/writes throw this instead of ever falling back
/// to a plaintext store.
final class PersonalLedgerUnavailable implements Exception {
  const PersonalLedgerUnavailable(this.reason, [this.cause]);

  final String reason;
  final Object? cause;

  @override
  String toString() => 'PersonalLedgerUnavailable($reason)';
}

/// The per-user, SQLCipher-encrypted Personal store. Holds every Personal row
/// the device keeps: the entity mirror (`personal_rows`), the outbox
/// (`personal_outbox` + its archive), exchange rates, the older per-table
/// Personal tables, and key/value user data (trees, account types).
///
/// Opened with the same plugin, key handling and fail-closed checks as the
/// Business [DirectoryDatabase]. Never talks to the network.
final class PersonalLedgerDatabase {
  PersonalLedgerDatabase._(this.owner, this.storageId, this.path, this._db);

  static const schemaVersion = 1;
  static final _opening = Lock();
  static final _factory = createDatabaseFactoryFfi();

  static const rows = 'personal_rows';
  static const outbox = 'personal_outbox';
  static const outboxLog = 'personal_outbox_log';
  static const kv = 'personal_kv';
  static const meta = 'personal_meta';
  static const conflicts = 'personal_migration_conflicts';
  static const syncLog = 'personal_sync_log';
  static const syncState = 'personal_sync_state';

  /// Older per-table Personal tables (same names/columns as the plain DB so
  /// [PersonalRepository] and backup/restore keep their SQL).
  static const legacyTables = [
    'personal_wallets',
    'personal_transactions',
    'savings_goals',
    'spending_categories',
    'personal_bank_accounts',
    'personal_bank_transactions',
    'personal_debts',
    'personal_debt_payments',
    'personal_exchange_rates',
    'personal_recurring_transactions',
    'personal_budgets',
    'budget_categories',
  ];

  /// Identity this file belongs to (the server user id; a fixed label in
  /// tests). Never stored in clear: the file name is a digest of it.
  final String owner;
  final String storageId;
  final String path;
  final Database _db;
  bool _closed = false;

  bool get isClosed => _closed;

  static String storageIdFor(String owner) => sha256
      .convert(utf8.encode('fyona-personal-ledger:v1:$owner'))
      .toString()
      .substring(0, 40);

  static String filePath(Directory root, String owner) =>
      p.join(root.path, '${storageIdFor(owner)}.sqlite');

  static Future<PersonalLedgerDatabase> open({
    required Directory root,
    required String owner,
    required PersonalLedgerKeyStore keys,
    DatabaseFactory? factory,
  }) => _opening.synchronized(() async {
    if (owner.isEmpty) throw const PersonalLedgerUnavailable('no_owner');
    final storageId = storageIdFor(owner);
    final path = p.normalize(p.absolute(filePath(root, owner)));
    String? key;
    try {
      key = await keys.read(storageId);
    } catch (e) {
      throw PersonalLedgerUnavailable('key_store', e);
    }
    if (key == null) {
      // A missing key is not a request to reset an existing ledger.
      if (await File(path).exists()) {
        throw const PersonalLedgerUnavailable('key_missing');
      }
      final random = Random.secure();
      key = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      try {
        await keys.write(storageId, key);
        // Read back: never create a file whose key did not persist.
        if (await keys.read(storageId) != key) {
          throw const PersonalLedgerUnavailable('key_store');
        }
      } on PersonalLedgerUnavailable {
        rethrow;
      } catch (e) {
        throw PersonalLedgerUnavailable('key_store', e);
      }
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const PersonalLedgerUnavailable('key_invalid');
    }
    final rawKey = key;
    await root.create(recursive: true);
    try {
      final db = await (factory ?? _factory).openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          singleInstance: false,
          onConfigure: (db) async {
            // Fail closed if the build does not contain the expected cipher.
            if ((await db.rawQuery('PRAGMA cipher_version')).isEmpty) {
              throw const PersonalLedgerUnavailable('no_cipher');
            }
            // SQLCipher requires a literal here. rawKey is exactly 64 hex.
            await db.execute('PRAGMA key = "x\'$rawKey\'"');
            await db.rawQuery('SELECT count(*) FROM sqlite_master');
            await db.execute('PRAGMA temp_store = MEMORY');
            await db.execute('PRAGMA busy_timeout = 3000');
            await db.rawQuery('PRAGMA journal_mode = DELETE');
            await db.execute('PRAGMA synchronous = FULL');
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, _) => _create(db),
          onDowngrade: (_, _, _) =>
              throw StateError('Unsupported personal ledger schema'),
          onUpgrade: (_, _, _) =>
              throw StateError('Missing personal ledger schema migration'),
        ),
      );
      return PersonalLedgerDatabase._(owner, storageId, path, db);
    } on PersonalLedgerUnavailable {
      rethrow;
    } catch (e) {
      // Wrong key / not a database / cipher refused: never touch the file.
      throw PersonalLedgerUnavailable('open_failed', e);
    }
  });

  static Future<void> _create(Database db) async {
    await db.execute('''
      CREATE TABLE $rows (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        entity_type TEXT NOT NULL,
        id TEXT NOT NULL,
        data_json TEXT NOT NULL,
        updated_us INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
        version INTEGER NOT NULL DEFAULT 0,
        UNIQUE (user_id, entity_type, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX personal_rows_by_type ON $rows (user_id, entity_type, seq)',
    );
    // Same columns and statuses as the old `sync_queue` outbox, so the
    // SyncEngine replay semantics are unchanged.
    await db.execute(
      Tables.syncQueue.replaceFirst('sync_queue', outbox),
    );
    await db.execute(
      Tables.syncOperationLog.replaceFirst('sync_operation_log', outboxLog),
    );
    for (final index in [
      'CREATE INDEX personal_outbox_status ON $outbox(status, created_at)',
      'CREATE INDEX personal_outbox_entity ON $outbox(entity_type, entity_id)',
      'CREATE INDEX personal_outbox_user ON $outbox(user_id, status)',
      'CREATE INDEX personal_outbox_log_entity ON $outboxLog(entity_type, entity_id)',
      'CREATE INDEX personal_outbox_log_created ON $outboxLog(created_at)',
    ]) {
      await db.execute(index);
    }
    await db.execute('''
      CREATE TABLE $kv (
        key TEXT PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('string', 'bool', 'int', 'double', 'string-list')),
        value TEXT NOT NULL,
        updated_us INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $conflicts (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL,
        row_key TEXT NOT NULL,
        row_json TEXT NOT NULL,
        noted_us INTEGER NOT NULL
      )
    ''');
    // Stage 3 (device relay) — created now, not used yet.
    await db.execute('''
      CREATE TABLE $syncLog (
        op_id TEXT PRIMARY KEY,
        seq INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $syncState (
        replica_id TEXT PRIMARY KEY,
        head INTEGER NOT NULL DEFAULT 0,
        resync INTEGER NOT NULL DEFAULT 0
      )
    ''');
    for (final ddl in const [
      Tables.personalWallets,
      Tables.personalTransactions,
      Tables.savingsGoals,
      Tables.spendingCategories,
      Tables.personalBankAccounts,
      Tables.personalBankTransactions,
      Tables.personalDebts,
      Tables.personalDebtPayments,
      Tables.personalExchangeRates,
      Tables.personalRecurringTransactions,
      Tables.personalBudgets,
      Tables.budgetCategories,
    ]) {
      await db.execute(ddl);
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_personal_tx_user_date ON personal_transactions(user_id, date)',
    );
  }

  static void _changed() {
    try {
      DatabaseHelper.onDataChanged?.call();
    } catch (_) {}
  }

  Database get _live {
    if (_closed) throw const PersonalLedgerUnavailable('closed');
    return _db;
  }

  /// Read access for helpers that take a [DatabaseExecutor].
  DatabaseExecutor get rawExecutor => _live;

  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) => _live.rawQuery(sql, args);

  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => _live.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  Future<int> rawInsert(String sql, [List<Object?>? args]) async {
    final result = await _live.rawInsert(sql, args);
    _changed();
    return result;
  }

  Future<int> rawUpdate(String sql, [List<Object?>? args]) async {
    final result = await _live.rawUpdate(sql, args);
    if (result > 0) _changed();
    return result;
  }

  Future<int> rawDelete(String sql, [List<Object?>? args]) async {
    final result = await _live.rawDelete(sql, args);
    if (result > 0) _changed();
    return result;
  }

  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final result = await _live.insert(
      table,
      values,
      conflictAlgorithm: conflictAlgorithm,
    );
    _changed();
    return result;
  }

  Future<int> update(
    String table,
    Map<String, Object?> values,
    String where,
    List<Object?> whereArgs,
  ) async {
    final result = await _live.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
    );
    if (result > 0) _changed();
    return result;
  }

  Future<int> delete(String table, String where, List<Object?> whereArgs) async {
    final result = await _live.delete(table, where: where, whereArgs: whereArgs);
    if (result > 0) _changed();
    return result;
  }

  Future<T> transaction<T>(Future<T> Function(Transaction tx) run) async {
    final result = await _live.transaction(run);
    _changed();
    return result;
  }

  Future<String?> readMeta(String key) async {
    final found = await rawQuery(
      'SELECT value FROM $meta WHERE key = ?',
      [key],
    );
    return found.isEmpty ? null : found.first['value'] as String?;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
  }
}
