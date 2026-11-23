import 'dart:core';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'tables.dart';

class DatabaseHelper {
  static Database? _database;
  static const int _dbVersion = 16;
  static const String _dbName = 'fyona_erp.db';
  static VoidCallback? onDataChanged;

  /// Test hook: when set, the database lives at this exact path (integration
  /// tests give every "virtual device" its own file). Never set in production.
  @visibleForTesting
  static String? debugDatabasePath;

  static int get databaseVersion => _dbVersion;

  static void _notifyDataChanged() => onDataChanged?.call();

  static Future<Database> get database async {
    if (kIsWeb) throw UnsupportedError('Local database not available on web');
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = debugDatabasePath ?? join(await getDatabasesPath(), _dbName);
    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    for (final table in Tables.allTables) {
      await db.execute(table);
    }
    for (final index in Tables.indexes) {
      await db.execute(index);
    }
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final personalTables = [
        'personal_exchange_rates',
        'personal_debts',
        'personal_bank_transactions',
        'personal_bank_accounts',
        'spending_categories',
        'savings_goals',
        'personal_transactions',
        'personal_wallets',
      ];
      for (final table in personalTables) {
        await db.execute('DROP TABLE IF EXISTS $table');
      }
      await db.execute(Tables.personalWallets);
      await db.execute(Tables.personalTransactions);
      await db.execute(Tables.savingsGoals);
      await db.execute(Tables.spendingCategories);
      await db.execute(Tables.personalBankAccounts);
      await db.execute(Tables.personalBankTransactions);
      await db.execute(Tables.personalDebts);
      await db.execute(Tables.personalExchangeRates);
    }
    if (oldVersion < 3) {
      try {
        await db.execute("ALTER TABLE personal_transactions ADD COLUMN currency TEXT NOT NULL DEFAULT 'SAR'");
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute("ALTER TABLE personal_debts ADD COLUMN paid REAL DEFAULT 0.0");
      } catch (_) {}
      try {
        await db.execute("ALTER TABLE personal_debts ADD COLUMN status TEXT DEFAULT 'active'");
      } catch (_) {}
      try {
        await db.execute("ALTER TABLE personal_debts ADD COLUMN reminder INTEGER DEFAULT 0");
      } catch (_) {}
      await db.execute(Tables.personalDebtPayments);
    }
    if (oldVersion < 6) {
      final columns = await db.rawQuery("PRAGMA table_info('personal_bank_accounts')");
      final hasAccountType = columns.any((c) => c['name'] == 'account_type');
      if (!hasAccountType) {
        await db.execute("ALTER TABLE personal_bank_accounts ADD COLUMN account_type TEXT DEFAULT 'checking'");
      }
    }
    if (oldVersion < 7) {
      await db.execute(Tables.syncQueue);
      await db.execute(Tables.syncLog);
      await db.execute(Tables.syncMetadata);
    }
    if (oldVersion < 8) {
      // Add personal tables that were added to allTables without a migration step.
      // Using CREATE TABLE IF NOT EXISTS so it's safe even if already present.
      await db.execute(Tables.personalBudgets);
      await db.execute(Tables.personalRecurringTransactions);
    }
    if (oldVersion < 9) {
      // Offline-first personal finance: mirrors server rows so the module keeps
      // working when the server is unreachable, and lets sync push/pull hydrate.
      await db.execute(Tables.personalEntityCache);
    }
    if (oldVersion < 10) {
      // Offline-first multi-device: upgrade the sync_queue into a real Outbox
      // with globally-unique operation ids (idempotency), entity identifiers,
      // user/device ownership and a base_version for conflict resolution.
      // Each ADD COLUMN is guarded via PRAGMA so an existing (partial) upgrade
      // never errors out and no data is ever dropped.
      final queueCols = await db.rawQuery("PRAGMA table_info('sync_queue')");
      final hasCol = (String name) => queueCols.any((c) => c['name'] == name);

      if (!hasCol('operation_id')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN operation_id TEXT");
        try {
          await db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_opid ON sync_queue(operation_id) WHERE operation_id IS NOT NULL AND operation_id != ''",
          );
        } catch (_) {
          // Fallback for older SQLite without partial index support
          try {
            await db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_opid ON sync_queue(operation_id)");
          } catch (_) {}
        }
      }
      if (!hasCol('entity_type')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN entity_type TEXT");
      }
      if (!hasCol('entity_id')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN entity_id TEXT");
      }
      if (!hasCol('user_id')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN user_id INTEGER");
      }
      if (!hasCol('device_id')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN device_id TEXT");
      }
      if (!hasCol('base_version')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN base_version INTEGER DEFAULT 0");
      }
      if (!hasCol('source')) {
        await db.execute("ALTER TABLE sync_queue ADD COLUMN source TEXT DEFAULT 'ui'");
      }

