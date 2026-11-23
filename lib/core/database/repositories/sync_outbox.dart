import 'dart:convert';
import 'dart:core';
import 'dart:math';
import '../database_helper.dart';
import '../../offline/sync_operation_types.dart';
import '../../offline/sync_integrity.dart';

/// Schema of one operation in the durable outbox (operation journal).
class PendingOperation {
  final int id;
  final String operationId;
  final String tableName;
  final String? entityType;
  final String? entityId;
  final String operation; // INSERT | UPDATE | DELETE (legacy tri-state)
  final String operationType; // semantic op (TRANSACTION_CREATE, …)
  final Map<String, dynamic> data;
  final int baseVersion;
  final String source;
  final String status;
  final int retryCount;
  final String? errorMessage;
  final String? deviceId;
  /// The user's intent time (ISO-8601, UTC). Immutable — never rewritten by
  /// a sync/retry, so ordering across devices reflects the real action time.
  final String occurredAt;
  /// Queue admission time (ISO-8601, local).
  final String createdAt;
  /// Entities this operation depends on (parents that must exist server-side).
  final List<Map<String, String>> dependsOn;
  // ── Additive integrity metadata (v15+, all nullable) ──
  /// Per-entity op sequence (1-based). Enables future gap detection.
  /// Null on legacy rows — replay treats them exactly as before.
  final int? opRevision;
  /// FNV-1a fingerprint of the staged payload (see sync_integrity.dart).
  /// Null on legacy rows (shadow verification skips them) and on ops with
  /// no payload.
  final String? payloadHash;
  /// Explicit idempotency key (client_operation_id when the intent carries
  /// one, else the operation_id). Informational in shadow phase.
  final String? idempotencyKey;

  const PendingOperation({
    required this.id,
    required this.operationId,
    required this.tableName,
    this.entityType,
    this.entityId,
    required this.operation,
    this.operationType = SyncOperationTypes.entityCreate,
    required this.data,
    this.baseVersion = 0,
    this.source = 'ui',
    this.status = 'pending',
    this.retryCount = 0,
    this.errorMessage,
    this.deviceId,
    this.occurredAt = '',
    this.createdAt = '',
    this.dependsOn = const [],
    this.opRevision,
    this.payloadHash,
    this.idempotencyKey,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'operation_id': operationId,
        'operation_type': operationType,
        'table_name': tableName,
        'entity_type': entityType,
        'entity_id': entityId,
        'operation': operation,
        'data': data,
        'base_version': baseVersion,
        'source': source,
        'status': status,
        'retry_count': retryCount,
        'error_message': errorMessage,
        'device_id': deviceId,
        'occurred_at': occurredAt,
        'created_at': createdAt,
        'depends_on': dependsOn,
        'op_revision': opRevision,
        'payload_hash': payloadHash,
        'idempotency_key': idempotencyKey,
      };
}

final Random _rng = Random();

String _randomHex(int bytes) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Globally-unique operation id (idempotency key): time + device + entropy.
String generateOperationId() =>
    'op_${DateTime.now().microsecondsSinceEpoch}_${_randomHex(8)}';

/// Crypto-grade UUID v4 (RFC 4122) used for offline-created entity ids.
String generateUuidV4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40; // version 4
  b[8] = (b[8] & 0x3F) | 0x80; // variant 10
  final hex = List.generate(16, (i) => b[i].toRadixString(16).padLeft(2, '0'));
  return '${hex[0]}${hex[1]}${hex[2]}${hex[3]}-'
      '${hex[4]}${hex[5]}-'
      '${hex[6]}${hex[7]}-'
      '${hex[8]}${hex[9]}-'
      '${hex[10]}${hex[11]}${hex[12]}${hex[13]}${hex[14]}${hex[15]}';
}

/// [SyncOutbox] — durable, operation-based outbox for offline-first writes.
///
/// Guarantees:
///  * Every user intent gets a globally-unique `operation_id` (idempotency
///    key) BEFORE it can reach the server.
///  * Operations are ONLY archived after the server confirms them; nothing is
///    dropped on send.
///  * Failures are retried with a backoff schedule; permanent failures and
///    conflicts are KEPT (never silently deleted) so financial data cannot
///    disappear.
///  * Deletes/cancellations are archived to `sync_operation_log` for audit.
class SyncOutbox {
  static const int maxRetries = 6;

