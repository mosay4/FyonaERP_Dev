part of 'directory_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Business sync engine — local-first, the server is only a relay.
//
// Every Business write commits here first (unchanged texts, no waiting). TEMP
// triggers capture the row images of the write into one operation that waits
// in the outbox. The relay stamps operations with the organization's arrival
// sequence and carries them to the other devices, then deletes them.
//
// Every device applies the same operations in the same sequence order with the
// same rules, so all of them converge and take the same conflict decisions:
//
// * Counters (stock, lot quantities, balances, paid/remaining amounts) travel
//   as deltas: «sold 50» from another device is −50 here, never «now 0».
// * Other columns: the last writer by sequence wins.
// * Floors: a counter replayed in sequence order may not cross its floor
//   (stock below zero, cash below zero when not allowed, a debt paid twice).
//   The first operation that crosses it is cancelled, with everything built
//   on it, and its author gets a notice naming who was first.
// * Duplicates: the same bank/cash slot created on two devices — the one
//   sequenced first stays, the other is cancelled with everything built on it.
//
// See docs/BUSINESS_SYNC_ENGINE.md.
// ─────────────────────────────────────────────────────────────────────────────

const _syncOutbox = 'business_sync_outbox';
const _syncLog = 'business_sync_log';
const _syncChanges = 'business_sync_changes';
const _syncRows = 'business_sync_rows';
const _syncState = 'business_sync_state';
const _syncContext = 'business_sync_context';
const _syncNotices = 'business_sync_notices';
const _syncNever = 9223372036854775807;

/// Business tables that travel between devices, with the key that identifies
/// a row on every device. A local AUTOINCREMENT is never a shared identity.
const Map<String, List<String>> _syncTables = {
  'directory_parties': ['kind', 'id'],
  'business_deleted_directory_parties': ['branch_id', 'kind', 'party_id'],
  'business_debt_groups': ['id'],
  'business_ledger_commands': ['branch_id', 'id'],
  'business_ledger_policy': ['branch_id'],
  'business_local_accounts': ['branch_id', 'id'],
  'business_local_bank_legs': ['branch_id', 'command_id', 'account_id'],
  'business_bank_account_edits': ['branch_id', 'command_id', 'account_id'],
  'business_local_debts': ['branch_id', 'id'],
  'business_local_payment_parts': ['branch_id', 'command_id', 'invoice_id'],
  'business_opening_debt_edits': ['branch_id', 'command_id'],
  'business_imported_opening_payments': ['branch_id', 'id'],
  'business_reconciliations': ['branch_id', 'id'],
  'business_branch_transfers': ['branch_id', 'id'],
  'business_branch_transfer_lines': ['branch_id', 'transfer_id', 'item_index'],
  'business_commerce_branches': ['branch_id'],
  'business_commerce_catalogue': ['branch_id'],
  'business_commerce_categories': ['branch_id', 'id'],
  'business_commerce_category_links': ['branch_id', 'id'],
  'business_commerce_products': ['branch_id', 'id'],
  'business_commerce_units': ['branch_id', 'id'],
  'business_commerce_barcodes': ['branch_id', 'id'],
  'business_commerce_prices': ['branch_id', 'id'],
  'business_commerce_stock': ['branch_id', 'id'],
  'business_commerce_stock_movements': ['branch_id', 'id'],
  'business_commerce_lots': ['branch_id', 'id'],
  'business_commerce_lot_consumptions': ['branch_id', 'id'],
  'business_commerce_invoices': ['branch_id', 'id'],
  'business_commerce_invoice_lines': ['branch_id', 'id'],
  'business_commerce_invoice_edits': ['branch_id', 'id'],
  'business_commerce_invoice_payments': ['branch_id', 'id'],
  'business_commerce_party_balances': ['branch_id', 'id'],
  'business_commerce_returns': ['branch_id', 'id'],
  'business_commerce_return_lines': ['branch_id', 'id'],
  'business_employee_grants': ['branch_id', 'employee_id'],
  'business_employee_payroll': ['branch_id', 'command_id'],
  'business_employee_debts': ['branch_id', 'debt_id'],
  'business_employee_debt_legs': ['branch_id', 'command_id'],
  'business_employee_receipts': ['branch_id', 'command_id'],
  'business_employees': ['id'],
};

/// Counter columns: merged as deltas, so concurrent work adds up.
const Map<String, Set<String>> _syncCounters = {
  'business_local_accounts': {'balance_minor'},
  'business_local_debts': {'paid_minor'},
  'business_commerce_stock': {'quantity_milli'},
  'business_commerce_lots': {'remaining_micro'},
  'business_commerce_lot_consumptions': {'restored_micro'},
  'business_commerce_invoices': {'paid_minor', 'balance_minor'},
  'business_commerce_party_balances': {'paid_minor'},
  'business_employee_debts': {'remaining_minor'},
};

/// Why a device cancels one of two operations that cannot both hold.
enum BusinessSyncConflict {
  debtOverpaid,
  stockShort,
  balanceShort,
  duplicate,
  dependent,
  revoked,
}

/// A floor on a counter. [crossed] sees the row as it was after each operation.
typedef _SyncFloor = ({
  String table,
  String column,
  BusinessSyncConflict reason,
  Future<bool> Function(DatabaseExecutor db, Map<String, Object?> row) crossed,
});

final List<_SyncFloor> _syncFloors = [
  (
    table: 'business_commerce_stock',
    column: 'quantity_milli',
    reason: BusinessSyncConflict.stockShort,
    crossed: (_, row) async => _syncInt(row['quantity_milli']) < 0,
  ),
  (
    table: 'business_commerce_lots',
    column: 'remaining_micro',
    reason: BusinessSyncConflict.stockShort,
    crossed: (_, row) async => _syncInt(row['remaining_micro']) < 0,
  ),
  (
    table: 'business_local_accounts',
    column: 'balance_minor',
    reason: BusinessSyncConflict.balanceShort,
    crossed: (db, row) async =>
        _syncInt(row['balance_minor']) < 0 &&
        (await db.query(
              'business_ledger_policy',
              columns: ['allow_negative'],
              where: 'branch_id = ?',
              whereArgs: [row['branch_id']],
            )).singleOrNull?['allow_negative'] !=
            1,
  ),
  (
    table: 'business_local_debts',
    column: 'paid_minor',
    reason: BusinessSyncConflict.debtOverpaid,
    crossed: (_, row) async =>
        row['cancelled_us'] == null &&
        _syncInt(row['paid_minor']) > _syncInt(row['total_minor']),
  ),
  (
    table: 'business_commerce_invoices',
    column: 'balance_minor',
    reason: BusinessSyncConflict.debtOverpaid,
    crossed: (_, row) async => _syncInt(row['balance_minor']) < 0,
  ),
  (
    table: 'business_employee_debts',
    column: 'remaining_minor',
    reason: BusinessSyncConflict.debtOverpaid,
    crossed: (_, row) async => _syncInt(row['remaining_minor']) < 0,
  ),
];

