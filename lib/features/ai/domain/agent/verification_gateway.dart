import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/api_endpoints.dart';
import 'package:fyona_flutter/core/offline/offline_guard.dart';
import 'package:fyona_flutter/features/personal/data/repositories/personal_finance_api.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

/// Canonical verification states for Sara operations.
///
/// - [successConfirmed]: local commit + server-side proof (sync archive or
///   server re-read by ID). The ONLY state that may be announced as done.
/// - [successLocalPendingSync]: committed locally, sync still pending and the
///   server does not confirm yet. Honest "saved locally" state — never
///   announced as server success, never reported as failure.
/// - [failed]: the write itself did not apply (validation, commit error, or
///   post-read proof of non-application).
/// - [verificationFailed]: committed locally but the state could not be
///   established (read error, malformed server response). NOT a failure of
///   the operation.
/// - [notFound]: the entity is missing on local read-back.
/// - [syncFailed]: the sync engine recorded failure/conflict for the entity.
enum SaraVerificationState {
  successConfirmed,
  successLocalPendingSync,
  failed,
  verificationFailed,
  notFound,
  syncFailed,
}

/// Outcome of one verified Sara operation.
class SaraVerificationResult {
  final SaraVerificationState state;
  final String tool;
  final String? entityId;
  final String? queueEntityType;
  final String? route;
  final bool serverConfirmed;
  final String syncState;
  final String messageAr;
  final String messageEn;
  final String? errorCode;
  final Map<String, dynamic>? data;
  final bool deduplicated;
  /// The local re-read row when available (lets callers compose messages
  /// with post-write values without another read).
  final Map<String, dynamic>? row;

  const SaraVerificationResult({
    required this.state,
    required this.tool,
    this.entityId,
    this.queueEntityType,
    this.route,
    this.serverConfirmed = false,
    this.syncState = 'none',
    required this.messageAr,
    required this.messageEn,
    this.errorCode,
    this.data,
    this.deduplicated = false,
    this.row,
  });

  /// Single source of truth for bubble tone. Callers must NOT map
  /// success/bool to emoji on their own.
  static String toneFor(SaraVerificationState state) {
    switch (state) {
      case SaraVerificationState.successConfirmed:
        return '✅';
      case SaraVerificationState.successLocalPendingSync:
        return '⏳';
      case SaraVerificationState.verificationFailed:
        return '⚠️';
      case SaraVerificationState.failed:
      case SaraVerificationState.notFound:
      case SaraVerificationState.syncFailed:
        return '❌';
    }
  }

  /// Ad-hoc failure result for write-stage throws (the write itself failed,
  /// so no verification stages apply).
  static SaraVerificationResult failure({
    required String tool,
    String? queueEntityType,
    required String failureAr,
    required String failureEn,
    String? errorCode,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.failed,
      tool: tool,
      queueEntityType: queueEntityType,
      messageAr: failureAr,
      messageEn: failureEn,
      errorCode: errorCode,
    );
  }

  String message(String lang) => lang == 'ar' ? messageAr : messageEn;
}

/// Local mirror read by queue entity type + id. Returns the row map or null.
/// Must throw (not return null) on read infrastructure errors so a missing
/// row is never confused with a broken read.
typedef SaraLocalRead = Future<Map<String, dynamic>?> Function(
    String queueEntityType, String id);

/// Server re-read by queue entity type + id. Returns the row map, null when
/// the server answers 404, and throws on transport/timeout/malformed bodies
/// (the gateway classifies the exception, never the caller).
typedef SaraServerRead = Future<Map<String, dynamic>?> Function(
    String queueEntityType, String id);

/// Sara-facing operation states live here — never inferred from message text.
class SaraVerificationGateway {
  static const double amountTolerance = 0.005;

  /// Sara tool entity type -> sync_queue entity_type.
  static const Map<String, String> saraToQueueType = {
    'bank': 'personal_bank_account',
    'transaction': 'personal_transaction',
    'goal': 'personal_savings_goal',
    'debt': 'personal_debt',
    'budget': 'personal_budget',
    'recurring': 'personal_recurring_transaction',
  };

