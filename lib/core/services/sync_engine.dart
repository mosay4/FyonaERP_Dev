import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';
import '../database/repositories/personal_cache_repository.dart';
import '../database/repositories/sync_outbox.dart';
import '../di/repository_providers.dart';
import '../database/providers/database_providers.dart';
import '../network/api_endpoints.dart';
import '../network/dio_provider.dart';
import '../../features/auth/di/auth_providers.dart';
import '../offline/offline_guard.dart';
import '../offline/sync_integrity.dart';
import '../offline/sync_logger.dart';
import '../offline/sync_operation_types.dart';
import '../services/currency/currency_engine.dart';
import 'connectivity_service.dart';

/// Connectivity states surfaced to the UI (single source of truth).
class SyncState {
  static const offline = 'offline';
  static const online = 'online';
  static const connecting = 'connecting';
  static const syncing = 'syncing';
  static const synced = 'synced';
  static const syncError = 'sync_error';

  /// Session/token expired while ops are still queued. Ops are kept
  /// pending/retryable (never conflicted) and resume automatically after the
  /// next successful login — no manual resolution needed. Unknown to older
  /// UI code, which safely falls through to its default branch.
  static const authNeeded = 'auth_needed';
}

/// Local-First, operation-based synchronisation engine for the PERSONAL
/// section.
///
/// Design principles (non-negotiable for financial correctness):
///  1. The UI never waits for the network — writes land in the local mirror +
///     durable outbox transactionally; the engine replays them later.
///  2. Every operation is replayed through the EXACT same REST endpoint the
///     online path uses. This reuses the server's atomic accounting
///     (deduct/credit/reverse) instead of shipping absolute balances, which
///     would lose money whenever two devices operate concurrently.
///  3. Replays are idempotent: `client_operation_id` (transactions/payments/
///     contributions) and client-generated entity UUIDs (creates) guarantee a
///     retried operation can never duplicate.
///  4. Operations are removed from the outbox ONLY after server confirmation;
///     conflicts are retained and surfaced — never dropped silently.
class SyncEngine {
  final Ref _ref;
  /// Test/dev hook: pins the local user namespace (one virtual device per
  /// namespace) without needing the full auth provider tree.
  final int? _userIdOverride;
  Timer? _timer;
  bool _isSyncing = false;
  bool _disposed = false;
  ConnectivityService? _connectivity;
  StreamSubscription? _connectivitySub;
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  String _status = SyncState.online;

  SyncEngine(this._ref, {int? userIdOverride}) : _userIdOverride = userIdOverride;

  /// Global sync status (synced / syncing / offline / sync_error / pending).
  Stream<String> get onStatusChanged => _statusController.stream;
  String get status => _status;

  /// True while the session is expired/dead and queued ops are waiting for
  /// the next successful login. Ops stay pending/retryable — never
  /// conflicted — and resume automatically once a replay succeeds.
  /// In-memory only: after a kill the flag rebuilds itself on the first 401,
  /// while the ops themselves wait safely in the durable outbox.
  bool _authNeeded = false;
  bool get isAuthNeeded => _authNeeded;

  void _setAuthNeeded(bool v) {
    _authNeeded = v;
    if (v) _updateStatus(SyncState.authNeeded);
  }

  /// True while a push/pull cycle is running (used by the UI and by tests to
  /// wait for a cycle to settle rather than racing it).
  bool get isSyncing => _isSyncing;

  int get _activeUserId {
    final override = _userIdOverride;
    if (override != null && override > 0) return override;
    final authState = _ref.read(authProvider);
    final userId = authState.user?.id;
    if (userId != null && userId.isNotEmpty) {
      // SAME canonical namespace as the finance service (warmed stable id or
      // deterministic FNV). Never String.hashCode — it is random per launch
      // and used to scatter orphan mirror rows across namespaces.
      return PersonalCacheRepository.stableIdSync(userId);
    }
    return 1;
  }

