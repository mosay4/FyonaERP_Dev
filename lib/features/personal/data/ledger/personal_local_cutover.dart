import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'personal_ledger_database.dart';
import 'personal_relay_config.dart';
import 'personal_relay_store.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Personal device-only cutover (Stage 6 of docs/PERSONAL_LOCAL_PLAN.md).
//
// On the first open with this build, each device of a local Personal user:
//   1. drains its old outbox (the old sync, while the server still takes it);
//   2. downloads the one-time export of the user's server Personal rows
//      (`/personal-local/export`, the same bytes on every device);
//   3. imports it into the ledger as a baseline, upsert by id, in one
//      transaction, never recorded as relay operations (every device imports
//      the same export itself, after its relay inbox is drained): a row the
//      device does not have is added; a row it holds only as a copy of the
//      server (no relay history, no unsent old write) takes the server's
//      values; a row changed here or through the relay (relay history or an
//      unsent old write) and a row deleted here (relay tombstone) is kept;
//   4. verifies counts, the digest and the balances of the accounts it wrote;
//   5. confirms (`/ack`): the server then deletes its copy after a grace
//      period;
//   6. turns old outbox rows written before the relay existed into relay
//      operations and empties the old outbox.
// From then on the old server sync is off for this user. Every step is
// idempotent and resumable (state in the ledger meta); offline it retries
// later; the user sees nothing unless it keeps failing.
// ─────────────────────────────────────────────────────────────────────────────

/// What the app tells the user about device-only Personal (calm, one-time).
enum PersonalLocalNotice { restoreBackup, cutoverFailing, updateRequired }

/// Who keeps Personal data on the device only, and the old sync's state.
abstract final class PersonalLocalMode {
  /// Builds with the Personal device relay are device-only builds (unless
  /// the server said it is not a device-only Personal server).
  static bool get active => PersonalRelayConfig.enabled && !serverDeclined;

  /// The server has no `/personal-local` (404): it still keeps Personal data,
  /// so the old sync stays fully on.
  static bool serverDeclined = false;

  /// The old server sync of this user is retired (cutover done, or the
  /// server already refuses it). Pulls never run for a local user.
  static bool oldSyncRetired = false;

  /// Protocol header: the server answers older builds «update the app».
  static const protocolHeader = 'X-Fyona-Personal-Protocol';
  static const protocol = '6';

  static const codeLocal = 'personal_local';
  static const codeUpdate = 'update_required';

  /// The notice to show, if any (the UI clears it once seen).
  static final notice = ValueNotifier<PersonalLocalNotice?>(null);

  /// The code of a refusal by the device-only guard (`personal_local` /
  /// `update_required`) in a server answer, else null.
  static String? refusalCode(Object? data) {
    if (data is Map) {
      final code = data['code'] ?? (data['detail'] is Map ? (data['detail'] as Map)['code'] : null);
      if (code == codeLocal || code == codeUpdate) return code as String;
    }
    return null;
  }

  @visibleForTesting
  static void debugReset() {
    oldSyncRetired = false;
    serverDeclined = false;
    notice.value = null;
  }
}

/// The migration endpoints (`/api/v1/personal-local`): `data` of the answer.
abstract interface class PersonalLocalTransport {
  Future<Map<String, dynamic>> get(String path);
  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body);
}

/// A refused / failed call ([status] null: no answer, e.g. offline).
final class PersonalLocalHttpError implements Exception {
  const PersonalLocalHttpError(this.status, [this.message]);
  final int? status;
  final String? message;

  @override
  String toString() => 'PersonalLocalHttpError($status, $message)';
}

/// The baseline did not check out (nothing was confirmed to the server).
final class PersonalLocalVerifyError implements Exception {
  const PersonalLocalVerifyError(this.reason);
  final String reason;

  @override
  String toString() => 'PersonalLocalVerifyError($reason)';
}

final class PersonalLocalCutover {
  PersonalLocalCutover({
    required this.db,
    required this.transport,
    required this.namespace,
    this.drain,
    this.relayIdle,
  });

  final PersonalLedgerDatabase db;
  final PersonalLocalTransport transport;

  /// Local namespace (`user_id` column) imported rows are written under.
  final int namespace;

  /// Pushes the old outbox while the server still accepts it.
  final Future<void> Function()? drain;

  /// True when the relay inbox is drained and nothing is parked: the import
  /// waits for it, so a relay change still on its way is never counted on
  /// top of a server value that already contains it.
  final Future<bool> Function()? relayIdle;

