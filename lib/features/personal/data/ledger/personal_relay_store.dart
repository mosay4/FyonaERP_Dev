import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'personal_ledger_database.dart';
import 'personal_relay_config.dart';
import 'personal_relay_crypto.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Personal device relay — the ledger side (Stage 3).
//
// Every Personal ledger commit records ONE operation in the same SQLite
// transaction (PersonalRelayCapture). An operation is a list of changes:
//
//   {"t": entity type | "_kv" | "_rate" | "_acct", "id": row id,
//    "k": "i" (created) | "u" (updated) | "d" (deleted),
//    "data": the row after the write (i/u),
//    "f": [fields the write changed] (u), "d": {counter: delta} (u)}
//
// The relay stamps operations with the user's arrival sequence; every device
// applies them in that order with the same rules, so all converge:
//
// * Counters (account balance, goal current_amount, debt paid, budget spent)
//   travel as deltas: «+50 here» is +50 on every device, never «now 150».
//   A row created elsewhere arrives with its full value; a create of a row
//   this device already has never adds the value a second time.
// * Other fields: per field, the last writer by sequence wins; a change made
//   here that is not sequenced yet is later than everything sequenced.
// * A delete leaves a tombstone that wins over later updates of the row.
// * Applying is idempotent by operation id and never records an operation.
// ─────────────────────────────────────────────────────────────────────────────

/// Counter fields per entity type: merged as deltas.
const Map<String, List<String>> personalRelayCounters = {
  'personal_bank_account': ['balance'],
  'personal_savings_goal': ['current_amount'],
  'personal_debt': ['paid'],
  'personal_budget': ['spent'],
};

/// Key/value user data that travels (financial trees and their reports).
/// Account types travel as their own `_acct` changes; device flags never.
bool personalRelayKvKey(String key) =>
    key == 'financial_trees_v1' ||
    key == 'financial_tree_reports_v1' ||
    key.startsWith('financial_tree_nodes_');

const _acctTypesKey = 'bank_account_types_v3';
const _acctAtKey = 'bank_account_types_v3_at';

/// Device-local metadata of a row (server version of the old sync): never
/// sent, never overwritten by another device.
const _localOnlyFields = {'_sync_version'};

/// The one field of a key/value entry or a rate.
const _value = 'v';
const _pushedKeep = Duration(days: 30);