  Future<void> init() async {
    _connectivity = _ref.read(connectivityServiceProvider);
    try {
      await _connectivity!.init();
    } catch (_) {
      // Offline-safe: connectivity probe failures must never crash startup.
      _updateStatus(SyncState.offline);
    }
    _updateStatus(
        _connectivity!.isOnline ? SyncState.online : SyncState.offline);
    _connectivitySub = _connectivity!.onConnectivityChanged.listen((online) {
      if (online) {
        _updateStatus(SyncState.syncing);
        // Re-arm operations that were stuck while the network was down.
        try {
          unawaited(SyncOutbox.resetStaleForRetry(userId: _activeUserId));
        } catch (_) {}
        processQueue();
      } else {
        _updateStatus(SyncState.offline);
      }
    });
    // Periodic auto-sync: 30s when online (lightweight — skips if queue empty).
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_connectivity?.isOnline ?? false) processQueue();
    });
    _updateStatus(
        _connectivity!.isOnline ? SyncState.online : SyncState.offline);
  }

  void _updateStatus(String s) {
    if (_disposed || _statusController.isClosed) return;
    if (_status == s) return;
    _status = s;
    _statusController.add(s);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connectivitySub?.cancel();
    _connectivity?.dispose();
    _statusController.close();
  }

  Future<void> processQueue() async {
    if (_disposed || _isSyncing || !(_connectivity?.isOnline ?? false)) return;
    _isSyncing = true;
    _updateStatus(SyncState.syncing);
    try {
      // Recover operations left in-flight by a killed/crashed app.
      await SyncOutbox.resetStaleForRetry(userId: _activeUserId);
      // Auth recovery: a previous 401/403 parked ops as pending under
      // `authNeeded`. Nothing to do explicitly — the push below replays
      // them; the first success clears the flag. But if the current user
      // has nothing queued (logout / switched account), drop the stale flag
      // so normal pull/status behaviour resumes.
      if (_authNeeded) {
        final pending = await SyncOutbox.pendingCount(userId: _activeUserId);
        final failed = await SyncOutbox.failedCount(userId: _activeUserId);
        if (pending == 0 && failed == 0) _setAuthNeeded(false);
      }
      await SyncOutbox.coalesce(userId: _activeUserId);
      await _pushPending();
      // While the session is dead there is no point pulling (it would 401
      // too); the next cycle after a successful push pulls normally.
      if (!_authNeeded) await _pullRemote();
      final pending = await SyncOutbox.pendingCount(userId: _activeUserId);
      final failed = await SyncOutbox.failedCount(userId: _activeUserId);
      final conflicts = await SyncOutbox.conflictCount(userId: _activeUserId);
      if (_authNeeded && (pending > 0 || failed > 0)) {
        _updateStatus(SyncState.authNeeded);
      } else {
        _updateStatus(pending == 0 && failed == 0 && conflicts == 0
            ? SyncState.synced
            : SyncState.syncError);
      }
    } catch (e) {
      SyncLogger.error('processQueue', e);
      _updateStatus(SyncState.syncError);
    } finally {
      _isSyncing = false;
      // keep polling for success feedback without spamming
      Timer(const Duration(seconds: 2), () {
        if (_status == SyncState.syncing || _status == SyncState.syncError) {
          _updateStatus(_connectivity?.isOnline ?? false
              ? SyncState.online
              : SyncState.offline);
        }
      });
    }
  }

  /// Local convenience: reads the small progress counters without full sync.
  Future<Map<String, dynamic>> localSyncSnapshot() async {
    return {
      'pending': await SyncOutbox.pendingCount(userId: _activeUserId),
      'failed': await SyncOutbox.failedCount(userId: _activeUserId),
      'conflicts': await SyncOutbox.conflictCount(userId: _activeUserId),
      'status': _status,
    };
  }

  // ═══ PUSH (outbox → server, exact operation replay) ═══

  Future<void> _pushPending() async {
    // Drain the outbox in batches so a single sync cycle can replay hundreds
    // of queued operations (500+ offline ops requirement).
    for (var round = 0; round < 40; round++) {
      // NOTE: no _authNeeded check here on purpose — the first op of every
      // round is the recovery probe: after a re-login it succeeds and clears
      // the flag; with a still-dead session it 401s once and the per-op
      // guard below stops the round.
      if (!(_connectivity?.isOnline ?? false)) return;
      final rows = await SyncOutbox.nextBatch(limit: 50, userId: _activeUserId);
      if (rows.isEmpty) return;
      // Dependency order: definitions first, financial mutations next,
      // deletes last; within a bucket, real intent time (occurred_at) decides.
      rows.sort((a, b) {
        final pa = SyncOperationTypes.priority(
            a.entityType ?? a.tableName, a.operationType);
        final pb = SyncOperationTypes.priority(
            b.entityType ?? b.tableName, b.operationType);
        if (pa != pb) return pa - pb;
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        if (byTime != 0) return byTime;
        return a.id - b.id;
      });
      // Legacy-queue guard: while an unreplayed debt payment / goal
      // contribution references a bank account, its absolute-balance
      // fragments must not be pushed (the atomic replay applies the exact
      // delta instead). Those ops stay pending and sync on the next cycle.
      final pendingPaymentAccounts = <String>{};
      for (final r in rows) {
        final canonical = _canonicalOperationType(r);
        if (canonical == SyncOperationTypes.debtPayment ||
            canonical == SyncOperationTypes.goalContribute) {
          final acc = (r.data['bank_account_id'] ?? '').toString();
          if (acc.isNotEmpty) pendingPaymentAccounts.add(acc);
        }
      }
      // The first op of every round is always attempted: it is the recovery
      // probe (after a re-login it succeeds and clears the flag; with a
      // still-dead session it 401s once and the guard below stops the
      // round). Without this, a stale flag would deadlock recovery.
      var firstAttemptDone = false;
      for (final op in rows) {
        // Stop the round as soon as the session proves dead: every further
        // op would 401 identically. Ops stay pending; the next cycle (after
        // re-login) resumes with the same identities.
        if (!(_connectivity?.isOnline ?? false)) return;
        if (_authNeeded && firstAttemptDone) return;
        if (pendingPaymentAccounts.contains(op.entityId) &&
            (op.entityType ?? '') == 'personal_bank_account' &&
            op.operation == 'UPDATE') {
          continue;
        }
        await _dispatch(op);
        firstAttemptDone = true;
      }
      if (rows.length < 50) return;
    }
  }

  Future<void> _dispatch(PendingOperation op) async {
    final entityType = op.entityType ?? op.tableName;
    await SyncOutbox.markInProgress(op.id);
    // ── Shadow integrity observation (phase 1) ──
    // Verifies the staged bytes survived intact until replay. LOGS ONLY:
    // legacy rows (no hash) pass, mismatches are reported, and replay ALWAYS
    // proceeds unchanged below — payload, ordering and conflict handling are
    // byte-for-byte identical with or without this block.
    try {
      final intact = verifyStagedIntegrity(
        data: op.data,
        expectedHash: op.payloadHash,
      );
      if (!intact) {
        SyncLogger.error('integrity', 'payload drift detected', {
          'op': op.operationId,
          'type': op.operationType,
          'entity': entityType,
          'id': op.entityId,
          'revision': op.opRevision,
        });
      }
    } catch (_) {}
    SyncLogger.info('push', {
      'op': op.operationId,
      'type': op.operationType,
      'entity': entityType,
      'id': op.entityId,
      'occurred': op.occurredAt,
      'retry': op.retryCount,
    });
    try {
      final result = await _replay(op, entityType);
      if (result.remapFrom != null &&
          result.remapFrom!.isNotEmpty &&
          result.remapTo != null &&
          result.remapTo!.isNotEmpty &&
          result.remapFrom != result.remapTo) {
        // The server already held this intent under another identity
        // (idempotent dedupe). Anchor the canonical row first so the next
        // pull — even if it fails or misses — can never make it vanish.
        await reconcileRemap(
          cache: _cache,
          userId: _activeUserId,
          entityType: entityType,
          response: result.response,
          remapFrom: result.remapFrom,
          remapTo: result.remapTo,
        );
      }
      if (entityType == 'personal_transaction' &&
          _canonicalOperationType(op) == SyncOperationTypes.transactionCreate &&
          result.remapFrom == null) {
        // Anchor the server-confirmed row BEFORE the queue guard below is
        // deleted: the follow-up pull runs afterwards and may legitimately
        // miss the row (cursor already advanced), which would otherwise
        // leave it unprotected in that window. Same-UUID upsert: idempotent.
        try {
          final row = Map<String, dynamic>.from(result.response);
          final rid = (row['id'] ?? '').toString();
          if (rid.isNotEmpty) {
            row['id'] = rid;
            row.remove('deduped');
            await _cache.upsertItem(_activeUserId, entityType, rid, row);
          }
        } catch (_) {}
      }
      await SyncOutbox.markSynced(op.id, response: result.response);
      // A successful replay proves the session is alive again: clear the
      // auth block so the round continues and pull runs afterwards.
      if (_authNeeded) _setAuthNeeded(false);
    } on DioException catch (e) {
      await _handleDioFailure(op, entityType, e);
    } on _SyncConflictException catch (e) {
      SyncLogger.error('conflict', e, {'op': op.operationId});
      await SyncOutbox.markConflict(op.id, e.message);
    } catch (e) {
      if (isConnectivityError(e)) {
        await SyncOutbox.markPending(op.id);
        _updateStatus(SyncState.offline);
      } else {
        SyncLogger.error('dispatch', e, {'op': op.operationId});
        await SyncOutbox.markFailed(op.id, e.toString());
      }
    }
  }

  Future<void> _handleDioFailure(
      PendingOperation op, String entityType, DioException e) async {
    final status = e.response?.statusCode;
    if (isConnectivityError(e)) {
      // Network broke mid-flight — re-arm for the next cycle. Idempotency
      // keys/ids prevent any server-side duplicate on the retry.
      await SyncOutbox.markPending(op.id);
      _updateStatus(SyncState.offline);
      SyncLogger.info('network-break', {'op': op.operationId});
      return;
    }
    final message = _serverMessage(e);
    SyncLogger.error('server-reject', e, {
      'op': op.operationId,
      'status': status,
      'message': message,
    });
    // Expired/revoked session (the TokenRefreshInterceptor already tried and
    // failed before this 401 surfaced; 403 never qualifies for refresh).
    // NEVER conflict these: the intent is valid, only the session is dead.
    // The op is re-armed untouched — same row, same operation_id, same retry
    // count (no exhaustion) — and the round stops until the next login, at
    // which point the first replay either succeeds (flag cleared) or 401s
    // again (flag stays, still pending). Nothing is deleted before a server
    // confirmation.
    if (status == 401 || status == 403) {
      await SyncOutbox.markPending(op.id);
      // Drop any stale retry backoff so the post-login cycle replays
      // immediately instead of waiting out an old transient backoff.
      try {
        await DatabaseHelper.rawUpdate(
          'UPDATE sync_queue SET next_attempt_at = NULL, updated_at = ? WHERE id = ?',
          [DateTime.now().toUtc().toIso8601String(), op.id],
        );
      } catch (_) {}
      _setAuthNeeded(true);
      SyncLogger.info('auth-needed', {'op': op.operationId, 'status': status});
      return;
    }
    // 404 on DELETE: the row is already gone server-side → success.
    if (status == 404 && op.operationType.endsWith('DELETE')) {
      await SyncOutbox.markSynced(op.id, response: {'already_deleted': true});
      return;
    }
    // Missing dependency (parent not yet materialised server-side) or a
    // transient version/ordering race: keep retrying; parents are pushed
    // first inside the same cycle and the next cycle retries.
    if (status == 404 || (status == 400 && _looksLikeMissingParent(message))) {
      await SyncOutbox.markFailed(op.id, message,
          permanent: false, response: {'status': status});
      return;
    }
    // Anything else (validation, insufficient balance on replay, permission,
    // deleted parent) is a CONFLICT: the operation is kept for explicit
    // resolution — financial data is never discarded.
    await SyncOutbox.markConflict(op.id, message, response: {
      'status': status,
      'message': message,
    });
  }

  bool _looksLikeMissingParent(String message) {
    return message.contains('غير موجود') ||
        message.contains('not found') ||
        message.contains('not yet');
  }

  String _serverMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final detail = data['detail'] ?? data['message'];
      if (detail is String && detail.trim().isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) {
        return detail['message'] as String;
      }
    }
    return 'HTTP ${e.response?.statusCode ?? '?'}';
  }

  Options get _replayOptions => Options(headers: {
        'X-Sync-Replay': '1',
      }, validateStatus: (s) => s != null && s >= 200 && s < 300);

  /// Replays ONE operation through the exact endpoint the online path uses.
  /// Returns a [_ReplayResult] carrying the raw server response and any
  /// identity remap (server dedupe returned a canonical different id).
  Future<_ReplayResult> _replay(PendingOperation op, String entityType) async {
    final client = _ref.read(apiClientProvider);
    final data = Map<String, dynamic>.from(op.data)
      ..remove('_sync_version');
    final id = op.entityId ?? data['id']?.toString() ?? '';
    final operationType = _canonicalOperationType(op);
    SyncLogger.info('replay', {
      'op': op.operationId,
      'kind': operationType,
      'id': id,
    });

    switch (entityType) {
      case 'personal_bank_account':
        return _replayEntity(
          client,
          collection: ApiEndpoints.personalFinanceAccounts,
          itemPath: ApiEndpoints.personalFinanceAccount(id),
          id: id,
          operationType: operationType,
          data: data,
        );
      case 'personal_savings_goal':
        return _replayEntity(
          client,
          collection: ApiEndpoints.personalFinanceGoals,
          itemPath: ApiEndpoints.personalFinanceGoal(id),
          id: id,
          operationType: operationType,
          data: data,
        );
      case 'personal_debt':
        // Legacy {paid,is_paid}-only fragments: `paid` is DERIVED server-side
        // from payment records and must never be pushed as absolute state.
        if ((op.operationType == SyncOperationTypes.entityUpdate ||
                operationType == SyncOperationTypes.debtUpdate) &&
            !data.containsKey('person_name')) {
          return const _ReplayResult(response: {'superseded': true});
        }
        return _replayEntity(
          client,
          collection: ApiEndpoints.personalFinanceDebts,
          itemPath: ApiEndpoints.personalFinanceDebt(id),
          id: id,
          operationType: operationType,
          data: data,
        );
      case 'personal_budget':
        return _replayEntity(
          client,
          collection: ApiEndpoints.personalFinanceBudgets,
          itemPath: ApiEndpoints.personalFinanceBudget(id),
          id: id,
          operationType: operationType,
          data: data,
        );
      case 'personal_recurring_transaction':
        return _replayEntity(
          client,
          collection: ApiEndpoints.personalFinanceRecurring,
          itemPath: ApiEndpoints.personalFinanceRecurringItem(id),
          id: id,
          operationType: operationType,
          data: data,
        );
      case 'personal_transaction':
        if (operationType == SyncOperationTypes.transactionUpdate) {
          // Same standard entity road as every other personal type
          // (bank/goal/debt/budget/recurring): scoped __changed-only PATCH
          // plus orphan self-heal — so tx edits propagate exactly like all
          // other edits. Same endpoints, same idempotency, same conflict
          // handling downstream; only the body construction is unified.
          return _replayEntity(
            client,
            collection: ApiEndpoints.personalFinanceTransactions,
            itemPath: ApiEndpoints.personalFinanceTransaction(id),
            id: id,
            operationType: operationType,
            data: data,
          );
        }
        return _replayTransaction(client, op, id, operationType, data);
      default:
        throw _SyncConflictException('Unsupported personal entity: $entityType');
    }
  }

  /// Maps legacy (pre-journal) transaction ops onto their semantic operation.
  String _canonicalOperationType(PendingOperation op) {
    if (op.operationType == SyncOperationTypes.entityCreate &&
        (op.entityType ?? '') == 'personal_transaction') {
      final debtId = (op.data['debt_id'] ?? '').toString();
      final category = (op.data['category'] ?? '').toString();
      if (debtId.isNotEmpty && category == 'سداد دين') {
        return SyncOperationTypes.debtPayment;
      }
      if ((op.data['goal_id'] ?? '').toString().isNotEmpty &&
          op.data.containsKey('goal_amount')) {
        return SyncOperationTypes.goalContribute;
      }
      return SyncOperationTypes.transactionCreate;
    }
    return op.operationType;
  }

  /// CRUD replay for definitional entities. Creates carry the client UUID so
  /// both sides share one identity; updates are naturally idempotent (absolute
  /// field set / balance set); deletes are terminal.
  Future<_ReplayResult> _replayEntity(
    dynamic client, {
    required String collection,
    required String itemPath,
    required String id,
    required String operationType,
    required Map<String, dynamic> data,
  }) async {
    if (id.isEmpty) {
      // Cannot replay an identity-less operation.
      return const _ReplayResult(response: {'skipped': 'missing_id'});
    }
    final isCreate = operationType.endsWith('_CREATE') ||
        operationType == SyncOperationTypes.entityCreate;
    final isDelete = operationType.endsWith('_DELETE') ||
        operationType == SyncOperationTypes.entityDelete;
    if (isCreate) {
      final body = Map<String, dynamic>.from(data)
        ..remove('__changed');
      final resp = await client.post(collection, data: body, options: _replayOptions);
      final respMap = _asMap(resp.data);
      return _ReplayResult(response: respMap);
    }
    if (isDelete) {
      final resp = await client.delete(itemPath, options: _replayOptions);
      return _ReplayResult(response: _asMap(resp.data));
    }
    // UPDATE (or an explicit BALANCE_SET for a bank account). Only the fields
    // the user actually changed are sent.
    final body = _explicitChanges(data);
    try {
      final resp = await client.patch(itemPath, data: body, options: _replayOptions);
      return _ReplayResult(response: _asMap(resp.data));
    } on DioException catch (e) {
      // Self-heal: a legacy orphan UPDATE (its CREATE never reached the
      // server) is promoted to an idempotent create carrying the same UUID.
      if (e.response?.statusCode == 404) {
        final created = Map<String, dynamic>.from(data)
          ..remove('__changed');
        final resp = await client.post(collection, data: created, options: _replayOptions);
        return _ReplayResult(response: _asMap(resp.data));
      }
      rethrow;
    }
  }

  /// Extracts the explicit-change subset recorded by the offline writer.
  /// Falls back to the full payload for legacy ops (no marker) minus
  /// transport-only keys.
  Map<String, dynamic> _explicitChanges(Map<String, dynamic> data) {
    final copy = Map<String, dynamic>.from(data)
      ..remove('remote_id');
    final changed = copy.remove('__changed');
    if (changed is List) {
      final keys = changed.map((e) => e.toString()).toSet();
      final out = <String, dynamic>{};
      keys.forEach((k) {
        if (copy.containsKey(k)) out[k] = copy[k];
      });
      // The contract requires at least one field; an empty edit is a no-op.
      if (out.isEmpty) return {'id': copy['id']};
      return out;
    }
    return copy;
  }

  Future<_ReplayResult> _replayTransaction(
    dynamic client,
    PendingOperation op,
    String id,
    String operationType,
    Map<String, dynamic> data,
  ) async {
    final clientOpId =
        (data['client_operation_id']?.toString().trim().isNotEmpty == true
                ? data['client_operation_id'].toString()
                : op.operationId);
    switch (operationType) {
      case SyncOperationTypes.goalContribute:
      case SyncOperationTypes.goalContributionDelete:
        final goalId = (data['goal_id'] ?? '').toString();
        if (operationType == SyncOperationTypes.goalContributionDelete) {
          final resp = await client.delete(
              ApiEndpoints.personalFinanceTransaction(id),
              options: _replayOptions);
          return _ReplayResult(response: _asMap(resp.data));
        }
        if (goalId.isEmpty) {
          return const _ReplayResult(response: {'skipped': 'missing_goal'});
        }
        final body = <String, dynamic>{
          'amount': data['amount'],
          if (data['goal_amount'] != null) 'goal_amount': data['goal_amount'],
          if (data['currency'] != null) 'currency': data['currency'],
          if ((data['bank_account_id'] ?? '').toString().isNotEmpty)
            'bank_account_id': data['bank_account_id'],
          if (data['payment_method'] != null)
            'payment_method': data['payment_method'],
          if (data['category'] != null) 'category': data['category'],
          if (data['description'] != null)
            'description': data['description'],
          'tx_id': id,
          'client_operation_id': clientOpId,
        };
        final resp = await client.post(
            ApiEndpoints.personalFinanceGoalContribute(goalId),
            data: body,
            options: _replayOptions);
        final bodyMap = _asMap(resp.data);
        return _replayResultFromDedupe(op, bodyMap, 'contribution_tx');
      case SyncOperationTypes.debtPayment:
      case SyncOperationTypes.debtPaymentDelete:
        final debtId = (data['debt_id'] ?? '').toString();
        if (operationType == SyncOperationTypes.debtPaymentDelete) {
          final resp = await client.delete(
              ApiEndpoints.personalFinanceTransaction(id),
              options: _replayOptions);
          return _ReplayResult(response: _asMap(resp.data));
        }
        if (debtId.isEmpty) {
          return const _ReplayResult(response: {'skipped': 'missing_debt'});
        }
        final body = <String, dynamic>{
          'amount': data['amount'],
          'payment_date': data['payment_date'] ?? data['date'],
          if ((data['bank_account_id'] ?? '').toString().isNotEmpty)
            'bank_account_id': data['bank_account_id'],
          'payment_method': data['payment_method'] ?? 'cash',
          if (data['currency'] != null) 'currency': data['currency'],
          if (data['debt_amount'] != null) 'debt_amount': data['debt_amount'],
          if (data['notes'] != null) 'notes': data['notes'],
          'tx_id': id,
          'client_operation_id': clientOpId,
        };
        final resp = await client.post(
            ApiEndpoints.personalFinanceDebtPayments(debtId),
            data: body,
            options: _replayOptions);
        return _replayResultFromDedupe(op, _asMap(resp.data), null);
      case SyncOperationTypes.transactionDelete:
        final resp = await client.delete(
            ApiEndpoints.personalFinanceTransaction(id),
            options: _replayOptions);
        return _ReplayResult(response: _asMap(resp.data));
      case SyncOperationTypes.transactionCreate:
      default:
        final body = Map<String, dynamic>.from(data);
        body['id'] = id;
        body['client_operation_id'] = clientOpId;
        final resp = await client.post(ApiEndpoints.personalFinanceTransactions,
            data: body, options: _replayOptions);
        final respMap = _asMap(resp.data);
        if (respMap['deduped'] == true) {
          final canonical = (respMap['id'] ?? '').toString();
          if (canonical.isNotEmpty && canonical != id) {
            return _ReplayResult(
                response: respMap, remapFrom: id, remapTo: canonical);
          }
        }
        return _ReplayResult(response: respMap);
    }
  }

  _ReplayResult _replayResultFromDedupe(
      PendingOperation op, Map<String, dynamic> body, String? nestedKey) {
    Map<String, dynamic>? nested;
    if (nestedKey != null && body[nestedKey] is Map) {
      nested = Map<String, dynamic>.from(body[nestedKey] as Map);
    }
    final canonical = nested?['id']?.toString() ?? body['id']?.toString() ?? '';
    final entityId = op.entityId ?? '';
    if (body['deduped'] == true &&
        canonical.isNotEmpty &&
        entityId.isNotEmpty &&
        canonical != entityId) {
      return _ReplayResult(
          response: body, remapFrom: entityId, remapTo: canonical);
    }
    return _ReplayResult(response: body);
  }

  Map<String, dynamic> _asMap(dynamic body) {
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return body;
    }
    if (body is Map) return Map<String, dynamic>.from(body);
    return <String, dynamic>{};
  }

  static const _personalEntities = {
    'personal_bank_account',
    'personal_savings_goal',
    'personal_debt',
    'personal_budget',
    'personal_recurring_transaction',
    'personal_transaction',
  };

  // ═══ PULL (server → local mirror, incremental per entity type) ═══

  Future<void> _pullRemote() async {
    try {
      final repo = _ref.read(syncRepositoryProvider);
      final lastSync = await _lastServerCursor();
      final resp = await repo.pull({
        'last_sync_at': lastSync,
        'entity_types': null,
        'full_sync': lastSync == null,
      });
      if (resp.success && resp.data != null) {
        final entities = resp.data['entities'] as List<dynamic>? ?? [];
        // OFFLINE-FIRST: never let the pull overwrite or delete a mirror row
        // that still has an un-synced outbox operation. Local truth wins
        // until the queued op is server-confirmed.
        final pending = <String>{};
        try {
          final prow = await DatabaseHelper.rawQuery(
            "SELECT entity_type, entity_id FROM sync_queue "
            "WHERE status IN ('pending', 'syncing', 'failed', 'conflict') "
            "AND user_id = ? "
            "AND entity_id IS NOT NULL AND entity_id != ''",
            [_activeUserId],
          );
          for (final r in prow) {
            pending.add(
                '${r['entity_type']?.toString() ?? ''}|${r['entity_id']?.toString() ?? ''}');
          }
        } catch (_) {}
        // Bank rows carrying un-replayed local balance effects (same family
        // as staged deletes): the pull must not clobber them with the stale
        // server snapshot until their transactions confirm.
        Set<String> guardedBanks = const {};
        try {
          guardedBanks = await _cache.pendingTransactionBankIds(_activeUserId);
        } catch (_) {}
        for (final c in entities) {
          final table = c['entity_type'] as String?;
          final recordId = c['entity_id']?.toString() ?? '';
          if (table == null || !_personalEntities.contains(table) || recordId.isEmpty) continue;
          if (pending.contains('$table|$recordId')) {
            // Local truth wins until its queued op is server-confirmed.
            continue;
          }
          final recordData = c['data'] as Map<String, dynamic>?;
          // SAFE pull semantics:
          //  - A server tombstone (deleted=true) removes the local row.
          //  - A row with NO data is kept locally — deleting it here is what
          //    "zeroed out" accounts built offline and never pushed.
          if (c['deleted'] == true) {
            await _cache.removeItem(_activeUserId, table, recordId);
            continue;
          }
          if (recordData == null) {
            continue;
          }
          if (table == 'personal_bank_account' &&
              guardedBanks.contains(recordId)) {
            // Balance touched by an unconfirmed local transaction: keep the
            // local mirror row instead of the stale server snapshot.
            continue;
          }
          // Inject the server-side entity version so a later DELETE carries
          // the correct base_version.
          final version = (c['version'] as num?)?.toInt() ?? 1;
          recordData['_sync_version'] = version;
          await _cache.upsertItem(_activeUserId, table, recordId, recordData);
        }
        // Use the SERVER'S clock for the cursor — client clock skew would
        // otherwise skip changes written between the local "now" and reality.
        final serverTime = (resp.data['server_time']?.toString().isNotEmpty ==
                true)
            ? resp.data['server_time'].toString()
            : DateTime.now().toUtc().toIso8601String();
        await _setServerCursor(serverTime);
        SyncLogger.info('pull', {
          'user': _activeUserId,
          'since': lastSync,
          'full': lastSync == null,
          'entities': entities.length,
          'pendingLocal': pending.length,
          'cursor': serverTime,
        });
      }
    } catch (e) {
      SyncLogger.error('pull', e);
      // pull is best-effort; connectivity errors surface via status
    }
  }

  Future<String?> _lastServerCursor() async {
    final key = '_global_$_activeUserId';
    final rows = await DatabaseHelper.query('sync_cursor',
        where: 'entity_type = ?', whereArgs: [key]);
    if (rows.isNotEmpty) {
      final v = rows.first['last_synced_at'] as String?;
      if (v != null && v.isNotEmpty) return v;
    }
    final meta = await DatabaseHelper.rawQuery(
      'SELECT MAX(last_synced_at) as last_sync FROM sync_metadata',
    );
    if (meta.isNotEmpty) {
      final v = meta.first['last_sync'] as String?;
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  Future<void> _setServerCursor(String iso) async {
    final key = '_global_$_activeUserId';
    await DatabaseHelper.rawInsert(
      "INSERT INTO sync_cursor (entity_type, last_synced_at, last_pull_at, last_version) "
      "VALUES (?, ?, ?, 0) "
      "ON CONFLICT(entity_type) DO UPDATE SET last_synced_at = excluded.last_synced_at, last_pull_at = excluded.last_pull_at",
      [key, iso, iso],
    );
  }

  // ═══ Backward-compatible helper (used by older callers) ═══

  PersonalCacheRepository get _cache =>
      _ref.read(personalCacheRepositoryProvider);

  Future<void> enqueue(
    String tableName,
    int? recordId,
    String operation,
    Map<String, dynamic>? data,
  ) async {
    await SyncOutbox.enqueue(
      tableName: tableName,
      entityType: tableName,
      entityId: data?['id']?.toString(),
      operation: operation,
      data: data,
      userId: _activeUserId,
    );
    if (_connectivity?.isOnline ?? false) processQueue();
  }
}

class _ReplayResult {
  final Map<String, dynamic> response;
  final String? remapFrom;
  final String? remapTo;
  const _ReplayResult({this.response = const {}, this.remapFrom, this.remapTo});
}

/// Reconciles an idempotent-dedupe remap WITHOUT ever losing the row.
///
/// The server's dedupe answer already carries the canonical row, so it is
/// anchored in the local mirror FIRST and the phantom local row is dropped
/// after. The follow-up pull upserts the very same row (idempotent). If the
/// pull fails or misses it, the authoritative server row still stays visible:
/// an offline-executed transaction looks identical before and after sync.
Future<void> reconcileRemap({
  required PersonalCacheRepository cache,
  required int userId,
  required String entityType,
  required Map<String, dynamic> response,
  required String? remapFrom,
  required String? remapTo,
}) async {
  if (remapFrom == null ||
      remapFrom.isEmpty ||
      remapTo == null ||
      remapTo.isEmpty ||
      remapFrom == remapTo) {
    return;
  }
  final canonicalId = (response['id'] ?? '').toString();
  if (canonicalId == remapTo) {
    try {
      final row = Map<String, dynamic>.from(response)..remove('deduped');
      row['id'] = remapTo;
      await cache.upsertItem(userId, entityType, remapTo, row);
    } catch (_) {}
  }
  try {
    await cache.removeItem(userId, entityType, remapFrom);
  } catch (_) {}
}

class _SyncConflictException implements Exception {
  final String message;
  _SyncConflictException(this.message);
  @override
  String toString() => message;
}

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(ref);
});
