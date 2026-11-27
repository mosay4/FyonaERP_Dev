import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A table the backup knows about (from the live schema).
class BackupTable {
  BackupTable(this.name, this.columns, this.blobColumns, this.withoutRowid, this.pk, this.numeric);
  final String name;
  final List<String> columns;
  final Set<String> blobColumns;
  final bool withoutRowid;
  final List<String> pk;

  /// INTEGER / REAL / NUMERIC columns: their totals verify a restore
  /// (balances, quantities, amounts must come back identical).
  final List<String> numeric;
}

/// Per-table verification values at one moment.
class BackupCheckpoint {
  BackupCheckpoint(this.seq, this.counts, this.totals);
  final int seq;
  final Map<String, int> counts;
  final Map<String, Map<String, num>> totals;

  Map<String, dynamic> toJson() => {'seq': seq, 'counts': counts, 'totals': totals};

  static BackupCheckpoint fromJson(Map j) => BackupCheckpoint(
        (j['seq'] as num).toInt(),
        {for (final e in (j['counts'] as Map).entries) '${e.key}': (e.value as num).toInt()},
        {
          for (final e in (j['totals'] as Map).entries)
            '${e.key}': {for (final c in (e.value as Map).entries) '${c.key}': c.value as num},
        },
      );

  /// Human-readable differences (empty = identical).
  List<String> diff(BackupCheckpoint other) {
    final out = <String>[];
    for (final t in {...counts.keys, ...other.counts.keys}) {
      if (counts[t] != other.counts[t]) out.add('$t: rows ${counts[t]} ≠ ${other.counts[t]}');
      final a = totals[t] ?? const {}, b = other.totals[t] ?? const {};
      for (final c in {...a.keys, ...b.keys}) {
        final x = a[c] ?? 0, y = b[c] ?? 0;
        if ((x - y).abs() > 1e-6 * (1 + x.abs())) out.add('$t.$c: total $x ≠ $y');
      }
    }
    return out;
  }
}

/// FYONA backup engine v2 — works on any of the app's SQLite / SQLCipher
/// databases (Personal ledger, Business branch database).
///
/// * [install] adds change capture: SQL triggers log every insert / update /
///   delete of every data table into `_bk_changes` INSIDE the same
///   transaction as the user's write — a saved operation is in the backup
///   log at the same instant, crash or not.
/// * [snapshot] dumps all tables WITHOUT blocking the user (fuzzy copy taken
///   after reading the current change seq S0). Replaying the changes after S0
///   (idempotent, by rowid / primary key) brings it to an exact state.
/// * [delta] returns the changes after a seq together with a checkpoint
///   (row counts + numeric totals per table) read in the SAME transaction,
///   so a restore can prove it reached exactly that state.
/// * [restore] builds a NEW database (never the live one): schema, rows,
///   changes, then indexes / app triggers (so no app trigger fires twice),
///   then verifies the checkpoint and SQLite integrity.
class BackupEngine {
  BackupEngine({Set<String> exclude = const {}}) : _exclude = exclude; // ignore: prefer_initializing_formals

  static const changes = '_bk_changes';
  final Set<String> _exclude;

  static String _q(String id) => '"${id.replaceAll('"', '""')}"';

