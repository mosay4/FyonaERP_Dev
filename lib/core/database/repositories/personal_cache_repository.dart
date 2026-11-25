import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import '../database_helper.dart';
import '../../../features/personal/data/ledger/personal_ledger.dart';
import '../../../features/personal/data/ledger/personal_local_cutover.dart';
import '../../../features/personal/data/ledger/personal_relay_store.dart';
import '../../offline/sync_integrity.dart';
import '../../offline/sync_operation_types.dart';
import 'sync_outbox.dart';

/// A single mirror-row mutation (upsert or delete) that must be committed
/// atomically together with the operation that caused it.
class MirrorMutation {
  final String entityType;
  final String remoteId;
  final Map<String, dynamic>? row; // null => delete

  const MirrorMutation(this.entityType, this.remoteId, this.row);

  static MirrorMutation upsert(
          String entityType, String remoteId, Map<String, dynamic> row) =>
      MirrorMutation(entityType, remoteId, row);

  static MirrorMutation delete(String entityType, String remoteId) =>
      MirrorMutation(entityType, remoteId, null);
}

/// Local mirror + pending-write queue for the personal finance module.
///
/// Every successful server read is mirrored here (keyed by the server UUID)
/// so the module keeps working when the server is unreachable. Offline writes
/// are also staged here and enqueued into the outbox so the [SyncEngine] can
/// push them once connectivity returns.
///
/// Storage: the signed-in user's encrypted Personal ledger
/// ([PersonalLedger] — `personal_rows` + `personal_outbox`), never the plain
/// app database. Rows keep their integer namespace (`user_id`) exactly as
/// before, so every caller keeps the same API and semantics.
class PersonalCacheRepository {
  static const _rows = PersonalLedgerDatabase.rows;
  static const _outbox = PersonalLedgerDatabase.outbox;

  static Future<PersonalLedgerDatabase> _ledger(int userId) =>
      PersonalLedger.forNamespace(userId);

  static int _versionOf(Map<String, dynamic>? row) {
    final v = row?['_sync_version'];
    return v is num ? v.toInt() : 0;
  }

  /// Upsert of one mirror row (`INSERT OR REPLACE`: a re-written row moves
  /// to the end of the collection order, exactly like the old mirror).
  ///
  /// [cap]: the relay capture of a user-intent commit (server-mirror writes
  /// pass none — they are never sent to the other devices).
  static Future<void> _put(
    DatabaseExecutor db,
    int userId,
    String entityType,
    String id,
    Map<String, dynamic> row, [
    PersonalRelayCapture? cap,
  ]) async {
    await cap?.put(db, entityType, id, row);
    await db.rawInsert(
      'INSERT OR REPLACE INTO $_rows '
      '(user_id, entity_type, id, data_json, updated_us, deleted, version) '
      'VALUES (?, ?, ?, ?, ?, 0, ?)',
      [
        userId,
        entityType,
        id,
        jsonEncode(row),
        DateTime.now().microsecondsSinceEpoch,
        _versionOf(row),
      ],
    );
  }

  static Future<void> _drop(
    DatabaseExecutor db,
    int userId,
    String entityType,
    String id, [
    PersonalRelayCapture? cap,
  ]) async {
    await cap?.drop(db, entityType, id);
    await db.rawDelete(
      'DELETE FROM $_rows WHERE user_id = ? AND entity_type = ? AND id = ?',
      [userId, entityType, id],
    );
  }