  /// Reverse lookup for result shaping (queue type -> Sara type).
  static String? saraTypeFor(String queueEntityType) {
    for (final e in saraToQueueType.entries) {
      if (e.value == queueEntityType) return e.key;
    }
    return null;
  }

  final SaraLocalRead readLocal;
  final SaraServerRead? readServer;
  final Duration serverTimeout;
  final Duration opKeyTtl;

  static final Map<String, Future<SaraVerificationResult>> _inflight = {};
  static final Map<String, _CompletedOp> _completed = {};

  SaraVerificationGateway({
    required this.readLocal,
    this.readServer,
    this.serverTimeout = const Duration(seconds: 6),
    this.opKeyTtl = const Duration(minutes: 5),
  });

  /// Wires the gateway to the real service (read-only usage) plus an
  /// optional API client for server confirmation. No service, repository,
  /// API or sync change — only reads through their existing methods.
  factory SaraVerificationGateway.forService(
    PersonalFinanceService service, {
    ApiClient? apiClient,
  }) {
    PersonalFinanceApi? serverApi;
    // Device-only Personal: the server holds no Personal rows to confirm
    // against; the device ledger is the confirmation.
    if (apiClient != null && !PersonalLocalMode.active) {
      try {
        serverApi = PersonalFinanceApi(apiClient);
      } catch (_) {
        serverApi = null;
      }
    }
    Future<Map<String, dynamic>?> local(String queueType, String id) async {
      switch (queueType) {
        case 'personal_bank_account':
          final list = await service.getBankAccounts();
          return _rowOf(list.map((e) => e.toJson()), id);
        case 'personal_transaction':
          final list = await service.getTransactions();
          return _rowOf(list.map((e) => e.toJson()), id);
        case 'personal_savings_goal':
          final list = await service.getSavingsGoals();
          return _rowOf(list.map((e) => e.toJson()), id);
        case 'personal_debt':
          final d = await service.getDebt(id);
          return d?.toJson();
        case 'personal_budget':
          final b = await service.getBudget(id);
          return b?.toJson();
        case 'personal_recurring_transaction':
          final list = await service.getRecurring();
          return _rowOf(list.map((e) => e.toJson()), id);
        default:
          return null;
      }
    }

    Future<Map<String, dynamic>?> server(String queueType, String id) async {
      final api = serverApi;
      if (api == null) throw StateError('no-server-api');
      final path = serverPathFor(queueType, id);
      if (path == null) throw StateError('unsupported-entity');
      return api.one(path);
    }

    return SaraVerificationGateway(
      readLocal: local,
      readServer: serverApi == null ? null : server,
    );
  }

  static Map<String, dynamic>? _rowOf(
      Iterable<Map<String, dynamic>> rows, String id) {
    for (final r in rows) {
      if ((r['id']?.toString() ?? '') == id) return r;
    }
    return null;
  }

  /// Server single-entity path per queue entity type, or null when the
  /// backend exposes no such endpoint (then confirmation stays pending).
  static String? serverPathFor(String queueEntityType, String id) {
    switch (queueEntityType) {
      case 'personal_bank_account':
        return ApiEndpoints.personalFinanceAccount(id);
      case 'personal_transaction':
        return ApiEndpoints.personalFinanceTransaction(id);
      case 'personal_savings_goal':
        return ApiEndpoints.personalFinanceGoal(id);
      case 'personal_debt':
        return ApiEndpoints.personalFinanceDebt(id);
      case 'personal_budget':
        return ApiEndpoints.personalFinanceBudget(id);
      case 'personal_recurring_transaction':
        return ApiEndpoints.personalFinanceRecurringItem(id);
      default:
        return null;
    }
  }

  /// Canonical idempotency key: tool + sorted normalized params.
  static String opKeyFor(String tool, Map<String, dynamic> params) {
    final keys = params.keys.toList()..sort();
    final parts = <String>[tool];
    for (final k in keys) {
      parts.add('$k=${_canon(params[k])}');
    }
    return parts.join('|');
  }

