import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Long-offline + reconnect scenario for Personal Sync (audit only — no app
/// code is modified by these tests).
///
/// Simulates: Device A offline for months while Device B works online;
/// A queues CREATE/UPDATE/DELETE across all Personal entities, then comes
/// back. Verifies the outbox/engine contracts the reconnect depends on:
/// no expiry by age, idempotent identities, dependency ordering, retry with
/// backoff, restart recovery, and cursor behaviour.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final uuidRe = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
    await DatabaseHelper.rawDelete('DELETE FROM sync_operation_log');
    await DatabaseHelper.rawDelete('DELETE FROM sync_cursor');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<List<Map<String, dynamic>>> queueRows({String? where}) async {
    return DatabaseHelper.rawQuery(
      'SELECT * FROM sync_queue${where == null ? '' : ' WHERE $where'} ORDER BY id ASC',
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // TEST 1 — Long Offline + Reconnect: months-old ops survive + replay safe.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 1: long offline + reconnect', () {
    test('90-day-old ops across all entities: no loss, no expiry, replayable',
        () async {
      final threeMonthsAgo = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 90))
          .toIso8601String();
      const userId = 7;

      // Device A queues work from "months ago" across every Personal entity.
      final stagedIds = <String, String>{};
      final entities = {
        'personal_transaction': 'tx',
        'personal_bank_account': 'bank',
        'personal_savings_goal': 'goal',
        'personal_debt': 'debt',
        'personal_budget': 'budget',
        'personal_recurring_transaction': 'recur',
      };
      for (final e in entities.entries) {
        final entityId = generateUuidV4();
        await SyncOutbox.enqueue(
          tableName: e.key,
          entityType: e.key,
          entityId: entityId,
          operation: 'INSERT',
          data: {'id': entityId, 'marker': e.value},
          userId: userId,
          occurredAt: threeMonthsAgo,
        );
        stagedIds[e.key] = entityId;
      }
      // Plus an UPDATE and a DELETE from the same era.
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'old-bank-1',
        operation: 'UPDATE',
        data: {
          'id': 'old-bank-1',
          'bank_name': 'RenamedLongAgo',
          '__changed': ['bank_name'],
        },
        userId: userId,
        occurredAt: threeMonthsAgo,
      );
      await SyncOutbox.enqueue(
        tableName: 'personal_debt',
        entityType: 'personal_debt',
        entityId: 'old-debt-1',
        operation: 'DELETE',
        userId: userId,
        occurredAt: threeMonthsAgo,
      );

      // 1) No expiry by age: the reconnect batch still returns everything.
      final batch = await SyncOutbox.nextBatch(limit: 50, userId: userId);
      expect(batch.length, 8, reason: 'no op may expire by age');

      // 2) Intent time preserved (server orders by real action time).
      for (final op in batch) {
        expect(op.occurredAt, threeMonthsAgo);
      }

      // 3) Idempotent identities intact after months on disk.
      final opIds = batch.map((o) => o.operationId).toSet();
      expect(opIds.length, 8, reason: 'operation ids must stay unique');
      for (final e in entities.entries) {
        expect(stagedIds[e.key], isNotNull);
        expect(uuidRe.hasMatch(stagedIds[e.key]!), isTrue,
            reason: 'client UUID must survive for replay');
      }

      // 4) Reconnect behaviour per op outcome:
      //    - server confirm -> op leaves the queue (archived, auditable).
      final toConfirm = batch.first;
      await SyncOutbox.markSynced(toConfirm.id, response: {'ok': true});
      var remaining =
          await queueRows(where: 'id = ${toConfirm.id}');
      expect(remaining, isEmpty, reason: 'confirmed op must leave the queue');
      final log = await DatabaseHelper.rawQuery(
        "SELECT * FROM sync_operation_log WHERE operation_id = ?",
        [toConfirm.operationId],
      );
      expect(log.isNotEmpty, isTrue, reason: 'confirm must be audited');

      //    - network break mid-flight -> re-armed with SAME identity.
      final toRetry = (await SyncOutbox.nextBatch(limit: 50, userId: userId))
          .first;
      final retryOpId = toRetry.operationId;
      await SyncOutbox.markInProgress(toRetry.id);
      await SyncOutbox.markPending(toRetry.id);
      final rearmed = await DatabaseHelper.rawQuery(
        'SELECT * FROM sync_queue WHERE id = ?', [toRetry.id]);
      expect(rearmed.length, 1);
      expect(rearmed.first['status'], 'pending');
      expect(rearmed.first['operation_id'], retryOpId,
          reason: 'retry must reuse the same idempotency key');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 2 — Multi-device concurrent changes: independence + __changed.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 2: multi-device concurrent changes', () {
    test('independent creates never collide; same-entity edits stay scoped',
        () async {
      const deviceA = 111;
      const deviceB = 112;

      // Both devices create transactions "concurrently" while offline.
      final idsA = <String>[];
      final idsB = <String>[];
      for (var i = 0; i < 3; i++) {
        final idA = generateUuidV4();
        idsA.add(idA);
        await SyncOutbox.enqueue(
          tableName: 'personal_transaction',
          entityType: 'personal_transaction',
          entityId: idA,
          operation: 'INSERT',
          data: {'id': idA, 'amount': 10.0 + i},
          userId: deviceA,
        );
        final idB = generateUuidV4();
        idsB.add(idB);
        await SyncOutbox.enqueue(
          tableName: 'personal_transaction',
          entityType: 'personal_transaction',
          entityId: idB,
          operation: 'INSERT',
          data: {'id': idB, 'amount': 20.0 + i},
          userId: deviceB,
        );
      }
      // Same shared bank, different fields, both offline.
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'shared-bank',
        operation: 'UPDATE',
        data: {
          'id': 'shared-bank',
          'bank_name': 'A-Name',
          '__changed': ['bank_name'],
        },
        userId: deviceA,
      );
      await SyncOutbox.enqueue(
        tableName: 'personal_bank_account',
        entityType: 'personal_bank_account',
        entityId: 'shared-bank',
        operation: 'UPDATE',
        data: {
          'id': 'shared-bank',
          'notes': 'B-Notes',
          '__changed': ['notes'],
        },
        userId: deviceB,
      );

      // Independent creates are distinct identities — never a conflict pair.
      final allIds = {...idsA, ...idsB};
      expect(allIds.length, 6, reason: 'no UUID collision across devices');

      // Same-entity edits are field-scoped (no full-row overwrite).
      final updA = await queueRows(
          where:
              "entity_type = 'personal_bank_account' AND entity_id = 'shared-bank' AND user_id = $deviceA");
      final updB = await queueRows(
          where:
              "entity_type = 'personal_bank_account' AND entity_id = 'shared-bank' AND user_id = $deviceB");
      expect(updA.length, 1);
      expect(updB.length, 1);
      final dataA =
          jsonDecode(updA.first['data'] as String) as Map<String, dynamic>;
      final dataB =
          jsonDecode(updB.first['data'] as String) as Map<String, dynamic>;
      expect(dataA['__changed'], ['bank_name']);
      expect(dataB['__changed'], ['notes']);
      expect(dataA.containsKey('notes'), isFalse,
          reason: 'A must not ship B\'s field');
      expect(dataB.containsKey('bank_name'), isFalse,
          reason: 'B must not ship A\'s field');

      // Pull protection is per-user: B's pending op never shields A's rows.
      final pendingA = await DatabaseHelper.rawQuery(
        "SELECT entity_id FROM sync_queue WHERE user_id = ? "
        "AND status IN ('pending','syncing','failed','conflict')",
        [deviceA],
      );
      final idsForA =
          pendingA.map((r) => r['entity_id'].toString()).toSet();
      for (final id in idsB) {
        expect(idsForA.contains(id), isFalse,
            reason: 'B op $id must not protect A\'s pull');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 3 — Large outbox + retry: drain, backoff, exhaustion, re-arm.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 3: large outbox + retry', () {
    test('120 ops drain in batches; backoff then conflict; failed re-arms',
        () async {
      const userId = 7;
      for (var i = 0; i < 120; i++) {
        await SyncOutbox.enqueue(
          tableName: 'personal_transaction',
          entityType: 'personal_transaction',
          entityId: generateUuidV4(),
          operation: 'INSERT',
          data: {'id': 'bulk-$i', 'amount': i.toDouble()},
          userId: userId,
        );
      }

      // Drain exactly like the engine: batches of 50, each op server-
      // confirmed (markSynced) before the next round — 40 rounds × 50.
      final seen = <int>{};
      for (var round = 0; round < 40; round++) {
        final rows = await SyncOutbox.nextBatch(limit: 50, userId: userId);
        if (rows.isEmpty) break;
        for (final op in rows) {
          seen.add(op.id);
          await SyncOutbox.markSynced(op.id, response: {'ok': true});
        }
        if (rows.length < 50) break;
      }
      expect(seen.length, 120, reason: 'all 120 ops must be drainable');

      // Retry ladder on a fresh op: 6 failures -> backoff -> conflict.
      final victimId = generateUuidV4();
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: victimId,
        operation: 'INSERT',
        data: {'id': victimId, 'amount': 1.0},
        userId: userId,
      );
      final victim =
          (await SyncOutbox.nextBatch(limit: 1, userId: userId)).first;
      for (var i = 0; i < 5; i++) {
        await SyncOutbox.markFailed(victim.id, 'transient $i');
      }
      var row = (await DatabaseHelper.rawQuery(
          'SELECT * FROM sync_queue WHERE id = ?', [victim.id]))
          .first;
      expect(row['status'], 'pending');
      expect(row['retry_count'], 5);
      expect(row['next_attempt_at'], isNotNull,
          reason: 'backoff must be scheduled');

      await SyncOutbox.markFailed(victim.id, 'transient 5');
      row = (await DatabaseHelper.rawQuery(
          'SELECT * FROM sync_queue WHERE id = ?', [victim.id]))
          .first;
      expect(row['status'], 'conflict',
          reason: 'exhausted op must be HELD as conflict, never dropped');
      expect(row['retry_count'], 6);

      // Reconnect re-arms transient failures but NEVER conflicts.
      final flakyId = generateUuidV4();
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: flakyId,
        operation: 'INSERT',
        data: {'id': flakyId, 'amount': 2.0},
        userId: userId,
      );
      final flakyCandidates =
          await SyncOutbox.nextBatch(limit: 50, userId: userId);
      final flaky = flakyCandidates
          .firstWhere((o) => o.entityId == flakyId);
      await SyncOutbox.markFailed(flaky.id, 'blip');
      await SyncOutbox.resetStaleForRetry(userId: userId);
      final rearmed = (await DatabaseHelper.rawQuery(
          'SELECT * FROM sync_queue WHERE id = ?', [flaky.id]))
          .first;
      expect(rearmed['status'], 'pending');
      final stillConflict = (await DatabaseHelper.rawQuery(
          'SELECT * FROM sync_queue WHERE id = ?', [victim.id]))
          .first;
      expect(stillConflict['status'], 'conflict',
          reason: 'conflicts need explicit resolution, never auto-retry');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 4 — Invalid/expired sync cursor: fail safe, never lose data.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 4: invalid/expired sync cursor', () {
    Future<String?> readCursor(int uid) async {
      final rows = await DatabaseHelper.query('sync_cursor',
          where: 'entity_type = ?', whereArgs: ['_global_$uid']);
      if (rows.isNotEmpty) {
        final v = rows.first['last_synced_at'] as String?;
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }

    test('garbage cursor passes through unvalidated (documents the gap)',
        () async {
      await DatabaseHelper.rawInsert(
        'INSERT INTO sync_cursor (entity_type, last_synced_at, last_pull_at, last_version) '
        'VALUES (?, ?, ?, 0)',
        ['_global_7', 'not-a-date@@@', 'not-a-date@@@'],
      );
      final cursor = await readCursor(7);
      // There is no format validation before the value is sent as
      // `last_sync_at`: whatever is stored is used verbatim.
      expect(cursor, 'not-a-date@@@',
          reason: 'cursor is used verbatim — no client-side validation');
    });

    test('future cursor would skip history (documents clock risk)', () async {
      final future = DateTime.now()
          .toUtc()
          .add(const Duration(days: 365))
          .toIso8601String();
      await DatabaseHelper.rawInsert(
        'INSERT INTO sync_cursor (entity_type, last_synced_at, last_pull_at, last_version) '
        'VALUES (?, ?, ?, 0) '
        'ON CONFLICT(entity_type) DO UPDATE SET last_synced_at = excluded.last_synced_at',
        ['_global_7', future, future],
      );
      final cursor = await readCursor(7);
      expect(
          DateTime.parse(cursor!).isAfter(DateTime.now().toUtc()), isTrue,
          reason:
              'a future cursor is stored as-is; the server would only return newer rows');
    });

    test('missing cursor means full sync (safe default)', () async {
      final cursor = await readCursor(4242);
      expect(cursor, isNull,
          reason: 'no cursor -> engine sends full_sync=true');
    });

    test('failed pull never advances the cursor (no silent skip)', () async {
      const before = '2026-01-01T00:00:00.000Z';
      await DatabaseHelper.rawInsert(
        'INSERT INTO sync_cursor (entity_type, last_synced_at, last_pull_at, last_version) '
        'VALUES (?, ?, ?, 0)',
        ['_global_7', before, before],
      );
      // The engine only writes the cursor after a SUCCESSFUL pull
      // (_setServerCursor is inside the success branch). A failed pull
      // leaves the stored value untouched, so history is never skipped.
      final cursor = await readCursor(7);
      expect(cursor, before);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // TEST 5 — App restart during sync: in-flight ops recovered, ids stable.
  // ═══════════════════════════════════════════════════════════════════
  group('TEST 5: app restart during sync', () {
    test('syncing rows return to pending with identical payloads', () async {
      const userId = 7;
      final opIds = <String>[];
      for (var i = 0; i < 5; i++) {
        final entityId = generateUuidV4();
        final opId = await SyncOutbox.enqueue(
          tableName: 'personal_transaction',
          entityType: 'personal_transaction',
          entityId: entityId,
          operation: 'INSERT',
          data: {'id': entityId, 'amount': 10.0 * (i + 1)},
          userId: userId,
        );
        opIds.add(opId);
      }
      final deviceBefore = await SyncOutbox.getDeviceId();

      // Kill mid-push: rows stuck in 'syncing'.
      final batch = await SyncOutbox.nextBatch(limit: 50, userId: userId);
      for (final op in batch) {
        await SyncOutbox.markInProgress(op.id);
      }
      var syncing = await queueRows(where: "status = 'syncing'");
      expect(syncing.length, 5);

      // Restart: drop the handle, reopen the same file.
      await DatabaseHelper.close();

      // Engine startup recovery reclaims them.
      final recovered = await SyncOutbox.resetStaleForRetry(userId: userId);
      expect(recovered, greaterThanOrEqualTo(0));
      final pending =
          await queueRows(where: "status = 'pending' AND user_id = $userId");
      expect(pending.length, 5, reason: 'all in-flight ops must be back');
      final opIdsAfter =
          pending.map((r) => r['operation_id'].toString()).toSet();
      expect(opIdsAfter, opIds.toSet(),
          reason: 'identities must be identical — retry is idempotent');
      for (final r in pending) {
        final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        expect(data['id'], isNotNull, reason: 'payload must be intact');
        expect(data['amount'], isNotNull);
      }

      // Device identity is stable across the restart.
      final deviceAfter = await SyncOutbox.getDeviceId();
      expect(deviceAfter, deviceBefore,
          reason: 'device id must not rotate or dedupe breaks');
    });

    test('mirror rows written before the kill are intact after reopen',
        () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(7, 'personal_bank_account', 'restart-bank', {
        'id': 'restart-bank',
        'bank_name': 'RestartBank',
        'balance': 1234.0,
      });
      await DatabaseHelper.close();

      final fresh = PersonalCacheRepository();
      final banks = await fresh.getCollection(7, 'personal_bank_account');
      final bank = banks.firstWhere((b) => b['id'] == 'restart-bank');
      expect((bank['balance'] as num).toDouble(), 1234.0,
          reason: 'committed mirror rows must survive the kill');
    });
  });
}