  /// Data tables (excludes SQLite / backup internals and [exclude]).
  Future<List<BackupTable>> tables(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
        "SELECT name, sql FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
        "AND name NOT LIKE '\\_bk\\_%' ESCAPE '\\' AND name <> 'android_metadata' ORDER BY name");
    final out = <BackupTable>[];
    for (final r in rows) {
      final name = '${r['name']}';
      if (_exclude.contains(name)) continue;
      final info = await db.rawQuery('PRAGMA table_info(${_q(name)})');
      final cols = [for (final c in info) '${c['name']}'];
      final blobs = {
        for (final c in info)
          if ('${c['type']}'.toUpperCase().contains('BLOB')) '${c['name']}',
      };
      final pk = [
        for (final c in (info.where((c) => (c['pk'] as int? ?? 0) > 0).toList()
          ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int))))
          '${c['name']}',
      ];
      final numeric = [
        for (final c in info)
          if (RegExp(r'INT|REAL|NUM|DEC|DOUB|FLOA', caseSensitive: false).hasMatch('${c['type']}'))
            '${c['name']}',
      ];
      final withoutRowid = '${r['sql']}'.toUpperCase().contains('WITHOUT ROWID');
      out.add(BackupTable(name, cols, blobs, withoutRowid, pk, numeric));
    }
    return out;
  }

  /// Row as JSON inside a trigger. Never fails, whatever the value: text is
  /// copied as text (`||''` drops SQLite's JSON subtype so JSON-looking text
  /// stays text), blobs become `{"$b": hex}`, numbers / NULL stay as they are.
  /// json_object takes ≤ 127 args, so wide tables are sliced into an array
  /// of objects (merged on read; NULLs kept).
  String _json(BackupTable t, String alias) {
    String val(String c) {
      final v = '$alias.${_q(c)}';
      return "CASE typeof($v) WHEN 'text' THEN $v || '' WHEN 'blob' THEN json_object('\$b', hex($v)) ELSE $v END";
    }

    final slices = <String>[];
    for (var i = 0; i < t.columns.length; i += 40) {
      final part = t.columns.skip(i).take(40);
      slices.add('json_object(${part.map((c) => "'${c.replaceAll("'", "''")}', ${val(c)}").join(', ')})');
    }
    return slices.length == 1 ? slices.single : 'json_array(${slices.join(', ')})';
  }

  /// Installs / refreshes change capture (idempotent; call on every open —
  /// schema changes are picked up).
  Future<void> install(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS $changes ('
        'seq INTEGER PRIMARY KEY AUTOINCREMENT, tbl TEXT NOT NULL, op TEXT NOT NULL, rid INTEGER, row TEXT)');
    final tabs = await tables(db);
    await db.transaction((tx) async {
      for (final t in tabs) {
        final n = t.name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
        final tq = _q(t.name), lit = "'${t.name.replaceAll("'", "''")}'";
        for (final s in ['i', 'u', 'd']) {
          await tx.execute('DROP TRIGGER IF EXISTS ${_q('_bk_${n}_$s')}');
        }
        if (t.withoutRowid) {
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_i')} AFTER INSERT ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'U', NULL, ${_json(t, 'NEW')}); END");
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_u')} AFTER UPDATE ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'D', NULL, ${_json(t, 'OLD')}); "
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'U', NULL, ${_json(t, 'NEW')}); END");
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_d')} AFTER DELETE ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'D', NULL, ${_json(t, 'OLD')}); END");
        } else {
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_i')} AFTER INSERT ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'U', NEW.rowid, ${_json(t, 'NEW')}); END");
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_u')} AFTER UPDATE ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) SELECT $lit, 'D', OLD.rowid, NULL WHERE OLD.rowid IS NOT NEW.rowid; "
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'U', NEW.rowid, ${_json(t, 'NEW')}); END");
          await tx.execute('CREATE TRIGGER ${_q('_bk_${n}_d')} AFTER DELETE ON $tq BEGIN '
              "INSERT INTO $changes(tbl, op, rid, row) VALUES ($lit, 'D', OLD.rowid, NULL); END");
        }
      }
    });
  }

  Future<int> lastSeq(DatabaseExecutor db) async {
    final has = await db.rawQuery("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = '$changes'");
    if (has.isEmpty) return 0; // capture not installed yet
    return ((await db.rawQuery('SELECT COALESCE(MAX(seq), 0) AS s FROM $changes')).first['s'] as int?) ?? 0;
  }

  Future<BackupCheckpoint> checkpoint(DatabaseExecutor db, List<BackupTable> tabs, int seq) async {
    final counts = <String, int>{};
    final totals = <String, Map<String, num>>{};
    for (final t in tabs) {
      final cols = t.numeric;
      final sel = ['COUNT(*) AS n', for (var i = 0; i < cols.length; i++) 'TOTAL(${_q(cols[i])}) AS c$i'];
      final r = (await db.rawQuery('SELECT ${sel.join(', ')} FROM ${_q(t.name)}')).first;
      counts[t.name] = r['n'] as int;
      totals[t.name] = {for (var i = 0; i < cols.length; i++) cols[i]: r['c$i'] as num};
    }
    return BackupCheckpoint(seq, counts, totals);
  }

  /// Schema of the data tables + their indexes / triggers (app ones only).
  Future<List<Map<String, String>>> schema(DatabaseExecutor db, List<BackupTable> tabs) async {
    // Excluded tables (device-local sync state) keep their schema but no
    // rows: a restored device starts them empty, as a new replica.
    final names = {for (final t in tabs) t.name, ..._exclude};
    final rows = await db.rawQuery(
        "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
        "AND name NOT LIKE '\\_bk\\_%' ESCAPE '\\' ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 "
        "WHEN 'view' THEN 2 ELSE 3 END, name");
    return [
      for (final r in rows)
        if ((names.contains('${r['tbl_name']}') || r['type'] == 'view') &&
            !(r['type'] == 'trigger' && _exclude.contains('${r['tbl_name']}')))
          {'type': '${r['type']}', 'name': '${r['name']}', 'sql': '${r['sql']}'},
    ];
  }

  /// Fuzzy, non-blocking dump. Emits JSONL lines through [sink].
  /// Returns S0: replay changes with seq > S0 on top of it.
  Future<int> snapshot(Database db, FutureOr<void> Function(String line) sink, {int pageSize = 2000}) async {
    final s0 = await lastSeq(db);
    final tabs = await tables(db);
    // The app's schema version travels too: a restored copy opens as the
    // same version (no "new database" creation or migration on top of it).
    final uv = (await db.rawQuery('PRAGMA user_version')).first.values.first as int? ?? 0;
    await sink(jsonEncode({'k': 'schema', 'v': 2, 's0': s0, 'uv': uv, 'objects': await schema(db, tabs)}));
    for (final t in tabs) {
      final tq = _q(t.name);
      if (t.withoutRowid) {
        var offset = 0;
        while (true) {
          final rows = await db.rawQuery('SELECT * FROM $tq LIMIT $pageSize OFFSET $offset');
          for (final r in rows) {
            await sink(jsonEncode({'k': 'r', 't': t.name, 'row': _encodeRow(t, r)}));
          }
          if (rows.length < pageSize) break;
          offset += pageSize;
        }
      } else {
        var after = -1 << 62;
        while (true) {
          // Keyset paging by rowid: constant cost per page, no lock held.
          final rows = await db.rawQuery(
              'SELECT rowid AS "__rid", * FROM $tq WHERE rowid > ? ORDER BY rowid LIMIT $pageSize', [after]);
          for (final r in rows) {
            final rid = r['__rid'] as int;
            final row = Map<String, Object?>.of(r)..remove('__rid');
            await sink(jsonEncode({'k': 'r', 't': t.name, 'rid': rid, 'row': _encodeRow(t, row)}));
            after = rid;
          }
          if (rows.length < pageSize) break;
        }
      }
    }
    return s0;
  }

  Map<String, Object?> _encodeRow(BackupTable t, Map<String, Object?> r) => {
        for (final e in r.entries) e.key: e.value is List<int> ? {r'$b': _hex(e.value as List<int>)} : e.value,
      };

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  static Uint8List _unhex(String s) =>
      Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

  /// Changes after [from] + the exact checkpoint at their end (one transaction).
  Future<({List<String> lines, BackupCheckpoint checkpoint})> delta(Database db, int from) async {
    final tabs = await tables(db);
    return db.transaction((tx) async {
      final rows = await tx.rawQuery('SELECT seq, tbl, op, rid, row FROM $changes WHERE seq > ? ORDER BY seq', [from]);
      final to = rows.isEmpty ? from : rows.last['seq'] as int;
      final lines = [
        for (final r in rows)
          jsonEncode({'k': 'c', 'seq': r['seq'], 't': r['tbl'], 'op': r['op'], 'rid': r['rid'], 'row': r['row']}),
      ];
      return (lines: lines, checkpoint: await checkpoint(tx, tabs, to));
    });
  }

  /// Where the change log ends now + the exact checkpoint at that point,
  /// read in ONE short transaction (only counts / totals; the change rows
  /// themselves are read afterwards — rows up to `to` never change).
  Future<BackupCheckpoint> head(Database db) async {
    final tabs = await tables(db);
    return db.transaction((tx) async => checkpoint(tx, tabs, await lastSeq(tx)));
  }

  /// The captured changes in (from, to], streamed page by page.
  Stream<String> changeLines(Database db, int from, int to, {int pageSize = 5000}) async* {
    var after = from;
    while (after < to) {
      final rows = await db.rawQuery(
          'SELECT seq, tbl, op, rid, row FROM $changes WHERE seq > ? AND seq <= ? ORDER BY seq LIMIT $pageSize',
          [after, to]);
      if (rows.isEmpty) break;
      for (final r in rows) {
        yield jsonEncode({'k': 'c', 'seq': r['seq'], 't': r['tbl'], 'op': r['op'], 'rid': r['rid'], 'row': r['row']});
      }
      after = rows.last['seq'] as int;
    }
  }

  /// The captured changes in (from, to] — rebuilds a lost change part.
  Future<List<String>> range(Database db, int from, int to) async => [
        for (final r in await db.rawQuery(
            'SELECT seq, tbl, op, rid, row FROM $changes WHERE seq > ? AND seq <= ? ORDER BY seq', [from, to]))
          jsonEncode({'k': 'c', 'seq': r['seq'], 't': r['tbl'], 'op': r['op'], 'rid': r['rid'], 'row': r['row']}),
      ];

  /// Drops captured changes every destination already holds.
  Future<void> forget(Database db, int upTo) =>
      db.delete(changes, where: 'seq <= ?', whereArgs: [upTo]);

  /// Builds a database from a snapshot + its changes into [target] (a NEW,
  /// empty database) and verifies it against [expected].
  /// Returns the list of problems (empty = verified identical).
  Future<List<String>> restore(Database target, Iterable<String> snapshotLines,
          Iterable<String> changeLines, BackupCheckpoint expected) =>
      restoreStream(target, Stream.fromIterable(snapshotLines), Stream.fromIterable(changeLines), expected);

  /// [restore] from streams: records are applied as they are read, in
  /// batches, inside ONE transaction of the new database — memory stays
  /// flat whatever the size, and an error at any point (damaged part,
  /// missing chunk, interruption) leaves nothing behind.
  Future<List<String>> restoreStream(Database target, Stream<String> snapshotLines,
      Stream<String> changeLines, BackupCheckpoint expected,
      {void Function(int records)? onProgress, int batchSize = 1000}) async {
    var objects = <Map>[];
    final tabs = <String, BackupTable>{};
    var s0 = 0;
    var userVersion = 0;
    var done = 0;
    await target.transaction((tx) async {
      var batch = tx.batch();
      var queued = 0;
      Future<void> flush() async {
        if (queued == 0) return;
        await batch.commit(noResult: true);
        batch = tx.batch();
        done += queued;
        queued = 0;
        onProgress?.call(done);
      }

      await for (final line in snapshotLines) {
        final j = jsonDecode(line) as Map;
        if (j['k'] == 'schema') {
          await flush();
          s0 = (j['s0'] as num).toInt();
          userVersion = (j['uv'] as num?)?.toInt() ?? 0;
          objects = (j['objects'] as List).cast<Map>();
          for (final o in objects.where((o) => o['type'] == 'table')) {
            await tx.execute('${o['sql']}');
          }
          for (final t in await tables(tx)) {
            tabs[t.name] = t;
          }
          continue;
        }
        final t = tabs['${j['t']}'];
        if (t == null) throw const FormatException('row for an unknown table');
        _put(batch, t, j['rid'] as int?, _decodeRow(t, j['row']));
        if (++queued >= batchSize) await flush();
      }
      await for (final line in changeLines) {
        final j = jsonDecode(line) as Map;
        if ((j['seq'] as num) <= s0) continue; // already in the fuzzy snapshot window? replay is idempotent
        final t = tabs['${j['t']}'];
        if (t == null) continue; // table not in this backup (excluded)
        final rowJson = j['row'];
        final row = rowJson == null ? null : _decodeRow(t, jsonDecode('$rowJson'));
        if (j['op'] == 'D') {
          if (t.withoutRowid) {
            if (row != null) {
              batch.delete(_q(t.name),
                  where: t.pk.map((c) => '${_q(c)} IS ?').join(' AND '), whereArgs: [for (final c in t.pk) row[c]]);
            }
          } else {
            batch.delete(_q(t.name), where: 'rowid = ?', whereArgs: [j['rid']]);
          }
        } else if (row != null) {
          _put(batch, t, j['rid'] as int?, row);
        }
        if (++queued >= batchSize) await flush();
      }
      await flush();
      // Indexes, views and the app's own triggers last: nothing fires twice.
      for (final o in objects.where((o) => o['type'] != 'table')) {
        await tx.execute('${o['sql']}');
      }
    });
    await target.execute('PRAGMA user_version = $userVersion');
    final problems = <String>[];
    final ok = await target.rawQuery('PRAGMA integrity_check');
    if ('${ok.first.values.first}' != 'ok') problems.add('integrity_check: ${ok.first.values.first}');
    final got = await checkpoint(target, tabs.values.toList(), expected.seq);
    problems.addAll(expected.diff(got));
    return problems;
  }

  /// Row from JSON: a trigger row may be sliced (array of objects).
  Map<String, Object?> _decodeRow(BackupTable t, Object? json) {
    final merged = <String, Object?>{};
    if (json is List) {
      for (final part in json) {
        merged.addAll((part as Map).cast<String, Object?>());
      }
    } else {
      merged.addAll((json as Map).cast<String, Object?>());
    }
    return {
      for (final e in merged.entries)
        e.key: e.value is Map && (e.value as Map).containsKey(r'$b') ? _unhex('${(e.value as Map)[r'$b']}') : e.value,
    };
  }

  void _put(Batch tx, BackupTable t, int? rid, Map<String, Object?> row) {
    final cols = row.keys.toList();
    final names = [if (!t.withoutRowid && rid != null) 'rowid', ...cols.map(_q)];
    final args = [if (!t.withoutRowid && rid != null) rid, ...cols.map((c) => row[c])];
    tx.rawInsert(
        'INSERT OR REPLACE INTO ${_q(t.name)} (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})',
        args);
  }

  /// Media references (`media:<sha256>`) found in any text value.
  static Set<String> mediaRefs(Iterable<String> lines) => {for (final l in lines) ...mediaRefsOf(l)};

  static final _mediaRe = RegExp(r'media:[0-9a-f]{64}');
  static Iterable<String> mediaRefsOf(String line) =>
      line.contains('media:') ? _mediaRe.allMatches(line).map((m) => m.group(0)!) : const [];

  /// gzip + JSONL helpers.
  static Uint8List pack(List<String> lines) => Uint8List.fromList(gzip.encode(utf8.encode(lines.join('\n'))));

  static List<String> unpack(Uint8List data) {
    final s = utf8.decode(gzip.decode(data));
    return s.isEmpty ? const [] : s.split('\n');
  }
}