  static String _canon(dynamic v) {
    if (v == null) return '';
    if (v is num) {
      // 1 and 1.0 are the same intent for idempotency purposes.
      if (v == v.toInt()) return v.toInt().toString();
      return v.toString();
    }
    if (v is bool) return v ? '1' : '0';
    if (v is DateTime) return v.toUtc().toIso8601String();
    return v.toString().trim().toLowerCase();
  }

  /// Runs [run] at most once per [opKey]: concurrent duplicates await the
  /// same future, recent duplicates replay the stored result. This is what
  /// stops timeout-retries and double taps from executing twice.
  Future<SaraVerificationResult> executeOnce({
    required String opKey,
    required Future<SaraVerificationResult> Function() run,
  }) {
    final now = DateTime.now();
    _completed.removeWhere((_, v) => v.expiresAt.isBefore(now));
    final done = _completed[opKey];
    if (done != null) {
      final prev = done.result;
      return Future.value(SaraVerificationResult(
        state: prev.state,
        tool: prev.tool,
        entityId: prev.entityId,
        queueEntityType: prev.queueEntityType,
        route: prev.route,
        serverConfirmed: prev.serverConfirmed,
        syncState: prev.syncState,
        messageAr: prev.messageAr,
        messageEn: prev.messageEn,
        errorCode: prev.errorCode,
        data: prev.data,
        deduplicated: true,
      ));
    }
    final flight = _inflight[opKey];
    if (flight != null) return flight;
    Future<SaraVerificationResult> fut;
    try {
      fut = run();
    } catch (e) {
      return Future.error(e);
    }
    _inflight[opKey] = fut;
    return fut.then((r) {
      _inflight.remove(opKey);
      _completed[opKey] = _CompletedOp(r, DateTime.now().add(opKeyTtl));
      return r;
    }, onError: (Object e) {
      _inflight.remove(opKey);
      throw e;
    });
  }

  /// Pure amount-delta check with money tolerance. Never throws.
  static bool amountsMatch(double before, double after, double expectedDelta,
      {double tolerance = amountTolerance}) {
    try {
      return ((after - before) - expectedDelta).abs() <= tolerance;
    } catch (_) {
      return false;
    }
  }

  /// Read-only sync truth for one entity. Never writes, never triggers sync.
  /// 'failed' covers failed/conflict rows; 'synced' requires a synced archive
  /// row; 'pending' covers pending/syncing rows; otherwise 'none'.
  /// Any read error yields 'unknown' (treated downstream as pending, never
  /// as failure).
  Future<String> syncStateFor(String queueEntityType, String id) async {
    try {
      final ledger = await PersonalLedger.active();
      final rows = await ledger.rawQuery(
        "SELECT status FROM ${PersonalLedgerDatabase.outbox} WHERE entity_type = ? AND entity_id = ? "
        "AND status IN ('pending','syncing','failed','conflict') "
        "ORDER BY id DESC LIMIT 1",
        [queueEntityType, id],
      );
      if (rows.isNotEmpty) {
        final s = (rows.first['status'] ?? '').toString();
        if (s == 'failed' || s == 'conflict') return 'failed';
        return 'pending';
      }
      final archived = await ledger.rawQuery(
        "SELECT status FROM ${PersonalLedgerDatabase.outboxLog} WHERE entity_type = ? AND entity_id = ? "
        "ORDER BY id DESC LIMIT 1",
        [queueEntityType, id],
      );
      if (archived.isNotEmpty &&
          (archived.first['status'] ?? '').toString() == 'synced') {
        return 'synced';
      }
      return 'none';
    } catch (_) {
      return 'unknown';
    }
  }

  // ── Message builders (single source; callers pass entity success text) ──

  SaraVerificationResult _confirmed({
    required String tool,
    String? entityId,
    String? queueEntityType,
    String? route,
    required String successAr,
    required String successEn,
    required bool serverConfirmed,
    required String syncState,
    Map<String, dynamic>? data,
    Map<String, dynamic>? row,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.successConfirmed,
      tool: tool,
      entityId: entityId,
      queueEntityType: queueEntityType,
      route: route,
      serverConfirmed: serverConfirmed,
      syncState: syncState,
      messageAr: successAr,
      messageEn: successEn,
      data: data,
      row: row,
    );
  }

