part of 'directory_database.dart';

/// Employee records of the business live on the devices (name, salary,
/// permissions, branches) and travel through the relay like every other
/// Business row. The server only learns what account linking and access
/// control need (identity + permissions), and only when online.
const _employeesTable = 'business_employees';

Future<void> _createBusinessEmployees(DatabaseExecutor db) => db.execute('''
  CREATE TABLE IF NOT EXISTS $_employeesTable (
    id TEXT PRIMARY KEY NOT NULL,
    branch_id TEXT NOT NULL,
    full_name TEXT NOT NULL,
    employee_code TEXT,
    phone TEXT,
    email TEXT,
    salary TEXT NOT NULL DEFAULT '0',
    salary_currency TEXT NOT NULL DEFAULT 'SAR',
    photo_url TEXT,
    notes TEXT,
    permissions TEXT NOT NULL DEFAULT '{}',
    branch_ids TEXT,
    linked_user_id TEXT,
    user_name TEXT,
    user_code TEXT,
    server_state TEXT NOT NULL DEFAULT 'new'
      CHECK (server_state IN ('new', 'dirty', 'synced')),
    created_us INTEGER NOT NULL,
    deleted_us INTEGER
  )
''');

extension BusinessEmployeesLocal on DirectoryDatabase {
  void _requireOwnerWorkspace(DirectoryAccess access) {
    if (access.workspace.storageId != workspace.storageId || access.member) {
      throw const DirectoryAccessDenied();
    }
  }

  static Map<String, Object?> _shape(Map<String, Object?> row) {
    Object? json(Object? text) {
      if (text is! String) return null;
      try {
        return jsonDecode(text);
      } catch (_) {
        return null;
      }
    }

    final linked = row['linked_user_id'] as String?;
    return {
      'id': row['id'],
      'full_name': row['full_name'],
      'employee_code': row['employee_code'],
      'email': row['email'],
      'phone': row['phone'],
      'salary': double.tryParse('${row['salary']}') ?? 0,
      'salary_currency': row['salary_currency'],
      'photo_url': row['photo_url'],
      'status': linked == null ? 'unlinked' : 'linked',
      'linked_user_id': linked,
      'permissions': json(row['permissions']) ?? const {},
      'branch_ids': json(row['branch_ids']) ?? [row['branch_id']],
      'notes': row['notes'],
      'created_at': DateTime.fromMicrosecondsSinceEpoch(
        row['created_us'] as int,
        isUtc: true,
      ).toIso8601String(),
      'online': false,
      'user_name': row['user_name'],
      'user_code': row['user_code'],
      'user_avatar': null,
    };
  }

  /// The employees working in [access]'s branch, newest first.
  Future<List<Map<String, Object?>>> localEmployees(DirectoryAccess access) {
    _requireOwnerWorkspace(access);
    return _read((db) async {
      final rows = await db.query(
        _employeesTable,
        where: 'deleted_us IS NULL',
        orderBy: 'created_us DESC, id',
      );
      return [
        for (final row in rows)
          if ((_shape(row)['branch_ids'] as List).contains(access.branchId))
            _shape(row),
      ];
    });
  }

  Future<Map<String, Object?>?> localEmployee(DirectoryAccess access, String id) {
    _requireOwnerWorkspace(access);
    return _read((db) async {
      final row = (await db.query(
        _employeesTable,
        where: 'id = ? AND deleted_us IS NULL',
        whereArgs: [id],
      )).singleOrNull;
      return row == null ? null : _shape(row);
    });
  }

  static Map<String, Object?> _fields(Map<String, dynamic> body) => {
    if (body['full_name'] != null) 'full_name': '${body['full_name']}'.trim(),
    if (body.containsKey('employee_code')) 'employee_code': body['employee_code'],
    if (body.containsKey('phone')) 'phone': body['phone'],
    if (body['salary'] != null) 'salary': '${body['salary']}',
    if (body['salary_currency'] != null) 'salary_currency': body['salary_currency'],
    if (body.containsKey('notes')) 'notes': body['notes'],
    if (body['permissions'] is Map) 'permissions': jsonEncode(body['permissions']),
    if (body['branch_ids'] is List)
      'branch_ids': jsonEncode([for (final b in body['branch_ids'] as List) '$b']),
  };

