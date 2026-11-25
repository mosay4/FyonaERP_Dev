import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/database/database_helper.dart';
import 'personal_ledger_database.dart';

/// Result of one migration pass (all counts are of rows found in the old
/// plain storage during this pass).
final class PersonalLedgerMigrationReport {
  const PersonalLedgerMigrationReport({
    required this.counts,
    required this.copied,
    required this.conflicts,
    required this.checksum,
  });

  final Map<String, int> counts;
  final int copied;
  final int conflicts;
  final String checksum;

  int get total => counts.values.fold(0, (a, b) => a + b);
}

/// One-time move of a user's Personal data from the old plain storage
/// (`fyona_erp.db` mirror/outbox/legacy tables + SharedPreferences trees and
/// account types) into that user's encrypted ledger.
///
/// Every pass is: COPY (one ledger transaction, merge by stable identity) →
/// VERIFY (re-read the ledger: every source row present with identical
/// content, or preserved in the encrypted conflicts table; counts and a
/// checksum recorded) → WIPE the verified plain rows (one plain-DB
/// transaction, by explicit row ids) → wipe the moved preferences → mark
/// done. Re-running is always safe: identical rows are skipped, so a crash at
/// any point simply continues on the next open. Nothing is wiped unless it
/// was verified in the ledger first.
final class PersonalLedgerMigration {
  PersonalLedgerMigration._();

  static const metaKey = 'plain_migration_v1';

  /// Test hook: called after each step ('copied', 'verified', 'wiped_db',
  /// 'wiped_prefs'); throwing simulates a crash at that point.
  @visibleForTesting
  static Future<void> Function(String step)? debugStep;

  /// Preference keys holding Personal user data that now lives in the
  /// ledger's key/value table (same key names, so backups stay compatible).
  static const prefsExact = {'financial_trees_v1', 'financial_tree_reports_v1'};
  static const prefsPrefixes = ['financial_tree_nodes_', 'bank_account_types_'];

  static bool isLedgerPrefKey(String key) =>
      prefsExact.contains(key) || prefsPrefixes.any(key.startsWith);

  static const _userTables = [
    'personal_wallets',
    'personal_transactions',
    'savings_goals',
    'spending_categories',
    'personal_bank_accounts',
    'personal_debts',
    'personal_debt_payments',
    'personal_exchange_rates',
    'personal_recurring_transactions',
    'personal_budgets',
  ];

  static String canonical(Map<String, Object?> row, {Set<String> skip = const {}}) {
    final sorted = SplayTreeMap<String, Object?>();
    row.forEach((k, v) {
      if (!skip.contains(k)) sorted[k] = v;
    });
    return jsonEncode(sorted);
  }

  static Future<void> _step(String name) async {
    final hook = debugStep;
    if (hook != null) await hook(name);
  }

  static Future<PersonalLedgerMigrationReport> run(
    PersonalLedgerDatabase ledger, {
    required Set<int> namespaces,
  }) async {
    final ns = namespaces.where((n) => n > 0).toList()..sort();
    final plain = await DatabaseHelper.database;
    final source = await _readPlain(plain, ns);
    final prefs = await _readPrefs();

    // ── COPY ──
    var copied = 0;
    if (source.isNotEmpty || prefs.isNotEmpty) {
      copied = await ledger.transaction((tx) async {
        var n = 0;
        n += await _copyRows(tx, source['personal_entity_cache'] ?? const []);
        n += await _copyOutbox(tx, source['sync_queue'] ?? const []);
        n += await _copyLog(tx, source['sync_operation_log'] ?? const []);
        for (final table in PersonalLedgerDatabase.legacyTables) {
          n += await _copyById(tx, table, source[table] ?? const []);
        }
        n += await _copyPrefs(tx, prefs);
        return n;
      });
    }
    await _step('copied');

    // ── VERIFY ──
    final verified = await _verify(ledger, source, prefs);
    final counts = {
      for (final e in source.entries) e.key: e.value.length,
      if (prefs.isNotEmpty) 'preferences': prefs.length,
    };
    final report = PersonalLedgerMigrationReport(
      counts: counts,
      copied: copied,
      conflicts: verified.conflicts,
      checksum: verified.checksum,
    );
    await _step('verified');

    // ── WIPE (plain) ──
    if (source.values.any((rows) => rows.isNotEmpty)) {
      await plain.transaction((tx) async {
        for (final entry in source.entries) {
          final ids = [
            for (final r in entry.value)
              if (r['id'] != null) r['id'],
          ];
          for (var i = 0; i < ids.length; i += 400) {
            final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
            await tx.rawDelete(
              'DELETE FROM ${entry.key} WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
              chunk,
            );
          }
        }
      });
    }
    await _step('wiped_db');
    await _wipePrefs(prefs.keys);
    await _step('wiped_prefs');

    final previous = await ledger.readMeta(metaKey);
    if (previous == null || report.total > 0) {
      await ledger.rawInsert(
        'INSERT OR REPLACE INTO ${PersonalLedgerDatabase.meta} (key, value) VALUES (?, ?)',
        [
          metaKey,
          jsonEncode({
            'state': 'done',
            'at': DateTime.now().toUtc().toIso8601String(),
            'counts': counts,
            'copied': copied,
            'conflicts': verified.conflicts,
            'checksum': verified.checksum,
            if (previous != null) 'previous': jsonDecode(previous),
          }),
        ],
      );
    }
    return report;
  }

