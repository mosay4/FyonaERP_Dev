import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/repositories/personal_cache_repository.dart';
import 'personal_ledger_database.dart';
import 'personal_ledger_keys.dart';
import 'personal_ledger_migration.dart';
import 'personal_relay_store.dart';

export 'personal_ledger_database.dart'
    show PersonalLedgerDatabase, PersonalLedgerKeyStore, PersonalLedgerUnavailable;

/// Process-wide access to the signed-in user's encrypted Personal ledger.
///
/// Exactly one ledger (one user) is active at a time. It is selected at the
/// auth boundary ([select], called from
/// [PersonalCacheRepository.stableIdSync]) and opened lazily; the first open
/// of a user runs the one-time move from the old plain storage. Requests for
/// a namespace that belongs to a different known user are refused, so one
/// user's rows can never land in another user's file.
///
/// Fail closed: when the ledger cannot be opened every Personal read/write
/// throws [PersonalLedgerUnavailable] (surfaced by the screens' normal error
/// path); nothing ever falls back to plaintext storage.
final class PersonalLedger {
  PersonalLedger._();

  static Future<Directory> Function() root = personalLedgerRoot;
  static PersonalLedgerKeyStore keys = const SecurePersonalLedgerKeys();
  static DatabaseFactory? factory;

  /// Test-only: ledger used when no user has been selected.
  @visibleForTesting
  static String? fallbackOwner;

  static String? _owner;
  static String? _openingOwner;
  static Future<PersonalLedgerDatabase>? _opening;
  static Future<void>? _closing;
  static final Map<int, String> _namespaceOwner = {};

  /// Why the last open failed (null after a successful open).
  static Object? lastError;

  static String? get owner => _owner;

  /// Records that [namespace] (a local integer namespace) belongs to
  /// [owner] (server user id).
  static void registerNamespace(String owner, int namespace) {
    if (owner.isEmpty || namespace <= 0) return;
    _namespaceOwner[namespace] = owner;
  }

  /// Selects [owner]'s ledger as the active one (closing the previous user's
  /// ledger) and starts opening it. Synchronous so it can run at the auth
  /// boundary before any Personal provider reads.
  static void select(String owner) {
    if (owner.isEmpty || owner == _owner) return;
    _owner = owner;
    lastError = null;
    final previous = _opening;
    _opening = null;
    _openingOwner = null;
    if (previous != null) _closing = _closeQuietly(previous, _closing);
    unawaited(_ensure(owner).then((_) {}, onError: (_) {}));
  }

  /// Signs the active ledger out (logout). Later Personal calls fail closed
  /// until a user is selected again.
  static Future<void> deactivate() async {
    _owner = null;
    final previous = _opening;
    _opening = null;
    _openingOwner = null;
    if (previous != null) {
      _closing = _closeQuietly(previous, _closing);
      await _closing;
    }
  }

  static Future<void> _closeQuietly(
    Future<PersonalLedgerDatabase> db,
    Future<void>? before,
  ) async {
    try {
      await before;
    } catch (_) {}
    try {
      await (await db).close();
    } catch (_) {}
  }

  /// The active user's ledger.
  static Future<PersonalLedgerDatabase> active() {
    final owner = _owner ?? fallbackOwner;
    if (owner == null) {
      return Future.error(const PersonalLedgerUnavailable('no_active_user'));
    }
    _owner ??= owner;
    return _ensure(owner);
  }

  /// The ledger holding local namespace [namespace] — the active ledger,
  /// unless that namespace is known to belong to someone else.
  static Future<PersonalLedgerDatabase> forNamespace(int? namespace) {
    final known = namespace == null ? null : _namespaceOwner[namespace];
    if (known != null) {
      if (_owner == null) {
        select(known);
      } else if (known != _owner) {
        return Future.error(const PersonalLedgerUnavailable('other_user'));
      }
    }
    return active();
  }

  static Future<PersonalLedgerDatabase> _ensure(String owner) {
    final pending = _opening;
    if (pending != null && _openingOwner == owner) return pending;
    final future = _open(owner);
    _opening = future;
    _openingOwner = owner;
    future.then((db) {
      if (identical(_opening, future)) lastError = null;
    }, onError: (Object e) {
      // Retry on the next call (e.g. the vault was locked). A missing key
      // for an existing file keeps failing: it is never replaced.
      if (identical(_opening, future)) {
        _opening = null;
        _openingOwner = null;
        lastError = e;
      }
    });
    return future;
  }

