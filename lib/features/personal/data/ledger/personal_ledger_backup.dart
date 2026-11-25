import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'personal_ledger.dart';

/// Keeps the local backup archive format unchanged while its Personal tables
/// live in the encrypted ledger: the mirror is exported/imported in the old
/// `personal_entity_cache` row shape, the other tables have their old names
/// and columns already.
final class PersonalLedgerBackup {
  PersonalLedgerBackup._();

  static const mirrorTable = 'personal_entity_cache';

  /// Snapshot tables whose rows live in the ledger.
  static bool isLedgerTable(String table) =>
      table == mirrorTable || PersonalLedgerDatabase.legacyTables.contains(table);

  /// Rows of [table] from the active user's ledger, in the archive shape.
  static Future<List<Map<String, dynamic>>> exportTable(String table) async {
    final db = await PersonalLedger.active();
    if (table != mirrorTable) {
      return (await db.query(table))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }
    final rows = await db.rawQuery(
      'SELECT seq, user_id, entity_type, id, data_json, updated_us '
      'FROM ${PersonalLedgerDatabase.rows} WHERE deleted = 0 ORDER BY seq ASC',
    );
    return [
      for (final r in rows)
        {
          'id': r['seq'],
          'user_id': r['user_id'],
          'entity_type': r['entity_type'],
          'remote_id': r['id'],
          'data_json': r['data_json'],
          'updated_at': DateTime.fromMicrosecondsSinceEpoch(
            (r['updated_us'] as num).toInt(),
          ).toIso8601String(),
        },
    ];
  }

  /// Upserts one archive mirror row (by user/type/remote id) inside a ledger
  /// transaction.
  static Future<void> upsertMirrorRow(
    Transaction tx, {
    required int userId,
    required String entityType,
    required String remoteId,
    required String dataJson,
  }) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    final updated = await tx.update(
      PersonalLedgerDatabase.rows,
      {'data_json': dataJson, 'updated_us': now, 'deleted': 0},
      where: 'user_id = ? AND entity_type = ? AND id = ?',
      whereArgs: [userId, entityType, remoteId],
    );
    if (updated == 0) {
      await tx.insert(PersonalLedgerDatabase.rows, {
        'user_id': userId,
        'entity_type': entityType,
        'id': remoteId,
        'data_json': dataJson,
        'updated_us': now,
        'deleted': 0,
      });
    }
  }

  static Future<void> deleteMirrorRow(
    Transaction tx, {
    required int userId,
    required String entityType,
    required String remoteId,
  }) => tx.delete(
    PersonalLedgerDatabase.rows,
    where: 'user_id = ? AND entity_type = ? AND id = ?',
    whereArgs: [userId, entityType, remoteId],
  );
}
