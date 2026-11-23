part of 'directory_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Business sync engine — local-first, the server is only a relay.
//
// Every Business write commits here first (unchanged texts, no waiting). SQLite
// triggers capture the row images of the write into one operation that waits
// in the outbox. The relay stamps operations with the organization's arrival
// sequence and carries them to the other devices, then deletes them.
// Every device applies the same operations in the same sequence order with the
// same rules, so all of them converge and take the same conflict decisions.
// See docs/BUSINESS_SYNC_ENGINE.md.
// ─────────────────────────────────────────────────────────────────────────────

const _syncOutbox = 'business_sync_outbox';
const _syncLog = 'business_sync_log';
const _syncChanges = 'business_sync_changes';
const _syncRows = 'business_sync_rows';
const _syncState = 'business_sync_state';
const _syncContext = 'business_sync_context';
const _syncNotices = 'business_sync_notices';

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
};

/// Columns that are never copied from another device: each device keeps them
/// as the sum of the facts it holds (see [_syncAggregates]).
const Map<String, Set<String>> _syncDerived = {
  'business_local_accounts': {'balance_minor'},
  'business_local_bank_legs': {'balance_minor', 'sequence'},
  'business_local_debts': {'paid_minor'},
};

/// Additive facts: a child row adds its value to a parent column. Concurrent
/// payments from two devices therefore add up instead of overwriting.
typedef _SyncAggregate = ({
  String child,
  String value,
  String parent,
  String column,
  Map<String, String> keys, // child column -> parent column
  String? running, // child column receiving the parent value after the fact
});

const List<_SyncAggregate> _syncAggregates = [
  (
    child: 'business_local_bank_legs',
    value: 'delta_minor',
    parent: 'business_local_accounts',
    column: 'balance_minor',
    keys: {'branch_id': 'branch_id', 'account_id': 'id'},
    running: 'balance_minor',
  ),
  (
    child: 'business_local_payment_parts',
    value: 'applied_minor',
    parent: 'business_local_debts',
    column: 'paid_minor',
    keys: {'branch_id': 'branch_id', 'invoice_id': 'id'},
    running: null,
  ),
];

/// The reason a device cancels one of two operations that cannot both hold.
enum BusinessSyncConflict { debtOverpaid, duplicate }

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