  /// The local device identifier, stable across restarts.
  static Future<String> getDeviceId() async {
    final rows = await DatabaseHelper.query('sync_device_info');
    if (rows.isNotEmpty) return rows.first['device_id'].toString();
    final id = generateUuidV4();
    await DatabaseHelper.insert('sync_device_info', {
      'device_id': id,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    return id;
  }

  /// Enqueue a new operation. Idempotent per (operation_id).
  static Future<String> enqueue({
    required String tableName,
    String? entityType,
    String? entityId,
    required String operation,
    Map<String, dynamic>? data,
    int baseVersion = 0,
    String source = 'ui',
    int? userId,
    String? deviceId,
    String? operationType,
    String? occurredAt,
    List<Map<String, String>> dependsOn = const [],
  }) async {
    final opId = generateOperationId();
    final dev = deviceId != null ? deviceId : await getDeviceId();
    final uid = userId ?? await activeUserId();
    final resolvedEntityId = entityId ?? data?['id']?.toString();
    final now = DateTime.now().toUtc().toIso8601String();
    // `remote_id` travels inside the payload (legacy contract) so mirror
    // rows, queued operations and the server share one identity.
    final payload = data == null
        ? null
        : {
            ...data,
            if (resolvedEntityId != null && resolvedEntityId.isNotEmpty)
              'remote_id': resolvedEntityId,
          };
    // ── Additive integrity stamp (shadow phase) ──
    // Per-entity revision (gap detection later), payload fingerprint and an
    // explicit idempotency key. Best-effort outside a txn here; the primary
    // writer (commitOfflineWrite) stamps atomically with the mirror row.
    // Replay payloads and behavior are unchanged by these columns.
    final integrity = await _integrityStamp(
      entityType: entityType ?? tableName,
      entityId: resolvedEntityId,
      payload: payload,
      opId: opId,
    );
    await DatabaseHelper.insert('sync_queue', {
      'operation_id': opId,
      'operation_type': operationType ?? SyncOperationTypes.fromLegacy(operation),
      'table_name': tableName,
      'entity_type': entityType ?? tableName,
      'entity_id': resolvedEntityId,
      'record_id': null,
      'user_id': uid,
      'device_id': dev,
      'operation': operation,
      'data': payload != null ? jsonEncode(payload) : null,
      'base_version': baseVersion,
      'source': source,
      'status': SyncStatuses.pending,
      'retry_count': 0,
      'depends_on': dependsOn.isEmpty ? null : jsonEncode(dependsOn),
      'occurred_at': occurredAt ?? now,
      'next_attempt_at': null,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'op_revision': integrity.revision,
      'payload_hash': integrity.hash,
      'idempotency_key': integrity.key,
    });
    return opId;
  }

  /// Computes the additive integrity stamp for one staged operation.
  /// Never throws: on any failure all three fields stay null (legacy shape).
  static Future<({int? revision, String? hash, String? key})>
      _integrityStamp({
    required String entityType,
    String? entityId,
    Map<String, dynamic>? payload,
    required String opId,
  }) async {
    try {
      int? revision;
      if (entityId != null && entityId.isNotEmpty) {
        final rows = await DatabaseHelper.rawQuery(
          'SELECT COALESCE(MAX(op_revision), 0) AS m FROM sync_queue '
          'WHERE entity_type = ? AND entity_id = ?',
          [entityType, entityId],
        );
        final max = rows.isNotEmpty
            ? ((rows.first['m'] as num?)?.toInt() ?? 0)
            : 0;
        revision = max + 1;
      }
      final hash =
          payload != null ? fingerprintPayload(payload) : null;
      final key = (payload?['client_operation_id']?.toString().isNotEmpty ==
              true)
          ? payload!['client_operation_id'].toString()
          : opId;
      return (revision: revision, hash: hash, key: key);
    } catch (_) {
      return (revision: null, hash: null, key: null);
    }
  }

  static Future<int?> activeUserId() async {
    final rows = await DatabaseHelper.query('users', limit: 1);
    return rows.isNotEmpty ? rows.first['id'] as int? : null;
  }

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Fetch the next batch of operations ready to run.
  ///
  /// Ready = `pending` (including re-armed retries whose backoff elapsed),
  /// plus `syncing` rows that were left dangling by a crash/kill (stale by
  /// [staleSyncingAfter]), plus retryable `failed` rows under the retry cap.
  /// Never returns `conflict` rows — those are held for explicit resolution.
  static Future<List<PendingOperation>> nextBatch({
    int limit = 50,
    Duration staleSyncingAfter = const Duration(minutes: 2),
    int? userId,
  }) async {
    final now = _nowIso();
    final staleBefore =
        DateTime.now().toUtc().subtract(staleSyncingAfter).toIso8601String();
    final userClause = userId != null ? ' AND user_id = $userId' : '';
    final rows = await DatabaseHelper.rawQuery(
      "SELECT * FROM sync_queue "
      "WHERE ((status = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?)) "
      "   OR (status = 'syncing' AND updated_at <= ?) "
      "   OR (status = 'failed' AND retry_count < ${maxRetries.toString()} "
      "       AND (next_attempt_at IS NULL OR next_attempt_at <= ?)))"
      "$userClause "
      "ORDER BY occurred_at ASC, id ASC LIMIT ${limit.toString()}",
      [now, staleBefore, now],
    );
    return rows.map(_fromRow).toList();
  }

  static Future<List<PendingOperation>> pendingByDevice({
    String? deviceId,
    int? userId,
  }) async {
    final where = <String>[];
    final args = <dynamic>[];
    if (deviceId != null) {
      where.add('device_id = ?');
      args.add(deviceId);
    }
    if (userId != null) {
      where.add('user_id = ?');
      args.add(userId);
    }
    where.add("status = 'pending'");
    final rows = await DatabaseHelper.rawQuery(
      'SELECT * FROM sync_queue WHERE ${where.join(' AND ')} ORDER BY occurred_at ASC',
      args,
    );
    return rows.map(_fromRow).toList();
  }

  static PendingOperation _fromRow(Map<String, dynamic> r) {
    final rawData = r['data'] as String?;
    List<Map<String, String>> deps = const [];
    try {
      final rawDeps = r['depends_on'] as String?;
      if (rawDeps != null && rawDeps.isNotEmpty) {
        deps = (jsonDecode(rawDeps) as List)
            .whereType<Map>()
            .map((m) => {
                  'entity_type': m['entity_type']?.toString() ?? '',
                  'entity_id': m['entity_id']?.toString() ?? '',
                })
            .where((m) => (m['entity_id'] ?? '').isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return PendingOperation(
      id: r['id'] as int,
      operationId: r['operation_id']?.toString() ?? '',
      tableName: r['table_name']?.toString() ?? '',
      entityType: r['entity_type']?.toString(),
      entityId: r['entity_id']?.toString(),
      operation: r['operation']?.toString() ?? 'INSERT',
      operationType: r['operation_type']?.toString().isNotEmpty == true
          ? r['operation_type'].toString()
          : SyncOperationTypes.fromLegacy(
              r['operation']?.toString() ?? 'INSERT'),
      data: (rawData != null && rawData.isNotEmpty)
          ? (jsonDecode(rawData) as Map<String, dynamic>?) ?? <String, dynamic>{}
          : <String, dynamic>{},
      baseVersion: (r['base_version'] as num?)?.toInt() ?? 0,
      source: r['source']?.toString() ?? 'ui',
      status: r['status']?.toString() ?? 'pending',
      retryCount: (r['retry_count'] as num?)?.toInt() ?? 0,
      errorMessage: r['error_message']?.toString(),
      deviceId: r['device_id']?.toString(),
      occurredAt: r['occurred_at']?.toString() ??
          r['created_at']?.toString() ??
          '',
      createdAt: r['created_at']?.toString() ?? '',
      dependsOn: deps,
      // Additive integrity metadata: absent (null) on legacy rows, which
      // replay exactly as before.
      opRevision: (r['op_revision'] as num?)?.toInt(),
      payloadHash: r['payload_hash']?.toString(),
      idempotencyKey: r['idempotency_key']?.toString(),
    );
  }

  /// Mark an operation as in-flight. Stale `syncing` rows are reclaimed by
  /// [nextBatch] after 2 minutes so a killed app never wedges an operation.
  static Future<void> markInProgress(int id) async {
    await DatabaseHelper.rawUpdate(
      "UPDATE sync_queue SET status = 'syncing', updated_at = ? WHERE id = ?",
      [_nowIso(), id],
    );
  }

  static Future<void> markPending(int id) async {
    await DatabaseHelper.rawUpdate(
      "UPDATE sync_queue SET status = 'pending', updated_at = ? WHERE id = ?",
      [_nowIso(), id],
    );
  }

  /// Server-confirmed success — ONLY now the operation leaves the queue.
  /// It is archived to `sync_operation_log` first (full audit trail).
  static Future<void> markSynced(
    int id, {
    Map<String, dynamic>? response,
    String? archivedStatus,
  }) async {
    await _archiveById(id,
        status: archivedStatus ?? 'synced', response: response);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue WHERE id = ?', [id]);
  }

  /// Record a failure. Transient failures are re-armed with exponential
  /// backoff; when retries are exhausted (or `permanent`) the row is kept in
  /// `conflict` state for explicit resolution — never deleted.
  static Future<void> markFailed(
    int id,
    String error, {
    bool permanent = false,
    Map<String, dynamic>? response,
  }) async {
    final row = await DatabaseHelper.query('sync_queue',
        where: 'id = ?', whereArgs: [id]);
    if (row.isEmpty) return;
    final retryCount = ((row.first['retry_count'] as num?)?.toInt() ?? 0) + 1;
    final exhausted = permanent || retryCount >= maxRetries;
    final nextStatus =
        exhausted ? SyncStatuses.conflict : SyncStatuses.pending;
    String? nextAttempt;
    if (!exhausted) {
      final backoffSeconds = min(300, 5 * (1 << min(retryCount, 6)));
      nextAttempt = DateTime.now()
          .toUtc()
          .add(Duration(seconds: backoffSeconds))
          .toIso8601String();
    }
    await DatabaseHelper.rawUpdate(
      'UPDATE sync_queue SET status = ?, retry_count = ?, error_message = ?, '
      'next_attempt_at = ?, updated_at = ? WHERE id = ?',
      [
        nextStatus,
        retryCount,
        error,
        nextAttempt,
        _nowIso(),
        id,
      ],
    );
    // Conflicts are mirrored into the archive immediately for visibility.
    if (exhausted) {
      await _archiveById(id,
          status: 'conflict', response: response, errorOverride: error);
    }
  }

  /// Explicit conflict: the server rejected the intent in a way that cannot be
  /// auto-resolved (or an operation references a deleted parent). The row is
  /// HELD, never dropped, until the user/system resolves it.
  static Future<void> markConflict(
    int id,
    String error, {
    Map<String, dynamic>? response,
  }) async {
    await DatabaseHelper.rawUpdate(
      "UPDATE sync_queue SET status = 'conflict', error_message = ?, updated_at = ? WHERE id = ?",
      [error, _nowIso(), id],
    );
    await _archiveById(id,
        status: 'conflict', response: response, errorOverride: error);
  }

  static Future<void> _archiveById(
    int id, {
    required String status,
    Map<String, dynamic>? response,
    String? errorOverride,
  }) async {
    try {
      final rows = await DatabaseHelper.query('sync_queue',
          where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final r = rows.first;
      await DatabaseHelper.rawInsert(
        'INSERT INTO sync_operation_log '
        '(operation_id, operation_type, entity_type, entity_id, operation, '
        ' status, device_id, user_id, occurred_at, created_at, synced_at, '
        ' retry_count, attempts, error_message, response_json) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          r['operation_id']?.toString(),
          r['operation_type']?.toString(),
          r['entity_type']?.toString(),
          r['entity_id']?.toString(),
          r['operation']?.toString(),
          status,
          r['device_id']?.toString(),
          r['user_id'],
          r['occurred_at']?.toString(),
          r['created_at']?.toString(),
          _nowIso(),
          (r['retry_count'] as num?)?.toInt() ?? 0,
          1,
          errorOverride ?? r['error_message']?.toString(),
          response == null ? null : jsonEncode(response),
        ],
      );
    } catch (_) {
      // Archiving is best-effort; the operation itself must still proceed.
    }
  }

  static Future<int> pendingCount({int? userId}) async {
    final rows = await DatabaseHelper.rawQuery(
        "SELECT COUNT(*) as c FROM sync_queue WHERE status IN ('pending','syncing')"
        "${userId != null ? ' AND user_id = $userId' : ''}");
    return rows.isNotEmpty ? (rows.first['c'] as num?)?.toInt() ?? 0 : 0;
  }

  static Future<int> failedCount({int? userId}) async {
    final rows = await DatabaseHelper.rawQuery(
        "SELECT COUNT(*) as c FROM sync_queue WHERE status = 'failed'"
        "${userId != null ? ' AND user_id = $userId' : ''}");
    return rows.isNotEmpty ? (rows.first['c'] as num?)?.toInt() ?? 0 : 0;
  }

  static Future<int> conflictCount({int? userId}) async {
    final rows = await DatabaseHelper.rawQuery(
        "SELECT COUNT(*) as c FROM sync_queue WHERE status = 'conflict'"
        "${userId != null ? ' AND user_id = $userId' : ''}");
    return rows.isNotEmpty ? (rows.first['c'] as num?)?.toInt() ?? 0 : 0;
  }

  /// Resets stale operations so the next sync round retries them.
  ///
  /// Called when Internet returns:
  ///  - transient `failed` ops are re-armed (conflicts are NEVER re-armed
  ///    blindly; they need explicit resolution),
  ///  - dangling `syncing` rows from a crashed app are reclaimed.
  static Future<int> resetStaleForRetry({int? userId}) async {
    final now = _nowIso();
    final userClause = userId != null ? ' AND user_id = $userId' : '';
    final rearmed = await DatabaseHelper.rawUpdate(
      "UPDATE sync_queue SET status = 'pending', next_attempt_at = NULL, updated_at = ? "
      "WHERE status = 'failed'$userClause",
      [now],
    );
    await DatabaseHelper.rawUpdate(
      "UPDATE sync_queue SET status = 'pending', updated_at = ? WHERE status = 'syncing'$userClause",
      [now],
    );
    return rearmed;
  }

  /// Drops every pending/syncing/failed op staged for one entity (used when
  /// the entity is deleted before sync: nothing must replay afterwards).
  /// Cancelled operations are archived for audit.
  static Future<void> cancelEntityOps({
    required String entityType,
    required String entityId,
    int? userId,
  }) async {
    if (entityId.isEmpty) return;
    final rows = await DatabaseHelper.rawQuery(
      userId != null
          ? "SELECT id FROM sync_queue WHERE user_id = ? AND entity_type = ? AND entity_id = ? AND status IN ('pending','syncing','failed')"
          : "SELECT id FROM sync_queue WHERE entity_type = ? AND entity_id = ? AND status IN ('pending','syncing','failed')",
      userId != null
          ? [userId, entityType, entityId]
          : [entityType, entityId],
    );
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      await _archiveById(id, status: 'cancelled');
      await DatabaseHelper.rawDelete('DELETE FROM sync_queue WHERE id = ?', [id]);
    }
  }

  /// Compacts redundant metadata UPDATE history for BUSINESS (non-personal)
  /// entities only. The personal section's operation journal is NEVER
  /// coalesced: every transaction/payment/contribution operation is replayed
  /// exactly once, in order, so no financial effect can be lost.
  static Future<void> coalesce({int? userId}) async {
    await DatabaseHelper.rawQuery("""
      DELETE FROM sync_queue
      WHERE id IN (
        SELECT s2.id FROM sync_queue s2
        JOIN (
          SELECT entity_type, entity_id, MAX(id) AS max_id
          FROM sync_queue
          WHERE status IN ('pending','syncing')
            AND entity_type NOT LIKE 'personal%'
          GROUP BY entity_type, entity_id
        ) latest ON s2.entity_type = latest.entity_type AND s2.entity_id = latest.entity_id
        WHERE s2.id <> latest.max_id
          AND s2.entity_type NOT LIKE 'personal%'
      )
    """);
  }
}