  static Future<PersonalLedgerDatabase> _open(String owner) async {
    try {
      await _closing;
    } catch (_) {}
    final Directory dir;
    try {
      dir = await root();
    } catch (e) {
      throw PersonalLedgerUnavailable('no_storage', e);
    }
    final db = await PersonalLedgerDatabase.open(
      root: dir,
      owner: owner,
      keys: keys,
      factory: factory,
    );
    try {
      await PersonalLedgerMigration.run(
        db,
        namespaces: await namespacesOf(owner),
      );
    } catch (e) {
      await db.close();
      debugPrint('PersonalLedger: migration did not complete: $e');
      throw PersonalLedgerUnavailable('migration_failed', e);
    }
    return db;
  }

  /// Every local namespace [owner]'s old plain rows can be stored under:
  /// the stable mapping, the deterministic FNV fallback and any registered.
  static Future<Set<int>> namespacesOf(String owner) async {
    final out = <int>{
      PersonalCacheRepository.fnvNamespace(owner),
      for (final e in _namespaceOwner.entries)
        if (e.value == owner) e.key,
    };
    try {
      final rows = await DatabaseHelper.rawQuery(
        'SELECT local_user_id FROM stable_user_ids WHERE real_user_id = ?',
        [owner],
      );
      for (final r in rows) {
        final id = (r['local_user_id'] as num?)?.toInt() ?? 0;
        if (id > 0) out.add(id);
      }
    } catch (_) {}
    out.remove(0);
    return out;
  }