  Future<Map<String, Object?>> createLocalEmployee(
    DirectoryAccess access,
    Map<String, dynamic> body,
  ) async {
    _requireOwnerWorkspace(access);
    final name = '${body['full_name'] ?? ''}'.trim();
    if (name.runes.length < 2) throw const FormatException('full_name');
    final id = '${body['id'] ?? const Uuid().v4()}';
    await _transaction((txn) async {
      await txn.insert(_employeesTable, {
        'id': id,
        'branch_id': access.branchId,
        ..._fields(body),
        'full_name': name,
        'server_state': 'new',
        'created_us': DateTime.now().toUtc().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
    return (await localEmployee(access, id))!;
  }

  Future<Map<String, Object?>> updateLocalEmployee(
    DirectoryAccess access,
    String id,
    Map<String, dynamic> body,
  ) async {
    _requireOwnerWorkspace(access);
    final changes = _fields(body);
    await _transaction((txn) async {
      if (changes.isNotEmpty) {
        await txn.update(_employeesTable, changes, where: 'id = ?', whereArgs: [id]);
      }
      await txn.rawUpdate(
        "UPDATE $_employeesTable SET server_state = 'dirty' WHERE id = ? AND server_state = 'synced'",
        [id],
      );
    });
    final row = await localEmployee(access, id);
    if (row == null) throw const DirectoryAccessDenied();
    return row;
  }

  Future<void> deleteLocalEmployee(DirectoryAccess access, String id) async {
    _requireOwnerWorkspace(access);
    await _transaction(
      (txn) => txn.rawUpdate(
        "UPDATE $_employeesTable SET deleted_us = ?, server_state = CASE server_state WHEN 'new' THEN 'new' ELSE 'dirty' END WHERE id = ?",
        [DateTime.now().toUtc().microsecondsSinceEpoch, id],
      ),
    );
  }

  /// Records the server needs to learn (identity/permissions for linking and
  /// access), oldest first.
  Future<List<Map<String, Object?>>> employeesForServer(DirectoryAccess access) {
    _requireOwnerWorkspace(access);
    return _read(
      (db) => db.query(
        _employeesTable,
        where: "server_state != 'synced'",
        orderBy: 'created_us',
      ),
    );
  }

  /// The server knows this record now (and, when linked, who the account is).
  Future<void> markEmployeeServer(
    DirectoryAccess access,
    String id, {
    String? linkedUserId,
    String? userName,
    String? userCode,
    bool synced = true,
  }) async {
    _requireOwnerWorkspace(access);
    await _transaction(
      (txn) => txn.update(
        _employeesTable,
        {
          'server_state': synced ? 'synced' : 'dirty',
          if (linkedUserId != null) 'linked_user_id': linkedUserId,
          if (userName != null) 'user_name': userName,
          if (userCode != null) 'user_code': userCode,
        },
        where: 'id = ?',
        whereArgs: [id],
      ),
    );
  }

  /// On an employee's device: the permissions the owner last gave this
  /// account, as synced to the device (works offline). Null when unknown.
  Future<Map<String, bool>?> memberPermissions(
    DirectoryAccess access,
    String userId,
  ) {
    if (access.workspace.storageId != workspace.storageId) {
      throw const DirectoryAccessDenied();
    }
    return _read((db) async {
      final row = (await db.query(
        _employeesTable,
        columns: ['permissions'],
        where: 'linked_user_id = ? AND deleted_us IS NULL',
        whereArgs: [userId],
        orderBy: 'created_us DESC',
        limit: 1,
      )).singleOrNull;
      if (row == null) return null;
      try {
        final raw = jsonDecode(row['permissions'] as String) as Map;
        return {for (final e in raw.entries) '${e.key}': e.value == true};
      } catch (_) {
        return null;
      }
    });
  }
}

/// Resetting a branch (تصفير) clears that branch's own Business data on this
/// device; the deletions travel to the other devices like any other change.
/// Its settings and identity stay; other branches are never touched.
extension BusinessBranchReset on DirectoryDatabase {
  static const _kept = {
    'business_commerce_branches',
    'business_ledger_policy',
    'business_commerce_catalogue',
  };

  Future<int> resetBranchData(DirectoryAccess access, String branchId) async {
    _requireOwnerWorkspace(access);
    if (!isDirectoryId(branchId)) throw const DirectoryAccessDenied();
    var removed = 0;
    await _transaction((txn) async {
      await txn.execute('PRAGMA defer_foreign_keys = ON');
      for (final table in _syncTables.keys) {
        if (_kept.contains(table)) continue;
        final columns = await txn.rawQuery('PRAGMA table_info($table)');
        if (!columns.any((c) => c['name'] == 'branch_id')) continue;
        removed += await txn.delete(table, where: 'branch_id = ?', whereArgs: [branchId]);
      }
    });
    return removed;
  }
}