/// One operation as stored/sent: the row changes of one local transaction.
typedef BusinessSyncOperation = ({
  String id,
  String? branchId,
  Map<String, Object?> payload,
});

/// A delivery from the relay.
typedef BusinessSyncDelivery = ({
  String id,
  int? seq,
  String kind,
  String? branchId,
  Map<String, Object?> payload,
});

/// A system notice for this device's user (e.g. an operation cancelled because
/// someone else did the same thing first).
typedef BusinessSyncNotice = ({
  String id,
  String opId,
  String kind,
  Map<String, Object?> details,
  int createdUs,
  bool read,
});

/// Fires after every local write that produced an operation, so it can leave
/// the device at once.
final businessSyncLocalWrites = StreamController<String>.broadcast(sync: false);

Future<void> _createBusinessSync(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncState (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncChanges (
      ord INTEGER PRIMARY KEY AUTOINCREMENT,
      op_id TEXT NOT NULL,
      tbl TEXT NOT NULL,
      pk TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('insert', 'update', 'delete')),
      old_row TEXT,
      new_row TEXT,
      delta TEXT
    )
  ''');
  final columns = {
    for (final c in await db.rawQuery('PRAGMA table_info($_syncChanges)')) c['name'],
  };
  if (!columns.contains('delta')) {
    await db.execute('ALTER TABLE $_syncChanges ADD COLUMN delta TEXT');
  }
  await db.execute(
    'CREATE INDEX IF NOT EXISTS business_sync_changes_op ON $_syncChanges (op_id, ord)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS business_sync_changes_row ON $_syncChanges (tbl, pk)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncOutbox (
      op_id TEXT PRIMARY KEY NOT NULL,
      branch_id TEXT,
      payload TEXT NOT NULL,
      created_us INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncLog (
      op_id TEXT PRIMARY KEY NOT NULL,
      seq INTEGER,
      branch_id TEXT,
      origin TEXT NOT NULL CHECK (origin IN ('local', 'remote', 'snapshot')),
      status TEXT NOT NULL CHECK (status IN ('applied', 'rejected')),
      author_replica TEXT,
      author_user TEXT,
      author_name TEXT,
      client_us INTEGER,
      applied_us INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS business_sync_log_seq ON $_syncLog (seq)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncRows (
      tbl TEXT NOT NULL,
      pk TEXT NOT NULL,
      last_seq INTEGER,
      pending_op TEXT,
      PRIMARY KEY (tbl, pk)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncNotices (
      id TEXT PRIMARY KEY NOT NULL,
      op_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      details TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      read INTEGER NOT NULL DEFAULT 0
    )
  ''');
}

/// Creates the capture triggers for this connection. They are TEMP triggers:
/// they live in memory with the connection (rebuilt from the live schema at
/// every open, so later columns are always captured), never touch the stored
/// schema, and the capture context they read is an in-memory table too — a
/// read-only transaction stays read-only and costs no disk sync.
Future<void> _installBusinessSyncTriggers(DatabaseExecutor db) async {
  await db.execute(
    'CREATE TEMP TABLE IF NOT EXISTS $_syncContext (op_id TEXT NOT NULL, mode TEXT NOT NULL)',
  );
  final batch = db.batch();
  for (final entry in _syncTables.entries) {
    final table = entry.key;
    final columns = await _syncColumns(db, table);
    if (columns.isEmpty) continue;
    String image(String side) => 'json_object(${[
          for (final c in columns) "'$c', $side.\"$c\"",
        ].join(', ')})';
    String key(String side) =>
        'json_array(${entry.value.map((c) => '$side."$c"').join(', ')})';
    const when =
        "WHEN (SELECT mode FROM temp.$_syncContext LIMIT 1) = 'local'";
    const op = '(SELECT op_id FROM temp.$_syncContext LIMIT 1)';
    for (final (name, event, kind, old, now) in [
      ('ai', 'INSERT', 'insert', null, 'NEW'),
      ('au', 'UPDATE', 'update', 'OLD', 'NEW'),
      ('ad', 'DELETE', 'delete', 'OLD', null),
    ]) {
      final trigger = 'business_sync_${name}_$table';
      batch.execute('DROP TRIGGER IF EXISTS temp."$trigger"');
      batch.execute('''
        CREATE TEMP TRIGGER "$trigger" AFTER $event ON main."$table" $when
        BEGIN
          INSERT INTO main.$_syncChanges (op_id, tbl, pk, kind, old_row, new_row)
          VALUES ($op, '$table', ${key(now ?? old!)}, '$kind',
            ${old == null ? 'NULL' : image(old)},
            ${now == null ? 'NULL' : image(now)});
        END
      ''');
    }
  }
  await batch.commit(noResult: true);
}

Future<List<String>> _syncColumns(DatabaseExecutor db, String table) async {
  final local = table == 'business_local_bank_legs' ? {'sequence'} : <String>{};
  return [
    for (final row in await db.rawQuery('PRAGMA table_info("$table")'))
      if (!local.contains(row['name'])) row['name'] as String,
  ];
}

extension BusinessSyncEngine on DirectoryDatabase {
  // ── identity ──────────────────────────────────────────────────────────────

  /// This database's stable replica id (one per install/workspace).
  Future<String> syncReplicaId() => _transactionRaw((txn) async {
    final existing = await _syncGet(txn, 'replica_id');
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await _syncPut(txn, 'replica_id', id);
    return id;
  });