      // Backfill operation ids for rows created before this migration so every
      // existing pending operation becomes idempotent-safe going forward.
      final rowsNoOp = await db.rawQuery(
        "SELECT id FROM sync_queue WHERE operation_id IS NULL OR operation_id = ''",
      );
      for (final r in rowsNoOp) {
        await db.rawUpdate(
          "UPDATE sync_queue SET operation_id = ? WHERE id = ?",
          ['op_${DateTime.now().microsecondsSinceEpoch}_${r['id']}', r['id']],
        );
      }
      // entity_id mirrors the old record_id for migration-era rows.
      await db.execute(
        "UPDATE sync_queue SET entity_id = CAST(record_id AS TEXT) WHERE entity_id IS NULL AND record_id IS NOT NULL",
      );

      await db.execute(Tables.syncCursor);
      await db.execute(Tables.syncDeviceInfo);

      // Drop legacy metadata rows; the new per-type cursor replaces them.
      try {
        await db.execute("DELETE FROM sync_metadata");
      } catch (_) {}
    }
    if (oldVersion < 11) {
      // Stable user-id mapping: guarantees offline data keyed by the same
      // real user always reads/writes under the SAME local integer namespace
      // (String.hashCode is not guaranteed stable across app runs).
      await db.execute(Tables.stableUserIdMap);
    }
    if (oldVersion < 12) {
      // Repair malformed offline entity ids: the old timestamp-based generator
      // emitted 35-hex-char strings instead of valid UUIDs. The server parses
      // every entity id as UUID, so those rows could never sync and could
      // never be updated/deleted online (HTTP 422) while the local mirror
      // kept showing them. Remap each one to a fresh UUID v4 across the
      // mirror + outbox (including embedded JSON references).
      await _sanitizeMalformedEntityIds(db);
    }
    if (oldVersion < 13) {
      await _upgradeToOperationJournal(db);
    }
    if (oldVersion < 14) {
      await db.execute(Tables.budgetCategories);
    }
    if (oldVersion < 15) {
      // v15 — additive sync-integrity metadata on the outbox. Nullable
      // columns only; legacy rows read back with nulls and replay exactly
      // as before (shadow verification skips them). PRAGMA-guarded so
      // partial upgrades never error.
      final queueCols = await db.rawQuery("PRAGMA table_info('sync_queue')");
      final hasCol = (String name) => queueCols.any((c) => c['name'] == name);
      if (!hasCol('op_revision')) {
        await db.execute('ALTER TABLE sync_queue ADD COLUMN op_revision INTEGER');
      }
      if (!hasCol('payload_hash')) {
        await db.execute('ALTER TABLE sync_queue ADD COLUMN payload_hash TEXT');
      }
      if (!hasCol('idempotency_key')) {
        await db.execute('ALTER TABLE sync_queue ADD COLUMN idempotency_key TEXT');
      }
    }
    if (oldVersion < 16) {
      const retiredTypes = [
        'customer', 'supplier', 'product', 'category', 'inventory_movement',
        'invoice', 'payment', 'sales_order', 'sales_return', 'sales_quote',
        'delivery_note', 'purchase_order', 'purchase_receipt', 'purchase_return',
        'supplier_bill', 'account', 'journal_entry', 'employee', 'department',
        'position', 'attendance', 'leave', 'payroll',
      ];
      final placeholders = List.filled(retiredTypes.length, '?').join(',');
      for (final table in ['personal_entity_cache', 'sync_queue', 'sync_operation_log']) {
        // A partial older copy may lack one of them: nothing to clean there.
        final exists = await db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table]);
        if (exists.isEmpty) continue;
        await db.delete(table,
          where: 'entity_type IN ($placeholders)', whereArgs: retiredTypes);
      }
      for (final table in const [
        'bank_transactions', 'cash_boxes', 'cheques',
        'contracts', 'custom_fields', 'debt_payments',
        'discount_types', 'expenses', 'fiscal_years',
        'fixed_assets', 'inventory_transactions', 'journal_entry_lines',
        'leaves', 'number_series', 'payment_terms',
        'payment_transactions', 'payments', 'payrolls',
        'price_levels', 'product_variants', 'purchase_invoice_lines',
        'recurring_invoice_templates', 'sales_invoice_lines', 'tax_types',
        'accounts', 'bank_accounts', 'debts',
        'employees', 'journal_entries', 'products',
        'purchase_invoices', 'sales_invoices', 'customers',
        'product_categories', 'suppliers',
      ]) {
        await db.execute('DROP TABLE IF EXISTS $table');
      }
    }
  }

  /// v13 — Local-First Operation Journal.
  ///
  /// Rebuilds `sync_queue` with the semantic columns required for exact,
  /// operation-based replay (operation_type, immutable occurred_at, dependency
  /// metadata, retry schedule) and removes the old restrictive CHECK
  /// constraints. Existing rows are preserved and upgraded in place. Also
  /// creates `sync_operation_log`, the immutable local archive of every
  /// confirmed/failed operation (audit + traceability).
  static Future<void> _upgradeToOperationJournal(Database db) async {
    try {
      final info = await db.rawQuery("PRAGMA table_info('sync_queue')");
      final hasCol = (String n) => info.any((c) => c['name'] == n);
      final needsRebuild = !hasCol('operation_type') ||
          !hasCol('occurred_at') ||
          !hasCol('depends_on') ||
          !hasCol('next_attempt_at');
      if (needsRebuild) {
        await db.execute('ALTER TABLE sync_queue RENAME TO sync_queue_v12');
        await db.execute(Tables.syncQueue);
        await db.execute('''
          INSERT INTO sync_queue (
            id, operation_id, operation_type, table_name, entity_type,
            entity_id, record_id, user_id, device_id, operation, data,
            base_version, source, status, error_message, retry_count,
            occurred_at, created_at, updated_at
          )
          SELECT
            id, operation_id,
            CASE operation
              WHEN 'INSERT' THEN 'ENTITY_CREATE'
              WHEN 'DELETE' THEN 'ENTITY_DELETE'
              ELSE 'ENTITY_UPDATE'
            END,
            table_name, entity_type, entity_id, record_id, user_id, device_id,
            operation, data, base_version, source,
            CASE WHEN status = 'in_progress' THEN 'pending'
                 WHEN status = 'completed' THEN 'pending'
                 ELSE status END,
            error_message, retry_count,
            COALESCE(created_at, updated_at), created_at, updated_at
          FROM sync_queue_v12
        ''');
        await db.execute('DROP TABLE sync_queue_v12');
      }
    } catch (_) {
      // Recovery: a failed rebuild must never leave the outbox missing. If
      // the renamed backup survived, restore it and add the new columns in
      // place (SQLite supports nullable ADD COLUMN).
      try {
        final tables = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'");
        final names =
            tables.map((t) => t['name']?.toString() ?? '').toSet();
        if (!names.contains('sync_queue') &&
            names.contains('sync_queue_v12')) {
          await db.execute('ALTER TABLE sync_queue_v12 RENAME TO sync_queue');
        }
        final info = await db.rawQuery("PRAGMA table_info('sync_queue')");
        final hasCol = (String n) => info.any((c) => c['name'] == n);
        for (final col in const [
          'operation_id',
          'operation_type',
          'entity_type',
          'entity_id',
          'user_id',
          'device_id',
          'base_version',
          'source',
          'retry_count',
          'depends_on',
          'occurred_at',
          'next_attempt_at',
        ]) {
          if (!hasCol(col)) {
            final type = col == 'base_version' || col == 'retry_count'
                ? 'INTEGER DEFAULT 0'
                : 'TEXT';
            try {
              await db.execute(
                  'ALTER TABLE sync_queue ADD COLUMN $col $type');
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    await db.execute(Tables.syncOperationLog);
    for (final index in const [
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_entity ON sync_queue(entity_type, entity_id)',
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_user ON sync_queue(user_id, status)',
      'CREATE INDEX IF NOT EXISTS idx_sync_oplog_entity ON sync_operation_log(entity_type, entity_id)',
      'CREATE INDEX IF NOT EXISTS idx_sync_oplog_created ON sync_operation_log(created_at)',
    ]) {
      try {
        await db.execute(index);
      } catch (_) {}
    }
  }

  /// Public entry for tests: runs the v12 id repair against the open database.
  static Future<void> sanitizeMalformedEntityIds() async {
    final db = await database;
    await _sanitizeMalformedEntityIds(db);
  }

  static bool _isMalformedEntityId(String id) {
    final hex = id.replaceAll('-', '');
    if (hex.length != 32) return true;
    return RegExp(r'[^0-9a-fA-F]').hasMatch(hex);
  }

  static String _freshUuidV4() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40; // version 4
    b[8] = (b[8] & 0x3F) | 0x80; // variant 10
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  static Future<void> _sanitizeMalformedEntityIds(Database db) async {
    final mapping = <String, String>{};
    Future<void> collect(String table, String idCol) async {
      List<Map<String, dynamic>> rows;
      try {
        rows = await db.rawQuery(
          "SELECT DISTINCT $idCol AS rid FROM $table "
          "WHERE entity_type LIKE 'personal%' "
          "AND $idCol IS NOT NULL AND $idCol != ''",
        );
      } catch (_) {
        return;
      }
      for (final r in rows) {
        final id = r['rid']?.toString() ?? '';
        if (id.isNotEmpty &&
            _isMalformedEntityId(id) &&
            !mapping.containsKey(id)) {
          mapping[id] = _freshUuidV4();
        }
      }
    }

    try {
      await collect('personal_entity_cache', 'remote_id');
      await collect('sync_queue', 'entity_id');
    } catch (_) {
      return;
    }
    for (final e in mapping.entries) {
      try {
        await db.rawUpdate(
          'UPDATE personal_entity_cache SET remote_id = ? WHERE remote_id = ?',
          [e.value, e.key],
        );
      } catch (_) {}
      try {
        await db.rawUpdate(
          'UPDATE sync_queue SET entity_id = ? WHERE entity_id = ?',
          [e.value, e.key],
        );
      } catch (_) {}
    }
    // Sweep embedded references (e.g. bank_account_id/goal_id inside tx rows):
    // every mapping pair is applied to EVERY personal row, because a row
    // carries other entities' ids besides its own. Quoted-string replace is
    // safe — ids only occur as complete JSON string values — and a no-op
    // where the pattern is absent.
    for (final e in mapping.entries) {
      final oldQ = '"${e.key}"';
      final newQ = '"${e.value}"';
      try {
        await db.rawUpdate(
          "UPDATE personal_entity_cache SET data_json = REPLACE(data_json, ?, ?) "
          "WHERE entity_type LIKE 'personal%'",
          [oldQ, newQ],
        );
      } catch (_) {}
      try {
        await db.rawUpdate(
          "UPDATE sync_queue SET data = REPLACE(data, ?, ?) "
          "WHERE entity_type LIKE 'personal%'",
          [oldQ, newQ],
        );
      } catch (_) {}
    }
  }

  static Future<int> insert(String table, Map<String, dynamic> data) async {
    final db = await database;
    final result = await db.insert(table, data);
    _notifyDataChanged();
    return result;
  }

  static Future<List<Map<String, dynamic>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    return await db.query(
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
  }

  static Future<int> update(
    String table,
    Map<String, dynamic> data,
    String where,
    List<dynamic> whereArgs,
  ) async {
    final db = await database;
    final result = await db.update(table, data, where: where, whereArgs: whereArgs);
    if (result > 0) _notifyDataChanged();
    return result;
  }

  static Future<int> delete(
    String table,
    String where,
    List<dynamic> whereArgs,
  ) async {
    final db = await database;
    final result = await db.delete(table, where: where, whereArgs: whereArgs);
    if (result > 0) _notifyDataChanged();
    return result;
  }

  static Future<int> rawInsert(String sql, [List<dynamic>? args]) async {
    final db = await database;
    final result = await db.rawInsert(sql, args);
    _notifyDataChanged();
    return result;
  }

  static Future<List<Map<String, dynamic>>> rawQuery(String sql, [List<dynamic>? args]) async {
    final db = await database;
    return await db.rawQuery(sql, args);
  }

  static Future<int> rawUpdate(String sql, [List<dynamic>? args]) async {
    final db = await database;
    final result = await db.rawUpdate(sql, args);
    if (result > 0) _notifyDataChanged();
    return result;
  }

  static Future<int> rawDelete(String sql, [List<dynamic>? args]) async {
    final db = await database;
    final result = await db.rawDelete(sql, args);
    if (result > 0) _notifyDataChanged();
    return result;
  }

  static Future<T> transaction<T>(Future<T> Function(Transaction tx) fn) async {
    final db = await database;
    final result = await db.transaction(fn);
    _notifyDataChanged();
    return result;
  }

  static Future<void> close() async {
    final db = await database;
    db.close();
    _database = null;
  }
}