  SaraVerificationResult _pending({
    required String tool,
    String? entityId,
    String? queueEntityType,
    String? route,
    required String successAr,
    required String successEn,
    required String syncState,
    Map<String, dynamic>? data,
    Map<String, dynamic>? row,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.successLocalPendingSync,
      tool: tool,
      entityId: entityId,
      queueEntityType: queueEntityType,
      route: route,
      serverConfirmed: false,
      syncState: syncState,
      messageAr: '$successAr تم حفظ العملية محليًا وهي بانتظار المزامنة.',
      messageEn: '$successEn Saved locally and pending server sync.',
      data: data,
      row: row,
    );
  }

  SaraVerificationResult _unverifiable({
    required String tool,
    String? entityId,
    String? queueEntityType,
    required String successAr,
    required String successEn,
    required String syncState,
    Map<String, dynamic>? data,
    Map<String, dynamic>? row,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.verificationFailed,
      tool: tool,
      entityId: entityId,
      queueEntityType: queueEntityType,
      serverConfirmed: false,
      syncState: syncState,
      messageAr: '$successAr تعذّر التحقق من الحالة.',
      messageEn: '$successEn State could not be verified.',
      errorCode: 'UNVERIFIED',
      data: data,
      row: row,
    );
  }

  SaraVerificationResult _failed({
    required String tool,
    String? entityType,
    required String failureAr,
    required String failureEn,
    String? errorCode,
    Map<String, dynamic>? data,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.failed,
      tool: tool,
      queueEntityType: entityType,
      messageAr: failureAr,
      messageEn: failureEn,
      errorCode: errorCode,
      data: data,
    );
  }

  SaraVerificationResult _notFound({
    required String tool,
    String? queueEntityType,
    required String failureAr,
    required String failureEn,
    String? errorCode,
  }) {
    return SaraVerificationResult(
      state: SaraVerificationState.notFound,
      tool: tool,
      queueEntityType: queueEntityType,
      messageAr: failureAr,
      messageEn: failureEn,
      errorCode: errorCode ?? 'NOT_FOUND',
    );
  }

  SaraVerificationResult _syncFailed({
    required String tool,
    String? entityId,
    String? queueEntityType,
    required String successAr,
    required String successEn,
    required String syncState,
    Map<String, dynamic>? data,
    Map<String, dynamic>? row,
  }) {
    final conflict = syncState == 'conflict';
    return SaraVerificationResult(
      state: SaraVerificationState.syncFailed,
      tool: tool,
      entityId: entityId,
      queueEntityType: queueEntityType,
      serverConfirmed: false,
      syncState: syncState,
      messageAr: conflict
          ? '$successAr لكن المزامنة متعارضة وتتطلب مراجعة.'
          : '$successAr لكن فشلت مزامنتها مع الخادم. ستُعاد المحاولة تلقائيًا.',
      messageEn: conflict
          ? '$successEn but sync is in conflict and needs review.'
          : '$successEn but server sync failed. It will be retried automatically.',
      errorCode: 'SYNC_FAILED',
      data: data,
      row: row,
    );
  }

  // ── Core flows (total: never throw FAILED blindly) ──