  /// The owner reset the whole Business account: this copy is emptied —
  /// every record of every branch, what was waiting to leave and the sync
  /// history. The device stays itself (its replica id and author) and starts
  /// again from nothing. Personal data is in another database: untouched.
  Future<void> syncWipe() => _transactionRaw((txn) async {
        await txn.execute('PRAGMA defer_foreign_keys = ON');
        final tables = [
          for (final r in await txn.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'"))
            r['name'] as String,
        ];
        for (final t in tables) {
          if (t == _syncState) continue;
          await txn.delete(t);
        }
        await txn.delete(_syncState, where: "key NOT IN ('replica_id', 'author_user', 'author_name')");
      });

  /// Who appears as the author of the operations made on this device.
  Future<void> syncSetAuthor({required String userId, required String name}) =>
      _transactionRaw((txn) async {
        await _syncPut(txn, 'author_user', userId);
        await _syncPut(txn, 'author_name', name);
      });

  Future<int> syncConfirmedThrough() => _read(
    (db) async => int.tryParse(await _syncGet(db, 'confirmed_through') ?? '') ?? 0,
  );

  Future<bool> syncResyncPending() =>
      _read((db) async => await _syncGet(db, 'resync_pending') == '1');

  Future<void> syncMarkResync(bool pending) => _transactionRaw(
    (txn) => _syncPut(txn, 'resync_pending', pending ? '1' : '0'),
  );

  // ── capture (called by DirectoryDatabase._transaction) ────────────────────

  Future<void> _syncBegin(Transaction txn, String opId) async {
    await txn.execute('DELETE FROM temp.$_syncContext');
    await txn.execute(
      "INSERT INTO temp.$_syncContext (op_id, mode) VALUES (?, 'local')",
      [opId],
    );
  }

  /// Turns the captured changes of this transaction into one operation in the
  /// outbox, atomically with the write itself. Returns whether it made one.
  Future<bool> _syncSeal(Transaction txn, String opId) async {
    await txn.execute('DELETE FROM temp.$_syncContext');
    final changes = await txn.query(
      _syncChanges,
      where: 'op_id = ?',
      whereArgs: [opId],
      orderBy: 'ord',
    );
    if (changes.isEmpty) return false;
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final payload = <String, Object?>{
      'v': 2,
      'id': opId,
      'author_replica': await _syncGet(txn, 'replica_id'),
      'author_user': await _syncGet(txn, 'author_user'),
      'author_name': await _syncGet(txn, 'author_name'),
      'client_us': now,
      'changes': [for (final c in changes) _syncWire(c)],
    };
    final branch = _syncBranch(changes);
    await txn.insert(_syncOutbox, {
      'op_id': opId,
      'branch_id': branch,
      'payload': jsonEncode(payload),
      'created_us': now,
    });
    await txn.insert(_syncLog, {
      'op_id': opId,
      'seq': null,
      'branch_id': branch,
      'origin': 'local',
      'status': 'applied',
      'author_replica': payload['author_replica'],
      'author_user': payload['author_user'],
      'author_name': payload['author_name'],
      'client_us': now,
      'applied_us': now,
    });
    for (final c in changes) {
      // A change that only moved counters (a balance, a stock quantity) does
      // not make the row «ours»: another device may still rename it.
      if (!_syncTouchesOwnColumns(c)) continue;
      await txn.rawInsert(
        '''
        INSERT INTO $_syncRows (tbl, pk, last_seq, pending_op) VALUES (?, ?, NULL, ?)
        ON CONFLICT (tbl, pk) DO UPDATE SET pending_op = excluded.pending_op
        ''',
        [c['tbl'], c['pk'], opId],
      );
    }
    return true;
  }

  // ── outbox / push ─────────────────────────────────────────────────────────

  Future<List<BusinessSyncOperation>> syncOutbox({int limit = 100}) => _read(
    (db) async => [
      for (final row in await db.query(
        _syncOutbox,
        orderBy: 'created_us, op_id',
        limit: limit,
      ))
        (
          id: row['op_id'] as String,
          branchId: row['branch_id'] as String?,
          payload: Map<String, Object?>.from(
            jsonDecode(row['payload'] as String) as Map,
          ),
        ),
    ],
  );

  /// The relay accepted these operations with these sequence numbers.
  Future<void> syncPushed(Map<String, int> sequenced) =>
      _transactionRaw((txn) async {
        for (final MapEntry(key: op, value: seq) in sequenced.entries) {
          await txn.delete(_syncOutbox, where: 'op_id = ?', whereArgs: [op]);
          await txn.update(
            _syncLog,
            {'seq': seq},
            where: 'op_id = ? AND seq IS NULL',
            whereArgs: [op],
          );
          await txn.rawUpdate(
            '''
            UPDATE $_syncRows SET last_seq = MAX(COALESCE(last_seq, 0), ?),
              pending_op = NULL
            WHERE pending_op = ?
            ''',
            [seq, op],
          );
        }
      });

  // ── apply deliveries ──────────────────────────────────────────────────────

  /// Applies deliveries in sequence order. Returns the ids that are stored
  /// (to acknowledge). [drained]/[head] tell how far this device has now seen
  /// every operation addressed to it, so conflicts can be decided for good.
  Future<List<String>> syncApply(
    List<BusinessSyncDelivery> items, {
    required bool drained,
    required int head,
  }) async {
    final stored = <String>[];
    final ordered = [...items]
      ..sort((a, b) => (a.seq ?? _syncNever).compareTo(b.seq ?? _syncNever));
    var through = await syncConfirmedThrough();
    for (final item in ordered) {
      if (item.kind != 'ops') continue;
      await _transactionRaw((txn) => _syncApplyOne(txn, item), exclusive: true);
      stored.add(item.id);
      if (item.seq != null && item.seq! > through) through = item.seq!;
    }
    if (drained && head > through) through = head;
    await _transactionRaw((txn) async {
      await _syncPut(txn, 'confirmed_through', '$through');
      await _syncResolve(txn, through, complete: drained);
    }, exclusive: true);
    return stored;
  }

  /// Decide conflicts with what is already stored (e.g. right after this
  /// device's own writes were sequenced and nothing else is waiting).
  Future<void> syncSettle({required int head}) => _transactionRaw((txn) async {
    final known = int.tryParse(await _syncGet(txn, 'confirmed_through') ?? '') ?? 0;
    final through = head > known ? head : known;
    await _syncPut(txn, 'confirmed_through', '$through');
    await _syncResolve(txn, through, complete: true);
  }, exclusive: true);

  Future<void> _syncApplyOne(Transaction txn, BusinessSyncDelivery item) async {
    final known = await txn.query(
      _syncLog,
      where: 'op_id = ?',
      whereArgs: [item.id],
    );
    if (known.isNotEmpty) {
      // Our own operation coming back, or a repeat: only record its order.
      if (item.seq != null && known.single['seq'] == null) {
        await txn.update(
          _syncLog,
          {'seq': item.seq},
          where: 'op_id = ?',
          whereArgs: [item.id],
        );
      }
      return;
    }
    final p = item.payload;
    final changes = [
      for (final c in p['changes'] as List? ?? const [])
        Map<String, Object?>.from(c as Map),
    ];
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await txn.insert(_syncLog, {
      'op_id': item.id,
      'seq': item.seq,
      'branch_id': item.branchId,
      'origin': 'remote',
      'status': 'applied',
      'author_replica': p['author_replica'],
      'author_user': p['author_user'],
      'author_name': p['author_name'],
      'client_us': p['client_us'],
      'applied_us': now,
    });
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    var attempt = 0;
    while (true) {
      await txn.execute('SAVEPOINT business_sync_apply');
      try {
        await _syncApplyChanges(txn, item.id, item.seq, changes);
        await txn.execute('RELEASE business_sync_apply');
        return;
      } on DatabaseException catch (error) {
        // Nothing of a failed attempt may remain.
        await txn.execute('ROLLBACK TO business_sync_apply');
        await txn.execute('RELEASE business_sync_apply');
        // Two operations that cannot both exist (e.g. the same unique row made
        // on two devices). The one sequenced later loses. Our unsent
        // operations are always later than anything already sequenced.
        // The stored rows refuse it (a unique row made twice, a stock or
        // balance that cannot go below zero...). Whatever touched the same
        // rows *after* it in server order is what loses; retry without it.
        final later = attempt++ > 50 || !_syncIsConstraint(error)
            ? null
            : await _syncLaterOnSameRows(txn, item.seq, changes);
        if (later == null) {
          await _syncDiscardRemote(txn, item.id);
          await _syncNoteRejected(
            txn,
            item.id,
            BusinessSyncConflict.duplicate,
            winner: null,
          );
          return;
        }
        await _syncReject(txn, later.$1, later.$2, winner: item.id);
      }
    }
  }

  Future<void> _syncApplyChanges(
    Transaction txn,
    String opId,
    int? seq,
    List<Map<String, Object?>> changes,
  ) async {
    final legs = <Map<String, Object?>>[];
    for (final c in changes) {
      final table = c['t'] as String;
      final keys = _syncTables[table];
      if (keys == null) continue; // a table this version does not hold
      final pkList = c['pk'] as List;
      final pk = jsonEncode(pkList);
      final kind = c['k'] as String;
      final wireOld = c['old'] == null ? null : Map<String, Object?>.from(c['old'] as Map);
      final wireNew = c['new'] == null ? null : Map<String, Object?>.from(c['new'] as Map);
      final counters = _syncCounters[table] ?? const <String>{};
      final state = (await txn.query(
        _syncRows,
        where: 'tbl = ? AND pk = ?',
        whereArgs: [table, pk],
      )).singleOrNull;
      final current = await _syncCurrent(txn, table, keys, pkList);
      // Last writer by sequence wins; our pending (later) change keeps its row.
      final stale = state != null &&
          (state['pending_op'] != null ||
              (seq != null && (state['last_seq'] as int? ?? 0) > seq));
      final columns = (await _syncColumns(txn, table)).toSet();
      String? recorded;
      Map<String, int>? delta;
      if (kind == 'delete') {
        if (current == null || stale) continue;
        await _syncDeleteRow(txn, table, keys, current);
        recorded = 'delete';
      } else if (current == null) {
        if (kind == 'update' && stale) continue;
        await txn.insert(table, {
          for (final MapEntry(:key, :value) in wireNew!.entries)
            if (columns.contains(key)) key: value,
        });
        recorded = 'insert';
        if (table == 'business_local_bank_legs') legs.add(wireNew);
      } else {
        // Counters move by what the other device changed, not to its value.
        // (A row that already exists here is never «added» twice.)
        delta = {
          if (kind == 'update')
            for (final col in counters)
              if (wireNew!.containsKey(col))
                col: _syncInt(wireNew[col]) - _syncInt(wireOld?[col]),
        }..removeWhere((_, v) => v == 0);
        final updates = <String, Object?>{
          if (!stale)
            for (final MapEntry(:key, :value) in wireNew!.entries)
              if (columns.contains(key) &&
                  !keys.contains(key) &&
                  !counters.contains(key))
                key: value,
        };
        if (kind == 'insert' && updates.isEmpty && delta.isEmpty) continue;
        final set = [
          for (final c in updates.keys) '"$c" = ?',
          for (final c in delta.keys) '"$c" = "$c" + ?',
        ];
        if (set.isEmpty) continue;
        await txn.rawUpdate(
          'UPDATE "$table" SET ${set.join(', ')} WHERE ${keys.map((k) => '"$k" IS ?').join(' AND ')}',
          [...updates.values, ...delta.values, for (final k in keys) current[k]],
        );
        recorded = 'update';
      }
      await txn.insert(_syncChanges, {
        'op_id': opId,
        'tbl': table,
        'pk': pk,
        'kind': recorded,
        'old_row': current == null ? null : jsonEncode(current),
        'new_row': wireNew == null ? null : jsonEncode(wireNew),
        'delta': delta == null || delta.isEmpty ? null : jsonEncode(delta),
      });
      await txn.rawInsert(
        '''
        INSERT INTO $_syncRows (tbl, pk, last_seq, pending_op) VALUES (?, ?, ?, NULL)
        ON CONFLICT (tbl, pk) DO UPDATE SET last_seq = MAX(COALESCE(last_seq, 0), excluded.last_seq)
        ''',
        [table, pk, seq],
      );
    }
    // A statement line shows the account balance after it, on this device.
    for (final leg in legs) {
      await txn.rawUpdate(
        '''
        UPDATE business_local_bank_legs SET balance_minor = (
          SELECT balance_minor FROM business_local_accounts a
          WHERE a.branch_id = business_local_bank_legs.branch_id
            AND a.id = business_local_bank_legs.account_id)
        WHERE branch_id = ? AND command_id = ? AND account_id = ?
        ''',
        [leg['branch_id'], leg['command_id'], leg['account_id']],
      );
    }
  }

  Future<Map<String, Object?>?> _syncCurrent(
    DatabaseExecutor db,
    String table,
    List<String> keys,
    List pk,
  ) async {
    final columns = await _syncColumns(db, table);
    final rows = await db.query(
      table,
      columns: columns.map((c) => '"$c"').toList(),
      where: keys.map((k) => '"$k" IS ?').join(' AND '),
      whereArgs: pk,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  Future<void> _syncDeleteRow(
    Transaction txn,
    String table,
    List<String> keys,
    Map<String, Object?> current,
  ) => txn.delete(
    table,
    where: keys.map((k) => '"$k" IS ?').join(' AND '),
    whereArgs: [for (final k in keys) current[k]],
  );

  // ── conflicts ─────────────────────────────────────────────────────────────

  /// Decides, for good, every conflict among operations sequenced up to
  /// [through] — the same decisions on every device. With [complete], this
  /// device holds every sequenced operation, so its own unsent work (always
  /// later than all of them) can be judged too.
  Future<void> _syncResolve(
    Transaction txn,
    int through, {
    required bool complete,
  }) async {
    for (var round = 0; round < 20; round++) {
      final changed =
          await _syncResolvePermissions(txn, through, complete: complete) |
          await _syncResolveDuplicates(txn, through, complete: complete) |
          await _syncResolveFloors(txn, through, complete: complete);
      if (!changed) return;
    }
  }

  bool _syncDecidable(int? seq, int through, bool complete) =>
      seq == null ? complete : seq <= through;

  /// An employee's operation is checked against the permissions the owner
  /// had given that employee at that point in server order (the owner may
  /// have removed them offline, earlier). Removed → cancelled with a notice.
  Future<bool> _syncResolvePermissions(
    Transaction txn,
    int through, {
    required bool complete,
  }) async {
    final members = {
      for (final row in await txn.query(
        'business_employees',
        columns: ['linked_user_id'],
        where: 'linked_user_id IS NOT NULL',
      ))
        row['linked_user_id'] as String,
    };
    if (members.isEmpty) return false;
    final checked =
        int.tryParse(await _syncGet(txn, 'permissions_checked_through') ?? '') ?? 0;
    final ops = await txn.rawQuery(
      '''
      SELECT op_id, seq, author_user FROM $_syncLog
      WHERE status = 'applied' AND author_user IN (${members.map((_) => '?').join(',')})
        AND (seq IS NULL OR seq > ?)
      ORDER BY COALESCE(seq, $_syncNever), applied_us
      ''',
      [...members, checked],
    );
    var changed = false;
    var decided = checked;
    for (final op in ops) {
      final seq = op['seq'] as int?;
      if (!_syncDecidable(seq, through, complete)) break;
      final opId = op['op_id'] as String;
      final changes = await txn.query(
        _syncChanges,
        where: 'op_id = ?',
        whereArgs: [opId],
        orderBy: 'ord',
      );
      final needed = _syncRequiredPermission(changes);
      if (needed != null) {
        final grant = await _syncMemberGrant(txn, op['author_user'] as String, seq);
        if (grant == null || !_syncAllowed(grant, needed)) {
          await _syncReject(txn, opId, BusinessSyncConflict.revoked, winner: null);
          changed = true;
        }
      }
      if (seq != null && seq > decided) decided = seq;
    }
    if (decided != checked) {
      await _syncPut(txn, 'permissions_checked_through', '$decided');
    }
    return changed;
  }

  /// The employee's permissions as of [seq] (null: removed or unknown).
  Future<Map<String, bool>?> _syncMemberGrant(
    DatabaseExecutor db,
    String userId,
    int? seq,
  ) async {
    final rows = await db.rawQuery(
      '''
      SELECT c.new_row FROM $_syncChanges c JOIN $_syncLog l ON l.op_id = c.op_id
      WHERE c.tbl = 'business_employees' AND l.status = 'applied'
        AND json_extract(c.new_row, '\$.linked_user_id') = ?
        AND COALESCE(l.seq, $_syncNever) <= ?
      ORDER BY COALESCE(l.seq, $_syncNever) DESC, l.applied_us DESC, c.ord DESC
      LIMIT 1
      ''',
      [userId, seq ?? _syncNever],
    );
    Map? row = rows.isEmpty ? null : jsonDecode(rows.single['new_row'] as String) as Map;
    // No history here (e.g. a device that joined by snapshot): the record.
    row ??= (await db.query(
      'business_employees',
      where: 'linked_user_id = ?',
      whereArgs: [userId],
      limit: 1,
    )).singleOrNull;
    if (row == null || row['deleted_us'] != null) return null;
    try {
      final raw = jsonDecode('${row['permissions'] ?? '{}'}') as Map;
      return {for (final e in raw.entries) '${e.key}': e.value == true};
    } catch (_) {
      return null;
    }
  }

  /// The same bank/cash slot (name + currency + type) opened on two devices:
  /// the one sequenced first stays.
  Future<bool> _syncResolveDuplicates(
    Transaction txn,
    int through, {
    required bool complete,
  }) async {
    final accounts = await txn.query(
      'business_local_accounts',
      columns: ['branch_id', 'id', 'bank_name', 'currency', 'account_type'],
      where: 'closed_us IS NULL',
    );
    final slots = <String, List<Map<String, Object?>>>{};
    for (final a in accounts) {
      final name = a['bank_name'] as String;
      final type = _isLedgerCash(name)
          ? _shownCashType(a['account_type'] as String)
          : a['account_type'] as String;
      (slots['${a['branch_id']}|${_slotKey(name)}|${a['currency']}|$type'] ??= [])
          .add(a);
    }
    var changed = false;
    for (final same in slots.values.where((rows) => rows.length > 1)) {
      final creators = <(int, String, Map<String, Object?>)>[];
      for (final row in same) {
        final creator = await _syncCreator(
          txn,
          'business_local_accounts',
          jsonEncode([row['branch_id'], row['id']]),
        );
        creators.add((creator?.$2 ?? -1, creator?.$1 ?? '', row));
      }
      creators.sort((a, b) => a.$1.compareTo(b.$1));
      final first = creators.first;
      for (final later in creators.skip(1)) {
        if (later.$2.isEmpty) continue; // older than this device's history
        final seq = later.$1 == _syncNever ? null : later.$1;
        if (!_syncDecidable(seq, through, complete)) continue;
        await _syncReject(
          txn,
          later.$2,
          BusinessSyncConflict.duplicate,
          winner: first.$2.isEmpty ? null : first.$2,
        );
        changed = true;
      }
    }
    return changed;
  }

  /// (op, seq) of the operation that created a row, from the change log.
  Future<(String, int)?> _syncCreator(
    DatabaseExecutor db,
    String table,
    String pk,
  ) async {
    final row = (await db.rawQuery(
      '''
      SELECT c.op_id, COALESCE(l.seq, $_syncNever) AS seq FROM $_syncChanges c
      JOIN $_syncLog l ON l.op_id = c.op_id
      WHERE c.tbl = ? AND c.pk = ? AND c.kind = 'insert' AND l.status = 'applied'
      ORDER BY COALESCE(l.seq, $_syncNever), l.applied_us LIMIT 1
      ''',
      [table, pk],
    )).singleOrNull;
    return row == null ? null : (row['op_id'] as String, row['seq'] as int);
  }

  /// Replays each counter that is now past its floor, in sequence order, and
  /// cancels the first operation that pushed it there.
  Future<bool> _syncResolveFloors(
    Transaction txn,
    int through, {
    required bool complete,
  }) async {
    var changed = false;
    for (final floor in _syncFloors) {
      final keys = _syncTables[floor.table]!;
      final columns = await _syncColumns(txn, floor.table);
      for (final row in await txn.query(
        floor.table,
        columns: columns.map((c) => '"$c"').toList(),
      )) {
        if (!await floor.crossed(txn, row)) continue;
        final pk = jsonEncode([for (final k in keys) row[k]]);
        final events = await txn.rawQuery(
          '''
          SELECT c.op_id, c.kind, c.old_row, c.new_row, c.delta, l.seq
          FROM $_syncChanges c JOIN $_syncLog l ON l.op_id = c.op_id
          WHERE c.tbl = ? AND c.pk = ? AND l.status = 'applied'
          ORDER BY COALESCE(l.seq, $_syncNever), l.applied_us, c.ord
          ''',
          [floor.table, pk],
        );
        if (events.isEmpty) continue;
        // Rebuild the row as it stood before the first known operation.
        final first = events.first;
        final state = <String, Object?>{
          ...row,
          if (first['kind'] == 'insert') floor.column: 0,
          if (first['kind'] != 'insert' && first['old_row'] != null)
            floor.column: _syncInt(
              (jsonDecode(first['old_row'] as String) as Map)[floor.column],
            ),
        };
        String? previous;
        for (final e in events) {
          final move = _syncEventDelta(e, floor.column);
          final newRow = e['new_row'] == null
              ? const {}
              : jsonDecode(e['new_row'] as String) as Map;
          for (final MapEntry(:key, :value) in newRow.entries) {
            if (key != floor.column && !(_syncCounters[floor.table]?.contains(key) ?? false)) {
              state[key as String] = value;
            }
          }
          final before = _syncInt(state[floor.column]);
          state[floor.column] = before + move;
          final op = e['op_id'] as String;
          final seq = e['seq'] as int?;
          final worse = floor.column == 'paid_minor' ? move > 0 : move < 0;
          if (worse &&
              await floor.crossed(txn, state) &&
              _syncDecidable(seq == _syncNever ? null : seq, through, complete)) {
            await _syncReject(txn, op, floor.reason, winner: previous);
            changed = true;
            break; // re-read the row: the rejection changed it
          }
          if (move != 0) previous = op;
        }
      }
    }
    return changed;
  }

  /// The latest applied operation, sequenced after [seq] (or not yet
  /// sequenced), that touched one of the rows of [changes].
  Future<(String, BusinessSyncConflict)?> _syncLaterOnSameRows(
    Transaction txn,
    int? seq,
    List<Map<String, Object?>> changes,
  ) async {
    final rows = {
      for (final c in changes) (c['t'] as String, jsonEncode(c['pk'])),
    };
    if (rows.isEmpty) return null;
    final found = (await txn.rawQuery(
      '''
      SELECT c.op_id, c.tbl FROM $_syncChanges c JOIN $_syncLog l ON l.op_id = c.op_id
      WHERE l.status = 'applied' AND COALESCE(l.seq, $_syncNever) > ?
        AND (${rows.map((_) => '(c.tbl = ? AND c.pk = ?)').join(' OR ')})
      ORDER BY COALESCE(l.seq, $_syncNever) DESC, l.applied_us DESC LIMIT 1
      ''',
      [seq ?? _syncNever - 1, for (final (t, pk) in rows) ...[t, pk]],
    )).singleOrNull;
    if (found == null) return null;
    final reason = switch (found['tbl']) {
      'business_commerce_stock' ||
      'business_commerce_lots' ||
      'business_commerce_lot_consumptions' ||
      'business_commerce_stock_movements' => BusinessSyncConflict.stockShort,
      'business_local_accounts' ||
      'business_local_bank_legs' => BusinessSyncConflict.balanceShort,
      'business_local_debts' ||
      'business_local_payment_parts' ||
      'business_commerce_invoices' ||
      'business_commerce_invoice_payments' => BusinessSyncConflict.debtOverpaid,
      _ => BusinessSyncConflict.duplicate,
    };
    return (found['op_id'] as String, reason);
  }

  /// Cancels an operation on this device: its row changes are undone (counters
  /// move back by what it moved), it is marked rejected, everything built on
  /// it is cancelled with it, and its author is told why.
  Future<void> _syncReject(
    Transaction txn,
    String opId,
    BusinessSyncConflict reason, {
    required String? winner,
  }) async {
    final log = (await txn.query(
      _syncLog,
      where: 'op_id = ?',
      whereArgs: [opId],
    )).singleOrNull;
    if (log == null || log['status'] == 'rejected') return;
    // Later work that used what this operation created goes with it.
    final created = <String>{};
    final changes = await txn.query(
      _syncChanges,
      where: 'op_id = ?',
      whereArgs: [opId],
      orderBy: 'ord DESC',
    );
    for (final c in changes) {
      if (c['kind'] != 'insert') continue;
      final row = jsonDecode((c['new_row'] ?? '{}') as String) as Map;
      for (final k in const ['id', 'debt_id', 'account_id', 'invoice_id']) {
        final v = row[k];
        if (v is String && isDirectoryId(v) && c['tbl'] != 'business_ledger_commands') {
          if (k == 'id' || c['tbl'] == 'business_local_accounts') created.add(v);
        }
      }
    }
    await txn.update(
      _syncLog,
      {'status': 'rejected'},
      where: 'op_id = ?',
      whereArgs: [opId],
    );
    await txn.delete(_syncOutbox, where: 'op_id = ?', whereArgs: [opId]);
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    for (final c in changes) {
      final table = c['tbl'] as String;
      final keys = _syncTables[table];
      if (keys == null) continue;
      final pk = jsonDecode(c['pk'] as String) as List;
      final current = await _syncCurrent(txn, table, keys, pk);
      final old = c['old_row'] == null
          ? null
          : Map<String, Object?>.from(jsonDecode(c['old_row'] as String) as Map);
      final counters = _syncCounters[table] ?? const <String>{};
      switch (c['kind']) {
        case 'insert':
          if (current != null) await _syncDeleteRow(txn, table, keys, current);
        case 'update':
          if (current == null || old == null) break;
          final moves = {
            for (final col in counters) col: _syncEventDelta(c, col),
          }..removeWhere((_, v) => v == 0);
          final restore = <String, Object?>{
            for (final MapEntry(:key, :value) in old.entries)
              if (!keys.contains(key) && !counters.contains(key)) key: value,
          };
          final set = [
            for (final col in restore.keys) '"$col" = ?',
            for (final col in moves.keys) '"$col" = "$col" - ?',
          ];
          if (set.isEmpty) break;
          await txn.rawUpdate(
            'UPDATE "$table" SET ${set.join(', ')} WHERE ${keys.map((k) => '"$k" IS ?').join(' AND ')}',
            [...restore.values, ...moves.values, for (final k in keys) current[k]],
          );
        case 'delete':
          if (old != null && current == null) {
            final columns = (await _syncColumns(txn, table)).toSet();
            await txn.insert(table, {
              for (final MapEntry(:key, :value) in old.entries)
                if (columns.contains(key)) key: value,
            });
          }
      }
      await txn.update(
        _syncRows,
        {'pending_op': null},
        where: 'tbl = ? AND pk = ? AND pending_op = ?',
        whereArgs: [table, c['pk'], opId],
      );
    }
    await _syncNoteRejected(txn, opId, reason, winner: winner);
    if (created.isEmpty) return;
    final mySeq = log['seq'] as int? ?? _syncNever;
    final dependants = await txn.rawQuery(
      '''
      SELECT DISTINCT c.op_id FROM $_syncChanges c JOIN $_syncLog l ON l.op_id = c.op_id
      WHERE l.status = 'applied' AND c.op_id != ?
        AND COALESCE(l.seq, $_syncNever) >= ?
        AND (${created.map((_) => 'c.new_row LIKE ?').join(' OR ')})
      ''',
      [opId, mySeq, for (final id in created) '%"$id"%'],
    );
    for (final d in dependants) {
      await _syncReject(
        txn,
        d['op_id'] as String,
        BusinessSyncConflict.dependent,
        winner: winner,
      );
    }
  }

  Future<void> _syncDiscardRemote(Transaction txn, String opId) async {
    await txn.delete(_syncChanges, where: 'op_id = ?', whereArgs: [opId]);
    await txn.update(
      _syncLog,
      {'status': 'rejected'},
      where: 'op_id = ?',
      whereArgs: [opId],
    );
  }

  Future<void> _syncNoteRejected(
    Transaction txn,
    String opId,
    BusinessSyncConflict reason, {
    required String? winner,
  }) async {
    final log = (await txn.query(
      _syncLog,
      where: 'op_id = ?',
      whereArgs: [opId],
    )).singleOrNull;
    if (log == null) return;
    final me = await _syncGet(txn, 'replica_id');
    if (log['origin'] != 'local' && log['author_replica'] != me) return;
    final first = winner == null
        ? null
        : (await txn.query(_syncLog, where: 'op_id = ?', whereArgs: [winner]))
              .singleOrNull;
    final changes = await txn.query(
      _syncChanges,
      where: 'op_id = ?',
      whereArgs: [opId],
      orderBy: 'ord',
    );
    await txn.insert(_syncNotices, {
      'id': const Uuid().v5(opId, 'fyona.sync.notice'),
      'op_id': opId,
      'kind': reason.name,
      'details': jsonEncode({
        'by_name': first?['author_name'],
        'by_user': first?['author_user'],
        'summary': _syncSummary(changes),
      }),
      'created_us': DateTime.now().toUtc().microsecondsSinceEpoch,
      'read': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// A short, readable trace of what the cancelled operation did.
  Map<String, Object?> _syncSummary(List<Map<String, Object?>> changes) {
    Map? row(String table) {
      for (final c in changes) {
        if (c['tbl'] == table && c['new_row'] != null) {
          return jsonDecode(c['new_row'] as String) as Map;
        }
      }
      return null;
    }

    final invoice = row('business_commerce_invoices');
    if (invoice != null) {
      return {
        'what': invoice['invoice_type'] == 'purchase' ? 'purchase' : 'sale',
        'number': invoice['number'],
        'amount_minor': invoice['total_minor'],
        'currency': invoice['currency'],
      };
    }
    final account = row('business_local_accounts');
    final leg = row('business_local_bank_legs');
    if (account != null && changes.any((c) => c['tbl'] == 'business_local_accounts' && c['kind'] == 'insert')) {
      return {
        'what': 'account',
        'name': account['bank_name'],
        'currency': account['currency'],
      };
    }
    if (leg != null) {
      return {
        'what': 'money',
        'description': leg['description'],
        'amount_minor': leg['delta_minor'],
        'currency': leg['currency'],
      };
    }
    final product = row('business_commerce_products');
    if (product != null) return {'what': 'product', 'name': product['name']};
    final party = row('directory_parties');
    if (party != null) return {'what': 'party', 'name': party['name']};
    final debt = row('business_local_debts');
    if (debt != null) {
      return {
        'what': 'debt',
        'number': debt['number'],
        'amount_minor': debt['total_minor'],
        'currency': debt['currency'],
      };
    }
    return {};
  }

  /// The relay refused this device's unsent work (its access was removed):
  /// cancel it here and tell the user.
  Future<void> syncRejectOutbox() => _transactionRaw((txn) async {
    final pending = await txn.query(_syncOutbox, columns: ['op_id'], orderBy: 'created_us DESC');
    for (final row in pending) {
      await _syncReject(
        txn,
        row['op_id'] as String,
        BusinessSyncConflict.revoked,
        winner: null,
      );
    }
  }, exclusive: true);

  // ── notices ───────────────────────────────────────────────────────────────

  Future<List<BusinessSyncNotice>> syncNotices() => _read(
    (db) async => [
      for (final row in await db.query(_syncNotices, orderBy: 'created_us DESC'))
        (
          id: row['id'] as String,
          opId: row['op_id'] as String,
          kind: row['kind'] as String,
          details: Map<String, Object?>.from(
            jsonDecode(row['details'] as String) as Map,
          ),
          createdUs: row['created_us'] as int,
          read: row['read'] == 1,
        ),
    ],
  );

  Future<void> syncMarkNoticesRead() =>
      _transactionRaw((txn) => txn.update(_syncNotices, {'read': 1}));

  Future<String?> syncOperationStatus(String opId) => _read(
    (db) async => (await db.query(
      _syncLog,
      columns: ['status'],
      where: 'op_id = ?',
      whereArgs: [opId],
    )).singleOrNull?['status'] as String?,
  );

  // ── snapshot for a new / long-absent device ───────────────────────────────

  /// Everything this device holds, and which operations it contains. Only
  /// served with an empty outbox, so every contained operation is sequenced.
  /// With [branchIds], only those branches (an employee's copy).
  Future<Map<String, Object?>?> syncSnapshot({Set<String>? branchIds}) =>
      _read((db) async {
    if ((await db.query(_syncOutbox, limit: 1)).isNotEmpty) return null;
    final tables = <String, Object?>{};
    for (final table in _syncTables.keys) {
      final columns = await _syncColumns(db, table);
      tables[table] = [
        for (final row in await db.query(table, columns: columns.map((c) => '"$c"').toList()))
          if (branchIds == null ||
              !row.containsKey('branch_id') ||
              branchIds.contains(row['branch_id']))
            row,
      ];
    }
    return {
      'v': 2,
      'confirmed_through':
          int.tryParse(await _syncGet(db, 'confirmed_through') ?? '') ?? 0,
      'tables': tables,
      'operations': [
        for (final row in await db.query(
          _syncLog,
          columns: ['op_id', 'seq', 'status', 'branch_id', 'author_replica', 'author_user', 'author_name', 'client_us'],
          where: 'seq IS NOT NULL',
        ))
          row,
      ],
    };
  });

  /// Replaces this device's Business copy with a snapshot, then re-applies
  /// its own operations that the snapshot does not contain yet.
  Future<void> syncApplySnapshot(Map<String, Object?> snapshot) =>
      _transactionRaw((txn) async {
        await txn.execute('PRAGMA defer_foreign_keys = ON');
        final operations = [
          for (final o in snapshot['operations'] as List? ?? const [])
            Map<String, Object?>.from(o as Map),
        ];
        final contained = {for (final o in operations) o['op_id'] as String};
        final ownLater = [
          for (final row in await txn.query(
            _syncLog,
            where: "origin = 'local' AND status = 'applied'",
            orderBy: 'COALESCE(seq, $_syncNever), applied_us',
          ))
            if (!contained.contains(row['op_id'])) row,
        ];
        final ownChanges = <String, List<Map<String, Object?>>>{};
        for (final op in ownLater) {
          final id = op['op_id'] as String;
          final outbox = (await txn.query(_syncOutbox, where: 'op_id = ?', whereArgs: [id])).singleOrNull;
          // The original wire form (images as made here) is what re-applies.
          ownChanges[id] = outbox != null
              ? [
                  for (final c in (jsonDecode(outbox['payload'] as String) as Map)['changes'] as List)
                    Map<String, Object?>.from(c as Map),
                ]
              : [
                  for (final c in await txn.query(
                    _syncChanges,
                    where: 'op_id = ?',
                    whereArgs: [id],
                    orderBy: 'ord',
                  ))
                    _syncWire(c),
                ];
        }
        final tables = snapshot['tables'] as Map? ?? const {};
        for (final table in _syncTables.keys.toList().reversed) {
          await txn.delete(table);
        }
        for (final table in _syncTables.keys) {
          final columns = (await _syncColumns(txn, table)).toSet();
          for (final row in tables[table] as List? ?? const []) {
            await txn.insert(table, {
              for (final MapEntry(:key, :value) in (row as Map).entries)
                if (columns.contains(key)) key as String: value,
            });
          }
        }
        await txn.delete(_syncRows);
        await txn.delete(_syncChanges);
        await txn.delete(_syncLog, where: "origin != 'local' OR status = 'rejected'");
        for (final o in operations) {
          await txn.insert(_syncLog, {
            'op_id': o['op_id'],
            'seq': o['seq'],
            'branch_id': o['branch_id'],
            'origin': 'snapshot',
            'status': o['status'],
            'author_replica': o['author_replica'],
            'author_user': o['author_user'],
            'author_name': o['author_name'],
            'client_us': o['client_us'],
            'applied_us': DateTime.now().toUtc().microsecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await _syncPut(
          txn,
          'confirmed_through',
          '${snapshot['confirmed_through'] ?? 0}',
        );
        // Our own later work is still ours: put it back on top.
        for (final op in ownLater) {
          final id = op['op_id'] as String;
          await _syncApplyChanges(txn, id, op['seq'] as int?, ownChanges[id]!);
          if (op['seq'] == null) {
            await txn.rawUpdate(
              '''
              UPDATE $_syncRows SET pending_op = ?
              WHERE (tbl, pk) IN (SELECT tbl, pk FROM $_syncChanges WHERE op_id = ?)
              ''',
              [id, id],
            );
          }
        }
        await _syncPut(txn, 'resync_pending', '0');
      }, exclusive: true);

  // ── helpers ───────────────────────────────────────────────────────────────

  Future<T> _transactionRaw<T>(
    Future<T> Function(Transaction) run, {
    bool exclusive = false,
  }) => _io.synchronized(() => _db.transaction(run, exclusive: exclusive));
}

int _syncInt(Object? value) => value is num ? value.toInt() : 0;

/// What an operation moved a counter by (local: after − before; remote: the
/// delta it applied here).
int _syncEventDelta(Map<String, Object?> change, String column) {
  if (change['delta'] != null) {
    return _syncInt((jsonDecode(change['delta'] as String) as Map)[column]);
  }
  final newRow = change['new_row'] == null
      ? null
      : jsonDecode(change['new_row'] as String) as Map;
  final oldRow = change['old_row'] == null
      ? null
      : jsonDecode(change['old_row'] as String) as Map;
  switch (change['kind']) {
    case 'insert':
      return _syncInt(newRow?[column]);
    case 'delete':
      return -_syncInt(oldRow?[column]);
    default:
      return _syncInt(newRow?[column]) - _syncInt(oldRow?[column]);
  }
}

Map<String, Object?> _syncWire(Map<String, Object?> c) => {
  't': c['tbl'],
  'pk': jsonDecode(c['pk'] as String),
  'k': c['kind'],
  if (c['old_row'] != null) 'old': jsonDecode(c['old_row'] as String),
  if (c['new_row'] != null) 'new': jsonDecode(c['new_row'] as String),
};

bool _syncTouchesOwnColumns(Map<String, Object?> c) {
  if (c['kind'] != 'update') return true;
  final counters = _syncCounters[c['tbl']] ?? const <String>{};
  final old = jsonDecode(c['old_row'] as String) as Map;
  final now = jsonDecode(c['new_row'] as String) as Map;
  return now.keys.any((k) => !counters.contains(k) && now[k] != old[k]);
}

String? _syncBranch(List<Map<String, Object?>> changes) {
  for (final c in changes) {
    final row = jsonDecode((c['new_row'] ?? c['old_row']) as String) as Map;
    final branch = row['branch_id'];
    if (branch is String) return branch;
  }
  return null;
}

bool _syncIsConstraint(DatabaseException error) =>
    error.toString().contains('constraint failed');

Future<String?> _syncGet(DatabaseExecutor db, String key) async =>
    (await db.query(
      _syncState,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    )).singleOrNull?['value'] as String?;

Future<void> _syncPut(DatabaseExecutor db, String key, String value) =>
    db.insert(_syncState, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);


/// The permission an operation needs, from what it wrote (first match wins).
String? _syncRequiredPermission(List<Map<String, Object?>> changes) {
  Map? first(String table, {String kind = 'insert'}) {
    for (final c in changes) {
      if (c['tbl'] == table && c['kind'] == kind && c['new_row'] != null) {
        return jsonDecode(c['new_row'] as String) as Map;
      }
    }
    return null;
  }

  bool touches(String table) => changes.any((c) => c['tbl'] == table);
  if (touches('business_employees') ||
      touches('business_employee_payroll') ||
      touches('business_employee_debts')) {
    return 'employees';
  }
  final returned = first('business_commerce_returns');
  if (returned != null) {
    return returned['invoice_type'] == 'purchase' ? 'purchases.returns' : 'sales.returns';
  }
  final invoice = first('business_commerce_invoices');
  if (invoice != null) {
    return invoice['invoice_type'] == 'purchase' ? 'purchases.create' : 'sales.create';
  }
  if (touches('business_reconciliations')) return 'reconciliation';
  if (touches('business_branch_transfers')) return 'branches.transfer';
  if (first('business_local_accounts') != null) return 'banks.add_delete';
  if (first('business_local_payment_parts') != null) return 'debts.settle';
  if (first('business_local_debts') != null) return 'debts.add';
  final leg = first('business_local_bank_legs');
  if (leg != null) {
    final kind = '${leg['kind']}';
    if (kind.startsWith('transfer')) return 'banks.transfer';
    if (kind == 'deposit') return 'income';
    if (kind == 'withdrawal') return leg['expense_category'] != null ? 'expenses' : 'transactions';
  }
  final party = first('directory_parties') ?? first('directory_parties', kind: 'update');
  if (party != null) {
    final group = party['kind'] == 'supplier' ? 'suppliers' : 'customers';
    return first('directory_parties') != null ? '$group.add' : '$group.edit';
  }
  if (first('business_commerce_products') != null) return 'inventory.add';
  if (first('business_commerce_products', kind: 'update') != null) return 'inventory.edit';
  return null;
}

/// Mirrors employeePermissionAllowed (lib/features/employees/data/employee_permissions.dart).
bool _syncAllowed(Map<String, bool> permissions, String key) {
  final parent = key.split('.').first;
  if (parent == 'employees') return false;
  const legacy = {'transactions': 'dashboard', 'income': 'reports', 'expenses': 'reports'};
  final enabled = permissions[parent] ?? permissions[legacy[parent]] ?? false;
  return enabled && (permissions[key] ?? enabled);
}
