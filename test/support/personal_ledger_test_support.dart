import 'dart:io';

import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';

/// Test-only stand-in for the platform vault (never used in the app).
final class MemoryPersonalLedgerKeys implements PersonalLedgerKeyStore {
  final memory = <String, String>{};
  bool failReads = false;

  @override
  Future<String?> read(String storageId) async {
    if (failReads) throw StateError('vault locked');
    return memory[storageId];
  }

  @override
  Future<void> write(String storageId, String key) async {
    memory[storageId] = key;
  }
}

final personalLedgerTestKeys = MemoryPersonalLedgerKeys();
Directory? _root;

/// Points the Personal ledger at a per-process temp folder with in-memory
/// keys, and lets tests that never sign in use one fixed test ledger.
void installPersonalLedgerForTests() {
  PersonalLedger.keys = personalLedgerTestKeys;
  PersonalLedger.root = () async =>
      _root ??= Directory.systemTemp.createTempSync('fyona-personal-ledger-');
  PersonalLedger.fallbackOwner = 'test-device';
}

/// The active test ledger (raw SQL access for assertions/seeding).
Future<PersonalLedgerDatabase> testLedger() => legacyLedger();

/// Empties every ledger (fresh state for the next test).
Future<void> resetPersonalLedger() => PersonalLedger.debugReset();

const _queueCols = [
  'id', 'operation_id', 'operation_type', 'table_name', 'entity_type',
  'entity_id', 'record_id', 'user_id', 'device_id', 'operation', 'data',
  'base_version', 'source', 'status', 'error_message', 'retry_count',
  'depends_on', 'occurred_at', 'next_attempt_at', 'created_at', 'updated_at',
  'op_revision', 'payload_hash', 'idempotency_key',
];
String _newValue(String c) => switch (c) {
  'status' => "COALESCE(NEW.status, 'pending')",
  'base_version' => 'COALESCE(NEW.base_version, 0)',
  'source' => "COALESCE(NEW.source, 'ui')",
  'retry_count' => 'COALESCE(NEW.retry_count, 0)',
  'attempts' => 'COALESCE(NEW.attempts, 0)',
  _ => 'NEW.$c',
};

const _logCols = [
  'id', 'operation_id', 'operation_type', 'entity_type', 'entity_id',
  'operation', 'status', 'device_id', 'user_id', 'occurred_at', 'created_at',
  'synced_at', 'retry_count', 'attempts', 'error_message', 'response_json',
];

/// The active ledger, with TEMP (connection-only, test-only) views under the
/// old plain-table names so existing assertions/seeds keep their SQL:
/// `personal_entity_cache` → `personal_rows`, `sync_queue` →
/// `personal_outbox`, `sync_operation_log` → `personal_outbox_log`.
Future<PersonalLedgerDatabase> legacyLedger() async {
  final db = await PersonalLedger.active();
  final have = await db.rawQuery(
    "SELECT 1 FROM sqlite_temp_master WHERE type = 'view' AND name = 'sync_queue'",
  );
  if (have.isNotEmpty) return db;
  const us = "CAST((julianday('now') - 2440587.5) * 86400000000 AS INTEGER)";
  final stmts = <String>[
    '''CREATE TEMP VIEW personal_entity_cache AS
       SELECT seq AS id, user_id, entity_type, id AS remote_id, data_json,
         strftime('%Y-%m-%dT%H:%M:%f', updated_us / 1000000.0, 'unixepoch') AS updated_at
       FROM main.personal_rows WHERE deleted = 0''',
    '''CREATE TEMP TRIGGER personal_entity_cache_ins INSTEAD OF INSERT ON personal_entity_cache
       BEGIN
         INSERT OR REPLACE INTO main.personal_rows (user_id, entity_type, id, data_json, updated_us, deleted, version)
         VALUES (NEW.user_id, NEW.entity_type, NEW.remote_id, NEW.data_json,
           COALESCE(CAST((julianday(NEW.updated_at) - 2440587.5) * 86400000000 AS INTEGER), $us), 0, 0);
       END''',
    '''CREATE TEMP TRIGGER personal_entity_cache_del INSTEAD OF DELETE ON personal_entity_cache
       BEGIN DELETE FROM main.personal_rows WHERE seq = OLD.id; END''',
    '''CREATE TEMP TRIGGER personal_entity_cache_upd INSTEAD OF UPDATE ON personal_entity_cache
       BEGIN
         UPDATE main.personal_rows SET user_id = NEW.user_id, entity_type = NEW.entity_type,
           id = NEW.remote_id, data_json = NEW.data_json,
           updated_us = COALESCE(CAST((julianday(NEW.updated_at) - 2440587.5) * 86400000000 AS INTEGER), $us)
         WHERE seq = OLD.id;
       END''',
    for (final (view, table, cols) in [
      ('sync_queue', 'personal_outbox', _queueCols),
      ('sync_operation_log', 'personal_outbox_log', _logCols),
    ]) ...[
      'CREATE TEMP VIEW $view AS SELECT * FROM main.$table',
      '''CREATE TEMP TRIGGER ${view}_ins INSTEAD OF INSERT ON $view
         BEGIN INSERT INTO main.$table (${cols.join(', ')})
           VALUES (${cols.map(_newValue).join(', ')}); END''',
      '''CREATE TEMP TRIGGER ${view}_del INSTEAD OF DELETE ON $view
         BEGIN DELETE FROM main.$table WHERE id = OLD.id; END''',
      '''CREATE TEMP TRIGGER ${view}_upd INSTEAD OF UPDATE ON $view
         BEGIN UPDATE main.$table SET ${cols.where((c) => c != 'id').map((c) => '$c = NEW.$c').join(', ')}
           WHERE id = OLD.id; END''',
    ],
  ];
  for (final s in stmts) {
    await db.rawExecutor.execute(s);
  }
  return db;
}