  /// Moves Personal preferences that (re)appeared in SharedPreferences into
  /// the ledger: same copy → verify → wipe rule as [run]. Cheap no-op when
  /// none are present.
  static Future<void> adoptPrefs(PersonalLedgerDatabase ledger) async {
    final prefs = await _readPrefs();
    if (prefs.isEmpty) return;
    await ledger.transaction((tx) => _copyPrefs(tx, prefs));
    await _verify(ledger, const {}, prefs);
    await _wipePrefs(prefs.keys);
  }

  // ── read ──

  static Future<Map<String, List<Map<String, Object?>>>> _readPlain(
    Database plain,
    List<int> ns,
  ) async {
    final out = <String, List<Map<String, Object?>>>{};
    if (ns.isEmpty) return out;
    final marks = List.filled(ns.length, '?').join(',');
    Future<bool> exists(String table) async => (await plain.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    )).isNotEmpty;
    Future<void> read(String table, String where, List<Object?> args) async {
      if (!await exists(table)) return;
      final rows = await plain.rawQuery(
        'SELECT * FROM $table WHERE $where ORDER BY id ASC',
        args,
      );
      if (rows.isNotEmpty) out[table] = rows;
    }

    await read('personal_entity_cache', 'user_id IN ($marks)', ns);
    await read('sync_queue', 'user_id IN ($marks)', ns);
    await read('sync_operation_log', 'user_id IN ($marks)', ns);
    for (final table in _userTables) {
      await read(table, 'user_id IN ($marks)', ns);
    }
    final accounts = [
      for (final r in out['personal_bank_accounts'] ?? const <Map<String, Object?>>[])
        r['id'],
    ];
    if (accounts.isNotEmpty) {
      await read(
        'personal_bank_transactions',
        'account_id IN (${List.filled(accounts.length, '?').join(',')})',
        accounts,
      );
    }
    final budgets = [
      for (final r in out['personal_budgets'] ?? const <Map<String, Object?>>[])
        r['id'],
    ];
    if (budgets.isNotEmpty) {
      await read(
        'budget_categories',
        'budget_id IN (${List.filled(budgets.length, '?').join(',')})',
        budgets,
      );
    }
    return out;
  }

  static Future<Map<String, ({String type, String value})>> _readPrefs() async {
    final out = <String, ({String type, String value})>{};
    final SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      return out;
    }
    for (final key in p.getKeys()) {
      if (!isLedgerPrefKey(key)) continue;
      final v = p.get(key);
      final typed = encodePref(v);
      if (typed != null) out[key] = typed;
    }
    return out;
  }

  static ({String type, String value})? encodePref(Object? v) {
    if (v is bool) return (type: 'bool', value: v.toString());
    if (v is int) return (type: 'int', value: v.toString());
    if (v is double) return (type: 'double', value: v.toString());
    if (v is String) return (type: 'string', value: v);
    if (v is List) {
      return (
        type: 'string-list',
        value: jsonEncode(v.map((e) => e.toString()).toList()),
      );
    }
    return null;
  }

  // ── copy ──

  static int _versionOf(String dataJson) {
    try {
      final m = jsonDecode(dataJson);
      if (m is Map && m['_sync_version'] is num) {
        return (m['_sync_version'] as num).toInt();
      }
    } catch (_) {}
    return 0;
  }

  static Future<void> _conflict(
    Transaction tx,
    String source,
    String key,
    Map<String, Object?> row,
  ) async {
    final json = canonical(row);
    final have = await tx.rawQuery(
      'SELECT 1 FROM ${PersonalLedgerDatabase.conflicts} WHERE source = ? AND row_key = ? AND row_json = ? LIMIT 1',
      [source, key, json],
    );
    if (have.isNotEmpty) return;
    await tx.insert(PersonalLedgerDatabase.conflicts, {
      'source': source,
      'row_key': key,
      'row_json': json,
      'noted_us': DateTime.now().toUtc().microsecondsSinceEpoch,
    });
  }

  static Future<int> _copyRows(
    Transaction tx,
    List<Map<String, Object?>> rows,
  ) async {
    var n = 0;
    for (final r in rows) {
      final userId = (r['user_id'] as num).toInt();
      final type = r['entity_type'].toString();
      final id = r['remote_id'].toString();
      final data = r['data_json']?.toString() ?? '{}';
      final have = await tx.rawQuery(
        'SELECT data_json FROM ${PersonalLedgerDatabase.rows} WHERE user_id = ? AND entity_type = ? AND id = ?',
        [userId, type, id],
      );
      if (have.isNotEmpty) {
        if (have.first['data_json'] != data) {
          await _conflict(tx, 'personal_entity_cache', '$userId|$type|$id', r);
        }
        continue;
      }
      final stamp = DateTime.tryParse(r['updated_at']?.toString() ?? '');
      await tx.insert(PersonalLedgerDatabase.rows, {
        'user_id': userId,
        'entity_type': type,
        'id': id,
        'data_json': data,
        'updated_us': (stamp ?? DateTime.now()).microsecondsSinceEpoch,
        'deleted': 0,
        'version': _versionOf(data),
      });
      n++;
    }
    return n;
  }

  static String _outboxKey(Map<String, Object?> r) {
    final op = r['operation_id']?.toString() ?? '';
    return op.isNotEmpty ? op : 'row:${canonical(r, skip: const {'id'})}';
  }

  static Future<int> _copyOutbox(
    Transaction tx,
    List<Map<String, Object?>> rows,
  ) async {
    var n = 0;
    for (final r in rows) {
      final op = r['operation_id']?.toString() ?? '';
      final content = canonical(r, skip: const {'id'});
      if (op.isNotEmpty) {
        final have = await tx.rawQuery(
          'SELECT * FROM ${PersonalLedgerDatabase.outbox} WHERE operation_id = ?',
          [op],
        );
        if (have.isNotEmpty) {
          if (canonical(have.first, skip: const {'id'}) != content) {
            await _conflict(tx, 'sync_queue', op, r);
          }
          continue;
        }
      } else if (await _hasCanonical(tx, PersonalLedgerDatabase.outbox, content,
          'operation_id IS NULL OR operation_id = ?', [''])) {
        continue;
      }
      await tx.insert(
        PersonalLedgerDatabase.outbox,
        Map<String, Object?>.from(r)..remove('id'),
      );
      n++;
    }
    return n;
  }

  static Future<bool> _hasCanonical(
    DatabaseExecutor db,
    String table,
    String content,
    String where,
    List<Object?> args,
  ) async {
    final rows = await db.rawQuery('SELECT * FROM $table WHERE $where', args);
    return rows.any((row) => canonical(row, skip: const {'id'}) == content);
  }

  static Future<int> _copyLog(
    Transaction tx,
    List<Map<String, Object?>> rows,
  ) async {
    var n = 0;
    for (final r in rows) {
      final content = canonical(r, skip: const {'id'});
      final op = r['operation_id'];
      if (await _hasCanonical(
        tx,
        PersonalLedgerDatabase.outboxLog,
        content,
        op == null ? 'operation_id IS NULL' : 'operation_id = ?',
        op == null ? const [] : [op],
      )) {
        continue;
      }
      await tx.insert(
        PersonalLedgerDatabase.outboxLog,
        Map<String, Object?>.from(r)..remove('id'),
      );
      n++;
    }
    return n;
  }

  static Future<int> _copyById(
    Transaction tx,
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    var n = 0;
    for (final r in rows) {
      final have = await tx.rawQuery('SELECT * FROM $table WHERE id = ?', [r['id']]);
      if (have.isNotEmpty) {
        if (canonical(have.first) != canonical(r)) {
          await _conflict(tx, table, '${r['id']}', r);
        }
        continue;
      }
      await tx.insert(table, r);
      n++;
    }
    return n;
  }

  static Future<int> _copyPrefs(
    Transaction tx,
    Map<String, ({String type, String value})> prefs,
  ) async {
    var n = 0;
    for (final e in prefs.entries) {
      final have = await tx.rawQuery(
        'SELECT type, value FROM ${PersonalLedgerDatabase.kv} WHERE key = ?',
        [e.key],
      );
      if (have.isNotEmpty) {
        if (have.first['type'] != e.value.type ||
            have.first['value'] != e.value.value) {
          await _conflict(tx, 'preferences', e.key, {
            'key': e.key,
            'type': e.value.type,
            'value': e.value.value,
          });
        }
        continue;
      }
      await tx.insert(PersonalLedgerDatabase.kv, {
        'key': e.key,
        'type': e.value.type,
        'value': e.value.value,
        'updated_us': DateTime.now().toUtc().microsecondsSinceEpoch,
      });
      n++;
    }
    return n;
  }

  // ── verify ──

  static Future<({int conflicts, String checksum})> _verify(
    PersonalLedgerDatabase ledger,
    Map<String, List<Map<String, Object?>>> source,
    Map<String, ({String type, String value})> prefs,
  ) async {
    final lines = <String>[];
    var conflicts = 0;
    Future<bool> stashed(String src, String key, Map<String, Object?> row) async {
      final found = await ledger.rawQuery(
        'SELECT 1 FROM ${PersonalLedgerDatabase.conflicts} WHERE source = ? AND row_key = ? AND row_json = ? LIMIT 1',
        [src, key, canonical(row)],
      );
      if (found.isNotEmpty) conflicts++;
      return found.isNotEmpty;
    }

    Never fail(String what) =>
        throw StateError('Personal ledger migration did not verify: $what');

    for (final entry in source.entries) {
      final table = entry.key;
      for (final r in entry.value) {
        switch (table) {
          case 'personal_entity_cache':
            final key = '${r['user_id']}|${r['entity_type']}|${r['remote_id']}';
            final have = await ledger.rawQuery(
              'SELECT data_json FROM ${PersonalLedgerDatabase.rows} WHERE user_id = ? AND entity_type = ? AND id = ?',
              [r['user_id'], r['entity_type'], r['remote_id']],
            );
            if (have.isEmpty) fail('$table $key missing');
            if (have.first['data_json'] != (r['data_json']?.toString() ?? '{}') &&
                !await stashed(table, key, r)) {
              fail('$table $key differs');
            }
            lines.add('$table|$key|${r['data_json']}');
          case 'sync_queue':
            final content = canonical(r, skip: const {'id'});
            final op = r['operation_id']?.toString() ?? '';
            if (op.isNotEmpty) {
              final have = await ledger.rawQuery(
                'SELECT * FROM ${PersonalLedgerDatabase.outbox} WHERE operation_id = ?',
                [op],
              );
              if (have.isEmpty) fail('$table $op missing');
              if (canonical(have.first, skip: const {'id'}) != content &&
                  !await stashed(table, op, r)) {
                fail('$table $op differs');
              }
            } else if (!await _hasCanonical(ledger.rawExecutor, PersonalLedgerDatabase.outbox,
                content, 'operation_id IS NULL OR operation_id = ?', [''])) {
              fail('$table ${_outboxKey(r)} missing');
            }
            lines.add('$table|$content');
          case 'sync_operation_log':
            final content = canonical(r, skip: const {'id'});
            final op = r['operation_id'];
            if (!await _hasCanonical(
              ledger.rawExecutor,
              PersonalLedgerDatabase.outboxLog,
              content,
              op == null ? 'operation_id IS NULL' : 'operation_id = ?',
              op == null ? const [] : [op],
            )) {
              fail('$table ${r['id']} missing');
            }
            lines.add('$table|$content');
          default:
            final have = await ledger.rawQuery(
              'SELECT * FROM $table WHERE id = ?',
              [r['id']],
            );
            if (have.isEmpty) fail('$table ${r['id']} missing');
            if (canonical(have.first) != canonical(r) &&
                !await stashed(table, '${r['id']}', r)) {
              fail('$table ${r['id']} differs');
            }
            lines.add('$table|${canonical(r)}');
        }
      }
    }
    for (final e in prefs.entries) {
      final have = await ledger.rawQuery(
        'SELECT type, value FROM ${PersonalLedgerDatabase.kv} WHERE key = ?',
        [e.key],
      );
      if (have.isEmpty) fail('preference ${e.key} missing');
      if ((have.first['type'] != e.value.type ||
              have.first['value'] != e.value.value) &&
          !await stashed('preferences', e.key, {
            'key': e.key,
            'type': e.value.type,
            'value': e.value.value,
          })) {
        fail('preference ${e.key} differs');
      }
      lines.add('pref|${e.key}|${e.value.type}|${e.value.value}');
    }
    lines.sort();
    return (
      conflicts: conflicts,
      checksum: sha256.convert(utf8.encode(lines.join('\n'))).toString(),
    );
  }

  static Future<void> _wipePrefs(Iterable<String> keys) async {
    final list = keys.toList();
    if (list.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    for (final key in list) {
      await p.remove(key);
    }
  }
}