Future<void> _createBusinessSync(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncState (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_syncContext (
      op_id TEXT NOT NULL,
      mode TEXT NOT NULL
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
      new_row TEXT
    )
  ''');
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

/// (Re)creates the capture triggers from the live schema. Run at every open so
/// columns added by later migrations are always captured.
Future<void> _installBusinessSyncTriggers(DatabaseExecutor db) async {
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
        "WHEN (SELECT mode FROM $_syncContext LIMIT 1) = 'local'";
    const op = '(SELECT op_id FROM $_syncContext LIMIT 1)';
    for (final (name, event, kind, old, now) in [
      ('ai', 'INSERT', 'insert', null, 'NEW'),
      ('au', 'UPDATE', 'update', 'OLD', 'NEW'),
      ('ad', 'DELETE', 'delete', 'OLD', null),
    ]) {
      final trigger = 'business_sync_${name}_$table';
      await db.execute('DROP TRIGGER IF EXISTS "$trigger"');
      await db.execute('''
        CREATE TRIGGER "$trigger" AFTER $event ON "$table" $when
        BEGIN
          INSERT INTO $_syncChanges (op_id, tbl, pk, kind, old_row, new_row)
          VALUES ($op, '$table', ${key(now ?? old!)}, '$kind',
            ${old == null ? 'NULL' : image(old)},
            ${now == null ? 'NULL' : image(now)});
        END
      ''');
    }
  }
}

Future<List<String>> _syncColumns(DatabaseExecutor db, String table) async {
  final derived = table == 'business_local_bank_legs' ? {'sequence'} : <String>{};
  return [
    for (final row in await db.rawQuery('PRAGMA table_info("$table")'))
      if (!derived.contains(row['name'])) row['name'] as String,
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
    await txn.delete(_syncContext);
    await txn.insert(_syncContext, {'op_id': opId, 'mode': 'local'});
  }

  /// Turns the captured changes of this transaction into one operation in the
  /// outbox, atomically with the write itself.
  Future<void> _syncSeal(Transaction txn, String opId) async {
    await txn.delete(_syncContext);
    final changes = await txn.query(
      _syncChanges,
      where: 'op_id = ?',
      whereArgs: [opId],
      orderBy: 'ord',
    );
    if (changes.isEmpty) return;
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final payload = <String, Object?>{
      'v': 1,
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
      // A change that only moved derived totals (a balance) does not make the
      // row «ours»: another device may still rename that account.
      if (!_syncTouchesOwnColumns(c)) continue;
      await txn.rawInsert(
        '''
        INSERT INTO $_syncRows (tbl, pk, last_seq, pending_op) VALUES (?, ?, NULL, ?)
        ON CONFLICT (tbl, pk) DO UPDATE SET pending_op = excluded.pending_op
        ''',
        [c['tbl'], c['pk'], opId],
      );
    }
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
      ..sort((a, b) => (a.seq ?? 1 << 62).compareTo(b.seq ?? 1 << 62));
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
      await _syncResolve(txn, through);
    }, exclusive: true);
    return stored;
  }

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
      for (final c in p['changes'] as List? ?? const []) Map<String, Object?>.from(c as Map),
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
        final pending = await _syncPendingLocal(txn);
        if (attempt++ > 50 || pending.isEmpty || !_syncIsConstraint(error)) {
          await _syncDiscardRemote(txn, item.id);
          await _syncNoteRejected(
            txn,
            item.id,
            BusinessSyncConflict.duplicate,
            winner: null,
          );
          return;
        }
        await _syncReject(
          txn,
          pending.first,
          BusinessSyncConflict.duplicate,
          winner: item.id,
        );
      }
    }
  }

  Future<void> _syncApplyChanges(
    Transaction txn,
    String opId,
    int? seq,
    List<Map<String, Object?>> changes,
  ) async {
    // Children added by this operation, per parent row, so a new parent row
    // starts from the value its facts will add up to.
    final incoming = <String, int>{};
    for (final c in changes) {
      final agg = _syncAggregateFor(c['t'] as String);
      if (agg == null || c['k'] != 'insert') continue;
      final row = c['new'] as Map;
      final key = _syncParentKey(agg, row);
      incoming[key] = (incoming[key] ?? 0) + ((row[agg.value] as num?)?.toInt() ?? 0);
    }
    for (final c in changes) {
      final table = c['t'] as String;
      final keyColumns = _syncTables[table];
      if (keyColumns == null) continue; // a table this version does not hold
      final pk = jsonEncode(c['pk']);
      final state = (await txn.query(
        _syncRows,
        where: 'tbl = ? AND pk = ?',
        whereArgs: [table, pk],
      )).singleOrNull;
      final kind = c['k'] as String;
      final newRow = c['new'] == null ? null : Map<String, Object?>.from(c['new'] as Map);
      final current = await _syncCurrent(txn, table, keyColumns, c['pk'] as List);
      // Last writer by sequence wins; our pending (later) change keeps its row.
      final stale = state != null &&
          (state['pending_op'] != null ||
              (seq != null && (state['last_seq'] as int? ?? 0) > seq));
      if (stale && kind != 'insert') continue;
      if (stale && current != null) continue;
      await txn.insert(_syncChanges, {
        'op_id': opId,
        'tbl': table,
        'pk': pk,
        'kind': current == null ? 'insert' : (kind == 'delete' ? 'delete' : 'update'),
        'old_row': current == null ? null : jsonEncode(current),
        'new_row': newRow == null ? null : jsonEncode(newRow),
      });
      if (kind == 'delete') {
        if (current == null) continue;
        await _syncDelete(txn, table, keyColumns, current);
      } else {
        await _syncUpsert(txn, table, keyColumns, newRow!, current, incoming);
      }
      await txn.rawInsert(
        '''
        INSERT INTO $_syncRows (tbl, pk, last_seq, pending_op) VALUES (?, ?, ?, NULL)
        ON CONFLICT (tbl, pk) DO UPDATE SET last_seq = MAX(COALESCE(last_seq, 0), excluded.last_seq)
        ''',
        [table, pk, seq],
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

  Future<void> _syncUpsert(
    Transaction txn,
    String table,
    List<String> keys,
    Map<String, Object?> wire,
    Map<String, Object?>? current,
    Map<String, int> incoming,
  ) async {
    final columns = await _syncColumns(txn, table);
    final derived = _syncDerived[table] ?? const <String>{};
    final row = <String, Object?>{
      for (final c in columns)
        if (wire.containsKey(c)) c: wire[c],
    };
    if (current == null) {
      // A new parent starts at what its own facts in this operation do not
      // explain (e.g. an imported opening balance); the facts then add up.
      for (final agg in _syncAggregates.where((a) => a.parent == table)) {
        final key = _syncParentKeyOfParent(agg, row);
        row[agg.column] =
            ((row[agg.column] as num?)?.toInt() ?? 0) - (incoming[key] ?? 0);
      }
      final child = _syncAggregateFor(table);
      if (child?.running != null) row[child!.running!] = 0;
      if (table == 'business_opening_debt_edits') {
        await _syncFreeRevision(txn, row);
      }
      await txn.insert(table, row);
      if (child != null) {
        await _syncAddToParent(txn, child, row, (row[child.value] as num).toInt());
      }
      return;
    }
    final updates = <String, Object?>{
      for (final c in row.keys)
        if (!keys.contains(c) && !derived.contains(c)) c: row[c],
    };
    final child = _syncAggregateFor(table);
    if (updates.isNotEmpty) {
      await txn.update(
        table,
        updates,
        where: keys.map((k) => '"$k" IS ?').join(' AND '),
        whereArgs: [for (final k in keys) current[k]],
      );
    }
    if (child != null) {
      final before = (current[child.value] as num?)?.toInt() ?? 0;
      final after = (row[child.value] as num?)?.toInt() ?? before;
      if (after != before) await _syncAddToParent(txn, child, row, after - before);
    }
  }

  Future<void> _syncDelete(
    Transaction txn,
    String table,
    List<String> keys,
    Map<String, Object?> current,
  ) async {
    await txn.delete(
      table,
      where: keys.map((k) => '"$k" IS ?').join(' AND '),
      whereArgs: [for (final k in keys) current[k]],
    );
    final child = _syncAggregateFor(table);
    if (child != null) {
      await _syncAddToParent(
        txn,
        child,
        current,
        -((current[child.value] as num?)?.toInt() ?? 0),
      );
    }
  }

  Future<void> _syncAddToParent(
    Transaction txn,
    _SyncAggregate agg,
    Map<String, Object?> child,
    int delta,
  ) async {
    final where = agg.keys.values.map((p) => '"$p" IS ?').join(' AND ');
    final args = [for (final c in agg.keys.keys) child[c]];
    if (delta != 0) {
      await txn.rawUpdate(
        'UPDATE "${agg.parent}" SET "${agg.column}" = "${agg.column}" + ? WHERE $where',
        [delta, ...args],
      );
    }
    final running = agg.running;
    if (running != null) {
      final parent = await txn.query(
        agg.parent,
        columns: [agg.column],
        where: where,
        whereArgs: args,
      );
      if (parent.isNotEmpty) {
        final childKeys = _syncTables[agg.child]!;
        await txn.update(
          agg.child,
          {running: parent.single[agg.column]},
          where: childKeys.map((k) => '"$k" IS ?').join(' AND '),
          whereArgs: [for (final k in childKeys) child[k]],
        );
      }
    }
  }

  /// Two devices editing the same opening debt both write «revision r+1».
  /// The edit keeps its own identity; its revision number moves up.
  Future<void> _syncFreeRevision(Transaction txn, Map<String, Object?> row) async {
    final taken = await txn.query(
      'business_opening_debt_edits',
      columns: ['1'],
      where: 'branch_id = ? AND invoice_id = ? AND revision = ?',
      whereArgs: [row['branch_id'], row['invoice_id'], row['revision']],
    );
    if (taken.isEmpty) return;
    final top = await txn.rawQuery(
      'SELECT MAX(revision) AS r FROM business_opening_debt_edits WHERE branch_id = ? AND invoice_id = ?',
      [row['branch_id'], row['invoice_id']],
    );
    row['revision'] = ((top.single['r'] as int?) ?? 0) + 1;
  }

  // ── conflicts ─────────────────────────────────────────────────────────────

  /// Decides, for good, every conflict among operations sequenced up to
  /// [through] — the same decisions on every device.
  Future<void> _syncResolve(Transaction txn, int through) async {
    await _syncResolveOverpaid(txn, through);
  }

  /// A debt cannot be paid beyond its amount: replay its facts in sequence
  /// order; a payment that would pass the amount (someone collected it first)
  /// is cancelled.
  Future<void> _syncResolveOverpaid(Transaction txn, int through) async {
    final debts = await txn.rawQuery('''
      SELECT branch_id, id, total_minor, paid_minor FROM business_local_debts
      WHERE paid_minor > total_minor AND cancelled_us IS NULL
    ''');
    for (final debt in debts) {
      final pk = jsonEncode([debt['branch_id'], debt['id']]);
      final events = await txn.rawQuery(
        '''
        SELECT c.op_id, c.tbl, c.kind, c.new_row, l.seq, l.status, c.ord
        FROM $_syncChanges c JOIN $_syncLog l ON l.op_id = c.op_id
        WHERE l.status = 'applied' AND (
          (c.tbl = 'business_local_debts' AND c.pk = ?)
          OR (c.tbl = 'business_local_payment_parts' AND c.kind = 'insert'
              AND json_extract(c.new_row, '\$.branch_id') = ?
              AND json_extract(c.new_row, '\$.invoice_id') = ?))
        ORDER BY COALESCE(l.seq, 9223372036854775807), l.applied_us, c.ord
        ''',
        [pk, debt['branch_id'], debt['id']],
      );
      var total = 0, paid = 0;
      String? lastPayer;
      final losers = <String>[];
      final winners = <String, String?>{};
      for (final e in events) {
        final row = e['new_row'] == null
            ? const {}
            : jsonDecode(e['new_row'] as String) as Map;
        if (e['tbl'] == 'business_local_debts') {
          total = (row['total_minor'] as num?)?.toInt() ?? total;
          continue;
        }
        final seq = e['seq'] as int?;
        final applied = (row['applied_minor'] as num).toInt();
        if (paid + applied > total && seq != null && seq <= through) {
          losers.add(e['op_id'] as String);
          winners[e['op_id'] as String] = lastPayer;
          continue;
        }
        paid += applied;
        lastPayer = e['op_id'] as String;
      }
      for (final op in losers.toSet()) {
        await _syncReject(
          txn,
          op,
          BusinessSyncConflict.debtOverpaid,
          winner: winners[op],
        );
      }
    }
  }

  Future<List<String>> _syncPendingLocal(Transaction txn) async => [
    for (final row in await txn.query(
      _syncLog,
      columns: ['op_id'],
      where: "origin = 'local' AND seq IS NULL AND status = 'applied'",
      orderBy: 'applied_us DESC',
    ))
      row['op_id'] as String,
  ];

  /// Cancels an operation on this device: its row changes are undone (facts
  /// adjust their totals), it is marked rejected, and its author is told why.
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
    final changes = await txn.query(
      _syncChanges,
      where: 'op_id = ?',
      whereArgs: [opId],
      orderBy: 'ord DESC',
    );
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
      switch (c['kind']) {
        case 'insert':
          if (current != null) await _syncDelete(txn, table, keys, current);
        case 'update':
          if (old != null) await _syncUpsert(txn, table, keys, old, current, const {});
        case 'delete':
          if (old != null && current == null) {
            await _syncUpsert(txn, table, keys, old, null, const {});
          }
      }
      await txn.update(
        _syncRows,
        {'pending_op': null},
        where: 'tbl = ? AND pk = ? AND pending_op = ?',
        whereArgs: [table, c['pk'], opId],
      );
    }
    await txn.update(
      _syncLog,
      {'status': 'rejected'},
      where: 'op_id = ?',
      whereArgs: [opId],
    );
    await _syncNoteRejected(txn, opId, reason, winner: winner);
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
    for (final c in changes) {
      final row = c['new_row'] == null
          ? null
          : jsonDecode(c['new_row'] as String) as Map;
      if (row == null) continue;
      if (c['tbl'] == 'business_local_bank_legs') {
        return {
          'kind': row['kind'],
          'amount_minor': row['delta_minor'],
          'currency': row['currency'],
          'description': row['description'],
        };
      }
    }
    return {};
  }

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
  Future<Map<String, Object?>?> syncSnapshot() => _read((db) async {
    if ((await db.query(_syncOutbox, limit: 1)).isNotEmpty) return null;
    final tables = <String, Object?>{};
    for (final table in _syncTables.keys) {
      final columns = await _syncColumns(db, table);
      tables[table] = [
        for (final row in await db.query(table, columns: columns.map((c) => '"$c"').toList()))
          row,
      ];
    }
    return {
      'v': 1,
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
            orderBy: 'COALESCE(seq, 9223372036854775807), applied_us',
          ))
            if (!contained.contains(row['op_id'])) row['op_id'] as String,
        ];
        final ownChanges = <String, List<Map<String, Object?>>>{
          for (final op in ownLater)
            op: [
              for (final c in await txn.query(
                _syncChanges,
                where: 'op_id = ?',
                whereArgs: [op],
                orderBy: 'ord',
              ))
                _syncWire(c),
            ],
        };
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
        await txn.delete(_syncChanges, where: 'op_id NOT IN (${ownLater.map((_) => '?').join(',').ifEmpty("''")})', whereArgs: ownLater);
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
          final changes = ownChanges[op]!;
          await txn.delete(_syncChanges, where: 'op_id = ?', whereArgs: [op]);
          await _syncApplyChanges(txn, op, null, changes);
          final seq = (await txn.query(_syncLog, columns: ['seq'], where: 'op_id = ?', whereArgs: [op])).singleOrNull?['seq'];
          await txn.rawUpdate(
            'UPDATE $_syncRows SET pending_op = ? WHERE pending_op IS NULL AND tbl || pk IN (SELECT tbl || pk FROM $_syncChanges WHERE op_id = ?)',
            [seq == null ? op : null, op],
          );
        }
        await _syncPut(txn, 'resync_pending', '0');
      }, exclusive: true);

  // ── helpers ───────────────────────────────────────────────────────────────

  Future<T> _transactionRaw<T>(
    Future<T> Function(Transaction) run, {
    bool exclusive = false,
  }) => _io.synchronized(() => _db.transaction(run, exclusive: exclusive));
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
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
  final derived = _syncDerived[c['tbl']] ?? const <String>{};
  final old = jsonDecode(c['old_row'] as String) as Map;
  final now = jsonDecode(c['new_row'] as String) as Map;
  return now.keys.any((k) => !derived.contains(k) && now[k] != old[k]);
}

String? _syncBranch(List<Map<String, Object?>> changes) {
  for (final c in changes) {
    final row = jsonDecode((c['new_row'] ?? c['old_row']) as String) as Map;
    final branch = row['branch_id'];
    if (branch is String) return branch;
  }
  return null;
}

_SyncAggregate? _syncAggregateFor(String child) {
  for (final agg in _syncAggregates) {
    if (agg.child == child) return agg;
  }
  return null;
}

String _syncParentKey(_SyncAggregate agg, Map row) =>
    jsonEncode([for (final c in agg.keys.keys) row[c]]);

String _syncParentKeyOfParent(_SyncAggregate agg, Map row) =>
    jsonEncode([for (final p in agg.keys.values) row[p]]);

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