  /// Verify a CREATE after a throwing-free local commit.
  /// [resolveId] locates the committed row (exact fields + recency);
  /// every later stage is strictly by the resolved ID.
  Future<SaraVerificationResult> verifyCreate({
    required String tool,
    required String queueEntityType,
    required Future<String?> Function() resolveId,
    required String successAr,
    required String successEn,
    required String failureAr,
    required String failureEn,
    String? route,
    Map<String, dynamic>? data,
    bool requireServerConfirmation = true,
  }) async {
    String? id;
    try {
      id = await resolveId();
    } catch (_) {
      return _unverifiable(
          tool: tool, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: 'unknown');
    }
    if (id == null || id.isEmpty) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'CREATION_FAILED');
    }
    Map<String, dynamic>? local;
    try {
      local = await readLocal(queueEntityType, id);
    } catch (_) {
      return _unverifiable(
          tool: tool, entityId: id, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: 'unknown');
    }
    if (local == null) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'CREATION_FAILED');
    }
    return _stages(
      tool: tool, queueEntityType: queueEntityType, entityId: id,
      successAr: successAr, successEn: successEn, route: route, data: data,
      row: local,
      requireServerConfirmation: requireServerConfirmation,
    );
  }

  /// Verify an UPDATE of a known [entityId], optionally asserting that
  /// [expectFields] match the re-read row (tolerance for numbers).
  Future<SaraVerificationResult> verifyUpdate({
    required String tool,
    required String queueEntityType,
    required String? entityId,
    Map<String, dynamic>? expectFields,
    required String successAr,
    required String successEn,
    required String failureAr,
    required String failureEn,
    String? route,
    Map<String, dynamic>? data,
    bool requireServerConfirmation = true,
  }) async {
    if (entityId == null || entityId.isEmpty) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'INVALID_ID');
    }
    Map<String, dynamic>? local;
    try {
      local = await readLocal(queueEntityType, entityId);
    } catch (_) {
      return _unverifiable(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: 'unknown');
    }
    if (local == null) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'NOT_FOUND');
    }
    if (expectFields != null && !_fieldsMatch(local, expectFields)) {
      return _failed(
          tool: tool, entityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'UPDATE_NOT_APPLIED', data: data);
    }
    return _stages(
      tool: tool, queueEntityType: queueEntityType, entityId: entityId,
      successAr: successAr, successEn: successEn, route: route, data: data,
      row: local,
      requireServerConfirmation: requireServerConfirmation,
    );
  }

  /// Verify a DELETE of a known [entityId]: the row must be gone locally.
  Future<SaraVerificationResult> verifyDelete({
    required String tool,
    required String queueEntityType,
    required String? entityId,
    required String successAr,
    required String successEn,
    required String failureAr,
    required String failureEn,
    bool requireServerConfirmation = true,
  }) async {
    if (entityId == null || entityId.isEmpty) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'INVALID_ID');
    }
    Map<String, dynamic>? local;
    try {
      local = await readLocal(queueEntityType, entityId);
    } catch (_) {
      return _unverifiable(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: 'unknown');
    }
    if (local != null) {
      return _failed(
          tool: tool, entityType: queueEntityType,
          failureAr: failureAr, failureEn: failureEn,
          errorCode: 'DELETE_NOT_APPLIED');
    }
    final sync = await syncStateFor(queueEntityType, entityId);
    if (sync == 'failed') {
      return _syncFailed(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: sync);
    }
    if (sync == 'synced') {
      return _confirmed(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn,
          serverConfirmed: true, syncState: sync);
    }
    if (requireServerConfirmation && readServer != null) {
      final hit = await _serverHit(queueEntityType, entityId);
      if (hit == _ServerHit.present) {
        return _pending(
            tool: tool, entityId: entityId, queueEntityType: queueEntityType,
            successAr: successAr, successEn: successEn, syncState: sync);
      }
      if (hit == _ServerHit.missing) {
        return _confirmed(
            tool: tool, entityId: entityId, queueEntityType: queueEntityType,
            successAr: successAr, successEn: successEn,
            serverConfirmed: true, syncState: sync);
      }
      return _pending(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: sync);
    }
    return _pending(
        tool: tool, entityId: entityId, queueEntityType: queueEntityType,
        successAr: successAr, successEn: successEn, syncState: sync);
  }

  /// Re-evaluate the CURRENT truth of a past operation (req: later sync
  /// failures must be discoverable; old messages are never final truth).
  Future<SaraVerificationResult> checkOperation({
    required String tool,
    required String queueEntityType,
    required String entityId,
  }) async {
    const genericAr = 'الحالة الحالية للعملية';
    const genericEn = 'Current operation state';
    Map<String, dynamic>? local;
    try {
      local = await readLocal(queueEntityType, entityId);
    } catch (_) {
      return _unverifiable(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: genericAr, successEn: genericEn, syncState: 'unknown');
    }
    if (local == null) {
      return _notFound(
          tool: tool, queueEntityType: queueEntityType,
          failureAr: 'لا يوجد سجل لهذه العملية محليًا.',
          failureEn: 'No local record of this operation.',
          errorCode: 'NOT_FOUND');
    }
    return _stages(
      tool: tool, queueEntityType: queueEntityType, entityId: entityId,
      successAr: 'العملية مؤكدة وموجودة.',
      successEn: 'Operation confirmed present.',
      requireServerConfirmation: true,
      row: local,
    );
  }

  Future<SaraVerificationResult> _stages({
    required String tool,
    required String queueEntityType,
    required String entityId,
    required String successAr,
    required String successEn,
    String? route,
    Map<String, dynamic>? data,
    Map<String, dynamic>? row,
    required bool requireServerConfirmation,
  }) async {
    String sync;
    try {
      sync = await syncStateFor(queueEntityType, entityId);
    } catch (_) {
      sync = 'unknown';
    }
    if (sync == 'failed') {
      return _syncFailed(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          successAr: successAr, successEn: successEn, syncState: sync,
          data: data, row: row);
    }
    if (sync == 'synced') {
      return _confirmed(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          route: route, successAr: successAr, successEn: successEn,
          serverConfirmed: true, syncState: sync, data: data, row: row);
    }
    if (requireServerConfirmation && readServer != null) {
      final hit = await _serverHit(queueEntityType, entityId);
      if (hit == _ServerHit.present) {
        return _confirmed(
            tool: tool, entityId: entityId, queueEntityType: queueEntityType,
            route: route, successAr: successAr, successEn: successEn,
            serverConfirmed: true, syncState: sync, data: data, row: row);
      }
      if (hit == _ServerHit.malformed) {
        return _unverifiable(
            tool: tool, entityId: entityId, queueEntityType: queueEntityType,
            successAr: successAr, successEn: successEn, syncState: sync,
            data: data, row: row);
      }
      return _pending(
          tool: tool, entityId: entityId, queueEntityType: queueEntityType,
          route: route, successAr: successAr, successEn: successEn,
          syncState: sync, data: data, row: row);
    }
    return _pending(
        tool: tool, entityId: entityId, queueEntityType: queueEntityType,
        route: route, successAr: successAr, successEn: successEn,
        syncState: sync, data: data, row: row);
  }

  Future<_ServerHit> _serverHit(String queueEntityType, String id) async {
    final reader = readServer;
    if (reader == null) return _ServerHit.unreachable;
    try {
      final map = await reader(queueEntityType, id).timeout(serverTimeout);
      if (map == null || map.isEmpty) return _ServerHit.missing;
      final remoteId = map['id']?.toString() ?? '';
      if (remoteId.isNotEmpty && remoteId != id) return _ServerHit.malformed;
      return _ServerHit.present;
    } on TimeoutException {
      return _ServerHit.unreachable;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return _ServerHit.missing;
      return _ServerHit.unreachable;
    } on FormatException {
      return _ServerHit.malformed;
    } catch (_) {
      return _ServerHit.unreachable;
    }
  }

  /// Field-by-field match with numeric tolerance. Null expectations are
  /// skipped. Never throws.
  bool _fieldsMatch(
      Map<String, dynamic> row, Map<String, dynamic> expected) {
    try {
      for (final entry in expected.entries) {
        if (entry.value == null) continue;
        final actual = row[entry.key];
        if (actual == null) return false;
        if (entry.value is num && actual is num) {
          if (((actual as num) - (entry.value as num)).abs() > amountTolerance) {
            return false;
          }
          continue;
        }
        if (actual.toString() != entry.value.toString()) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

enum _ServerHit { present, missing, unreachable, malformed }

class _CompletedOp {
  final SaraVerificationResult result;
  final DateTime expiresAt;
  _CompletedOp(this.result, this.expiresAt);
}