  /// The v12 repair (malformed offline entity ids → fresh UUIDs across the
  /// mirror, the outbox and embedded JSON references), applied to the active
  /// ledger. Never throws.
  static Future<void> sanitizeMalformedEntityIds() async {
    try {
      final db = await active();
      bool bad(String id) {
        final hex = id.replaceAll('-', '');
        return hex.length != 32 || RegExp(r'[^0-9a-fA-F]').hasMatch(hex);
      }

      String fresh() {
        final rnd = Random.secure();
        final b = List<int>.generate(16, (_) => rnd.nextInt(256));
        b[6] = (b[6] & 0x0F) | 0x40;
        b[8] = (b[8] & 0x3F) | 0x80;
        final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
            '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      }

      final mapping = <String, String>{};
      for (final (table, col) in const [
        (PersonalLedgerDatabase.rows, 'id'),
        (PersonalLedgerDatabase.outbox, 'entity_id'),
      ]) {
        final rows = await db.rawQuery(
          "SELECT DISTINCT $col AS rid FROM $table WHERE entity_type LIKE 'personal%' "
          "AND $col IS NOT NULL AND $col != ''",
        );
        for (final r in rows) {
          final id = r['rid']?.toString() ?? '';
          if (id.isNotEmpty && bad(id)) mapping.putIfAbsent(id, fresh);
        }
      }
      if (mapping.isEmpty) return;
      await db.transaction((tx) async {
        for (final e in mapping.entries) {
          await tx.rawUpdate(
            'UPDATE ${PersonalLedgerDatabase.rows} SET id = ? WHERE id = ?',
            [e.value, e.key],
          );
          await tx.rawUpdate(
            'UPDATE ${PersonalLedgerDatabase.outbox} SET entity_id = ? WHERE entity_id = ?',
            [e.value, e.key],
          );
        }
        for (final e in mapping.entries) {
          final from = '"${e.key}"';
          final to = '"${e.value}"';
          await tx.rawUpdate(
            "UPDATE ${PersonalLedgerDatabase.rows} SET data_json = REPLACE(data_json, ?, ?) WHERE entity_type LIKE 'personal%'",
            [from, to],
          );
          await tx.rawUpdate(
            "UPDATE ${PersonalLedgerDatabase.outbox} SET data = REPLACE(data, ?, ?) WHERE entity_type LIKE 'personal%'",
            [from, to],
          );
        }
      });
    } catch (_) {}
  }

  /// Test-only: closes the active ledger, forgets every selection and
  /// deletes the ledger files under [root].
  @visibleForTesting
  static Future<void> debugReset({bool deleteFiles = true}) async {
    await deactivate();
    _namespaceOwner.clear();
    lastError = null;
    if (!deleteFiles) return;
    try {
      final dir = await root();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Key/value Personal user data in the active ledger (financial trees,
/// account types). Same key names and value types as the SharedPreferences
/// entries they replace.
final class PersonalLedgerKv {
  PersonalLedgerKv._();

  static Future<PersonalLedgerDatabase> _db() async {
    final db = await PersonalLedger.active();
    // Older builds (or an older backup) may have written these preferences
    // after the first move: take them over the same verified way.
    await PersonalLedgerMigration.adoptPrefs(db);
    return db;
  }

  static Future<({String type, String value})?> _read(String key) async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT type, value FROM ${PersonalLedgerDatabase.kv} WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return (type: rows.first['type'] as String, value: rows.first['value'] as String);
  }

  static Future<String?> getString(String key) async {
    final v = await _read(key);
    return v != null && v.type == 'string' ? v.value : null;
  }

  static Future<bool?> getBool(String key) async {
    final v = await _read(key);
    return v != null && v.type == 'bool' ? v.value == 'true' : null;
  }

  static Future<void> _insert(
    DatabaseExecutor tx,
    String key,
    String type,
    String value,
  ) => tx.rawInsert(
    'INSERT OR REPLACE INTO ${PersonalLedgerDatabase.kv} (key, type, value, updated_us) VALUES (?, ?, ?, ?)',
    [key, type, value, DateTime.now().toUtc().microsecondsSinceEpoch],
  );

  /// One entry; user data keys (trees) also go to the user's other devices,
  /// in the same transaction.
  static Future<void> _write(String key, String type, String value) async {
    final db = await _db();
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      await _insert(tx, key, type, value);
      cap?.kv(key, type: type, value: value);
      await cap?.seal(tx);
    });
  }

  /// Several string entries in one transaction. [relay] adds what travels to
  /// the user's other devices (e.g. an account type choice).
  static Future<void> setStrings(
    Map<String, String> values, {
    void Function(PersonalRelayCapture cap)? relay,
  }) async {
    final db = await _db();
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      for (final e in values.entries) {
        await _insert(tx, e.key, 'string', e.value);
        cap?.kv(e.key, type: 'string', value: e.value);
      }
      if (cap != null) {
        relay?.call(cap);
        await cap.seal(tx);
      }
    });
  }

  static Future<void> setString(String key, String value) =>
      _write(key, 'string', value);

  static Future<void> setBool(String key, bool value) =>
      _write(key, 'bool', value.toString());

  static Future<void> remove(String key) async {
    final db = await _db();
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      final n = await tx.rawDelete(
        'DELETE FROM ${PersonalLedgerDatabase.kv} WHERE key = ?',
        [key],
      );
      if (n > 0) cap?.kv(key);
      await cap?.seal(tx);
    });
  }

  /// Every entry, typed like SharedPreferences values (backup export).
  static Future<Map<String, Object>> all() async {
    final db = await _db();
    final rows = await db.rawQuery(
      'SELECT key, type, value FROM ${PersonalLedgerDatabase.kv} ORDER BY key',
    );
    final out = <String, Object>{};
    for (final r in rows) {
      final v = decode(r['type'] as String, r['value'] as String);
      if (v != null) out[r['key'] as String] = v;
    }
    return out;
  }

  /// Writes one SharedPreferences-typed value (backup restore).
  static Future<void> put(String key, Object value) async {
    final typed = PersonalLedgerMigration.encodePref(value);
    if (typed == null) return;
    await _write(key, typed.type, typed.value);
  }

  static Object? decode(String type, String value) {
    switch (type) {
      case 'string':
        return value;
      case 'bool':
        return value == 'true';
      case 'int':
        return int.tryParse(value);
      case 'double':
        return double.tryParse(value);
      case 'string-list':
        try {
          return (jsonDecode(value) as List).map((e) => e.toString()).toList();
        } catch (_) {
          return null;
        }
    }
    return null;
  }
}