  /// Ledger-side namespace wipe (reset account): mirror rows and outbox
  /// operations of [namespaces] only — never other users' data.
  Future<void> wipeNamespaces(Iterable<int> namespaces) async {
    final ns = namespaces.where((n) => n > 0).toSet().toList();
    if (ns.isEmpty) return;
    final db = await _ledger(ns.first);
    final marks = List.filled(ns.length, '?').join(',');
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      if (cap != null) {
        // The reset reaches the user's other devices as one operation.
        for (final r in await tx.rawQuery(
          'SELECT entity_type, id FROM $_rows WHERE user_id IN ($marks) AND deleted = 0',
          ns,
        )) {
          await cap.drop(tx, r['entity_type'] as String, r['id'] as String);
        }
      }
      await tx.rawDelete('DELETE FROM $_rows WHERE user_id IN ($marks)', ns);
      await tx.rawDelete('DELETE FROM $_outbox WHERE user_id IN ($marks)', ns);
      await cap?.seal(tx);
    });
  }

  /// In-memory canonical namespace per real user id, warmed at auth
  /// boundaries (login / session restore / biometric entry) BEFORE any
  /// personal provider runs. Reads during a session NEVER change it, so
  /// mirrors and outbox rows always share one namespace — no flip-flop.
  static final Map<String, int> _memStableIds = {};

  /// Deterministic FNV-1a 31-bit hash — stable across launches by
  /// construction (unlike String.hashCode). Used as the pre-warm fallback
  /// namespace AND to recognize legacy rows for migration.
  static int fnvNamespace(String s) {
    if (s.isEmpty) return 0;
    var h = 0x811C9DC5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  /// Synchronous canonical namespace for a real user id: the warmed stable
  /// id when available, else the deterministic FNV fallback. Every reader
  /// (finance service, sync engine) MUST use this — never String.hashCode
  /// (random per launch) and never a value that changes mid-session.
  ///
  /// Also selects [realUserId]'s encrypted Personal ledger as the active one
  /// (every caller asks for the signed-in user's namespace).
  static int stableIdSync(String realUserId) {
    if (realUserId.isEmpty) return 0;
    PersonalLedger.select(realUserId);
    final fnv = fnvNamespace(realUserId);
    PersonalLedger.registerNamespace(realUserId, fnv);
    final hit = _memStableIds[realUserId];
    if (hit != null && hit > 0) {
      PersonalLedger.registerNamespace(realUserId, hit);
      return hit;
    }
    return fnv;
  }

  /// Warm the canonical namespace for [realUserId]: resolve + persist the
  /// stable mapping, migrate FNV-namespace rows into it, drop orphan mirror
  /// rows under unknown namespaces (server re-pull restores them), cache it
  /// in memory. Call at auth boundaries before personal providers run.
  Future<int> warmStableId(String realUserId) async {
    if (realUserId.isEmpty) return 0;
    PersonalLedger.select(realUserId);
    PersonalLedger.registerNamespace(realUserId, fnvNamespace(realUserId));
    final resolved = await stableUserIdFor(realUserId);
    if (resolved > 0) {
      _memStableIds[realUserId] = resolved;
      PersonalLedger.registerNamespace(realUserId, resolved);
    }
    try {
      await _dropUnknownNamespaceMirrors(realUserId, resolved);
    } catch (_) {}
    return resolved;
  }

  /// Drops MIRROR rows (never outbox rows — unpushed writes must survive)
  /// sitting under namespaces no known user owns. Those rows are invisible
  /// to every reader (wrong-namespace orphans from hashCode-era pulls);
  /// the next online read re-caches them under the canonical namespace.
  Future<void> _dropUnknownNamespaceMirrors(
      String realUserId, int resolved) async {
    final keep = <int>{};
    if (resolved > 0) keep.add(resolved);
    keep.add(fnvNamespace(realUserId));
    try {
      final known = await DatabaseHelper.rawQuery(
        'SELECT real_user_id, local_user_id FROM stable_user_ids',
      );
      for (final r in known) {
        final rid = (r['real_user_id']?.toString() ?? '');
        final lid = (r['local_user_id'] as num?)?.toInt() ?? 0;
        if (lid > 0) keep.add(lid);
        if (rid.isNotEmpty) keep.add(fnvNamespace(rid));
      }
    } catch (_) {}
    if (keep.isEmpty) return;
    final marks = List.filled(keep.length, '?').join(',');
    try {
      final db = await _ledger(resolved > 0 ? resolved : fnvNamespace(realUserId));
      await db.rawDelete(
        'DELETE FROM $_rows WHERE user_id NOT IN ($marks)',
        keep.toList(),
      );
    } catch (_) {}
  }

  /// Returns a STABLE local integer id for the given real user id string.
  ///
  /// The mapping is persisted in `stable_user_ids`, so the same user always
  /// resolves to the same integer across app launches. This is critical for
  /// offline-first: cached rows and the outbox are keyed by this integer, and
  /// a changing value (String.hashCode) silently orphans all offline data.
  ///
  /// On FIRST resolution it also migrates any rows previously stored under a
  /// DIFFERENT integer (the old unstable String.hashCode namespace) into the
  /// new one, so historical offline data is never lost.
  Future<int> stableUserIdFor(String realUserId) async {
    if (realUserId.isEmpty) return 0;
    final rows = await DatabaseHelper.query(
      'stable_user_ids',
      where: 'real_user_id = ?',
      whereArgs: [realUserId],
    );
    final int resolved;
    if (rows.isNotEmpty) {
      resolved = rows.first['local_user_id'] as int;
    } else {
      final maxRows = await DatabaseHelper.rawQuery(
        'SELECT COALESCE(MAX(local_user_id), 0) + 1 AS next_id FROM stable_user_ids',
      );
      final nextId = (maxRows.isNotEmpty ? maxRows.first['next_id'] : 1) as int;
      await DatabaseHelper.rawInsert(
        'INSERT INTO stable_user_ids (real_user_id, local_user_id, created_at) VALUES (?, ?, ?)',
        [realUserId, nextId, DateTime.now().toIso8601String()],
      );
      resolved = nextId;
    }
    // Migrate legacy rows (old hash namespace) into this user's namespace so
    // the data the user created in earlier app versions is not orphaned.
    try {
      // Legacy namespace = any non-stable integer id that has entity_cache
      // rows OR outbox rows for this real user but is not the resolved id.
      // We can't know which others belong to this user directly, so we adopt
      // the previously-used deterministic FNV hash namespace (single extra id).
      final legacy = await _legacyHashNamespace(realUserId);
      if (legacy != null && legacy != resolved) {
        // Rows still in the old plain store (not yet moved to the ledger).
        try {
          await DatabaseHelper.rawUpdate(
            'UPDATE personal_entity_cache SET user_id = ? WHERE user_id = ?',
            [resolved, legacy],
          );
          await DatabaseHelper.rawUpdate(
            'UPDATE sync_queue SET user_id = ? WHERE user_id = ? AND entity_id IS NOT NULL',
            [resolved, legacy],
          );
        } catch (_) {}
        PersonalLedger.registerNamespace(realUserId, resolved);
        final db = await _ledger(resolved);
        await db.rawUpdate(
          'UPDATE $_rows SET user_id = ? WHERE user_id = ?',
          [resolved, legacy],
        );
        await db.rawUpdate(
          'UPDATE $_outbox SET user_id = ? WHERE user_id = ? AND entity_id IS NOT NULL',
          [resolved, legacy],
        );
      }
    } catch (_) {}
    return resolved;
  }

  /// Deterministic FNV-1a 31-bit hash of the real user id — the BEFORE-fix
  /// namespace (the old code used realUserId.hashCode.abs(), but Dart does not
  /// guarantee stability; FNV is our deterministic approximation). Used to
  /// migrate legacy cached rows into the stable namespace.
  Future<int?> _legacyHashNamespace(String s) async {
    if (s.isEmpty) return null;
    var h = 0x811C9DC5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  // ── Read mirror ──

  /// Replaces the remote mirror for an entity type WITHOUT dropping any local
  /// rows that still have a pending (un-synced) operation in the outbox.
  ///
  /// Previously this deleted the whole collection then re-wrote the server rows,
  /// which silently wiped offline-created/edited entries the moment any server
  /// read (or partial pull) succeeded — causing "saved but disappeared" rows.
  Future<void> replaceCollection(
    int userId,
    String entityType,
    List<Map<String, dynamic>> rows,
  ) async {
    // Collect remote (server) ids we are about to store.
    final remoteIds = <String>{};
    final rowsFor = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final rid = row['id']?.toString() ?? '';
      if (rid.isEmpty) continue;
      remoteIds.add(rid);
      rowsFor[rid] = row;
    }
    // Rows of this user/entity that still have a pending/in-progress outbox op
    // must NOT be removed (they are local truth until the server confirms).
    final pendingIds = await _pendingOutboxIds(userId, entityType);
    // Rows with a staged (unconfirmed) DELETE are locally gone: they must
    // neither be re-inserted from the server snapshot below nor kept via the
    // pending set — otherwise a deleted row resurrects on every pull.
    final deleteIds = await pendingDeleteIds(userId, entityType);

    // Read live mirror to know current local ids.
    final db = await _ledger(userId);
    final currentRows = await db.rawQuery(
      'SELECT id AS remote_id, data_json FROM $_rows '
      'WHERE user_id = ? AND entity_type = ?',
      [userId, entityType],
    );
    final currentLocalIds = currentRows.map((r) => r['remote_id']?.toString() ?? '').toSet();
    final currentJson = <String, String>{};
    for (final r in currentRows) {
      final rid = r['remote_id']?.toString() ?? '';
      if (rid.isNotEmpty) currentJson[rid] = r['data_json'] as String? ?? '';
    }

    // Bank rows carrying un-replayed local balance effects keep the local
    // truth too (same family as staged deletes): a server snapshot must not
    // clobber them until their transactions confirm. Goals/debts/budgets
    // moved by the same unconfirmed transactions keep their local derived
    // values for the same reason.
    final guardedBankIds = entityType == 'personal_bank_account'
        ? await pendingTransactionBankIds(userId)
        : const <String>{};
    final guardedLinkedIds =
        (entityType == 'personal_savings_goal' ||
                entityType == 'personal_debt' ||
                entityType == 'personal_budget')
            ? ((await pendingTransactionLinkedIds(userId))[entityType] ??
                const <String>{})
            : const <String>{};
    // Build the final set: every provided server row + every local pending row,
    // minus rows with a staged DELETE (locally gone — never re-inserted).
    // Guarded bank rows stay IN the set (so they are never deleted) but the
    // upsert below keeps their local version untouched.
    final finalIds = <String>{};
    finalIds.addAll(remoteIds.where((id) => !deleteIds.contains(id)));
    finalIds.addAll(pendingIds.where((id) => !deleteIds.contains(id)));
    finalIds.addAll(currentLocalIds.where((id) => !remoteIds.contains(id) && pendingIds.contains(id) && !deleteIds.contains(id)));

    await db.transaction((tx) async {
    // Delete rows that are NOT in the final set (i.e. not server & not pending).
    for (final id in currentLocalIds) {
      if (!finalIds.contains(id)) {
        await _drop(tx, userId, entityType, id);
      }
    }

    // Upsert server rows — but NEVER overwrite a local row that still has a
    // pending outbox operation.  Pending rows are the LOCAL truth (e.g. an
    // offline-created bank account whose balance was bumped by an offline
    // income).  Overwriting them with the (stale) server response would erase
    // the user's offline edits the moment a pull completes.
    for (final id in finalIds) {
      final row = rowsFor[id];
      if ((pendingIds.contains(id) ||
              guardedBankIds.contains(id) ||
              guardedLinkedIds.contains(id)) &&
          currentJson.containsKey(id)) {
        // Pending entity (or bank/goal/debt/budget with unconfirmed local
        // effects): keep the local mirror untouched.
        continue;
      }
      if (row != null) {
        await _put(tx, userId, entityType, id, row);
      }
    }
    });
  }

  /// Returns server rows PLUS any local mirror row that still has a pending
  /// (un-synced) outbox operation. This guarantees offline-created/edited rows
  /// are NEVER hidden by a (possibly empty) server response after reconnect.
  Future<List<Map<String, dynamic>>> mergePendingInto(
    int userId,
    String entityType,
    List<Map<String, dynamic>> serverRows,
  ) async {
    final pendingIds = await _pendingOutboxIds(userId, entityType);
    // Locally-deleted rows (staged DELETE, unconfirmed) must never leak back
    // into the returned list from the server snapshot — they have no mirror
    // row left for the pending-merge below to protect.
    final deleteIds = await pendingDeleteIds(userId, entityType);
    final guardedBankIds = entityType == 'personal_bank_account'
        ? await pendingTransactionBankIds(userId)
        : const <String>{};
    // Goals/debts/budgets moved by an unconfirmed transaction edit or
    // payment keep their local derived values (credit/paid/spent) until
    // that transaction confirms — same family as the bank guard above.
    final guardedLinkedIds =
        (entityType == 'personal_savings_goal' ||
                entityType == 'personal_debt' ||
                entityType == 'personal_budget')
            ? ((await pendingTransactionLinkedIds(userId))[entityType] ??
                const <String>{})
            : const <String>{};
    if (pendingIds.isEmpty &&
        deleteIds.isEmpty &&
        guardedBankIds.isEmpty &&
        guardedLinkedIds.isEmpty) {
      return serverRows;
    }
    final byId = <String, Map<String, dynamic>>{};
    for (final r in serverRows) {
      final rid = r['id']?.toString() ?? '';
      if (rid.isNotEmpty &&
          !deleteIds.contains(rid) &&
          !guardedBankIds.contains(rid) &&
          !guardedLinkedIds.contains(rid)) {
        byId[rid] = r;
      }
    }
    final pendingRows = await (await _ledger(userId)).rawQuery(
      'SELECT data_json FROM $_rows '
      'WHERE user_id = ? AND entity_type = ?',
      [userId, entityType],
    );
    for (final row in pendingRows) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(row['data_json'] as String) as Map);
        final rid = m['id']?.toString() ?? '';
        if (rid.isEmpty) continue;
        if (pendingIds.contains(rid) ||
            guardedBankIds.contains(rid) ||
            guardedLinkedIds.contains(rid)) {
          // ALWAYS prefer local pending version over server version.
          // The local mirror reflects offline edits (e.g. bank balance bumped
          // by an offline transaction) that have not been pushed yet.  Using
          // the server's stale value here is what causes "saved but
          // disappeared" rows the moment the user refreshes after reconnecting.
          // Guarded bank rows (balance touched by an unconfirmed transaction)
          // are returned from the local mirror for the same reason.
          byId[rid] = m;
        }
      } catch (_) {}
    }
    return byId.values.toList();
  }

  /// Ids of this user/entity with a staged DELETE that has not been
  /// server-confirmed yet. Local truth for these rows is "gone": no server
  /// pull/refresh may re-insert them into the mirror, or a just-deleted row
  /// resurrects on screen (and on every reconnect) even though the user
  /// deleted it. Once the DELETE replays, the id leaves this set and normal
  /// behavior resumes. Never throws.
  Future<Set<String>> pendingDeleteIds(int userId, String entityType) async {
    try {
      final rows = await (await _ledger(userId)).rawQuery(
        "SELECT entity_id FROM $_outbox "
        "WHERE entity_type = ? "
        "  AND user_id = ? "
        "  AND operation = 'DELETE' "
        "  AND status IN ('pending', 'syncing', 'failed', 'conflict') "
        "  AND entity_id IS NOT NULL AND entity_id != ''",
        [entityType, userId],
      );
      return rows.map((r) => r['entity_id'].toString()).toSet();
    } catch (_) {
      return const {};
    }
  }

  /// Bank account ids touched by staged (unconfirmed) transaction writes.
  ///
  /// A transaction INSERT/UPDATE moves the account balance in the local
  /// mirror immediately (offline-first). Until the operation replays, no
  /// server snapshot may overwrite that account row — otherwise a just-added
  /// income vanishes (and reads 0) on every refresh/pull/reconnect. Once the
  /// ops confirm, their ids leave this set and normal syncing resumes.
  /// Never throws.
  Future<Set<String>> pendingTransactionBankIds(int userId) async {
    final linked = await pendingTransactionLinkedIds(userId);
    return linked['personal_bank_account'] ?? const <String>{};
  }

  /// Every section a staged (unconfirmed) transaction INSERT/UPDATE moves,
  /// by mirror entity type: the bank/cash account plus the linked savings
  /// goal, debt and budget (goal credit, debt paid, budget spent are derived
  /// locally the moment the user saves — exactly like the balance).
  ///
  /// Until the transaction op is server-confirmed, these rows are local
  /// truth: no server snapshot (refresh, pull, restore re-read) may
  /// overwrite them with the pre-edit values, or an amount edit would stick
  /// on the cards while the goal/debt/budget visibly snap back to the old
  /// number. Read-side protection only — replay behavior is untouched.
  /// Never throws.
  Future<Map<String, Set<String>>> pendingTransactionLinkedIds(
      int userId) async {
    const types = <String>{
      'personal_bank_account',
      'personal_savings_goal',
      'personal_debt',
      'personal_budget',
    };
    final out = <String, Set<String>>{
      for (final t in types) t: <String>{},
    };
    try {
      final rows = await (await _ledger(userId)).rawQuery(
        "SELECT data FROM $_outbox "
        "WHERE entity_type = 'personal_transaction' "
        "  AND user_id = ? "
        "  AND operation IN ('INSERT', 'UPDATE') "
        "  AND status IN ('pending', 'syncing', 'failed', 'conflict')",
        [userId],
      );
      for (final r in rows) {
        try {
          final raw = r['data'] as String?;
          if (raw == null || raw.isEmpty) continue;
          final data = jsonDecode(raw) as Map<String, dynamic>;
          void add(String type, dynamic id) {
            final v = id?.toString() ?? '';
            if (v.isNotEmpty) out[type]!.add(v);
          }

          add('personal_bank_account', data['bank_account_id']);
          add('personal_savings_goal', data['goal_id']);
          add('personal_debt', data['debt_id']);
          add('personal_budget', data['budget_id']);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Ids of this user/entity that still have an outstanding outbox op — ANY
  /// status (pending, syncing, failed, conflict). A failed/conflicted op still
  /// represents local truth that must NOT be deleted from the mirror by a
  /// server pull; the sync engine re-arms transient failures on the next
  /// connectivity gain and conflicts are held for explicit resolution.
  Future<Set<String>> _pendingOutboxIds(int userId, String entityType) async {
    final rows = await (await _ledger(userId)).rawQuery(
      "SELECT entity_id FROM $_outbox "
      "WHERE entity_type = ? "
      "  AND user_id = ? "
      "  AND status IN ('pending', 'syncing', 'failed', 'conflict') "
      "  AND entity_id IS NOT NULL AND entity_id != ''",
      [entityType, userId],
    );
    return rows.map((r) => r['entity_id'].toString()).toSet();
  }

  Future<List<Map<String, dynamic>>> getCollection(int userId, String entityType) async {
    final rows = await (await _ledger(userId)).rawQuery(
      'SELECT data_json FROM $_rows '
      'WHERE user_id = ? AND entity_type = ? AND deleted = 0 ORDER BY seq ASC',
      [userId, entityType],
    );
    return rows.map((r) {
      try {
        return Map<String, dynamic>.from(jsonDecode(r['data_json'] as String) as Map);
      } catch (_) {
        return <String, dynamic>{};
      }
    }).where((m) => m.isNotEmpty).toList();
  }

  /// When the local mirror row was last written (the `updated_at` column),
  /// or null when the row does not exist / has no stamp. Used by the
  /// stale-response guard: a row modified after a fetch started must never
  /// be overwritten by that fetch's (older) snapshot.
  Future<DateTime?> getMirrorUpdatedAt(
      int userId, String entityType, String remoteId) async {
    try {
      final rows = await (await _ledger(userId)).rawQuery(
        'SELECT updated_us FROM $_rows '
        'WHERE user_id = ? AND entity_type = ? AND id = ? LIMIT 1',
        [userId, entityType, remoteId],
      );
      if (rows.isEmpty) return null;
      final us = (rows.first['updated_us'] as num?)?.toInt();
      if (us == null) return null;
      return DateTime.fromMicrosecondsSinceEpoch(us);
    } catch (_) {
      return null;
    }
  }

  Future<void> upsertItem(
    int userId,
    String entityType,
    String remoteId,
    Map<String, dynamic> data,
  ) async {
    await (await _ledger(userId))
        .transaction((tx) => _put(tx, userId, entityType, remoteId, data));
  }

  Future<void> removeItem(int userId, String entityType, String remoteId) async {
    await (await _ledger(userId))
        .transaction((tx) => _drop(tx, userId, entityType, remoteId));
  }

  /// A user's own write of one device-only row (e.g. a category): stored,
  /// and sent to the user's other devices. [row] null deletes it. Unlike
  /// [upsertItem]/[removeItem] (server mirror), this is a user intent.
  Future<void> commitLocalRow(
    int userId,
    String entityType,
    String remoteId,
    Map<String, dynamic>? row,
  ) async {
    final cap = PersonalRelayCapture.begin();
    await (await _ledger(userId)).transaction((tx) async {
      if (row != null) {
        await _put(tx, userId, entityType, remoteId, row, cap);
      } else {
        await _drop(tx, userId, entityType, remoteId, cap);
      }
      await cap?.seal(tx);
    });
  }

  Future<bool> isOfflineCached(int userId, String entityType) async {
    final rows = await (await _ledger(userId)).rawQuery(
      'SELECT 1 FROM $_rows WHERE user_id = ? AND entity_type = ? AND deleted = 0 LIMIT 1',
      [userId, entityType],
    );
    return rows.isNotEmpty;
  }

  // ── Pending writes for the sync engine ──

  /// Device-only Personal (Stage 6): after this user's cutover nothing goes
  /// to the old outbox any more — every intent is a relay operation [cap].
  static bool _oldOutboxRetired(PersonalRelayCapture? cap) =>
      cap != null &&
      PersonalLocalMode.active &&
      PersonalLocalMode.oldSyncRetired;

  Future<void> enqueue(
    int userId,
    String entityType,
    String remoteId,
    String operation, {
    Map<String, dynamic>? data,
    int baseVersion = 0,
    String? operationType,
    String? occurredAt,
    List<Map<String, String>> dependsOn = const [],
  }) async {
    // Route through the durable outbox (idempotent operation_id, device
    // ownership, base_version, semantic operation type, immutable intent
    // time) instead of inserting directly into sync_queue.
    await SyncOutbox.enqueue(
      tableName: entityType,
      entityType: entityType,
      entityId: remoteId,
      operation: operation,
      data: data,
      userId: userId,
      baseVersion: baseVersion,
      operationType: operationType,
      occurredAt: occurredAt,
      dependsOn: dependsOn,
    );
  }

  /// Atomically commit an offline user intent:
  ///  1. the primary mirror row (upsert or delete),
  ///  2. every derived mirror row it affects (bank balance, goal amount,
  ///     debt paid, budget spent, …),
  ///  3. the semantic operation itself in the durable outbox.
  ///
  /// All three happen in ONE SQLite transaction. If any statement fails the
  /// whole intent rolls back — the user never sees a half-applied operation,
  /// and the sync engine never replays an operation whose local effect is
  /// missing (or vice versa).
  Future<void> commitOfflineWrite({
    required int userId,
    required String entityType,
    required String remoteId,
    Map<String, dynamic>? primaryRow, // null => primary delete
    required String operation, // INSERT | UPDATE | DELETE
    Map<String, dynamic>? data,
    String? operationType,
    String? occurredAt,
    int baseVersion = 0,
    String source = 'ui',
    List<MirrorMutation> related = const [],
    List<Map<String, String>> dependsOn = const [],
    bool cancelExistingOps = false,
  }) async {
    final deviceId = await SyncOutbox.getDeviceId();
    final opId = generateOperationId();
    final nowUtc = DateTime.now().toUtc().toIso8601String();
    final nowLocal = DateTime.now().toIso8601String();
    final resolvedType =
        operationType ?? SyncOperationTypes.fromLegacy(operation);
    final occurred = occurredAt ?? nowUtc;

    final db = await _ledger(userId);
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      if (cancelExistingOps) {
        // A new intent for this entity supersedes queued (not yet
        // server-confirmed) operations for it. Conflicts are preserved.
        await tx.rawDelete(
          "DELETE FROM $_outbox WHERE entity_type = ? AND entity_id = ? "
          "AND status IN ('pending','syncing','failed')",
          [entityType, remoteId],
        );
      }
      if (primaryRow != null) {
        await _put(tx, userId, entityType, remoteId, primaryRow, cap);
      } else {
        await _drop(tx, userId, entityType, remoteId, cap);
      }
      for (final m in related) {
        if (m.row != null) {
          await _put(tx, userId, m.entityType, m.remoteId, m.row!, cap);
        } else {
          await _drop(tx, userId, m.entityType, m.remoteId, cap);
        }
      }
      // ── Additive integrity stamp (shadow phase), computed INSIDE the same
      // atomic transaction: per-entity revision (gap detection later),
      // payload fingerprint and explicit idempotency key. The staged bytes
      // and replay behavior are unchanged — three extra nullable columns.
      final storedData = data == null
          ? null
          : <String, dynamic>{...data, 'remote_id': remoteId};
      int? opRevision;
      String? payloadHash;
      String? idempotencyKey;
      try {
        final revRows = await tx.rawQuery(
          'SELECT COALESCE(MAX(op_revision), 0) AS m FROM $_outbox '
          'WHERE entity_type = ? AND entity_id = ?',
          [entityType, remoteId],
        );
        final maxRev = revRows.isNotEmpty
            ? ((revRows.first['m'] as num?)?.toInt() ?? 0)
            : 0;
        opRevision = maxRev + 1;
        if (storedData != null) {
          payloadHash = fingerprintPayload(storedData);
          final clientOp =
              storedData['client_operation_id']?.toString() ?? '';
          idempotencyKey = clientOp.isNotEmpty ? clientOp : opId;
        }
      } catch (_) {
        // Stamp is best-effort metadata: never fail the financial write.
        opRevision = null;
        payloadHash = null;
        idempotencyKey = null;
      }
      // Device-only Personal after the cutover: the intent travels as the
      // relay operation sealed below; the old server sync is off.
      if (!_oldOutboxRetired(cap)) await tx.rawInsert(
        'INSERT INTO $_outbox ('
        'operation_id, operation_type, table_name, entity_type, entity_id, '
        'record_id, user_id, device_id, operation, data, base_version, source, '
        'status, retry_count, depends_on, occurred_at, next_attempt_at, '
        'created_at, updated_at, op_revision, payload_hash, idempotency_key) '
        'VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, ?, ?, ?, ?, ?)',
        [
          opId,
          resolvedType,
          entityType,
          entityType,
          remoteId,
          userId,
          deviceId,
          operation,
          storedData == null ? null : jsonEncode(storedData),
          baseVersion,
          source,
          SyncStatuses.pending,
          dependsOn.isEmpty ? null : jsonEncode(dependsOn),
          occurred,
          nowLocal,
          nowLocal,
          opRevision,
          payloadHash,
          idempotencyKey,
        ],
      );
      // The same intent, for the user's other devices (same transaction).
      await cap?.seal(tx);
    });
  }

  /// Applies mirror mutations in ONE transaction WITHOUT staging any
  /// operation. Used to reverse local effects when an offline intent is
  /// cancelled before it ever reached the server (nothing to replay).
  Future<void> commitMirrorOnly({
    required int userId,
    String? deleteEntityType,
    String? deleteRemoteId,
    List<MirrorMutation> related = const [],
  }) async {
    final db = await _ledger(userId);
    // Nothing to replay on the server, but the other devices may already
    // hold the cancelled row/effects: the reversal travels to them.
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      for (final m in related) {
        if (m.row != null) {
          await _put(tx, userId, m.entityType, m.remoteId, m.row!, cap);
        } else {
          await _drop(tx, userId, m.entityType, m.remoteId, cap);
        }
      }
      if (deleteEntityType != null && deleteRemoteId != null) {
        await _drop(tx, userId, deleteEntityType, deleteRemoteId, cap);
      }
      await cap?.seal(tx);
    });
  }

  /// Atomic transfer: two transaction mirrors + two balance mutations + two
  /// outbox ops in ONE SQLite transaction. Either both legs and both balances
  /// commit together or nothing commits — satisfying the "no deposit without
  /// withdraw" rule. Used by [PersonalFinanceService.transferBetweenAccounts].
  Future<void> commitTransferAtomic({
    required int userId,
    required String outId,
    required Map<String, dynamic> outMirrorRow,
    required Map<String, dynamic> outSend,
    required String inId,
    required Map<String, dynamic> inMirrorRow,
    required Map<String, dynamic> inSend,
    required List<MirrorMutation> balanceMutations,
  }) async {
    final deviceId = await SyncOutbox.getDeviceId();
    final nowLocal = DateTime.now().toIso8601String();
    final nowUtc = DateTime.now().toUtc().toIso8601String();
    // Prepare two ops
    final ops = [
      {'id': outId, 'mirror': outMirrorRow, 'send': outSend, 'type': SyncOperationTypes.transactionCreate},
      {'id': inId, 'mirror': inMirrorRow, 'send': inSend, 'type': SyncOperationTypes.transactionCreate},
    ];
    final db = await _ledger(userId);
    final cap = PersonalRelayCapture.begin();
    await db.transaction((tx) async {
      // Balance mutations first (both accounts)
      for (final m in balanceMutations) {
        if (m.row != null) {
          await _put(tx, userId, m.entityType, m.remoteId, m.row!, cap);
        }
      }
      // Both transaction mirrors
      for (final op in ops) {
        final rid = op['id'] as String;
        final mirror = op['mirror'] as Map<String, dynamic>;
        await _put(tx, userId, 'personal_transaction', rid, {...mirror, 'id': rid}, cap);
      }
      // Both outbox rows (none once the old sync is retired: the relay
      // operation sealed below carries the transfer).
      for (final op in _oldOutboxRetired(cap) ? const <Map<String, dynamic>>[] : ops) {
        final rid = op['id'] as String;
        final send = Map<String, dynamic>.from(op['send'] as Map<String, dynamic>);
        send['id'] = rid;
        send['remote_id'] = rid;
        final opId = generateOperationId();
        final storedData = {...send, 'remote_id': rid};
        int? opRevision;
        String? payloadHash;
        String? idempotencyKey;
        try {
          final revRows = await tx.rawQuery(
            'SELECT COALESCE(MAX(op_revision), 0) AS m FROM $_outbox WHERE entity_type = ? AND entity_id = ?',
            ['personal_transaction', rid],
          );
          final maxRev = revRows.isNotEmpty ? ((revRows.first['m'] as num?)?.toInt() ?? 0) : 0;
          opRevision = maxRev + 1;
          payloadHash = fingerprintPayload(storedData);
          final clientOp = storedData['client_operation_id']?.toString() ?? '';
          idempotencyKey = clientOp.isNotEmpty ? clientOp : opId;
        } catch (_) {
          opRevision = null;
          payloadHash = null;
          idempotencyKey = null;
        }
        await tx.rawInsert(
          'INSERT INTO $_outbox (operation_id, operation_type, table_name, entity_type, entity_id, record_id, user_id, device_id, operation, data, base_version, source, status, retry_count, depends_on, occurred_at, next_attempt_at, created_at, updated_at, op_revision, payload_hash, idempotency_key) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, ?, ?, ?, ?, ?)',
          [
            opId,
            op['type'],
            'personal_transaction',
            'personal_transaction',
            rid,
            userId,
            deviceId,
            'INSERT',
            jsonEncode(storedData),
            0,
            'ui',
            SyncStatuses.pending,
            null,
            nowUtc,
            nowLocal,
            nowLocal,
            opRevision,
            payloadHash,
            idempotencyKey,
          ],
        );
      }
      // Both legs and both balances: one operation for the other devices.
      await cap?.seal(tx);
    });
  }
}