double? _num(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// Money is summed at 1e-6: the same deltas give the same value on every
/// device whatever the order.
double _r6(double v) => (v * 1e6).roundToDouble() / 1e6;

Map<String, dynamic>? _decode(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final v = jsonDecode(raw);
    return v is Map ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _wire(Map<String, dynamic> row) =>
    Map<String, dynamic>.from(row)
      ..removeWhere((k, _) => _localOnlyFields.contains(k));

/// The fields of [row] that are written last-writer-wins.
List<String> _ownFields(String type, Iterable<String> keys) {
  final counters = personalRelayCounters[type] ?? const <String>[];
  return [
    for (final k in keys)
      if (!counters.contains(k) && !_localOnlyFields.contains(k)) k,
  ];
}

/// Recomputes fields derived from counters, the same way on every device.
void _derive(String type, Map<String, dynamic> row) {
  if (type == 'personal_savings_goal') {
    final target = _num(row['target_amount']);
    final current = _num(row['current_amount']);
    if (target != null && current != null && target > 0) {
      row['is_completed'] = current >= target;
    }
  } else if (type == 'personal_debt') {
    final amount = _num(row['amount']);
    final paid = _num(row['paid']);
    if (amount != null && paid != null) {
      final rest = _r6(amount - paid);
      row['remaining'] = rest <= 0 ? 0.0 : rest;
      if (amount > 0 && rest <= 0) {
        row['is_paid'] = true;
        row['status'] = 'paid';
      }
    }
  }
}

/// Per-row order: the sequence each field was last written at, the fields
/// an unsent operation of this device owns, and the tombstone.
final class _Clock {
  _Clock(this.type, this.id);

  final String type;
  final String id;
  int? lastSeq;
  Map<String, int> fields = {};
  Map<String, String> pending = {};
  bool deleted = false;

  static const _table = PersonalLedgerDatabase.relayRows;

  int seqOf(String f) => fields[f] ?? lastSeq ?? 0;

  /// A remote write of [f] at [seq] loses: this device's unsent change is
  /// later, or a later write was already applied here.
  bool stale(String f, int? seq) =>
      pending.containsKey(f) || (seq != null && seqOf(f) > seq);

  void applied(String f, int? seq) {
    if (seq != null && seq > seqOf(f)) fields[f] = seq;
  }

  static Future<_Clock> load(
    DatabaseExecutor ex,
    String type,
    String id,
  ) async {
    final c = _Clock(type, id);
    final r = (await ex.rawQuery(
      'SELECT last_seq, fields, pending, deleted FROM $_table WHERE entity_type = ? AND id = ?',
      [type, id],
    )).firstOrNull;
    if (r == null) return c;
    c.lastSeq = (r['last_seq'] as num?)?.toInt();
    c.deleted = r['deleted'] == 1;
    c.fields = {
      for (final e in (_decode(r['fields']) ?? const {}).entries)
        e.key: (_num(e.value) ?? 0).toInt(),
    };
    c.pending = {
      for (final e in (_decode(r['pending']) ?? const {}).entries)
        e.key: '${e.value}',
    };
    return c;
  }

  Future<void> save(DatabaseExecutor ex) => ex.rawInsert(
    'INSERT OR REPLACE INTO $_table (entity_type, id, last_seq, fields, pending, deleted) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [
      type,
      id,
      lastSeq,
      fields.isEmpty ? null : jsonEncode(fields),
      pending.isEmpty ? null : jsonEncode(pending),
      deleted ? 1 : 0,
    ],
  );
}

final class _Row {
  _Row(this.type, this.id, this.before);
  final String type;
  final String id;
  final Map<String, dynamic>? before;
  Map<String, dynamic>? now;
  bool written = false;
}

/// Collects the changes of one ledger transaction into one relay operation.
/// Null (no capture) when the relay is off.
final class PersonalRelayCapture {
  PersonalRelayCapture._();

  static PersonalRelayCapture? begin() =>
      PersonalRelayConfig.enabled ? PersonalRelayCapture._() : null;

  /// Fires after a commit recorded an operation (the runtime sends soon).
  static final localWrites = StreamController<String>.broadcast();

  /// Upper size of one operation's plaintext (the relay takes 16 MiB).
  static int maxOpBytes = 4 * 1024 * 1024;

  final _rows = <String, _Row>{};
  final _other = <String, Map<String, Object?>>{};

  bool get isEmpty => _rows.isEmpty && _other.isEmpty;

  Future<_Row> _track(DatabaseExecutor tx, String type, String id) async {
    final key = '$type\u0000$id';
    final known = _rows[key];
    if (known != null) return known;
    final found = await tx.rawQuery(
      'SELECT data_json FROM ${PersonalLedgerDatabase.rows} '
      'WHERE entity_type = ? AND id = ? AND deleted = 0 LIMIT 1',
      [type, id],
    );
    return _rows[key] = _Row(
      type,
      id,
      found.isEmpty ? null : _decode(found.first['data_json']),
    );
  }

  /// Call BEFORE writing [row] as the new value of (type, id).
  Future<void> put(
    DatabaseExecutor tx,
    String type,
    String id,
    Map<String, dynamic> row,
  ) async {
    final r = await _track(tx, type, id);
    r
      ..now = Map<String, dynamic>.from(row)
      ..written = true;
  }

  /// Call BEFORE deleting (type, id).
  Future<void> drop(DatabaseExecutor tx, String type, String id) async {
    final r = await _track(tx, type, id);
    r
      ..now = null
      ..written = true;
  }

  /// A row only this device has, sent to the others as new.
  void _adopt(String type, String id, Map<String, dynamic> row) {
    _rows['$type\u0000$id'] = _Row(type, id, null)
      ..now = row
      ..written = true;
  }

  /// A key/value entry written ([type]/[value]) or removed (null).
  void kv(String key, {String? type, String? value}) {
    if (!personalRelayKvKey(key)) return;
    _other['_kv\u0000$key'] = {
      't': '_kv',
      'id': key,
      'k': type == null ? 'd' : 'u',
      if (type != null) 'data': {'type': type, 'value': value},
    };
  }

  /// An exchange rate set (or removed with null).
  void rate(String from, String to, double? rate) {
    final id = '${from.toUpperCase()}>${to.toUpperCase()}';
    _other['_rate\u0000$id'] = {
      't': '_rate',
      'id': id,
      'k': rate == null ? 'd' : 'u',
      'data': {'from': from, 'to': to, 'rate': ?rate},
    };
  }

  /// A bank account type chosen ([type]) or forgotten (null) at [at] ms.
  void accountType(String accountId, String? type, int at) {
    _other['_acct\u0000$accountId'] = {
      't': '_acct',
      'id': accountId,
      'k': type == null ? 'd' : 'u',
      'data': {'t': ?type, 'at': at},
    };
  }

  /// The changes, each with the fields it makes «ours» until sequenced. A
  /// change that only moved counters (a balance after an expense) owns
  /// nothing: another device may still rename the account meanwhile.
  List<(Map<String, Object?>, List<String>)> _changes() {
    final out = <(Map<String, Object?>, List<String>)>[];
    for (final r in _rows.values) {
      if (!r.written) continue;
      final now = r.now;
      final before = r.before;
      if (now == null) {
        if (before == null) continue; // never existed
        out.add(({'t': r.type, 'id': r.id, 'k': 'd'}, const []));
        continue;
      }
      final data = _wire(now);
      if (before == null) {
        out.add((
          {'t': r.type, 'id': r.id, 'k': 'i', 'data': data},
          _ownFields(r.type, data.keys),
        ));
        continue;
      }
      final old = _wire(before);
      final delta = <String, double>{};
      for (final c in personalRelayCounters[r.type] ?? const <String>[]) {
        final n = _num(now[c]);
        if (n == null) continue;
        final d = _r6(n - (_num(before[c]) ?? 0));
        if (d != 0) delta[c] = d;
      }
      final changed = [
        for (final k in _ownFields(r.type, {...data.keys, ...old.keys}))
          if (jsonEncode(data[k]) != jsonEncode(old[k])) k,
      ];
      if (delta.isEmpty && changed.isEmpty) continue; // nothing changed
      out.add((
        {
          't': r.type,
          'id': r.id,
          'k': 'u',
          'data': data,
          'f': changed,
          if (delta.isNotEmpty) 'd': delta,
        },
        changed,
      ));
    }
    for (final c in _other.values) {
      out.add((c, c['t'] == '_acct' ? const <String>[] : const [_value]));
    }
    return out;
  }

  /// Writes the operation into the relay outbox, inside the same
  /// transaction as the write. Returns its id (null: nothing changed).
  ///
  /// A very large commit (a restore) is split into several operations of at
  /// most [maxOpBytes] each, all written in this transaction.
  Future<String?> seal(DatabaseExecutor tx) async {
    final changes = _changes();
    if (changes.isEmpty) return null;
    final chunks = <List<(Map<String, Object?>, List<String>)>>[[]];
    var size = 0;
    for (final change in changes) {
      final n = jsonEncode(change.$1).length;
      if (chunks.last.isNotEmpty && size + n > maxOpBytes) {
        chunks.add([]);
        size = 0;
      }
      chunks.last.add(change);
      size += n;
    }
    String? first;
    var now = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final chunk in chunks) {
      final opId = const Uuid().v4();
      first ??= opId;
      await tx.insert(PersonalLedgerDatabase.relayOutbox, {
        'op_id': opId,
        'payload': jsonEncode({
          'v': 1,
          'id': opId,
          'us': now,
          'c': [for (final (c, _) in chunk) c],
        }),
        'created_us': now++,
      });
      for (final (c, owned) in chunk) {
        final type = c['t'] as String;
        if (type == '_acct') continue; // ordered by its own time stamp
        final deleted = c['k'] == 'd' && !type.startsWith('_');
        if (!deleted && owned.isEmpty) continue;
        final clock = await _Clock.load(tx, type, '${c['id']}');
        if (deleted) clock.deleted = true;
        for (final f in owned) {
          clock.pending[f] = opId;
        }
        await clock.save(tx);
      }
    }
    final id = first!;
    scheduleMicrotask(() => localWrites.add(id));
    return id;
  }
}

