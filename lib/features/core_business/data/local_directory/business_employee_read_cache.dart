part of 'directory_database.dart';

/// The employee receives a view, never a BusinessLedgerAccess. This database
/// lives under a separate root and is not included in a merchant's archive.
final class BusinessEmployeeReadCache {
  BusinessEmployeeReadCache(this._root, this._keys);

  final Future<Directory> Function() _root;
  final DirectoryKeyStore _keys;
  final _lock = Lock();
  DirectoryDatabase? _db;
  static const _table = 'employee_read_copy';

  Future<void> close() => _lock.synchronized(() async {
    await _db?.close();
    _db = null;
  });

  Future<DirectoryDatabase?> _open(
    DirectoryWorkspace workspace, {
    required bool create,
  }) async {
    if (_db?.workspace.storageId == workspace.storageId) return _db;
    final root = await _root();
    if (!create &&
        !await File(DirectoryDatabase.filePath(root, workspace)).exists()) {
      return null;
    }
    await _db?.close();
    _db = null;
    return _db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: _keys,
    );
  }

  Future<bool> _created(DatabaseExecutor db) async => (await db.query(
    'sqlite_master',
    columns: ['name'],
    where: "type = 'table' AND name = ?",
    whereArgs: [_table],
  )).isNotEmpty;

  Future<Map<String, dynamic>?> read(
    DirectoryWorkspace workspace,
    String branch,
  ) => _lock.synchronized(() async {
    final db = await _open(workspace, create: false);
    return db?._read((reader) async {
      if (!await _created(reader)) return null;
      final rows = await reader.query(
        _table,
        where: 'branch_id = ?',
        whereArgs: [branch],
      );
      final raw = rows.singleOrNull?['payload'] as String?;
      return raw == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    });
  });

  /// Profile, rows and their authorization take effect in one durable commit.
  /// An identical retry does not add records or expose partly applied data.
  Future<bool> replace(
    DirectoryWorkspace workspace,
    String branch,
    Map<String, dynamic>? data, {
    required bool Function() current,
  }) => _lock.synchronized(() async {
    if (!current()) throw const DirectoryAccessDenied();
    final db = await _open(workspace, create: data != null);
    if (db == null) return false;
    return db._transaction((txn) async {
      if (!current()) throw const DirectoryAccessDenied();
      final bool changed;
      if (data == null) {
        changed =
            await _created(txn) &&
            await txn.delete(
                  _table,
                  where: 'branch_id = ?',
                  whereArgs: [branch],
                ) >
                0;
      } else {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS $_table (
            branch_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
          )
        ''');
        final rows = await txn.query(
          _table,
          where: 'branch_id = ?',
          whereArgs: [branch],
        );
        final payload = jsonEncode(data);
        changed = rows.singleOrNull?['payload'] != payload;
        if (changed) {
          await txn.insert(_table, {
            'branch_id': branch,
            'payload': payload,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (!current()) throw const DirectoryAccessDenied();
      return changed;
    }, exclusive: true);
  });
}