  static const metaKey = 'personal_local_cutover_v1';
  static const format = 'fyona-personal-baseline';
  static const noticeAfterFailures = 3;

  /// Entity types stored as ledger rows (budget categories travel inside
  /// their budget, like the server lists send them).
  static const importTypes = [
    'personal_bank_account',
    'personal_budget',
    'personal_savings_goal',
    'personal_debt',
    'personal_debt_payment',
    'personal_recurring_transaction',
    'personal_transaction',
  ];

  static const _rows = PersonalLedgerDatabase.rows;
  static const _relayRows = PersonalLedgerDatabase.relayRows;

  /// Test hook: called after each step; throwing simulates a crash there.
  @visibleForTesting
  static Future<void> Function(String step)? debugStep;

  static Future<void> _step(String name) async {
    final hook = debugStep;
    if (hook != null) await hook(name);
  }

  static Future<Map<String, dynamic>> readState(DatabaseExecutor ex) async {
    final rows = await ex.rawQuery(
      'SELECT value FROM ${PersonalLedgerDatabase.meta} WHERE key = ?',
      [metaKey],
    );
    if (rows.isEmpty) return {};
    try {
      final v = jsonDecode(rows.first['value'] as String);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeState(
    DatabaseExecutor ex,
    Map<String, dynamic> state,
  ) => ex.rawInsert(
    'INSERT OR REPLACE INTO ${PersonalLedgerDatabase.meta} (key, value) VALUES (?, ?)',
    [metaKey, jsonEncode(state)],
  );

  Future<Map<String, dynamic>> state() => readState(db.rawExecutor);

  Future<void> _save(Map<String, dynamic> st) =>
      db.transaction((tx) => _writeState(tx, st));

  /// True once this device finished the cutover.
  Future<bool> isDone() async => (await state())['state'] == 'done';

  /// One attempt. True: done (now or earlier). False: try again later.
  Future<bool> run() async {
    var st = await state();
    if (st['state'] == 'done') {
      PersonalLocalMode.oldSyncRetired = true;
      // Writes queued in the old outbox before this run knew it was done.
      try {
        await convertOutbox(db);
      } catch (_) {}
      return true;
    }
    try {
      if (st['state'] == null || st['state'] == 'start') {
        final d = drain;
        if (d != null && !PersonalLocalMode.oldSyncRetired) {
          try {
            await d();
          } catch (_) {
            // Whatever stays in the old outbox is handled in step 6.
          }
        }
        await _step('drained');
        final status = await transport.get('/status');
        final nothing = status['purged'] == true ||
            (status['needed'] != true &&
                status['imported'] != true &&
                ((status['rows'] as num?) ?? 0) == 0);
        st = {...st, 'state': nothing ? 'acked' : 'export', if (nothing) 'nothing': true};
        await _save(st);
      }
      if (st['state'] == 'export') {
        Map<String, dynamic> export;
        try {
          export = await transport.post('/export', const {});
        } on PersonalLocalHttpError catch (e) {
          if (e.status != 410) rethrow;
          // Already deleted on the server (grace over): the other devices
          // hold it; the relay snapshot brings it here.
          st = {...st, 'state': 'acked', 'purged': true};
          await _save(st);
          export = const {};
        }
        if (st['state'] == 'export') {
          final idle = relayIdle;
          if (idle != null && !await idle()) return false; // next round
          st = await _import(st, export);
          await _step('imported');
        }
      }
      if (st['state'] == 'imported') {
        await transport.post('/ack', {
          'snapshot_id': st['snapshot_id'],
          'digest': st['digest'],
        });
        st = {...st, 'state': 'acked'};
        await _save(st);
        await _step('acked');
      }
      if (st['state'] == 'acked') {
        final converted = await convertOutbox(db);
        st = {
          ...st,
          'state': 'done',
          'converted': converted,
          'at': DateTime.now().toUtc().toIso8601String(),
        }..remove('failures');
        await _save(st);
      }
      PersonalLocalMode.oldSyncRetired = true;
      if (PersonalLocalMode.notice.value == PersonalLocalNotice.cutoverFailing) {
        PersonalLocalMode.notice.value = null;
      }
      return true;
    } on PersonalLocalHttpError catch (e) {
      if (e.status == 404) {
        // Not a device-only Personal server: the old sync stays on.
        PersonalLocalMode.serverDeclined = true;
        return false;
      }
      return _failed(st, e, offline: e.status == null);
    } catch (e) {
      return _failed(st, e);
    }
  }

  Future<bool> _failed(Map<String, dynamic> st, Object e, {bool offline = false}) async {
    debugPrint('PersonalLocalCutover: not yet: $e');
    if (offline) return false; // just try again when back online
    final latest = {...await state()};
    final failures = ((latest['failures'] as num?) ?? 0).toInt() + 1;
    latest['failures'] = failures;
    latest['last_error'] = e.toString().substring(0, e.toString().length.clamp(0, 300));
    latest.putIfAbsent('state', () => st['state'] ?? 'start');
    try {
      await _save(latest);
    } catch (_) {}
    if (failures >= noticeAfterFailures) {
      PersonalLocalMode.notice.value ??= PersonalLocalNotice.cutoverFailing;
    }
    return false;
  }

  static String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

  /// Steps 3–4 in one ledger transaction (state 'imported' included): a
  /// crash leaves either nothing or everything.
  Future<Map<String, dynamic>> _import(
    Map<String, dynamic> st,
    Map<String, dynamic> export,
  ) async {
    final b64 = export['body'];
    final digest = '${export['digest'] ?? ''}';
    final snapshotId = '${export['snapshot_id'] ?? ''}';
    if (b64 is! String || digest.length != 64 || snapshotId.isEmpty) {
      throw const PersonalLocalVerifyError('malformed_export');
    }
    final bytes = base64Decode(b64);
    if (digestOf(bytes) != digest) {
      throw const PersonalLocalVerifyError('digest');
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map ||
        body['format'] != format ||
        '${body['snapshot_id']}' != snapshotId) {
      throw const PersonalLocalVerifyError('format');
    }
    if ('${body['user_id']}' != db.owner) {
      throw const PersonalLocalVerifyError('other_user');
    }
    final entities = body['entities'];
    final counts = body['counts'];
    if (entities is! Map || counts is! Map) {
      throw const PersonalLocalVerifyError('format');
    }
    for (final e in counts.entries) {
      final list = entities[e.key];
      if (list is! List || list.length != (e.value as num).toInt()) {
        throw const PersonalLocalVerifyError('counts');
      }
    }
    final balances = body['balances'] is Map
        ? Map<String, dynamic>.from(body['balances'] as Map)
        : const <String, dynamic>{};

    return db.transaction((tx) async {
      final now = DateTime.now().microsecondsSinceEpoch;
      final added = <String, int>{};
      final replaced = <String, int>{};
      final kept = <String, int>{};
      final written = <String>{};
      for (final type in importTypes) {
        final list = entities[type];
        if (list is! List) continue;
        for (final raw in list) {
          if (raw is! Map) continue;
          final row = Map<String, dynamic>.from(raw);
          final id = '${row['id'] ?? ''}';
          if (id.isEmpty) continue;
          if (await _tombstoned(tx, type, id) || await _changedHere(tx, type, id)) {
            kept[type] = (kept[type] ?? 0) + 1;
            continue;
          }
          final have = await tx.rawQuery(
            'SELECT seq, data_json FROM $_rows WHERE entity_type = ? AND id = ? LIMIT 1',
            [type, id],
          );
          if (have.isEmpty) {
            await tx.rawInsert(
              'INSERT INTO $_rows (user_id, entity_type, id, data_json, updated_us, deleted, version) '
              'VALUES (?, ?, ?, ?, ?, 0, 0)',
              [namespace, type, id, jsonEncode(row), now],
            );
            added[type] = (added[type] ?? 0) + 1;
          } else {
            // A copy of the server's row (old sync): the server's values.
            // Device-local metadata (the old sync version) is kept.
            final old = _decode(have.first['data_json']);
            final merged = {
              ...row,
              if (old.containsKey('_sync_version')) '_sync_version': old['_sync_version'],
            };
            await tx.rawUpdate(
              'UPDATE $_rows SET data_json = ?, updated_us = ?, deleted = 0 WHERE seq = ?',
              [jsonEncode(merged), now, have.first['seq']],
            );
            replaced[type] = (replaced[type] ?? 0) + 1;
          }
          if (type == 'personal_bank_account') written.add(id);
        }
      }
      // ── verify (same transaction: a failure rolls the import back) ──
      for (final type in importTypes) {
        final list = entities[type];
        if (list is! List) continue;
        for (final raw in list) {
          final id = raw is Map ? '${raw['id'] ?? ''}' : '';
          if (id.isEmpty) continue;
          if (!await _present(tx, type, id) && !await _tombstoned(tx, type, id)) {
            throw PersonalLocalVerifyError('missing $type');
          }
        }
      }
      for (final id in written) {
        final r = await tx.rawQuery(
          'SELECT data_json FROM $_rows WHERE entity_type = ? AND id = ? AND deleted = 0 LIMIT 1',
          ['personal_bank_account', id],
        );
        final stored = r.isEmpty ? null : jsonDecode(r.first['data_json'] as String);
        final have = stored is Map ? (stored['balance'] as num?)?.toDouble() : null;
        final want = (balances[id] as num?)?.toDouble();
        if (want == null || have == null || (have - want).abs() > 1e-9) {
          throw const PersonalLocalVerifyError('balance');
        }
      }
      final next = <String, dynamic>{
        ...st,
        'state': 'imported',
        'snapshot_id': snapshotId,
        'digest': digest,
        'counts': Map<String, dynamic>.from(counts),
        'added': added,
        'replaced': replaced,
        'kept': kept,
      }..remove('failures');
      await _writeState(tx, next);
      return next;
    });
  }

  static Future<bool> _present(DatabaseExecutor tx, String type, String id) async =>
      (await tx.rawQuery(
        'SELECT 1 FROM $_rows WHERE entity_type = ? AND id = ? AND deleted = 0 LIMIT 1',
        [type, id],
      )).isNotEmpty;

  static Map<String, dynamic> _decode(Object? json) {
    try {
      final v = jsonDecode('$json');
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return {};
  }

  /// The row was changed on this device or through the relay (relay
  /// history), or an old write of it was never sent: this device's values
  /// are newer than the export.
  static Future<bool> _changedHere(DatabaseExecutor tx, String type, String id) async =>
      (await tx.rawQuery(
        'SELECT 1 FROM $_relayRows WHERE entity_type = ? AND id = ? LIMIT 1',
        [type, id],
      )).isNotEmpty ||
      (await tx.rawQuery(
        'SELECT 1 FROM ${PersonalLedgerDatabase.outbox} WHERE entity_type = ? AND entity_id = ? LIMIT 1',
        [type, id],
      )).isNotEmpty;

  static Future<bool> _tombstoned(DatabaseExecutor tx, String type, String id) async =>
      (await tx.rawQuery(
        'SELECT 1 FROM $_relayRows WHERE entity_type = ? AND id = ? AND deleted = 1',
        [type, id],
      )).isNotEmpty;

  /// Step 6 (also when the server refuses the old sync): old outbox rows
  /// written before this device recorded relay operations become relay
  /// operations (the row as it is here, or its delete); rows written since
  /// already travelled as relay operations. Then the old outbox is emptied.
  /// Counters (balances) of rows other devices already hold are not moved
  /// by these operations (a re-sent row never adds its value twice).
  /// Returns how many rows were re-sent.
  static Future<int> convertOutbox(PersonalLedgerDatabase db) async {
    final outbox = PersonalLedgerDatabase.outbox;
    return db.transaction((tx) async {
      final pending = await tx.rawQuery(
        'SELECT id, entity_type, entity_id, operation, created_at FROM $outbox ORDER BY id',
      );
      if (pending.isEmpty) return 0;
      final first = await tx.rawQuery(
        'SELECT MIN(created_us) AS us FROM ${PersonalLedgerDatabase.relayOutbox}',
      );
      final sinceUs = (first.first['us'] as num?)?.toInt();
      final targets = <String, (String, String, bool)>{};
      for (final r in pending) {
        final type = '${r['entity_type'] ?? ''}';
        final id = '${r['entity_id'] ?? ''}';
        if (!type.startsWith('personal_') || id.isEmpty) continue;
        final created = DateTime.tryParse('${r['created_at'] ?? ''}');
        final before = sinceUs == null ||
            created == null ||
            created.toUtc().microsecondsSinceEpoch < sinceUs;
        if (!before) continue;
        final delete = '${r['operation'] ?? ''}'.toUpperCase() == 'DELETE';
        targets['$type\u0000$id'] = (type, id, delete);
      }
      final cap = PersonalRelayCapture.begin();
      var sent = 0;
      if (cap != null) {
        for (final (type, id, delete) in targets.values) {
          final found = await tx.rawQuery(
            'SELECT data_json FROM $_rows WHERE entity_type = ? AND id = ? AND deleted = 0 LIMIT 1',
            [type, id],
          );
          if (found.isNotEmpty) {
            final row = jsonDecode(found.first['data_json'] as String);
            if (row is Map) {
              cap.resend(type, id, Map<String, dynamic>.from(row));
              sent++;
            }
          } else if (delete) {
            cap.resendDelete(type, id);
            sent++;
          }
        }
        await cap.seal(tx);
      }
      await tx.rawDelete('DELETE FROM $outbox');
      return sent;
    });
  }
}