/// One received relay item waiting here (for a key or a snapshot).
typedef PersonalRelayParked = ({
  String id,
  int? seq,
  String kind,
  String? author,
  Uint8List payload,
});

/// Relay state and the apply/snapshot rules on one Personal ledger.
final class PersonalRelayStore {
  PersonalRelayStore(this.db);

  final PersonalLedgerDatabase db;

  static const _meta = PersonalLedgerDatabase.meta;
  static const _outbox = PersonalLedgerDatabase.relayOutbox;
  static const _clock = PersonalLedgerDatabase.relayRows;
  static const _parked = PersonalLedgerDatabase.relayParked;
  static const _log = PersonalLedgerDatabase.syncLog;
  static const _rows = PersonalLedgerDatabase.rows;
  static const _kv = PersonalLedgerDatabase.kv;
  static const _rates = 'personal_exchange_rates';

  // ── state ────────────────────────────────────────────────────────────────

  static Future<String?> _get(DatabaseExecutor ex, String key) async {
    final rows = await ex.rawQuery('SELECT value FROM $_meta WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<void> _put(DatabaseExecutor ex, String key, String? value) =>
      value == null
      ? ex.rawDelete('DELETE FROM $_meta WHERE key = ?', [key])
      : ex.rawInsert(
          'INSERT OR REPLACE INTO $_meta (key, value) VALUES (?, ?)',
          [key, value],
        );

  Future<String?> read(String key) => _get(db.rawExecutor, 'relay_$key');

  Future<void> write(String key, String? value) =>
      db.transaction((tx) => _put(tx, 'relay_$key', value));

  Future<int> _int(String key) async =>
      int.tryParse(await read(key) ?? '') ?? 0;

  /// This install's stable replica id for this user (kept in the ledger).
  Future<String> replicaId() => db.transaction((tx) async {
    final known = await _get(tx, 'relay_replica');
    if (known != null) return known;
    final id = const Uuid().v4();
    await _put(tx, 'relay_replica', id);
    return id;
  });

  /// Highest sequence applied from other devices.
  Future<int> head() => _int('head');

  /// Operations up to this sequence are contained in the applied snapshot.
  Future<int> floor() => _int('floor');

  /// '' (following the log), 'waiting' (for a snapshot) or 'gave_up' (no
  /// device answered in time; going on with what is here).
  Future<String> resync() async => await read('resync') ?? '';

  Future<int> resyncSinceUs() => _int('resync_us');

  Future<void> setResync(String state, {int? sinceUs}) =>
      db.transaction((tx) async {
        await _put(tx, 'relay_resync', state);
        if (sinceUs != null) await _put(tx, 'relay_resync_us', '$sinceUs');
      });

  // ── keys ─────────────────────────────────────────────────────────────────

  /// The user's data keys this device holds (kid → 32-byte key).
  Future<Map<String, List<int>>> keyring() async {
    final raw = _decode(await read('keys')) ?? const {};
    return {for (final e in raw.entries) e.key: base64Decode('${e.value}')};
  }

  Future<String?> currentKid() => read('kid');

  /// Adds keys (from a grant, or a new key of this device). The current key
  /// only changes when this device had none.
  Future<void> addKeys(Map<String, List<int>> keys, {String? current}) =>
      db.transaction((tx) async {
        final raw =
            _decode(await _get(tx, 'relay_keys')) ?? <String, dynamic>{};
        for (final e in keys.entries) {
          raw[e.key] = base64Encode(e.value);
        }
        await _put(tx, 'relay_keys', jsonEncode(raw));
        final kid = await _get(tx, 'relay_kid');
        final next = kid ?? current ?? (keys.isEmpty ? null : keys.keys.first);
        if (next != null) await _put(tx, 'relay_kid', next);
      });

  /// Creates this user's first data key here (no other device holds one).
  Future<void> createDataKey() async {
    final k = PersonalRelayCrypto.newDataKey();
    await addKeys({k.kid: k.key}, current: k.kid);
  }

  /// This device's X25519 key pair for receiving the data key.
  Future<({Uint8List priv, Uint8List pub})> deviceKeys() async {
    final priv = await read('dev_priv');
    if (priv != null) {
      final p = base64Decode(priv);
      return (priv: p, pub: await PersonalRelayCrypto.devicePublic(p));
    }
    final made = await PersonalRelayCrypto.newDeviceKeys();
    await write('dev_priv', base64Encode(made.priv));
    return made;
  }

  // ── outbox ───────────────────────────────────────────────────────────────

  Future<List<({String id, String payload})>> unsent({int limit = 100}) async =>
      [
        for (final r in await db.rawQuery(
          'SELECT op_id, payload FROM $_outbox WHERE seq IS NULL '
          'ORDER BY created_us, op_id LIMIT ?',
          [limit],
        ))
          (id: r['op_id'] as String, payload: r['payload'] as String),
      ];

  Future<bool> hasUnsent() async => (await db.rawQuery(
    'SELECT 1 FROM $_outbox WHERE seq IS NULL LIMIT 1',
  )).isNotEmpty;

  /// The relay accepted these operations with these sequence numbers.
  Future<void> pushed(Map<String, int> sequenced) => db.transaction((tx) async {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final MapEntry(key: op, value: seq) in sequenced.entries) {
      await tx.rawUpdate(
        'UPDATE $_outbox SET seq = ?, pushed_us = ? WHERE op_id = ? AND seq IS NULL',
        [seq, now, op],
      );
      await tx.rawInsert(
        'INSERT OR IGNORE INTO $_log (op_id, seq) VALUES (?, ?)',
        [op, seq],
      );
      for (final r in await tx.rawQuery(
        'SELECT entity_type, id FROM $_clock WHERE pending LIKE ?',
        ['%"$op"%'],
      )) {
        final clock = await _Clock.load(
          tx,
          r['entity_type'] as String,
          r['id'] as String,
        );
        for (final f in [...clock.pending.keys]) {
          if (clock.pending[f] != op) continue;
          clock.pending.remove(f);
          clock.applied(f, seq);
        }
        await clock.save(tx);
      }
    }
    // Own operations are kept a while, in case a snapshot from another device
    // arrives without them and they must be put back on top.
    await tx.rawDelete(
      'DELETE FROM $_outbox WHERE seq IS NOT NULL AND pushed_us < ?',
      [now - _pushedKeep.inMicroseconds],
    );
  });

  // ── parked items ─────────────────────────────────────────────────────────

  Future<void> park(List<PersonalRelayParked> items) => db.transaction((
    tx,
  ) async {
    for (final i in items) {
      await tx.rawInsert(
        'INSERT OR IGNORE INTO $_parked (item_id, seq, kind, author, payload) '
        'VALUES (?, ?, ?, ?, ?)',
        [i.id, i.seq, i.kind, i.author, base64Encode(i.payload)],
      );
    }
  });

  /// Snapshots first, then operations in sequence order.
  Future<List<PersonalRelayParked>> parked() async => [
    for (final r in await db.rawQuery(
      'SELECT item_id, seq, kind, author, payload FROM $_parked '
      "ORDER BY kind = 'snapshot' DESC, COALESCE(seq, 0), ord",
    ))
      (
        id: r['item_id'] as String,
        seq: (r['seq'] as num?)?.toInt(),
        kind: r['kind'] as String,
        author: r['author'] as String?,
        payload: base64Decode(r['payload'] as String),
      ),
  ];

  Future<bool> hasParked() async =>
      (await db.rawQuery('SELECT 1 FROM $_parked LIMIT 1')).isNotEmpty;

  Future<void> unpark(String id) => db.transaction(
    (tx) => tx.rawDelete('DELETE FROM $_parked WHERE item_id = ?', [id]),
  );

  // ── apply ────────────────────────────────────────────────────────────────

  Future<bool> isApplied(String opId, int? seq) async {
    if (seq != null && seq <= await floor()) return true;
    return (await db.rawQuery('SELECT 1 FROM $_log WHERE op_id = ?', [
      opId,
    ])).isNotEmpty;
  }

  /// Applies one operation from another device. False: already here
  /// (duplicate id, or contained in the applied snapshot).
  Future<bool> applyOp({
    required String opId,
    required int? seq,
    required Map<String, dynamic> payload,
    required int namespace,
  }) => db.transaction((tx) async {
    final floor = int.tryParse(await _get(tx, 'relay_floor') ?? '') ?? 0;
    if (seq != null && seq <= floor) return false;
    if ((await tx.rawQuery('SELECT 1 FROM $_log WHERE op_id = ?', [
      opId,
    ])).isNotEmpty) {
      return false;
    }
    await _applyChanges(tx, _changesOf(payload), seq, namespace);
    if (seq != null) {
      await tx.rawInsert(
        'INSERT OR IGNORE INTO $_log (op_id, seq) VALUES (?, ?)',
        [opId, seq],
      );
      final head = int.tryParse(await _get(tx, 'relay_head') ?? '') ?? 0;
      if (seq > head) await _put(tx, 'relay_head', '$seq');
    }
    return true;
  });

  static List<Map<String, dynamic>> _changesOf(Map payload) => [
    for (final c in payload['c'] as List? ?? const [])
      if (c is Map && c['t'] is String && c['id'] != null)
        Map<String, dynamic>.from(c),
  ];

  /// The fields a change writes last-writer-wins.
  static List<String> _fieldsOf(Map<String, dynamic> c) {
    final type = c['t'] as String;
    if (type.startsWith('_')) return const [_value];
    if (c['k'] == 'u' && c['f'] is List) {
      return _ownFields(type, [for (final f in c['f'] as List) '$f']);
    }
    final data = c['data'];
    return data is Map
        ? _ownFields(type, data.keys.map((k) => '$k'))
        : const [];
  }

  Future<void> _applyChanges(
    Transaction tx,
    List<Map<String, dynamic>> changes,
    int? seq,
    int namespace, {
    Set<String> skipRows = const {},
  }) async {
    for (final c in changes) {
      final type = c['t'] as String;
      final id = '${c['id']}';
      final kind = '${c['k']}';
      final data = c['data'] is Map
          ? Map<String, dynamic>.from(c['data'] as Map)
          : null;
      if (type == '_acct') {
        await _applyAccountType(tx, id, kind, data);
        continue;
      }
      if (skipRows.contains('$type\u0000$id')) continue;
      final clock = await _Clock.load(tx, type, id);
      if (!type.startsWith('_')) {
        if (clock.deleted) continue; // tombstone wins
        await _applyRow(tx, clock, c, kind, data, seq, namespace);
        await clock.save(tx);
        continue;
      }
      if (clock.stale(_value, seq)) continue;
      if (type == '_kv') await _applyKv(tx, id, kind, data);
      if (type == '_rate') await _applyRate(tx, id, kind, data, namespace);
      clock.applied(_value, seq);
      await clock.save(tx);
    }
  }

  Future<void> _applyRow(
    Transaction tx,
    _Clock clock,
    Map<String, dynamic> c,
    String kind,
    Map<String, dynamic>? data,
    int? seq,
    int namespace,
  ) async {
    final type = clock.type;
    final id = clock.id;
    if (kind == 'd') {
      await tx.rawDelete(
        'DELETE FROM $_rows WHERE entity_type = ? AND id = ?',
        [type, id],
      );
      clock.deleted = true;
      if (seq != null && seq > (clock.lastSeq ?? 0)) clock.lastSeq = seq;
      return;
    }
    if (data == null) return;
    final found = (await tx.rawQuery(
      'SELECT seq, data_json FROM $_rows WHERE entity_type = ? AND id = ? AND deleted = 0 '
      'ORDER BY (user_id = ?) DESC LIMIT 1',
      [type, id, namespace],
    )).firstOrNull;
    final current = found == null ? null : _decode(found['data_json']);
    final now = DateTime.now().microsecondsSinceEpoch;
    if (found == null || current == null) {
      if (found != null) {
        await tx.rawDelete('DELETE FROM $_rows WHERE seq = ?', [found['seq']]);
      }
      // New here: the row as the author has it (counters included).
      final row = _wire(data);
      _derive(type, row);
      await tx.insert(_rows, {
        'user_id': namespace,
        'entity_type': type,
        'id': id,
        'data_json': jsonEncode(row),
        'updated_us': now,
        'deleted': 0,
        'version': 0,
      });
      for (final f in _ownFields(type, row.keys)) {
        clock.applied(f, seq);
      }
      return;
    }
    final row = Map<String, dynamic>.from(current);
    for (final f in _fieldsOf(c)) {
      if (clock.stale(f, seq)) continue;
      if (data.containsKey(f)) {
        row[f] = data[f];
      } else {
        row.remove(f);
      }
      clock.applied(f, seq);
    }
    // Counters keep this device's value and move by the delta only (a
    // create of a row already here adds nothing).
    final delta = c['d'] is Map
        ? Map<String, dynamic>.from(c['d'] as Map)
        : const {};
    for (final f in personalRelayCounters[type] ?? const <String>[]) {
      final d = kind == 'u' ? _num(delta[f]) : null;
      if (d == null) continue;
      row[f] = _r6((_num(current[f]) ?? 0) + d);
    }
    _derive(type, row);
    await tx.rawUpdate(
      'UPDATE $_rows SET data_json = ?, updated_us = ? WHERE seq = ?',
      [jsonEncode(row), now, found['seq']],
    );
  }

  static Future<void> _applyKv(
    Transaction tx,
    String key,
    String kind,
    Map<String, dynamic>? data,
  ) async {
    if (!personalRelayKvKey(key)) return;
    if (kind == 'd') {
      await tx.rawDelete('DELETE FROM $_kv WHERE key = ?', [key]);
      return;
    }
    final type = '${data?['type']}';
    if (!const {
      'string',
      'bool',
      'int',
      'double',
      'string-list',
    }.contains(type)) {
      return;
    }
    await tx.rawInsert(
      'INSERT OR REPLACE INTO $_kv (key, type, value, updated_us) VALUES (?, ?, ?, ?)',
      [
        key,
        type,
        '${data?['value'] ?? ''}',
        DateTime.now().toUtc().microsecondsSinceEpoch,
      ],
    );
  }

  static Future<void> _applyRate(
    Transaction tx,
    String id,
    String kind,
    Map<String, dynamic>? data,
    int namespace,
  ) async {
    final from = '${data?['from'] ?? id.split('>').first}';
    final to = '${data?['to'] ?? (id.contains('>') ? id.split('>').last : '')}';
    if (from.isEmpty || to.isEmpty) return;
    if (kind == 'd') {
      await tx.rawDelete(
        'DELETE FROM $_rates WHERE from_currency = ? AND to_currency = ?',
        [from, to],
      );
      return;
    }
    final rate = _num(data?['rate']);
    if (rate == null) return;
    final now = DateTime.now().toIso8601String();
    final n = await tx.rawUpdate(
      'UPDATE $_rates SET rate = ?, updated_at = ? '
      'WHERE from_currency = ? AND to_currency = ?',
      [rate, now, from, to],
    );
    if (n == 0) {
      await tx.insert(_rates, {
        'user_id': namespace,
        'from_currency': from,
        'to_currency': to,
        'rate': rate,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  static Future<(Map<String, String>, Map<String, int>)> _accountTypes(
    DatabaseExecutor tx,
  ) async {
    Future<Map<String, dynamic>> read(String key) async {
      final rows = await tx.rawQuery('SELECT value FROM $_kv WHERE key = ?', [
        key,
      ]);
      return rows.isEmpty
          ? const {}
          : (_decode(rows.first['value']) ?? const {});
    }

    final types = await read(_acctTypesKey);
    final at = await read(_acctAtKey);
    return (
      {for (final e in types.entries) e.key: '${e.value}'},
      {for (final e in at.entries) e.key: (_num(e.value) ?? 0).toInt()},
    );
  }

  static Future<void> _writeAccountTypes(
    DatabaseExecutor tx,
    Map<String, String> types,
    Map<String, int> at,
  ) async {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final (key, value) in [
      (_acctTypesKey, jsonEncode(types)),
      (_acctAtKey, jsonEncode(at)),
    ]) {
      await tx.rawInsert(
        "INSERT OR REPLACE INTO $_kv (key, type, value, updated_us) VALUES (?, 'string', ?, ?)",
        [key, value, now],
      );
    }
  }

  /// Account types: the later choice (by the time it was made) wins — the
  /// same rule as the older peer-relay merge.
  static Future<bool> _applyAccountType(
    Transaction tx,
    String accountId,
    String kind,
    Map<String, dynamic>? data,
  ) async {
    final when = (_num(data?['at']) ?? 0).toInt();
    final t = data?['t']?.toString();
    if (kind != 'd' && t != 'checking' && t != 'savings') return false;
    final (types, at) = await _accountTypes(tx);
    final known = types.containsKey(accountId);
    if (known && (at[accountId] ?? 0) >= when) return false;
    if (kind == 'd') {
      if (!known) return false;
      types.remove(accountId);
      at.remove(accountId);
    } else {
      types[accountId] = t!;
      at[accountId] = when;
    }
    await _writeAccountTypes(tx, types, at);
    return true;
  }

  // ── snapshot ─────────────────────────────────────────────────────────────

  /// Everything this device holds, for another device of the same user.
  /// Null while anything made here is unsent or anything received waits.
  Future<Map<String, Object?>?> snapshot() async {
    if (await hasUnsent() || await hasParked()) return null;
    final head = await this.head();
    final clocks = <String, _Clock>{};
    for (final r in await db.rawQuery('SELECT entity_type, id FROM $_clock')) {
      final c = await _Clock.load(
        db.rawExecutor,
        r['entity_type'] as String,
        r['id'] as String,
      );
      clocks['${c.type}\u0000${c.id}'] = c;
    }
    Map<String, Object?> order(String type, String id) {
      final c = clocks['$type\u0000$id'];
      return {'ls': c?.lastSeq, 'fs': c?.fields ?? const <String, int>{}};
    }

    final rows = <String, Map<String, Object?>>{};
    for (final r in await db.rawQuery(
      'SELECT entity_type, id, data_json FROM $_rows WHERE deleted = 0 ORDER BY seq',
    )) {
      final data = _decode(r['data_json']);
      if (data == null) continue;
      final type = r['entity_type'] as String;
      final id = r['id'] as String;
      rows['$type\u0000$id'] = {
        't': type,
        'id': id,
        'data': data,
        ...order(type, id),
      };
    }
    final kv = [
      for (final r in await db.rawQuery(
        'SELECT key, type, value FROM $_kv ORDER BY key',
      ))
        if (personalRelayKvKey(r['key'] as String))
          {
            'key': r['key'],
            'type': r['type'],
            'value': r['value'],
            ...order('_kv', r['key'] as String),
          },
    ];
    final rates = <String, Map<String, Object?>>{};
    for (final r in await db.rawQuery(
      'SELECT from_currency, to_currency, rate FROM $_rates ORDER BY id',
    )) {
      final id = _rateId(r['from_currency'], r['to_currency']);
      rates[id] = {
        'from': r['from_currency'],
        'to': r['to_currency'],
        'rate': r['rate'],
        ...order('_rate', id),
      };
    }
    final (types, at) = await _accountTypes(db.rawExecutor);
    return {
      'v': 1,
      'seq': head,
      'own': [
        for (final r in await db.rawQuery(
          'SELECT op_id, seq FROM $_outbox WHERE seq > ?',
          [head],
        ))
          {'id': r['op_id'], 'seq': r['seq']},
      ],
      'rows': rows.values.toList(),
      'tomb': [
        for (final c in clocks.values)
          if (c.deleted) {'t': c.type, 'id': c.id, 'ls': c.lastSeq},
      ],
      'kv': kv,
      'rates': rates.values.toList(),
      'acct': {
        for (final e in types.entries)
          e.key: {'t': e.value, 'at': at[e.key] ?? 0},
      },
    };
  }

  static String _rateId(Object? from, Object? to) =>
      '${'$from'.toUpperCase()}>${'$to'.toUpperCase()}';

  static _Clock _clockFrom(String type, String id, Map r) {
    final c = _Clock(type, id)..lastSeq = (_num(r['ls']))?.toInt();
    final fs = r['fs'];
    if (fs is Map) {
      c.fields = {
        for (final e in fs.entries) '${e.key}': (_num(e.value) ?? 0).toInt(),
      };
    }
    return c;
  }

  /// Takes another device's snapshot: its rows replace ours, rows only this
  /// device has are kept (and sent to the others), operations of this device
  /// the snapshot does not contain are put back on top. Later operations up
  /// to the snapshot's sequence are skipped.
  ///
  /// [fill]: this device already went on without the snapshot (no device
  /// answered in time) and has applied later operations since — then the
  /// snapshot only adds what is missing here (rows, entries, rates) and its
  /// deletions; nothing here is replaced.
  Future<void> applySnapshot(
    Map snapshot, {
    required int namespace,
    bool fill = false,
  }) => db.transaction((tx) async {
    final floor = (_num(snapshot['seq']) ?? 0).toInt();
    final contained = <String, int>{
      for (final o in snapshot['own'] as List? ?? const [])
        if (o is Map) '${o['id']}': (_num(o['seq']) ?? 0).toInt(),
    };
    // Own operations the snapshot does not contain, oldest first.
    final own = [
      if (!fill)
        for (final r in await tx.rawQuery(
          'SELECT op_id, payload, seq FROM $_outbox ORDER BY created_us, op_id',
        ))
          if (!(r['seq'] != null &&
              ((r['seq'] as num).toInt() <= floor ||
                  contained.containsKey(r['op_id']))))
            r,
    ];
    final ownRows = <String>{
      for (final o in own)
        for (final c in _changesOf(_decode(o['payload']) ?? const {}))
          '${c['t']}\u0000${c['id']}',
    };
    final snapRows = <String, Map>{
      for (final r in snapshot['rows'] as List? ?? const [])
        if (r is Map && r['t'] is String && r['data'] is Map)
          '${r['t']}\u0000${r['id']}': r,
    };
    final tombs = <String, Map>{
      for (final r in snapshot['tomb'] as List? ?? const [])
        if (r is Map && r['t'] is String) '${r['t']}\u0000${r['id']}': r,
    };
    final emit = PersonalRelayCapture._();
    final localOnly = <String>{};
    for (final r in await tx.rawQuery(
      'SELECT entity_type, id, data_json FROM $_rows WHERE deleted = 0 ORDER BY seq',
    )) {
      final type = r['entity_type'] as String;
      final id = r['id'] as String;
      final key = '$type\u0000$id';
      if (snapRows.containsKey(key) || tombs.containsKey(key)) continue;
      localOnly.add(key);
      final data = _decode(r['data_json']);
      // Only here: the other devices learn it as a new row.
      if (data != null && !ownRows.contains(key)) emit._adopt(type, id, data);
    }
    if (!fill) await tx.rawDelete('DELETE FROM $_clock');
    final now = DateTime.now().microsecondsSinceEpoch;
    for (final r in snapRows.values) {
      final type = r['t'] as String;
      final id = '${r['id']}';
      final data = Map<String, dynamic>.from(r['data'] as Map);
      if (fill &&
          ((await _Clock.load(tx, type, id)).deleted ||
              (await tx.rawQuery(
                'SELECT 1 FROM $_rows WHERE entity_type = ? AND id = ? LIMIT 1',
                [type, id],
              )).isNotEmpty)) {
        continue;
      }
      final n = await tx.rawUpdate(
        'UPDATE $_rows SET data_json = ?, updated_us = ? WHERE entity_type = ? AND id = ?',
        [jsonEncode(data), now, type, id],
      );
      if (n == 0) {
        await tx.insert(_rows, {
          'user_id': namespace,
          'entity_type': type,
          'id': id,
          'data_json': jsonEncode(data),
          'updated_us': now,
          'deleted': 0,
          'version': 0,
        });
      }
      await _clockFrom(type, id, r).save(tx);
    }
    for (final r in tombs.values) {
      final type = r['t'] as String;
      final id = '${r['id']}';
      await tx.rawDelete(
        'DELETE FROM $_rows WHERE entity_type = ? AND id = ?',
        [type, id],
      );
      await (_clockFrom(type, id, r)..deleted = true).save(tx);
    }
    // Key/value data.
    final snapKv = <String>{};
    for (final r in snapshot['kv'] as List? ?? const []) {
      if (r is! Map) continue;
      final key = '${r['key']}';
      snapKv.add(key);
      if (fill &&
          (await tx.rawQuery('SELECT 1 FROM $_kv WHERE key = ?', [
            key,
          ])).isNotEmpty) {
        continue;
      }
      await _applyKv(tx, key, 'u', {'type': r['type'], 'value': r['value']});
      await _clockFrom('_kv', key, r).save(tx);
    }
    for (final r in await tx.rawQuery('SELECT key, type, value FROM $_kv')) {
      final key = r['key'] as String;
      if (personalRelayKvKey(key) &&
          !snapKv.contains(key) &&
          !ownRows.contains('_kv\u0000$key')) {
        emit.kv(key, type: r['type'] as String, value: r['value'] as String);
      }
    }
    // Exchange rates.
    final snapRates = <String>{};
    for (final r in snapshot['rates'] as List? ?? const []) {
      if (r is! Map) continue;
      final id = _rateId(r['from'], r['to']);
      snapRates.add(id);
      if (fill &&
          (await tx.rawQuery(
            'SELECT 1 FROM $_rates WHERE from_currency = ? AND to_currency = ? LIMIT 1',
            [r['from'], r['to']],
          )).isNotEmpty) {
        continue;
      }
      await _applyRate(tx, id, 'u', Map<String, dynamic>.from(r), namespace);
      await _clockFrom('_rate', id, r).save(tx);
    }
    for (final r in await tx.rawQuery(
      'SELECT from_currency, to_currency, rate FROM $_rates',
    )) {
      final id = _rateId(r['from_currency'], r['to_currency']);
      if (snapRates.contains(id) || ownRows.contains('_rate\u0000$id')) {
        continue;
      }
      snapRates.add(id);
      emit.rate(
        '${r['from_currency']}',
        '${r['to_currency']}',
        _num(r['rate']),
      );
    }
    // Account types: the later choice wins either way.
    final incoming = snapshot['acct'] is Map
        ? snapshot['acct'] as Map
        : const {};
    for (final e in incoming.entries) {
      if (e.value is! Map) continue;
      await _applyAccountType(
        tx,
        '${e.key}',
        'u',
        Map<String, dynamic>.from(e.value as Map),
      );
    }
    final (types, at) = await _accountTypes(tx);
    for (final e in types.entries) {
      final theirs = incoming[e.key];
      final theirAt = theirs is Map ? (_num(theirs['at']) ?? 0).toInt() : -1;
      if ((at[e.key] ?? 0) > theirAt) {
        emit.accountType(e.key, e.value, at[e.key] ?? 0);
      }
    }
    // What the snapshot contains is never applied again.
    for (final e in contained.entries) {
      await tx.rawInsert(
        'INSERT OR IGNORE INTO $_log (op_id, seq) VALUES (?, ?)',
        [e.key, e.value],
      );
    }
    // Our own later work stays ours: put it back on top (rows only this
    // device had already include it).
    for (final o in own) {
      final changes = _changesOf(_decode(o['payload']) ?? const {});
      final seq = (o['seq'] as num?)?.toInt();
      await _applyChanges(tx, changes, seq, namespace, skipRows: localOnly);
      if (seq != null) continue;
      for (final c in changes) {
        if (c['t'] == '_acct') continue;
        final clock = await _Clock.load(tx, c['t'] as String, '${c['id']}');
        for (final f in _fieldsOf(c)) {
          clock.pending[f] = o['op_id'] as String;
        }
        await clock.save(tx);
      }
    }
    await emit.seal(tx);
    if (!fill) {
      await _put(tx, 'relay_floor', '$floor');
      final head = int.tryParse(await _get(tx, 'relay_head') ?? '') ?? 0;
      if (floor > head) await _put(tx, 'relay_head', '$floor');
    }
    await _put(tx, 'relay_resync', '');
  });
}
