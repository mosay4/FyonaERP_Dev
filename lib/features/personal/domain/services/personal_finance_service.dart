import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/repositories/personal_repository.dart';
import '../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../../core/database/repositories/sync_outbox.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/offline/offline_guard.dart';
import '../../../../core/offline/sync_operation_types.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../../data/repositories/personal_finance_api.dart';
import 'budget_aggregation.dart';
import 'exchange_rate_service.dart';

/// Typed failure for recurring execution (expense withdrawals). The [code]
/// drives localized UI messages; [message] is an Arabic fallback used by
/// non-UI callers (e.g. Sara tools) so failures are never silent.
class RecurringExecutionException implements Exception {
  final String code;
  final String message;
  const RecurringExecutionException(this.code, this.message);

  @override
  String toString() => message;
}

/// Remote-first personal finance service backed by `/personal/finance/*`.
///
/// All entity IDs are backend UUID strings end to end:
/// Database (UUID) → Backend (str) → API → Flutter (String).
/// There is no local int mapping and no fake IDs; a missing relation is null.
class PersonalFinanceService {
  final PersonalRepository? _repo;
  final ApiClient? _apiClient;
  final PersonalCacheRepository? _cache;
  int _userId = 1;

  /// Local-First sync hook: set by the provider layer to
  /// `SyncEngine.processQueue`. Invoked fire-and-forget AFTER every local
  /// commit — never awaited, never blocks the UI. When unset (tests) writes
  /// still land locally + in the outbox; the engine picks them up on its
  /// next connectivity/periodic trigger.
  Future<void> Function()? requestSync;

  void _scheduleSync() {
    final fn = requestSync;
    if (fn == null) return;
    Future<void>(() async {
      try {
        await fn();
      } catch (_) {}
    });
  }

  PersonalFinanceService({ApiClient? apiClient, PersonalRepository? repo, PersonalCacheRepository? cache})
      : _apiClient = apiClient,
        _repo = repo,
        _cache = cache;

  PersonalFinanceApi? _apiInstance;

  /// In-flight write operations by idempotency key. A second concurrent call
  /// with the same key (double-tap, retry) joins the first call's future
  /// instead of executing again — one intent runs exactly once.
  final Map<String, Future<dynamic>> _inflight = {};

  Future<T> _joinFlight<T>(String key, Future<T> Function() fn) {
    final existing = _inflight[key];
    if (existing != null) return existing as Future<T>;
    final fut = fn();
    _inflight[key] = fut;
    void cleanup() {
      if (identical(_inflight[key], fut)) _inflight.remove(key);
    }
    // Both outcomes clean the in-flight map; the error listener is consumed
    // here so a guarded failure never surfaces as an unhandled async error.
    fut.then<void>((_) => cleanup(), onError: (Object _) => cleanup());
    return fut;
  }

  /// Generates a client operation id (one per user intent).
  String newOperationId() => 'op_${_newUuid()}';

  PersonalFinanceApi get _api {
    final client = _apiClient;
    if (client == null) {
      throw StateError('PersonalFinanceService: apiClient غير مهيأ');
    }
    return _apiInstance ??= PersonalFinanceApi(client);
  }

  /// Local cache namespace only (hash of the auth UUID). Not an entity id.
  void setUserId(int id) => _userId = id;

  int get currentUserId => _userId;

  /// Fetches a list from the server and mirrors it locally; when the server is
  /// unreachable falls back to the local mirror so the module stays usable
  /// offline. Returns raw server-shaped rows.
  ///
  /// IMPORTANT (offline-first correctness): whenever there are LOCAL rows that
  /// still have a pending (un-synced) outbox operation, they are ALWAYS merged
  /// into the result — even when the server responds. Otherwise, right after a
  /// partial reconnect the UI would show a blank list and the user's
  /// "just saved offline" operations seem to disappear.
  /// Local-First read path for every personal list.
  ///
  /// The UI ALWAYS reads from the local mirror first and returns instantly —
  /// Internet is never required to display data. When the mirror has data a
  /// background refresh (stale-while-revalidate) updates it for the next read;
  /// when the mirror is empty (first run) a network fetch populates it. Offline
  /// writes/edits are always merged in and never hidden by server responses.
  Future<List<Map<String, dynamic>>> _safeList(
    String entityType,
    String path, {
    Map<String, dynamic>? params,
    bool fullReplace = true,
  }) async {
    final cache = _cache;
    if (cache != null) {
      List<Map<String, dynamic>> local;
      try {
        local = await cache.getCollection(_userId, entityType);
      } catch (_) {
        local = const [];
      }
      if (local.isNotEmpty) {
        final merged = await cache.mergePendingInto(_userId, entityType, local);
        _scheduleBackgroundRefresh(entityType, path,
            params: params, fullReplace: fullReplace);
        return _filterActive(merged, params);
      }
    }
    // Empty local mirror (first run / fresh account) → network fetch.
    final fetchStartedAt = DateTime.now();
    try {
      final raw = await _api.list(path, params: params);
      final items = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (cache != null) {
        await _storeFetched(entityType, items,
            fullReplace: fullReplace, fetchStartedAt: fetchStartedAt);
        final all = await cache.getCollection(_userId, entityType);
        final merged = await cache.mergePendingInto(_userId, entityType, all);
        return _filterActive(merged, params);
      }
      return _filterActive(items, params);
    } catch (e) {
      if (isConnectivityError(e) && cache != null) {
        final cached = await cache.getCollection(_userId, entityType);
        return _filterActive(cached, params);
      }
      rethrow;
    }
  }

  /// Applies the `is_active` filter locally (server filters are no longer
  /// required for the local-first path).
  List<Map<String, dynamic>> _filterActive(
      List<Map<String, dynamic>> rows, Map<String, dynamic>? params) {
    if (params == null) return rows;
    if (params['is_active'] == true || params['is_active'] == 1) {
      return rows
          .where((m) => m['is_active'] == true || m['is_active'] == 1)
          .toList();
    }
    return rows;
  }

  /// Fire-and-forget refresh of one entity collection. Never blocks the UI,
  /// never overwrites local pending truth ([replaceCollection] guarantees it).
  ///
  /// Navigation-safety: background refreshes are ALWAYS upsert-only
  /// ([fullReplace] forced false) so a partial/empty server page can never
  /// wipe the local mirror — the next page open must find its rows locally
  /// and never fall back to a blocking network fetch.
  void _scheduleBackgroundRefresh(
    String entityType,
    String path, {
    Map<String, dynamic>? params,
    bool fullReplace = true,
  }) {
    Future<void>(() async {
      // Snapshot BEFORE the network call: any mirror row written after this
      // instant is newer than the snapshot we are about to receive, so the
      // store step must leave such rows untouched (stale-response race).
      final fetchStartedAt = DateTime.now();
      try {
        final raw = await _api.list(path, params: params);
        final items = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        await _storeFetched(entityType, items,
            fullReplace: false, fetchStartedAt: fetchStartedAt);
      } catch (_) {
        // Offline / transient: the mirror stays as-is (local-first).
      }
    });
  }

  /// Stale-response guard predicate: returns true when a fetched snapshot
  /// (whose network call started at [fetchStartedAt]) must NOT overwrite a
  /// mirror row last written at [localStamp]. A local write made after the
  /// fetch started is definitionally absent from that snapshot (the server
  /// could not have seen the future), so overwriting would erase offline
  /// work the moment a slow fetch completes.
  ///
  /// Null on either side means "unknown" → allow the write (previous
  /// behavior). When both sides did change concurrently, local wins —
  /// the same offline-first rule as the pending-ids protection; the sync
  /// engine converges the server on replay.
  bool shouldSkipStaleSnapshot(
      {required DateTime? localStamp, required DateTime? fetchStartedAt}) {
    if (localStamp == null || fetchStartedAt == null) return false;
    return localStamp.isAfter(fetchStartedAt);
  }

  Future<void> _storeFetched(
    String entityType,
    List<Map<String, dynamic>> items, {
    bool fullReplace = true,
    DateTime? fetchStartedAt,
  }) async {
    final cache = _cache;
    if (cache == null) return;
    if (!fullReplace) {
      // Filtered fetch (e.g. is_active=true): upsert the returned rows WITHOUT
      // deleting the rest of the collection namespace.
      // Rows with a staged (unconfirmed) DELETE are locally gone: never
      // re-insert them from a background snapshot, or deletes resurrect.
      final Set<String> deleteIds =
          await cache.pendingDeleteIds(_userId, entityType);
      // Derived rows moved by an unconfirmed transaction (goal credit, debt
      // paid, budget spent, bank balance) are local truth until that
      // transaction confirms: a background snapshot that started after the
      // edit carries the pre-edit server values and must not overwrite them.
      Set<String> guarded = const {};
      if (entityType == 'personal_bank_account') {
        guarded = await cache.pendingTransactionBankIds(_userId);
      } else if (entityType == 'personal_savings_goal' ||
          entityType == 'personal_debt' ||
          entityType == 'personal_budget') {
        guarded =
            (await cache.pendingTransactionLinkedIds(_userId))[entityType] ??
                const <String>{};
      }
      for (final item in items) {
        final rid = item['id']?.toString() ?? '';
        if (rid.isEmpty || deleteIds.contains(rid) || guarded.contains(rid)) {
          continue;
        }
        try {
          final existing = await _localRow(entityType, rid);
          final v = (existing?['_sync_version'] as num?)?.toInt();
          if (v != null) item['_sync_version'] = v;
        } catch (_) {}
        // Stale-response guard: the fetched snapshot predates any local
        // write made after the fetch started (e.g. a bank balance bumped
        // by an offline transaction, which carries no outbox op of its own
        // and is therefore invisible to the pending-ids protection).
        // Overwriting it would erase the user's offline work the moment a
        // slow fetch completes — this is what made balances "vanish".
        if (fetchStartedAt != null) {
          try {
            final localStamp = await cache.getMirrorUpdatedAt(
                _userId, entityType, rid);
            if (shouldSkipStaleSnapshot(
                localStamp: localStamp, fetchStartedAt: fetchStartedAt)) {
              continue;
            }
          } catch (_) {}
        }
        await cache.upsertItem(_userId, entityType, rid, item);
      }
      return;
    }
    await cache.replaceCollection(_userId, entityType, items);
  }

  /// Stages a create when the server is unreachable: persists a local mirror
  /// row (with a synthetic UUID) and enqueues it for the sync engine.
  /// Returns the generated remoteId (or null if no cache).
  ///
  /// The staged payload carries the client-generated `id` so the server's
  /// create endpoint materialises the SAME UUID — the identity is stable from
  /// the moment of creation locally and stays stable after sync.
  Future<String?> _offlineCreate(
    String entityType,
    Map<String, dynamic> sendPayload,
    Map<String, dynamic> mirrorRow, {
    String? operationType,
    List<Map<String, String>> dependsOn = const [],
    String? occurredAt,
  }) async {
    final cache = _cache;
    if (cache == null) return null;
    final remoteId = _newUuid();
    final nowIso = occurredAt ?? DateTime.now().toUtc().toIso8601String();
    await cache.commitOfflineWrite(
      userId: _userId,
      entityType: entityType,
      remoteId: remoteId,
      primaryRow: {...mirrorRow, 'id': remoteId},
      operation: 'INSERT',
      data: {...sendPayload, 'id': remoteId},
      operationType: operationType ?? _createOpFor(entityType),
      occurredAt: nowIso,
      dependsOn: dependsOn,
    );
    return remoteId;
  }

  /// Default create-operation tag per entity type.
  String _createOpFor(String entityType) {
    switch (entityType) {
      case 'personal_transaction':
        return SyncOperationTypes.transactionCreate;
      case 'personal_savings_goal':
        return SyncOperationTypes.goalCreate;
      case 'personal_debt':
        return SyncOperationTypes.debtCreate;
      case 'personal_budget':
        return SyncOperationTypes.budgetCreate;
      case 'personal_recurring_transaction':
        return SyncOperationTypes.recurringCreate;
      case 'personal_bank_account':
      default:
        return SyncOperationTypes.bankCreate;
    }
  }

  /// Stages an edit when the server is unreachable: updates the local mirror with
  /// the new payload and enqueues it for the sync engine.
  ///
  /// OFFLINE-FIRST: preserves the mirror's `_sync_version` (so a later DELETE
  /// or retry carries the right base_version) and stages the UPDATE with that
  /// baseVersion. A blind baseVersion=0 caused version conflicts on entities
  /// previously updated via CRUD, silently dropping the offline edit on sync.
  ///
  /// The payload is MERGED over the existing mirror row (never a blind
  /// replace): partial edits (e.g. balance-only) must not wipe the other
  /// columns locally, and the staged op must carry the complete row so the
  /// server upsert cannot blank the missing fields with defaults.
  Future<bool> _offlineUpdate(
    String entityType,
    String remoteId,
    Map<String, dynamic> payload, {
    String? operationType,
    String? occurredAt,
    // Optional derived-mirror effects (bank balance, goal, debt, budget)
    // committed atomically with the UPDATE. Called with the untouched row
    // BEFORE the merge and with the fully merged row, so the caller can
    // reverse the old effect and apply the new one — the same order the
    // server uses — inside a single SQLite transaction.
    Future<List<MirrorMutation>> Function(
            Map<String, dynamic>? oldRow, Map<String, dynamic> merged)?
        planRelated,
  }) async {
    final cache = _cache;
    if (cache == null) return false;
    Map<String, dynamic>? existing;
    try {
      existing = await _localRow(entityType, remoteId);
    } catch (_) {}
    final syncVersion =
        (existing?['_sync_version'] as num?)?.toInt() ?? 0;
    final merged = <String, dynamic>{
      if (existing != null) ...existing,
      ...payload,
      'id': remoteId,
      if (syncVersion > 0) '_sync_version': syncVersion,
    };
    final staged = Map<String, dynamic>.from(merged)
      ..remove('_sync_version')
      // Remember exactly which fields the user's intent touched: the sync
      // engine replays ONLY these, so a stale full-row blob can never
      // overwrite fields another device changed in the meantime.
      ..['__changed'] = payload.keys.toList();
    final related = planRelated == null
        ? const <MirrorMutation>[]
        : await planRelated(existing, merged);
    // Atomic: mirror row + derived effects + operation in one SQLite transaction.
    await cache.commitOfflineWrite(
      userId: _userId,
      entityType: entityType,
      remoteId: remoteId,
      primaryRow: merged,
      operation: 'UPDATE',
      data: staged,
      baseVersion: syncVersion,
      operationType: operationType ?? _updateOpFor(entityType),
      occurredAt: occurredAt,
      related: related,
    );
    return true;
  }

  /// Default update-operation tag per entity type.
  String _updateOpFor(String entityType) {
    switch (entityType) {
      case 'personal_savings_goal':
        return SyncOperationTypes.goalUpdate;
      case 'personal_debt':
        return SyncOperationTypes.debtUpdate;
      case 'personal_budget':
        return SyncOperationTypes.budgetUpdate;
      case 'personal_recurring_transaction':
        return SyncOperationTypes.recurringUpdate;
      case 'personal_transaction':
        return SyncOperationTypes.transactionUpdate;
      case 'personal_bank_account':
      default:
        return SyncOperationTypes.bankUpdate;
    }
  }

  /// Stages a delete when the server is unreachable: drops the local mirror row
  /// and enqueues it for the sync engine.
  Future<bool> _offlineDelete(
    String entityType,
    String remoteId, {
    String? operationType,
    String? occurredAt,
  }) async {
    final cache = _cache;
    if (cache == null) return false;
    // Capture version BEFORE removing the mirror so the DELETE carries the
    // correct base_version (prevents version conflicts / resurrection).
    int syncVersion = 0;
    try {
      final row = await _localRow(entityType, remoteId);
      syncVersion = (row?['_sync_version'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    // Atomic: mirror removal + DELETE operation (superseding any queued
    // pending ops for the entity) in one SQLite transaction.
    await cache.commitOfflineWrite(
      userId: _userId,
      entityType: entityType,
      remoteId: remoteId,
      primaryRow: null,
      operation: 'DELETE',
      operationType: operationType ?? _deleteOpFor(entityType),
      occurredAt: occurredAt,
      baseVersion: syncVersion,
      cancelExistingOps: true,
    );
    return true;
  }

  String _deleteOpFor(String entityType) {
    switch (entityType) {
      case 'personal_savings_goal':
        return SyncOperationTypes.goalDelete;
      case 'personal_debt':
        return SyncOperationTypes.debtDelete;
      case 'personal_budget':
        return SyncOperationTypes.budgetDelete;
      case 'personal_recurring_transaction':
        return SyncOperationTypes.recurringDelete;
      case 'personal_transaction':
        return SyncOperationTypes.transactionDelete;
      case 'personal_bank_account':
      default:
        return SyncOperationTypes.bankDelete;
    }
  }

  /// Crypto-grade UUID v4 (RFC 4122) for offline-created entity ids.
  ///
  /// These ids travel to the server as typed UUIDs (sync push `entity_id`,
  /// update/delete path params) and Python rejects anything that is not
  /// exactly 32 hex digits — the previous timestamp-based format emitted 35
  /// and made every offline-created entity permanently unreachable (HTTP 422
  /// on push/update/delete while the local mirror kept showing it).
  String _newUuid() => generateUuidV4();

  /// Resolves the mirror row of the cash ("كاش"/"Cash") account, mirroring the
  /// server rule: a transaction without an explicit bank account targets cash.
  /// When [currency] is given, the same-bucket row wins (preferring a funded
  /// one) so account-less operations can never credit a wrong-currency row
  /// just because it sorts first; otherwise the first cash row is returned.
  Future<Map<String, dynamic>?> _cashAccountRow({
    Map<String, Map<String, dynamic>>? overlay,
    String? currency,
  }) async {
    try {
      final all = await _cache?.getCollection(_userId, 'personal_bank_account');
      if (all == null) return null;
      Map<String, dynamic>? first;
      Map<String, dynamic>? bucketMatch;
      final want = (currency ?? '').trim().isEmpty
          ? null
          : cashBucket(currency!);
      for (final r in all) {
        final name = (r['bank_name'] ?? '').toString().trim();
        if (name != 'كاش' && name != 'Cash') continue;
        first ??= r;
        if (want != null &&
            cashBucket((r['currency'] ?? '').toString()) == want) {
          final bal = (r['balance'] as num?)?.toDouble() ?? 0;
          if (bal != 0) {
            bucketMatch = r;
            break;
          }
          bucketMatch ??= r;
        }
      }
      final picked = bucketMatch ?? first;
      if (picked == null) return null;
      // With an overlay in play (UPDATE reverse-then-apply) return the
      // already-touched copy instead of the untouched database row.
      if (overlay == null) return picked;
      return _planRow(
          'personal_bank_account', (picked['id'] ?? '').toString(), overlay);
    } catch (_) {}
    return null;
  }

  /// Currency bucket for cash matching: YER and YER_NEW are the same money
  /// (mirrors the selector alias), everything else matches case-insensitively.
  /// Public so the bank form enforces the same no-duplicate rule.
  static String cashBucket(String code) {
    final c = code.trim().toUpperCase();
    if (c == 'YER_NEW') return 'YER';
    return c;
  }

  /// Canonical cash code for creating cash: bare YER is always stored as YER_NEW
  /// (the three spellings YER / YER_NEW / YER_OLD produced parallel rows).
  static String canonicalCashCode(String code) {
    final c = code.trim().toUpperCase();
    if (c == 'YER') return 'YER_NEW';
    return c;
  }

  /// One logical cash row per currency bucket: duplicate mirror rows (same
  /// bucket, e.g. a stale zero stub beside the live row) collapse into a
  /// single entry whose balance is the SUM — money can never hide behind a
  /// duplicate — and whose id is the first non-zero row (else the first).
  /// Pure; every cash picker, card and resolver must go through this so all
  /// of them see and move the same row.
  static List<PersonalBankAccount> canonicalCashAccounts(
      List<PersonalBankAccount> accounts) {
    final order = <String>[];
    final groups = <String, List<PersonalBankAccount>>{};
    for (final a in accounts) {
      if (!isCashAccount(a.bankName)) continue;
      final b = cashBucket(a.currency);
      if (!groups.containsKey(b)) {
        groups[b] = [];
        order.add(b);
      }
      groups[b]!.add(a);
    }
    final out = <PersonalBankAccount>[];
    for (final b in order) {
      final rows = groups[b]!;
      var canon = rows.first;
      for (final r in rows) {
        if (r.balance != 0) {
          canon = r;
          break;
        }
      }
      var sum = 0.0;
      for (final r in rows) {
        sum += r.balance;
      }
      out.add(PersonalBankAccount(
        id: canon.id,
        bankName: canon.bankName,
        balance: sum,
        currency: canon.currency,
        notes: canon.notes,
        accountType: canon.accountType,
      ));
    }
    return out;
  }

  /// Account-type equivalence for the uniqueness rule: manually created cash
  /// is stored with type 'cash', which counts as 'checking' — only a real
  /// 'savings' row may coexist with it for the same currency.
  static String cashTypeKey(String? type) {
    final t = (type ?? 'checking').trim().toLowerCase();
    if (t == 'cash') return 'checking';
    // Server rows say current/savings; the device says checking/savings.
    return personalAccountTypeFromServer(t);
  }

  static String _cashVaultKey(int userId) => 'cash_vault_$userId';

  Future<Map<String, dynamic>> _readCashVault() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cashVaultKey(_userId));
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) return m;
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return {};
  }

  Future<void> _writeCashVault(Map<String, dynamic> vault) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cashVaultKey(_userId), jsonEncode(vault));
    } catch (_) {}
  }

  /// Reads AND consumes the stashed balance for [currency] (null when the
  /// currency was never removed). Used when re-adding a previously removed
  /// cash currency so it comes back with the same amount.
  Future<double?> takeStashedCashBalance(String currency) async {
    try {
      final code = currency.trim().toUpperCase();
      if (code.isEmpty) return null;
      final vault = await _readCashVault();
      final stash =
          vault[code] ?? vault[cashBucket(code)];
      if (stash is! Map) return null;
      final balance = (stash['balance'] as num?)?.toDouble();
      vault.remove(code);
      vault.remove(cashBucket(code));
      await _writeCashVault(vault);
      return balance;
    } catch (_) {
      return null;
    }
  }

  /// Snapshot of the cash currency codes currently present (canonical
  /// codes). Used by account reset to recreate the same currency set
  /// afterwards with zero balances. Currencies the user removed manually
  /// are simply absent, so they stay deleted. Read-only: never writes.
  Future<Set<String>> snapshotCashCurrencies() async {
    try {
      final out = <String>{};
      for (final a in await getBankAccounts()) {
        if (!isCashAccount(a.bankName)) continue;
        final code = canonicalCashCode(a.currency);
        if (code.isNotEmpty) out.add(code);
      }
      return out;
    } catch (_) {
      return <String>{};
    }
  }

  /// Clears stashed balances of removed cash currencies. Reset-only:
  /// after a full wipe no old money may resurrect when a currency is
  /// re-added later.
  Future<void> clearCashVault() async {
    await _writeCashVault({});
  }

  /// Ensures a cash account exists for each currency code (skips existing,
  /// restores a stashed balance when the currency was removed before).
  /// Used once after phone-country confirmation and when the user re-checks
  /// a currency in customization. Uses the existing local-first create only.
  ///
  /// Uniqueness rule: the same currency is NEVER created twice in the same
  /// account — unless the account TYPE differs (checking vs savings).
  /// The check consults the local mirror (type-aware) AND the server: a
  /// fresh/unsynced mirror must not recreate what already exists remotely
  /// (that blind path is what produced permanent same-name duplicates).
  /// When [enabled] is given, only those currencies may be created — this is
  /// what stops a deleted currency from resurrecting on the next trigger.
  /// Fully offline → falls back to the mirror-only check.
  Future<void> ensureCashAccounts(List<String> currencies, {Set<String>? enabled}) {
    // Serialized: two concurrent triggers (country confirm + customization)
    // used to both see an empty mirror and create the same bucket twice —
    // the permanent duplicates behind phantom-zero cards.
    return _joinFlight<void>('ensure-cash-accounts', () async {
    final cache = _cache;
    if (cache == null || currencies.isEmpty) return;
    final allowed = enabled == null
        ? null
        : enabled.map((e) => canonicalCashCode(e)).toSet();
    List<Map<String, dynamic>> accounts;
    try {
      accounts = await cache.getCollection(_userId, 'personal_bank_account');
    } catch (_) {
      return;
    }
    // Mirror rows without a type (server pulls) count as checking; manual
    // 'cash' rows count as checking too (only 'savings' may coexist).
    final haveChecking = <String>{};
    for (final a in accounts) {
      if (!isCashAccount((a['bank_name'] ?? '').toString())) continue;
      if (cashTypeKey(a['account_type']?.toString()) != 'checking') continue;
      haveChecking.add(cashBucket((a['currency'] ?? '').toString()));
    }
    // Server rows carry no account type, so any remote cash of the bucket
    // blocks creating another checking one (the type-differ exception can
    // only be proven locally).
    final haveRemote = <String>{};
    try {
      final raw = await _api.list(ApiEndpoints.personalFinanceAccounts);
      for (final e in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(e);
        if (!isCashAccount((m['bank_name'] ?? '').toString())) continue;
        haveRemote.add(cashBucket((m['currency'] ?? '').toString()));
      }
    } catch (_) {}
    for (final c in currencies) {
      final code = canonicalCashCode(c);
      if (code.isEmpty) continue;
      if (allowed != null && !allowed.contains(code)) continue;
      final bucket = cashBucket(code);
      if (haveChecking.contains(bucket) || haveRemote.contains(bucket)) {
        continue;
      }
      // Restores a previously stashed balance, else starts at zero.
      final opening = await takeStashedCashBalance(code) ?? 0;
      try {
        await addBankAccount(bankName: 'كاش', currency: code, openingBalance: opening);
      } catch (_) {}
      haveChecking.add(bucket);
    }
    // Heal historical duplicates (same bucket+type): unreferenced zero rows
    // are exactly the phantom-zero cards — remove them everywhere.
    await sweepDuplicateCashAccounts();
    });
  }

  /// Merges exact-duplicate cash rows in the local mirror (same currency
  /// bucket + same account-type key): the survivor keeps its balance, every
  /// other row must be zero-balance AND referenced by no mirror transaction
  /// or recurring row (same safety rule as the restore sweep — money never
  /// moves, nothing user-visible changes except the phantom duplicates
  /// disappearing). Absorbed ids are staged as DELETEs so the server
  /// converges to one row per bucket too. Never throws.
  Future<void> sweepDuplicateCashAccounts() async {
    final cache = _cache;
    if (cache == null) return;
    try {
      final banks =
          await cache.getCollection(_userId, 'personal_bank_account');
      final txs = await cache.getCollection(_userId, 'personal_transaction');
      final recs =
          await cache.getCollection(_userId, 'personal_recurring_transaction');
      final referenced = <String>{};
      for (final t in [...txs, ...recs]) {
        final aid = (t['bank_account_id'] ?? '').toString();
        if (aid.isNotEmpty) referenced.add(aid);
      }
      final stagedBanks = await cache.pendingTransactionBankIds(_userId);
      // Rows with their own staged op are local truth in flight — deleting
      // one from under its unconfirmed create/update would orphan the replay.
      Set<String> ownPending = const {};
      try {
        final rows = await DatabaseHelper.rawQuery(
          "SELECT entity_id FROM sync_queue "
          "WHERE entity_type = 'personal_bank_account' "
          "  AND user_id = ? "
          "  AND status IN ('pending', 'syncing', 'failed', 'conflict') "
          "  AND entity_id IS NOT NULL AND entity_id != ''",
          [_userId],
        );
        ownPending = rows.map((r) => r['entity_id'].toString()).toSet();
      } catch (_) {}
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final m in banks) {
        if (!isCashAccount((m['bank_name'] ?? '').toString())) continue;
        final key =
            '${cashBucket((m['currency'] ?? '').toString())}\u0000${cashTypeKey((m['account_type'] ?? '').toString())}';
        groups.putIfAbsent(key, () => []).add(m);
      }
      for (final rows in groups.values) {
        if (rows.length < 2) continue;
        var survivor = rows.first;
        for (final r in rows) {
          if (((r['balance'] as num?)?.toDouble() ?? 0) != 0) {
            survivor = r;
            break;
          }
        }
        final survivorId = (survivor['id'] ?? '').toString();
        for (final r in rows) {
          final id = (r['id'] ?? '').toString();
          if (id.isEmpty || id == survivorId) continue;
          if (((r['balance'] as num?)?.toDouble() ?? 0) != 0) continue;
          if (referenced.contains(id)) continue;
          if (stagedBanks.contains(id)) continue;
          if (ownPending.contains(id)) continue;
          await _offlineDelete('personal_bank_account', id,
              operationType: SyncOperationTypes.bankDelete);
        }
      }
    } catch (_) {}
  }

  /// Removes every cash account of [currency] plus its transactions (explicit
  /// user intent from currency customization — even with past operations),
  /// stashing balances so re-enabling restores the same amounts. Uses only
  /// the existing local-first delete primitives.
  Future<void> removeCashCurrency(String currency) async {
    final code = canonicalCashCode(currency);
    if (code.isEmpty) return;
    final cache = _cache;
    if (cache == null) return;
    final bucket = cashBucket(code);
    List<Map<String, dynamic>> accounts;
    List<Map<String, dynamic>> txs;
    try {
      accounts = await cache.getCollection(_userId, 'personal_bank_account');
      txs = await cache.getCollection(_userId, 'personal_transaction');
    } catch (_) {
      return;
    }
    final targets = accounts.where((a) {
      if (!isCashAccount((a['bank_name'] ?? '').toString())) return false;
      return cashBucket((a['currency'] ?? '').toString()) == bucket;
    }).toList();
    if (targets.isEmpty) return;
    final ids = targets
        .map((a) => (a['id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet();
    double total = 0;
    for (final a in targets) {
      total += ((a['balance'] as num?)?.toDouble() ?? 0);
    }
    final vault = await _readCashVault();
    vault[code] = {'bank_name': 'كاش', 'balance': total};
    await _writeCashVault(vault);
    for (final t in txs) {
      final accId = (t['bank_account_id'] ?? '').toString();
      final tid = (t['id'] ?? '').toString();
      if (accId.isEmpty || tid.isEmpty || !ids.contains(accId)) continue;
      try {
        await deleteTransaction(tid);
      } catch (_) {}
    }
    for (final a in targets) {
      final aid = (a['id'] ?? '').toString();
      if (aid.isEmpty) continue;
      try {
        await deleteBankAccount(aid);
      } catch (_) {}
    }
  }

  /// Overlay-aware mirror read used by the effect planners.
  ///
  /// An UPDATE replays "reverse the old effect, then apply the new one" in
  /// one commit; the second pass must therefore SEE the rows the first pass
  /// just changed, while the untouched database is what the create/delete
  /// paths read. [overlay] memoizes every row by `entityType|id` for the
  /// duration of one plan — mutating a returned row updates the overlay too,
  /// because the very same object is stored there.
  Future<Map<String, dynamic>?> _planRow(
    String entityType,
    String id,
    Map<String, Map<String, dynamic>>? overlay,
  ) async {
    if (overlay == null) return _localRow(entityType, id);
    if (id.isEmpty) return null;
    final key = '$entityType|$id';
    final seen = overlay[key];
    if (seen != null) return seen;
    final row = await _localRow(entityType, id);
    if (row != null) overlay[key] = row;
    return row;
  }

  /// Computes — WITHOUT writing — the mirror mutations caused by applying a
  /// transaction: bank balance movement, goal credit, debt paid/remaining and
  /// budget spent. The mutations are committed atomically with the operation
  /// itself by [PersonalCacheRepository.commitOfflineWrite]; the server applies
  /// the exact same effect through its own endpoints.
  Future<List<MirrorMutation>> _planTransactionEffect(
      Map<String, dynamic> tx,
      [Map<String, Map<String, dynamic>>? overlay]) async {
    final cache = _cache;
    if (cache == null) return const [];
    final mutations = <MirrorMutation>[];
    final type = (tx['tx_type'] ?? tx['type'] ?? '').toString();
    final amount = (tx['amount'] as num?)?.toDouble() ?? 0;
    var accId = (tx['bank_account_id'] ?? tx['accountId'] ?? '').toString();
    final isIncome = type == 'income' || type == 'transfer_in';
    final isExpense = type == 'expense' || type == 'transfer_out';
    final movement = isIncome ? amount : (isExpense ? -amount : 0.0);
    final nowIso = DateTime.now().toIso8601String();

    // 1) Bank (or cash) account balance.
    if (accId.isEmpty) {
      final cash = await _cashAccountRow(
          overlay: overlay, currency: (tx['currency'] ?? '').toString());
      if (cash != null) accId = (cash['id'] ?? '').toString();
    }
    if (accId.isNotEmpty && movement != 0) {
      final accRow = await _planRow('personal_bank_account', accId, overlay);
      if (accRow != null) {
        final oldBal = (accRow['balance'] as num?)?.toDouble() ?? 0;
        final newBal = (oldBal + movement).clamp(0, double.infinity);
        accRow['balance'] = newBal;
        accRow['updated_at'] = nowIso;
        mutations.add(MirrorMutation.upsert(
            'personal_bank_account', accId, accRow));
      }
    }

    // 2) Goal current_amount.
    final goalId = (tx['goal_id'] ?? '').toString();
    if (goalId.isNotEmpty) {
      // For contributions the amount credited to the goal may differ from the
      // transaction amount (goal_amount); when present, use it for the goal.
      final goalDelta = (tx['goal_amount'] as num?)?.toDouble() ?? movement;
      if (goalDelta != 0) {
        final goalRow = await _planRow('personal_savings_goal', goalId, overlay);
        if (goalRow != null) {
          final cur = (goalRow['current_amount'] as num?)?.toDouble() ?? 0;
          final newCur = (cur + (goalDelta < 0 ? -goalDelta : goalDelta))
              .clamp(0, double.infinity);
          goalRow['current_amount'] = newCur;
          final target = (goalRow['target_amount'] as num?)?.toDouble() ?? 0;
          goalRow['is_completed'] = target > 0 && newCur >= target;
          goalRow['updated_at'] = nowIso;
          mutations.add(MirrorMutation.upsert(
              'personal_savings_goal', goalId, goalRow));
        }
      }
    }

    // 3) Debt remaining (paid) — a payment (payable) or a collection
    // (receivable) both reduce the outstanding amount. Cross-currency
    // credit (goals-style): the debt is credited debt_amount in debt
    // currency; the bank moves the raw tx amount in account currency.
    final debtId = (tx['debt_id'] ?? '').toString();
    if (debtId.isNotEmpty && (isExpense || isIncome)) {
      final debtRow = await _planRow('personal_debt', debtId, overlay);
      if (debtRow != null) {
        final debtDelta = (tx['debt_amount'] as num?)?.toDouble() ?? amount;
        final paid = (debtRow['paid'] as num?)?.toDouble() ?? 0;
        final newPaid = paid + debtDelta;
        final totalAmt = (debtRow['amount'] as num?)?.toDouble() ?? 0;
        final newRem = totalAmt - newPaid;
        debtRow['paid'] = newPaid;
        debtRow['remaining'] = newRem <= 0 ? 0 : newRem;
        if (newRem <= 0 || newPaid >= totalAmt) {
          debtRow['is_paid'] = true;
          debtRow['status'] = 'paid';
        }
        debtRow['updated_at'] = nowIso;
        mutations
            .add(MirrorMutation.upsert('personal_debt', debtId, debtRow));
      }
    }

    // 4) Budget spent.
    final budgetId = (tx['budget_id'] ?? '').toString();
    if (budgetId.isNotEmpty && isExpense) {
      final budRow = await _planRow('personal_budget', budgetId, overlay);
      if (budRow != null) {
        final spent = (budRow['spent'] as num?)?.toDouble() ?? 0;
        final newSpent = (spent + amount)
            .clamp(0, (budRow['amount'] as num?)?.toDouble() ?? double.infinity);
        budRow['spent'] = newSpent;
        budRow['updated_at'] = nowIso;
        mutations
            .add(MirrorMutation.upsert('personal_budget', budgetId, budRow));
      }
    }
    return mutations;
  }

  /// Computes — WITHOUT writing — the inverse of a transaction's effects,
  /// used by offline deletes: bank balance back, goal credit removed, debt
  /// paid/remaining restored, budget spent reduced. Mirrors the server-side
  /// reversal in DELETE /personal/finance/transactions/{id} exactly.
  Future<List<MirrorMutation>> _planReverseTransaction(
      Map<String, dynamic> row,
      [Map<String, Map<String, dynamic>>? overlay]) async {
    final cache = _cache;
    if (cache == null) return const [];
    final mutations = <MirrorMutation>[];
    final type = (row['tx_type'] ?? row['type'] ?? '').toString();
    final amount = (row['amount'] as num?)?.toDouble() ?? 0;
    if (amount <= 0) return mutations;
    final isIncome = type == 'income' || type == 'transfer_in';
    final nowIso = DateTime.now().toIso8601String();

    // 1) Bank account balance back.
    var accId = (row['bank_account_id'] ?? '').toString();
    if (accId.isEmpty) {
      final cash = await _cashAccountRow(
          overlay: overlay, currency: (row['currency'] ?? '').toString());
      if (cash != null) accId = (cash['id'] ?? '').toString();
    }
    if (accId.isNotEmpty) {
      final accRow = await _planRow('personal_bank_account', accId, overlay);
      if (accRow != null) {
        final oldBal = (accRow['balance'] as num?)?.toDouble() ?? 0;
        final newBal =
            (oldBal + (isIncome ? -amount : amount)).clamp(0, double.infinity);
        accRow['balance'] = newBal;
        accRow['updated_at'] = nowIso;
        mutations.add(MirrorMutation.upsert(
            'personal_bank_account', accId, accRow));
      }
    }

    // 2) Goal credit removed (exact credited amount, not the raw tx amount).
    // The completion flag is recomputed from the real state (same rule as
    // the contribute path): reversing a contribution that had completed
    // the goal must un-complete it again.
    final goalId = (row['goal_id'] ?? '').toString();
    if (goalId.isNotEmpty) {
      final goalDelta = (row['goal_amount'] as num?)?.toDouble() ?? amount;
      final goalRow = await _planRow('personal_savings_goal', goalId, overlay);
      if (goalRow != null && goalDelta != 0) {
        final cur = (goalRow['current_amount'] as num?)?.toDouble() ?? 0;
        final newCur = (cur - goalDelta).clamp(0, double.infinity);
        goalRow['current_amount'] = newCur;
        final target = (goalRow['target_amount'] as num?)?.toDouble() ?? 0;
        goalRow['is_completed'] = target > 0 && newCur >= target;
        goalRow['updated_at'] = nowIso;
        mutations.add(MirrorMutation.upsert(
            'personal_savings_goal', goalId, goalRow));
      }
    }

    // 3) Debt payment undone (mirror only — the server derives paid from
    // payment records and will also remove the matching payment row).
    // Reverses the EXACT credited amount (debt_amount), not the raw tx
    // amount — they differ for cross-currency payments. The status is
    // restored symmetrically with the pay path (which sets 'paid' only
    // when fully paid): without this the card keeps status='paid' with a
    // reduced paid amount, hiding all four action buttons offline.
    final debtId = (row['debt_id'] ?? '').toString();
    if (debtId.isNotEmpty) {
      final debtRow = await _planRow('personal_debt', debtId, overlay);
      if (debtRow != null) {
        final debtDelta = (row['debt_amount'] as num?)?.toDouble() ?? amount;
        final paid = (debtRow['paid'] as num?)?.toDouble() ?? 0;
        final newPaid = (paid - debtDelta).clamp(0, double.infinity);
        final total = (debtRow['amount'] as num?)?.toDouble() ?? 0;
        final newRem = total - newPaid;
        final fullyPaid = newRem <= 0 && total > 0;
        debtRow['paid'] = newPaid;
        debtRow['remaining'] = fullyPaid ? 0 : newRem;
        debtRow['is_paid'] = fullyPaid;
        debtRow['status'] = fullyPaid ? 'paid' : 'active';
        debtRow['updated_at'] = nowIso;
        mutations
            .add(MirrorMutation.upsert('personal_debt', debtId, debtRow));
      }
    }

    // 4) Budget spent reduced.
    final budgetId = (row['budget_id'] ?? '').toString();
    if (budgetId.isNotEmpty && !isIncome) {
      final budRow = await _planRow('personal_budget', budgetId, overlay);
      if (budRow != null) {
        final spent = (budRow['spent'] as num?)?.toDouble() ?? 0;
        final newSpent = (spent - amount).clamp(0, double.infinity);
        budRow['spent'] = newSpent;
        budRow['updated_at'] = nowIso;
        mutations
            .add(MirrorMutation.upsert('personal_budget', budgetId, budRow));
      }
    }
    return mutations;
  }

  /// Applies mirror mutations WITHOUT staging any operation. Used after an
  /// ONLINE success where the server already applied the exact same effect
  /// atomically — re-queuing it would double-apply on the next sync.
  Future<void> _applyMutations(List<MirrorMutation> mutations) async {
    final cache = _cache;
    if (cache == null) return;
    for (final m in mutations) {
      if (m.row != null) {
        await cache.upsertItem(_userId, m.entityType, m.remoteId, m.row!);
      } else {
        await cache.removeItem(_userId, m.entityType, m.remoteId);
      }
    }
  }

  /// Atomic offline transaction create: mirror row + all derived effects +
  /// the operation itself, in one SQLite transaction.
  Future<String?> _offlineCreateTransaction(
    Map<String, dynamic> send,
    Map<String, dynamic> mirrorRow, {
    String operationType = SyncOperationTypes.transactionCreate,
    List<Map<String, String>> dependsOn = const [],
    String? occurredAt,
  }) async {
    final cache = _cache;
    if (cache == null) return null;
    final remoteId = _newUuid();
    final related = await _planTransactionEffect({...send, 'id': remoteId});
    await cache.commitOfflineWrite(
      userId: _userId,
      entityType: 'personal_transaction',
      remoteId: remoteId,
      primaryRow: {...mirrorRow, 'id': remoteId},
      operation: 'INSERT',
      data: {...send, 'id': remoteId},
      operationType: operationType,
      occurredAt: occurredAt,
      related: related,
      dependsOn: dependsOn,
    );
    return remoteId;
  }

  /// Reads ONE local mirror row by entity type + remote id.
  Future<Map<String, dynamic>?> _localRow(String entityType, String id) async {
    final cache = _cache;
    if (cache == null) return null;
    try {
      final all = await cache.getCollection(_userId, entityType);
      for (final r in all) {
        if ((r['id']?.toString() ?? '') == id) return Map<String, dynamic>.from(r);
      }
    } catch (_) {}
    return null;
  }

  /// Offline-safe guard: checks whether the local bank account has enough
  /// balance for an expense/withdrawal. Returns true when allowed.
  Future<bool> _localSufficientBalance(String accountId, double amount, String currency) async {
    final row = await _localRow('personal_bank_account', accountId);
    if (row == null) return true; // no mirror → let server decide when online
    final bal = (row['balance'] as num?)?.toDouble() ?? 0;
    final accCur = (row['currency'] ?? 'SAR').toString().toUpperCase();
    // When currencies differ we can't compare reliably offline; allow it so the
    // user is not blocked (server re-checks on sync).
    if (accCur != currency.toUpperCase()) return true;
    return bal >= amount;
  }

  /// Resolves the bank account for a recurring rule from the local-first
  /// mirror (merged view first, raw mirror row as fallback — offline-safe).
  Future<PersonalBankAccount?> _recurringBankAccount(String accountId) async {
    try {
      final accounts = await getBankAccounts();
      for (final a in accounts) {
        if (a.id == accountId) return a;
      }
    } catch (_) {}
    final row = await _localRow('personal_bank_account', accountId);
    if (row == null) return null;
    try {
      return PersonalBankAccount.fromServer(Map<String, dynamic>.from(row));
    } catch (_) {
      return null;
    }
  }

  // ── Bank accounts ──

  Future<List<PersonalBankAccount>> getBankAccounts() async {
    final raw = await _safeList('personal_bank_account', ApiEndpoints.personalFinanceAccounts);
    return raw.map((e) => PersonalBankAccount.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  Future<PersonalBankAccount?> getBankAccount(String accountId) async {
    if (accountId.isEmpty) return null;
    final accounts = await getBankAccounts();
    for (final a in accounts) {
      if (a.id == accountId) return a;
    }
    return null;
  }

  // ── Transactions ──

  Future<List<PersonalTransaction>> getTransactions({String? accountId, int month = 0, int year = 0}) async {
    final params = <String, dynamic>{};
    if (accountId != null && accountId.isNotEmpty) params['account_id'] = accountId;
    if (month > 0) params['month'] = month;
    if (year > 0) params['year'] = year;
    // The server list endpoint is PAGINATED (default 50). Merging the returned
    // page instead of replacing the collection guarantees the local mirror can
    // never lose rows beyond the first page; deletions arrive through the sync
    // pull tombstones (and the background refresh converges the first page).
    final raw = await _safeList('personal_transaction', ApiEndpoints.personalFinanceTransactions,
        params: params, fullReplace: false);
    var result = raw.map((e) => PersonalTransaction.fromServer(Map<String, dynamic>.from(e))).toList();
    // The backend filters by account; the local filter below additionally
    // covers offline mirror rows and cached data.
    if (accountId != null && accountId.isNotEmpty) {
      result = result.where((t) => t.accountId == accountId).toList();
    }
    if (month > 0) result = result.where((t) => t.date != null && t.date!.month == month).toList();
    if (year > 0) result = result.where((t) => t.date != null && t.date!.year == year).toList();
    // Canonical order everywhere (dashboard recent, history, reports):
    // newest first, stable across server / offline-mirror / merged rows.
    sortTransactionsNewestFirst(result);
    return result;
  }

  Future<List<PersonalTransaction>> getBankTransactions(String accountId) async {
    return getTransactions(accountId: accountId);
  }

  /// Local-First UPDATE: the local mirror + outbox op commit first and the
  /// call returns immediately; the SyncEngine replays the op in the
  /// background. Only the fields in [send] are recorded in `__changed`, so
  /// replay sends just those (see [_explicitChanges] in the sync engine).
  Future<void> updateTransaction({
    required String id,
    double? amount,
    String? category,
    String? description,
    DateTime? date,
    String? currency,
    String? accountId,
    String? paymentMethod,
    String? budgetId,
    String? budgetCategoryId,
    String? goalId,
    String? debtId,
    bool clearBudget = false,
    bool clearBudgetCategory = false,
    bool clearGoal = false,
    bool clearDebt = false,
  }) async {
    final send = <String, dynamic>{
      if (amount != null) 'amount': amount,
      if (category != null) 'category': category,
      if (description != null) 'description': description,
      if (date != null) 'date': date.toIso8601String(),
      if (currency != null) 'currency': currency,
      if (accountId != null) 'bank_account_id': accountId,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (budgetId != null) 'budget_id': budgetId,
      if (clearBudget) 'budget_id': '',
      if (budgetCategoryId != null) 'budget_category_id': budgetCategoryId,
      if (clearBudgetCategory) 'budget_category_id': '',
      if (goalId != null) 'goal_id': goalId,
      if (clearGoal) 'goal_id': '',
      if (debtId != null) 'debt_id': debtId,
      if (clearDebt) 'debt_id': '',
    };
    // Local commit first — never wait for the network. The edit carries the
    // derived effects with it: reverse what the OLD values moved, then apply
    // what the NEW ones move — bank balance, goal credit, debt paid and
    // budget spent — in the same SQLite transaction as the row itself, so an
    // offline edit is visible everywhere immediately and cannot half-apply.
    await _offlineUpdate('personal_transaction', id, send,
        operationType: SyncOperationTypes.transactionUpdate,
        planRelated: (oldRow, merged) async {
          // No mirror row means no locally applied effect to undo (and no
          // safe base to compute one from): the server owns the numbers and
          // the refresh after sync reconciles them.
          if (oldRow == null) return const <MirrorMutation>[];
          // Same-currency linked credit follows the edited amount: when the
          // stored credit is absent (or equals the old amount) it describes
          // money moved 1:1 with this transaction, so re-credit the new
          // amount. An explicitly different stored credit is a fixed
          // cross-currency credit — it stays untouched (server rule).
          // Mirror-only: the staged op still carries just the user's fields,
          // so replay matches the server's own payment/credit update logic.
          final newAmount = (merged['amount'] as num?)?.toDouble();
          final oldAmount = (oldRow['amount'] as num?)?.toDouble();
          if (newAmount != null &&
              oldAmount != null &&
              oldAmount != 0 &&
              newAmount != oldAmount) {
            if ((merged['goal_id'] ?? '').toString().isNotEmpty) {
              final g = (merged['goal_amount'] as num?)?.toDouble();
              if (g == null || g == oldAmount) {
                merged['goal_amount'] = newAmount;
              }
            }
            if ((merged['debt_id'] ?? '').toString().isNotEmpty) {
              final d = (merged['debt_amount'] as num?)?.toDouble();
              if (d == null || d == oldAmount) {
                merged['debt_amount'] = newAmount;
              }
            }
          }
          final overlay = <String, Map<String, dynamic>>{};
          return <MirrorMutation>[
            ...await _planReverseTransaction(oldRow, overlay),
            ...await _planTransactionEffect(merged, overlay),
          ];
        });
    _scheduleSync();
  }

  /// Local-First DELETE: reverses every financial effect on the local mirror
  /// first, drops the mirror row and stages a DELETE (or cancels the staged
  /// INSERT when the row never synced) — all inside one SQLite transaction.
  /// Returns immediately; the SyncEngine replays the DELETE in the
  /// background. Returns true when the transaction is gone (or scheduled).
  Future<bool> deleteTransaction(String id) async {
    return _joinFlight<bool>('del_tx:$id', () async {
      // Snapshot the mirror row FIRST so deletes can reverse effects.
      final mirror = await _localRow('personal_transaction', id);
      // Capture the server-side version BEFORE the mirror is purged so the
      // DELETE op carries the correct base_version (avoids version conflicts
      // that caused "resurrected" transactions).
      final syncVersion = (mirror?['_sync_version'] as num?)?.toInt() ?? 0;
      // Reverse every financial effect locally FIRST — this must happen
      // whether or not the transaction already reached the server.
      final related = mirror == null
          ? const <MirrorMutation>[]
          : await _planReverseTransaction(mirror);
      // If the row was created offline and never synced there is nothing to
      // delete server-side: cancel its staged INSERT and restore the mirror
      // atomically.
      final neverSynced = await _hasPendingInsert(id);
      if (neverSynced) {
        final cache = _cache;
        if (cache != null) {
          await cache.commitMirrorOnly(
            userId: _userId,
            deleteEntityType: 'personal_transaction',
            deleteRemoteId: id,
            related: related,
          );
        }
        await SyncOutbox.cancelEntityOps(
          entityType: 'personal_transaction',
          entityId: id,
          userId: _userId,
        );
        _scheduleSync();
        return true;
      }
      // Atomic offline delete: reverse effects on the mirror and stage the
      // DELETE, in ONE local transaction.
      final cache = _cache;
      if (cache != null) {
        await cache.commitOfflineWrite(
          userId: _userId,
          entityType: 'personal_transaction',
          remoteId: id,
          primaryRow: null,
          operation: 'DELETE',
          operationType: SyncOperationTypes.transactionDelete,
          baseVersion: syncVersion,
          related: related,
          cancelExistingOps: true,
        );
      }
      _scheduleSync();
      return true;
    });
  }

  /// Drops a transaction's local mirror row + any pending outbox ops for it.
  Future<void> _purgeLocalTx(String id) async {
    await _purgeLocalEntity('personal_transaction', id);
  }

  /// Drops any entity's local mirror row + its pending outbox ops. Called
  /// after an ONLINE delete succeeds so the row can never resurrect from a
  /// stale mirror row or a superseded queued op on the next refresh/pull.
  Future<void> _purgeLocalEntity(String entityType, String id) async {
    final cache = _cache;
    if (cache == null) return;
    try {
      await cache.removeItem(_userId, entityType, id);
    } catch (_) {}
    try {
      await SyncOutbox.cancelEntityOps(
        entityType: entityType,
        entityId: id,
        userId: _userId,
      );
    } catch (_) {}
  }

  Future<bool> _hasPendingInsert(String entityId) async {
    try {
      final rows = await DatabaseHelper.rawQuery(
        "SELECT id FROM sync_queue WHERE entity_type = 'personal_transaction' "
        "AND entity_id = ? AND operation = 'INSERT' "
        "AND status IN ('pending','syncing','failed') LIMIT 1",
        [entityId],
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _isNotFoundError(Object e) {
    try {
      // ignore: avoid_dynamic_calls
      final code = (e as dynamic)?.response?.statusCode;
      if (code == 404) return true;
    } catch (_) {}
    return e.toString().contains('404');
  }

  // ── Savings goals ──

  Future<List<SavingsGoal>> getSavingsGoals() async {
    final raw = await _safeList('personal_savings_goal', ApiEndpoints.personalFinanceGoals);
    return raw.map((e) => SavingsGoal.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  /// Local-First CREATE: mirror row + outbox op commit first, UI returns
  /// immediately, SyncEngine replays in the background.
  Future<void> addSavingsGoal(SavingsGoal goal) async {
    final send = goal.toServerJson();
    await _offlineCreate('personal_savings_goal', send, {
      'name': goal.name,
      'target_amount': goal.targetAmount,
      'current_amount': goal.currentAmount,
      if (goal.deadline != null) 'deadline': goal.deadline,
      'currency': goal.currency,
      'icon': goal.icon,
      if (goal.notes != null) 'notes': goal.notes,
      'is_completed': goal.isCompleted,
      if (goal.budgetId != null) 'budget_id': goal.budgetId,
      'created_at': DateTime.now().toIso8601String(),
    });
    _scheduleSync();
  }

  /// Local-First UPDATE: local mirror + outbox op first, background replay.
  Future<void> updateSavingsGoal(SavingsGoal goal) async {
    final payload = goal.toServerJson();
    await _offlineUpdate('personal_savings_goal', goal.id, payload);
    _scheduleSync();
  }

  /// Contributes to a goal in ONE call. The backend deducts the money from
  /// the resolved account, credits the goal, AND creates the linked
  /// transaction (goal_id + budget_id). Returns the created tx (if any).
  Future<Map<String, dynamic>?> contributeToGoal(
    String id,
    double amount, {
    double? goalAmount,
    String? currency,
    String? bankAccountId,
    String? paymentMethod,
    String? category,
    String? description,
    String? clientOperationId,
  }) async {
    final opId = clientOperationId ?? newOperationId();
    return _joinFlight<Map<String, dynamic>?>('contrib:$opId', () async {
      return await _contributeToGoalInner(
        id, amount,
        goalAmount: goalAmount,
        currency: currency,
        bankAccountId: bankAccountId,
        paymentMethod: paymentMethod,
        category: category,
        description: description,
        opId: opId,
      );
    });
  }

  /// Local-First goal contribution: the linked expense transaction is staged
  /// locally (bearing goal_id + bank_account_id + client_operation_id) and
  /// the bank/goal effects apply to the mirror instantly. Returns
  /// immediately; the SyncEngine replays the contribution in the background.
  /// Financial logic (amounts, goal credit, effects) is unchanged — only the
  /// order flipped: local commit first, network later.
  Future<Map<String, dynamic>?> _contributeToGoalInner(
    String id,
    double amount, {
    double? goalAmount,
    String? currency,
    String? bankAccountId,
    String? paymentMethod,
    String? category,
    String? description,
    required String opId,
  }) async {
    final result = await _contributeGoalOffline(id, amount, goalAmount,
        currency, bankAccountId, paymentMethod, category, description, opId);
    _scheduleSync();
    return result;
  }

  Future<Map<String, dynamic>> _contributeGoalOffline(
    String id, double amount, double? goalAmount, String? currency,
    String? bankAccountId, String? paymentMethod, String? category,
    String? description, [
    String? opId,
  ]) async {
    final send = <String, dynamic>{
      'amount': amount,
      if (goalAmount != null) 'goal_amount': goalAmount,
      if (currency != null) 'currency': currency,
      if (bankAccountId != null && bankAccountId.isNotEmpty) 'bank_account_id': bankAccountId,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (category != null) 'category': category,
      if (description != null) 'description': description,
      // Same goal-link rule as above: the staged op must carry goal_id so the
      // synced server row is linked and deletable with full reversal.
      'goal_id': id,
      'tx_type': 'expense',
      if (opId != null) 'client_operation_id': opId,
    };
    final goalCredit = goalAmount ?? amount;
    final nowIso = DateTime.now().toIso8601String();
    await _offlineCreateTransaction(
      send,
      {
        ...send,
        'goal_id': id,
        'goal_amount': goalCredit,
        'tx_type': 'expense',
        'description': description ?? 'مساهمة في هدف',
        'date': nowIso,
      },
      operationType: SyncOperationTypes.goalContribute,
    );
    return <String, dynamic>{
      'amount': amount,
      'goal_id': id,
      'tx_type': 'expense',
      'offline': true,
    };
  }

  /// Local-First DELETE: mirror row dropped + DELETE staged first, replay later.
  Future<void> deleteSavingsGoal(String id) async {
    await _offlineDelete('personal_savings_goal', id,
        operationType: SyncOperationTypes.goalDelete);
    _scheduleSync();
  }

  // ── Debts ──

  Future<List<PersonalDebt>> getDebts() async {
    final raw = await _safeList('personal_debt', ApiEndpoints.personalFinanceDebts);
    return raw.map((e) => PersonalDebt.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  Future<PersonalDebt?> getDebt(String id) async {
    if (id.isEmpty) return null;
    final debts = await getDebts();
    for (final d in debts) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Local-First CREATE: mirror + outbox first, background replay.
  Future<void> addDebt(PersonalDebt debt) async {
    final send = debt.toServerJson();
    await _offlineCreate('personal_debt', send, {
      'debt_type': debt.type,
      'person_name': debt.personName,
      'amount': debt.amount,
      'currency': debt.currency,
      if (debt.description != null) 'description': debt.description,
      if (debt.dueDate != null) 'due_date': debt.dueDate!.toIso8601String(),
      'is_paid': debt.isPaid,
      'reminder': debt.reminder,
      if (debt.budgetId != null) 'budget_id': debt.budgetId,
      'created_at': DateTime.now().toIso8601String(),
    });
    _scheduleSync();
  }

  /// Local-First UPDATE: local mirror + outbox first, background replay.
  Future<void> updateDebt(PersonalDebt debt) async {
    final payload = debt.toServerJson();
    await _offlineUpdate('personal_debt', debt.id, payload);
    _scheduleSync();
  }

  /// Local-First DELETE: mirror dropped + DELETE staged first, replay later.
  Future<void> deleteDebt(String id) async {
    await _offlineDelete('personal_debt', id);
    _scheduleSync();
  }

  /// Records a debt payment. The backend creates the payment AND the linked
  /// transaction (debt_id + budget_id from the debt). Returns the payment.
  Future<Map<String, dynamic>> payDebt(String id, double amount, DateTime date,
      {String method = 'cash', String? bankAccountId, String? notes, String? clientOperationId, String? currency, double? debtAmount}) async {
    final opId = clientOperationId ?? newOperationId();
    return _joinFlight<Map<String, dynamic>>('pay:$opId', () async {
      return await _payDebtInner(id, amount, date,
        method: method, bankAccountId: bankAccountId, notes: notes, currency: currency, debtAmount: debtAmount, opId: opId);
    });
  }

  /// Local-First debt payment: the linked payment transaction is staged
  /// locally (with the existing balance guard + date guarantee) and effects
  /// apply to the mirror instantly. Returns immediately; the SyncEngine
  /// replays the payment in the background. Payment/financial logic is
  /// unchanged — only the order flipped: local commit first, network later.
  Future<Map<String, dynamic>> _payDebtInner(String id, double amount, DateTime date,
      {required String method, String? bankAccountId, String? notes, String? currency, double? debtAmount, required String opId}) async {
    final send = <String, dynamic>{
      'amount': amount,
      // amount/currency describe the money movement in the account currency;
      // debt_amount (default = amount) is credited to the debt in debt
      // currency (goals-style cross-currency support).
      if (currency != null && currency.isNotEmpty) 'currency': currency,
      if (debtAmount != null) 'debt_amount': debtAmount,
      'payment_date': date.toIso8601String(),
      if (notes != null) 'notes': notes,
      if (bankAccountId != null && bankAccountId.isNotEmpty) 'bank_account_id': bankAccountId,
      'payment_method': method,
      'client_operation_id': opId,
    };
    final result =
        await _payDebtOffline(id, amount, date, method, bankAccountId, notes, send);
    _scheduleSync();
    return result;
  }

  Future<Map<String, dynamic>> _payDebtOffline(
    String id, double amount, DateTime date, String method,
    String? bankAccountId, String? notes, Map<String, dynamic> send,
  ) async {
    final debtRow = await _localRow('personal_debt', id);
    final isReceivable =
        (debtRow?['debt_type'] ?? debtRow?['type'] ?? '') == 'receivable';
    // Payable: money LEAVES the account -> the balance guard applies (in the
    // account/movement currency). Receivable (owed to me): money ENTERS the
    // account -> no balance requirement, the guard is skipped entirely.
    if (!isReceivable && bankAccountId != null && bankAccountId.isNotEmpty) {
      final cur = (send['currency']?.toString() ??
              debtRow?['currency']?.toString() ??
              'SAR');
      final ok = await _localSufficientBalance(bankAccountId, amount, cur);
      if (!ok) throw Exception('لا يوجد رصيد كافٍ لسداد الدين من الحساب المحدد');
    }
    final txType = isReceivable ? 'income' : 'expense';
    // Same `date` guarantee as above: the staged row must be datable or it
    // vanishes from newest-first lists.
    final payDateIso = date.toIso8601String();
    await _offlineCreateTransaction(
      {
        ...send,
        'debt_id': id,
        'tx_type': txType,
        'category': isReceivable ? 'تحصيل دين' : 'سداد دين',
        'date': payDateIso,
      },
      {
        ...send,
        'debt_id': id,
        'tx_type': txType,
        'category': isReceivable ? 'تحصيل دين' : 'سداد دين',
        'payment_method': method,
        'date': payDateIso,
      },
      operationType: SyncOperationTypes.debtPayment,
    );
    return <String, dynamic>{'offline': true, 'amount': amount, 'debt_id': id};
  }

  /// Lists a debt's payments. Offline this reconstructs the history from the
  /// locally mirrored payment transactions (exact amounts/dates are stored on
  /// the transaction row), so the UI keeps working without Internet.
  Future<List<PersonalDebtPayment>> getDebtPayments(String debtId) async {
    try {
      final raw = await _api.list(ApiEndpoints.personalFinanceDebtPayments(debtId));
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return PersonalDebtPayment.fromServer(m);
      }).toList();
    } catch (e) {
      if (!isConnectivityError(e)) rethrow;
      final txs = await _cache?.getCollection(_userId, 'personal_transaction') ??
          const <Map<String, dynamic>>[];
      return txs
          .where((t) =>
              (t['debt_id']?.toString() ?? '') == debtId &&
              ((t['tx_type'] ?? '') == 'expense' || (t['tx_type'] ?? '') == 'income'))
          .map((t) => PersonalDebtPayment(
                id: t['id']?.toString() ?? '',
                debtId: debtId,
                amount: (t['debt_amount'] as num?)?.toDouble() ??
                    (t['amount'] as num?)?.toDouble() ??
                    0,
                paymentDate:
                    DateTime.tryParse(t['date']?.toString() ?? '') ??
                        DateTime.now(),
                notes: t['description']?.toString() ?? '',
              ))
          .toList();
    }
  }

  // ── Analytics / totals ──

  Future<Map<String, double>> getSpendingAnalytics() async {
    final txs = await getTransactions();
    final cats = <String, double>{};
    double total = 0;
    for (final t in txs.where((t) => t.type == 'expense')) {
      cats[t.category] = (cats[t.category] ?? 0) + t.amount;
      total += t.amount;
    }
    if (total == 0) return {};
    return cats.map((k, v) => MapEntry(k, (v / total * 100).roundToDouble()));
  }

  Future<double> getTotalBalance() async {
    final accounts = await getBankAccounts();
    return accounts.fold<double>(0, (sum, a) => sum + a.balance);
  }

  // ── Exchange rates (local reference data; no backend endpoint) ──

  Future<List<ExchangeRate>> getExchangeRates() async {
    final repo = _repo;
    if (repo == null) return const [];
    final rows = await repo.getExchangeRates(_userId);
    return rows.map((r) => ExchangeRate(
      id: r['id'] as int,
      fromCurrency: r['from_currency'] as String? ?? '',
      toCurrency: r['to_currency'] as String? ?? '',
      rate: (r['rate'] as num?)?.toDouble() ?? 0,
    )).toList();
  }

  Future<bool> addExchangeRate({required String fromCurrency, required String toCurrency, required double rate}) async {
    try {
      final repo = _repo;
      if (repo == null) return false;
      final existing = await repo.getExchangeRate(_userId, fromCurrency, toCurrency);
      if (existing != null) {
        await repo.updateExchangeRate(existing['id'] as int, rate);
      } else {
        await repo.insertExchangeRate({'user_id': _userId, 'from_currency': fromCurrency, 'to_currency': toCurrency, 'rate': rate});
      }
      return true;
    } catch (_) { return false; }
  }

  // ── Transactions (write) ──

  Future<bool> addTransaction({
    required String type,
    required double amount,
    required String category,
    String? description,
    String? paymentMethod,
    required DateTime date,
    String? accountId,
    String currency = 'USD',
    String? budgetId,
    String? budgetCategoryId,
    String? goalId,
    String? debtId,
    String? clientOperationId,
  }) async {
    final opId = clientOperationId ?? newOperationId();
    return _joinFlight<bool>('addtx:$opId', () async {
      return await _addTransactionInner(
        type: type,
        amount: amount,
        category: category,
        description: description,
        paymentMethod: paymentMethod,
        date: date,
        accountId: accountId,
        currency: currency,
        budgetId: budgetId,
        budgetCategoryId: budgetCategoryId,
        goalId: goalId,
        debtId: debtId,
        opId: opId,
      );
    });
  }

  /// Local-First CREATE: balance guard + mirror row + effects + outbox op
  /// commit atomically first (via [_addTransactionOffline]), the call returns
  /// immediately, and the SyncEngine replays the op in the background with
  /// the same `client_operation_id` (idempotent — no duplicate on retry).
  Future<bool> _addTransactionInner({
    required String type,
    required double amount,
    required String category,
    String? description,
    String? paymentMethod,
    required DateTime date,
    String? accountId,
    String currency = 'USD',
    String? budgetId,
    String? budgetCategoryId,
    String? goalId,
    String? debtId,
    required String opId,
  }) async {
    final send = <String, dynamic>{
      'tx_type': type,
      'amount': amount,
      'category': category,
      if (description != null) 'description': description,
      'date': date.toIso8601String(),
      if (accountId != null && accountId.isNotEmpty) 'bank_account_id': accountId,
      if (currency.isNotEmpty) 'currency': currency,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (budgetId != null && budgetId.isNotEmpty) 'budget_id': budgetId,
      if (budgetCategoryId != null && budgetCategoryId.isNotEmpty) 'budget_category_id': budgetCategoryId,
      if (goalId != null && goalId.isNotEmpty) 'goal_id': goalId,
      if (debtId != null && debtId.isNotEmpty) 'debt_id': debtId,
      'client_operation_id': opId,
    };
    final ok =
        await _addTransactionOffline(send, type, amount, accountId, currency);
    _scheduleSync();
    return ok;
  }

  /// Shared offline path for addTransaction — stages the op and applies effects.
  Future<bool> _addTransactionOffline(
    Map<String, dynamic> send,
    String type,
    double amount,
    String? accountId,
    String currency,
  ) async {
    final isExpense = type == 'expense' || type == 'transfer_out';
    if (isExpense && accountId != null && accountId.isNotEmpty) {
      final ok = await _localSufficientBalance(accountId, amount, currency);
      if (!ok) throw Exception('لا يوجد رصيد كافٍ في الحساب المحدد');
    }
    await _offlineCreateTransaction(send, {
      'tx_type': type,
      'amount': amount,
      'category': send['category'],
      if (send['description'] != null) 'description': send['description'],
      'date': send['date'],
      if (accountId != null && accountId.isNotEmpty) 'bank_account_id': accountId,
      if (currency.isNotEmpty) 'currency': currency,
      if (send['payment_method'] != null) 'payment_method': send['payment_method'],
      if (send['budget_id'] != null) 'budget_id': send['budget_id'],
      if (send['budget_category_id'] != null) 'budget_category_id': send['budget_category_id'],
      if (send['goal_id'] != null) 'goal_id': send['goal_id'],
      if (send['goal_amount'] != null) 'goal_amount': send['goal_amount'],
      if (send['debt_id'] != null) 'debt_id': send['debt_id'],
      if (send['debt_amount'] != null) 'debt_amount': send['debt_amount'],
      if (send['exchange_rate'] != null) 'exchange_rate': send['exchange_rate'],
      if (send['exchange_rate_currency'] != null) 'exchange_rate_currency': send['exchange_rate_currency'],
      if (send['fx_source'] != null) 'fx_source': send['fx_source'],
      if (send['client_operation_id'] != null) 'client_operation_id': send['client_operation_id'],
      'created_at': send['date'],
    });
    return true;
  }

  // ── Bank accounts (write) ──

  /// Local-First CREATE: mirror + outbox first, background replay.
  Future<void> addBankAccount({required String bankName, required String currency, required double openingBalance, String? notes, String accountType = 'checking'}) async {
    // The type (جاري/توفير) travels with the create (server vocabulary
    // current/savings) so it syncs across devices and survives reinstall;
    // the outbox replays it when the create was made offline.
    final isCash = accountType == 'cash';
    await _offlineCreate('personal_bank_account', {
      'bank_name': bankName,
      'currency': currency,
      if (!isCash) 'account_type': personalAccountTypeToServer(accountType),
      if (notes != null) 'notes': notes,
      'balance': openingBalance,
      'created_at': DateTime.now().toIso8601String(),
    }, {
      'bank_name': bankName,
      'currency': currency,
      'account_type': accountType,
      if (!isCash) 'account_type_set': true,
      'balance': openingBalance,
      if (notes != null) 'notes': notes,
      'created_at': DateTime.now().toIso8601String(),
    });
    _scheduleSync();
  }

  /// Local-First UPDATE: local mirror + outbox first, background replay.
  /// Only the provided fields are recorded in `__changed`.
  Future<void> updateBankAccount(String accountId, {String? bankName, String? currency, double? balance, String? notes, String? accountType}) async {
    final data = <String, dynamic>{};
    if (bankName != null) data['bank_name'] = bankName;
    if (currency != null) data['currency'] = currency;
    if (balance != null) data['balance'] = balance;
    if (notes != null) data['notes'] = notes;
    if (accountType != null && accountType != 'cash') {
      data['account_type'] = personalAccountTypeToServer(accountType);
      // Local truth until the server confirms (the field is ignored there).
      data['account_type_set'] = true;
    }
    if (data.isEmpty) return;
    await _offlineUpdate('personal_bank_account', accountId, data);
    _scheduleSync();
  }

  /// Local-First balance set: local mirror + BALANCE_SET op first, replay later.
  Future<void> updateBankBalance(String accountId, double newBalance) async {
    await _offlineUpdate('personal_bank_account', accountId, {'balance': newBalance},
        operationType: SyncOperationTypes.bankBalanceSet);
    _scheduleSync();
  }

  /// Local-First transfer — ATOMIC: both legs + both balances in ONE SQLite
  /// transaction. Either the withdraw + deposit + balance updates all commit
  /// together or nothing commits (no deposit without withdraw). The SyncEngine
  /// later replays both ops in order.
  Future<bool> transferBetweenAccounts({required String fromId, required String toId, required double amount, required String fromCurrency, required String toCurrency, required double rate}) async {
    if (fromId == toId) throw Exception('لا يمكن التحويل إلى نفس الحساب');
    final converted = fromCurrency == toCurrency ? amount : amount * rate;
    final accounts = await getBankAccounts();
    PersonalBankAccount? from;
    PersonalBankAccount? to;
    for (final a in accounts) {
      if (a.id == fromId) from = a;
      if (a.id == toId) to = a;
    }
    if (from == null || to == null) return false;
    if (from.balance < amount) throw Exception('الرصيد غير كافٍ في حساب ${from.bankName} (${from.currency}). الحالي: ${from.balance}، المطلوب: $amount');
    final cache = _cache;
    if (cache == null) return false;
    final now = DateTime.now().toIso8601String();
    final outId = _newUuid();
    final inId = _newUuid();
    // Prepare mirror rows
    final outSend = {
      'tx_type': 'transfer_out',
      'amount': amount,
      'category': 'تحويل',
      'description': 'تحويل بين الحسابات',
      'date': now,
      'bank_account_id': fromId,
      'currency': fromCurrency,
    };
    final outMirror = {
      'tx_type': 'expense',
      'amount': amount,
      'category': 'تحويل',
      'description': 'تحويل بين الحسابات',
      'date': now,
      'bank_account_id': fromId,
      'currency': fromCurrency,
    };
    final inSend = {
      'tx_type': 'transfer_in',
      'amount': converted,
      'category': 'تحويل',
      'description': 'تحويل بين الحسابات',
      'date': now,
      'bank_account_id': toId,
      'currency': toCurrency,
    };
    final inMirror = {
      'tx_type': 'income',
      'amount': converted,
      'category': 'تحويل',
      'description': 'تحويل بين الحسابات',
      'date': now,
      'bank_account_id': toId,
      'currency': toCurrency,
    };
    // Balance mutations — read current mirror rows, bump, keep updated_at
    final fromRow = await _localRow('personal_bank_account', fromId);
    final toRow = await _localRow('personal_bank_account', toId);
    final mutations = <MirrorMutation>[];
    if (fromRow != null) {
      final oldBal = (fromRow['balance'] as num?)?.toDouble() ?? from.balance;
      fromRow['balance'] = (oldBal - amount).clamp(0, double.infinity);
      fromRow['updated_at'] = now;
      mutations.add(MirrorMutation.upsert('personal_bank_account', fromId, fromRow));
    }
    if (toRow != null) {
      final oldBal = (toRow['balance'] as num?)?.toDouble() ?? to.balance;
      toRow['balance'] = oldBal + converted;
      toRow['updated_at'] = now;
      mutations.add(MirrorMutation.upsert('personal_bank_account', toId, toRow));
    }
    await cache.commitTransferAtomic(
      userId: _userId,
      outId: outId,
      outMirrorRow: outMirror,
      outSend: outSend,
      inId: inId,
      inMirrorRow: inMirror,
      inSend: inSend,
      balanceMutations: mutations,
    );
    _scheduleSync();
    return true;
  }

  /// Local-First DELETE: mirror dropped + DELETE staged first, replay later.
  Future<void> deleteBankAccount(String accountId) async {
    await _offlineDelete('personal_bank_account', accountId);
    _scheduleSync();
  }

  Future<void> resetAccount() async {
    try {
      await _api.remove(ApiEndpoints.personalFinanceReset);
      return;
    } catch (_) {
      // Backend قديم بدون endpoint الدفعة أو مشكلة اتصال: نرجع للاتصال الفردي.
    }
    for (final a in await getBankAccounts()) {
      try { await _api.remove(ApiEndpoints.personalFinanceAccount(a.id)); } catch (_) {}
    }
    for (final t in await getTransactions()) {
      try { await _api.remove(ApiEndpoints.personalFinanceTransaction(t.id)); } catch (_) {}
    }
    for (final g in await getSavingsGoals()) {
      try { await _api.remove(ApiEndpoints.personalFinanceGoal(g.id)); } catch (_) {}
    }
    for (final d in await getDebts()) {
      try { await _api.remove(ApiEndpoints.personalFinanceDebt(d.id)); } catch (_) {}
    }
    for (final b in await getAllBudgets()) {
      try { await _api.remove(ApiEndpoints.personalFinanceBudget(b.id)); } catch (_) {}
    }
    for (final r in await getRecurring()) {
      try { await _api.remove(ApiEndpoints.personalFinanceRecurringItem(r.id)); } catch (_) {}
    }
  }

  /// Bulk restore all personal finance data in a single API request.
  /// Returns a map of counts per type restored, or null on failure.
  /// Schema-4.0.0 server restore: sends canonical entities (original UUIDs,
  /// exact money strings) to the validated atomic bulk endpoint and returns
  /// the server's verification envelope `{expected, restored, verified,
  /// backup_id}`. Transport/validation failures throw (DioException or
  /// FormatException) — the caller must treat anything but
  /// `verified == true` as a failure. There is intentionally no silent
  /// fallback: an unverified restore is a failed restore.
  Future<Map<String, dynamic>> bulkRestoreV2({
    required String schemaVersion,
    required String? backupId,
    required Map<String, dynamic> entities,
  }) async {
    final payload = <String, dynamic>{
      'schema_version': schemaVersion,
      'backup_id': backupId,
      'entities': entities,
    };
    final result = await _api.create(ApiEndpoints.personalFinanceBulkRestore, payload);
    return result;
  }

  Future<void> migrateCashWallet() async {
    // The backend has no local-wallet concept; accounts live server-side.
  }

  // ── Budgets ──

  Future<List<PersonalBudget>> getBudgets(int month, int year) async {
    // The backend list endpoint carries no month/year filter; period filtering
    // happens in the aggregation layer per budget start/end dates.
    return getAllBudgets();
  }

  Future<List<PersonalBudget>> getAllBudgets() async {
    final raw = await _safeList('personal_budget', ApiEndpoints.personalFinanceBudgets);
    return raw.map((e) => PersonalBudget.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  Future<PersonalBudget?> getBudget(String id) async {
    if (id.isEmpty) return null;
    final budgets = await getAllBudgets();
    for (final b in budgets) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Single source of truth: backend-computed aggregation for one budget.
  Future<BudgetAggregation> getBudgetAggregation(String budgetId) async {
    final res = await _api.one(ApiEndpoints.personalFinanceBudgetAggregation(budgetId));
    return BudgetAggregation.fromJson(res);
  }

  /// Local-First CREATE: mirror + outbox first, background replay.
  Future<void> addBudget(PersonalBudget budget) async {
    // Stable client UUIDs for brand-new categories (empty ids) FIRST, so
    // transaction links and local progress are valid from the first local
    // commit — and the server materializes the same ids on sync.
    final withIds =
        budget.copyWith(categories: _withCategoryIds(budget.categories));
    final send = withIds.toServerJson();
    await _offlineCreate('personal_budget', send, {
      'name': withIds.name,
      'period_type': withIds.periodType,
      'start_date': withIds.startDate?.toIso8601String(),
      'end_date': withIds.endDate?.toIso8601String(),
      'custom_days': withIds.customDays,
      'total_amount': withIds.totalAmount,
      'amount': withIds.totalAmount,
      'spent': withIds.totalSpent,
      'currency': withIds.currency,
      'bank_account_ids': withIds.bankAccountIds,
      'budget_types': withIds.budgetTypes,
      'categories':
          withIds.categories.map((c) => c.toJson()).toList(),
      'created_at': DateTime.now().toIso8601String(),
    });
    _scheduleSync();
  }

  /// Local-First UPDATE: local mirror + outbox first, background replay.
  Future<void> updateBudget(PersonalBudget budget) async {
    final withIds =
        budget.copyWith(categories: _withCategoryIds(budget.categories));
    final payload = withIds.toServerJson();
    await _offlineUpdate('personal_budget', withIds.id, payload);
    _scheduleSync();
  }

  /// Fills missing budget-category ids with stable client UUIDs (existing
  /// server ids are never touched), so offline links survive sync.
  List<BudgetCategory> _withCategoryIds(List<BudgetCategory> cats) {
    return cats.map((c) {
      if (c.id.isNotEmpty) return c;
      return c.copyWith(id: _newUuid());
    }).toList();
  }

  /// Local-First DELETE: mirror dropped + DELETE staged first, replay later.
  Future<void> deleteBudget(String id) async {
    await _offlineDelete('personal_budget', id);
    _scheduleSync();
  }

  Future<void> recalcBudgetSpent(int month, int year) async {
    // The backend computes aggregation on every GET .../budgets/{id}/aggregation call.
  }

  // ── Recurring transactions ──

  Future<List<RecurringTransaction>> getRecurring() async {
    final raw = await _safeList('personal_recurring_transaction', ApiEndpoints.personalFinanceRecurring);
    return raw.map((e) => RecurringTransaction.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<RecurringTransaction>> getActiveRecurring() async {
    final raw = await _safeList('personal_recurring_transaction', ApiEndpoints.personalFinanceRecurring, params: {'is_active': true}, fullReplace: false);
    return raw.map((e) => RecurringTransaction.fromServer(Map<String, dynamic>.from(e))).toList();
  }

  /// Local-First CREATE: mirror + outbox first, background replay.
  Future<void> addRecurring(RecurringTransaction rt) async {
    final send = rt.toServerJson();
    await _offlineCreate('personal_recurring_transaction', send, {
      'name': rt.name,
      'tx_type': rt.type,
      'amount': rt.amount,
      'currency': rt.currency,
      'category': rt.category,
      if (rt.description != null) 'description': rt.description,
      'frequency': rt.frequency,
      'interval_value': rt.intervalValue,
      if (rt.nextDate != null) 'next_run_date': rt.nextDate!.toIso8601String(),
      'is_active': rt.isActive,
      // The detail page resolves the fixed account from these keys; without
      // them an offline-created rule shows "unspecified" until sync+pull.
      'account_type': rt.accountType,
      if (rt.bankAccountId != null) 'bank_account_id': rt.bankAccountId,
      'execution_type': rt.executionType,
      if (rt.reminderTime != null) 'reminder_time': rt.reminderTime,
      if (rt.paymentMethod != null) 'payment_method': rt.paymentMethod,
      if (rt.approximateStartDay != null)
        'approximate_start_day': rt.approximateStartDay,
      if (rt.approximateEndDay != null)
        'approximate_end_day': rt.approximateEndDay,
      if (rt.lastExecutedAt != null)
        'last_executed_at': rt.lastExecutedAt!.toIso8601String(),
      'created_at': DateTime.now().toIso8601String(),
    });
    _scheduleSync();
  }

  /// Local-First UPDATE: local mirror + outbox first, background replay.
  Future<void> updateRecurring(RecurringTransaction rt) async {
    await _offlineUpdate(
        'personal_recurring_transaction', rt.id, rt.toServerJson());
    _scheduleSync();
  }

  /// Local-First toggle: single-field UPDATE staged locally first.
  Future<void> toggleRecurringActive(String id, bool active) async {
    final payload = <String, dynamic>{'is_active': active};
    await _offlineUpdate('personal_recurring_transaction', id, payload);
    _scheduleSync();
  }

  /// Local-First DELETE: mirror dropped + DELETE staged first, replay later.
  Future<void> deleteRecurring(String id) async {
    await _offlineDelete('personal_recurring_transaction', id);
    _scheduleSync();
  }

  /// Executes a rule immediately (manual "execute now" or the auto sweep).
  ///
  /// Idempotency keys differ by intent: the AUTO sweep keeps the deterministic
  /// per-rule-per-day key (every sweep of the same day is one intent), while a
  /// MANUAL tap gets a per-second key — a user's explicit tap is its own
  /// intent and must never collapse into (or vanish against) the day's
  /// automatic execution, online or offline. Same-second double-taps still
  /// share one key (plus the in-flight guard below).
  Future<void> executeRecurringNow(RecurringTransaction rt, {String? overrideCurrency, String? overrideBankAccountId, CurrencyEngine? currencyEngine, String? clientOperationId, bool manual = false}) async {
    // Deterministic per rule+day: double-taps (and sync replays) share one key.
    final day = DateTime.now();
    final dayKey = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final opId = clientOperationId ??
        (manual
            ? 'recur_${rt.id}_${dayKey}_${day.hour.toString().padLeft(2, '0')}${day.minute.toString().padLeft(2, '0')}${day.second.toString().padLeft(2, '0')}'
            : 'recur_${rt.id}_$dayKey');
    return _joinFlight<void>('exec:$opId', () async {
      return await _executeRecurringNowInner(rt,
        overrideCurrency: overrideCurrency,
        overrideBankAccountId: overrideBankAccountId,
        currencyEngine: currencyEngine,
        opId: opId);
    });
  }

  Future<void> _executeRecurringNowInner(RecurringTransaction rt, {String? overrideCurrency, String? overrideBankAccountId, CurrencyEngine? currencyEngine, required String opId}) async {
    final bankAccountId = overrideBankAccountId ?? rt.bankAccountId;
    var txCurrency = overrideCurrency ?? rt.currency;

    double finalAmount = rt.amount;
    var finalCurrency = txCurrency;

    if (bankAccountId != null && bankAccountId.isNotEmpty) {
      // Offline-safe: read the account from the (cached) local mirror so the
      // recurring execution works identically when the network is down.
      final account = await _recurringBankAccount(bankAccountId);
      if (rt.type == 'expense') {
        // Recurring EXPENSES withdraw real money: the chosen account MUST
        // hold enough after converting the rule's currency to the account
        // currency at the live/cached rate. Unknown account/rate/balance
        // fails closed — never a phantom success, never a silent no-op.
        if (account == null) {
          throw const RecurringExecutionException(
              'account_unavailable',
              'الحساب البنكي المحدد غير متاح — تعذر التحقق من الرصيد');
        }
        final rawAccCur = account.currency.trim();
        final accountCurrency = (rawAccCur.isEmpty ? 'SAR' : rawAccCur).toUpperCase();
        final srcCurrency = rt.currency.trim().toUpperCase();
        if (accountCurrency != srcCurrency) {
          final converted =
              currencyEngine?.convert(rt.amount, rt.currency, accountCurrency) ?? 0;
          if (converted <= 0) {
            throw const RecurringExecutionException(
                'fx_unavailable',
                'تعذر التحقق من الرصيد: سعر الصرف غير متاح حالياً. أعد المحاولة عند توفر الإنترنت');
          }
          finalAmount = converted;
          finalCurrency = accountCurrency;
          txCurrency = accountCurrency;
        } else {
          finalCurrency = accountCurrency;
          txCurrency = accountCurrency;
        }
        if (account.balance < finalAmount) {
          throw RecurringExecutionException(
              'insufficient_balance',
              'لا يوجد رصيد كافٍ في الحساب المحدد لتنفيذ العملية المتكررة. '
              'الرصيد الحالي: ${account.balance.toStringAsFixed(2)} $accountCurrency');
        }
      } else if (account != null) {
        // Income only ADDS money: best-effort conversion, never blocked.
        final accountCurrency = account.currency.toUpperCase();
        final srcCurrency = rt.currency.toUpperCase();
        if (accountCurrency.isNotEmpty && accountCurrency != srcCurrency) {
          final converted =
              currencyEngine?.convert(rt.amount, rt.currency, accountCurrency) ?? 0;
          if (converted != 0) finalAmount = converted;
          finalCurrency = accountCurrency;
          txCurrency = accountCurrency;
        } else if (txCurrency.toUpperCase() != srcCurrency) {
          final converted =
              currencyEngine?.convert(rt.amount, rt.currency, txCurrency) ?? 0;
          if (converted != 0) finalAmount = converted;
          finalCurrency = txCurrency;
        } else {
          finalCurrency = txCurrency;
        }
      }
    }

    final send = <String, dynamic>{
      'tx_type': rt.type,
      'amount': finalAmount,
      'category': rt.category,
      'description': rt.description ?? rt.name,
      'date': DateTime.now().toIso8601String(),
      if (bankAccountId != null && bankAccountId.isNotEmpty) 'bank_account_id': bankAccountId,
      'currency': finalCurrency,
      'client_operation_id': opId,
    };
    // Local-First: stage the execution transaction on the local mirror first,
    // then return; the SyncEngine replays it in the background. The balance
    // guard above (converted to the account currency) already rejected any
    // uncovered withdrawal — nothing reaches the outbox on failure.
    await _offlineCreateTransaction(send, send);
    _scheduleSync();
    final nextDate = _calculateNextRecurringDate(rt);
    try {
      await updateRecurring(rt.copyWith(nextDate: nextDate, lastExecutedAt: DateTime.now()));
    } catch (_) {
      // nextDate update is best-effort; the tx itself is already staged.
    }
  }

  DateTime? _calculateNextRecurringDate(RecurringTransaction rt) {
    final current = rt.nextDate ?? DateTime.now();
    switch (rt.frequency) {
      case 'daily':
        return current.add(Duration(days: rt.intervalValue));
      case 'weekly':
        return current.add(Duration(days: 7 * rt.intervalValue));
      case 'monthly':
        return _addMonths(current, rt.intervalValue);
      case 'yearly':
        return _addMonths(current, 12 * rt.intervalValue);
      default:
        return current.add(Duration(days: rt.intervalValue));
    }
  }

  DateTime _addMonths(DateTime date, int months) {
    var year = date.year;
    var month = date.month + months;
    while (month > 12) { month -= 12; year++; }
    while (month < 1) { month += 12; year--; }
    final day = date.day.clamp(1, DateTime(year, month + 1, 0).day);
    return DateTime(year, month, day);
  }

  /// Exact execution instant of a rule: nextDate at reminderTime
  /// (09:00 AM when the user never picked a time). Mirrors the device
  /// alarm so automatic execution and notifications share one instant.
  DateTime? _recurringFireAt(RecurringTransaction rt) {
    final d = rt.nextDate;
    if (d == null) return null;
    var hour = 9;
    var minute = 0;
    final rem = rt.reminderTime;
    if (rem != null) {
      final parts = rem.split(':');
      if (parts.length == 2) {
        hour = int.tryParse(parts[0]) ?? 9;
        minute = int.tryParse(parts[1]) ?? 0;
      }
    }
    return DateTime(d.year, d.month, d.day, hour, minute);
  }

  /// Rules whose most recent AUTOMATIC sweep execution failed (e.g. the
  /// selected account had insufficient balance). The provider layer reads
  /// this right after `processDueRecurring` to warn the user instead of
  /// silently skipping the occurrence.
  List<RecurringTransaction> lastRecurringSweepFailures = [];

  /// Executes due automatic recurring rules (the former no-op stub).
  ///
  /// Runs on every recurring-list load (online AND offline — execution uses
  /// the local mirror when the network is down). A rule fires when it is
  /// active, automatic, bound to a fixed account, its nextDate is today
  /// or past, AND the chosen execution time has arrived (never before the
  /// exact day + time the user picked). Returns the rules executed this run
  /// so the caller can notify.
  ///
  /// Safety: one execution per rule per sweep, plus a same-calendar-day guard
  /// on lastExecutedAt, plus the deterministic per-rule-per-day operation id
  /// (server-deduped). A failed rule (e.g. insufficient balance) is skipped
  /// and stays due for the next run instead of crashing the sweep.
  Future<List<RecurringTransaction>> processDueRecurring({CurrencyEngine? currencyEngine}) async {
    final executed = <RecurringTransaction>[];
    lastRecurringSweepFailures = [];
    List<Map<String, dynamic>> rows;
    try {
      rows = await _safeList(
          'personal_recurring_transaction', ApiEndpoints.personalFinanceRecurring);
    } catch (_) {
      try {
        final cache = _cache;
        if (cache == null) return executed;
        rows = await cache.getCollection(_userId, 'personal_recurring_transaction');
      } catch (_) {
        return executed;
      }
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final doneIds = <String>{};
    for (final m in rows) {
      RecurringTransaction rt;
      try {
        rt = RecurringTransaction.fromServer(Map<String, dynamic>.from(m));
      } catch (_) {
        continue;
      }
      if (!rt.isActive || doneIds.contains(rt.id)) continue;
      final due = rt.nextDate;
      if (due == null || due.isAfter(today)) continue;
      // Never execute before the exact day + time the user chose.
      final fireAt = _recurringFireAt(rt);
      if (fireAt != null && now.isBefore(fireAt)) continue;
      final last = rt.lastExecutedAt;
      if (last != null &&
          last.year == now.year &&
          last.month == now.month &&
          last.day == now.day) {
        continue;
      }
      if (rt.executionType != 'auto') continue;
      if (rt.accountType != 'fixed' ||
          rt.bankAccountId == null ||
          rt.bankAccountId!.isEmpty) {
        continue;
      }
      try {
        await executeRecurringNow(rt, currencyEngine: currencyEngine);
        doneIds.add(rt.id);
        executed.add(rt);
      } catch (_) {
        lastRecurringSweepFailures.add(rt);
      }
    }
    return executed;
  }

  // ── Spending categories ──
  //
  // The server has no category entity: it only derives names from the
  // user's transactions. Categories the user adds/edits live on the device
  // in the encrypted Personal mirror (`personal_entity_cache`, entity
  // [categoryEntityType]) — offline, survive restart, and travel with the
  // Personal backup/restore (the mirror table is snapshotted and restored
  // whole). Derived names (transactions) are merged in; a stored category
  // wins over a derived name it matches.

  static const categoryEntityType = 'personal_category';

  Future<List<SpendingCategory>> _storedCategories() async {
    final cache = _cache;
    if (cache == null) return const [];
    final rows = await cache.getCollection(_userId, categoryEntityType);
    final list = rows
        .map(SpendingCategory.fromJson)
        .where((c) => c.id.isNotEmpty)
        .toList();
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  static String _catKey(String s) => s.trim().toLowerCase();

  static bool _catMatches(SpendingCategory c, String value) {
    final k = _catKey(value);
    return k.isNotEmpty && (_catKey(c.name) == k || _catKey(c.nameAr) == k);
  }

  List<SpendingCategory> _mergeCategories(
      List<SpendingCategory> stored, Iterable<String> derived) {
    final out = [...stored];
    final known = <String>{
      for (final c in stored) ...[_catKey(c.name), _catKey(c.nameAr)],
    };
    for (final n in derived) {
      final name = n.trim();
      if (name.isEmpty) continue;
      if (known.add(_catKey(name))) {
        out.add(SpendingCategory(id: name, name: name, nameAr: name));
      }
    }
    return out;
  }

  Future<List<String>> _localCategoryNames() async {
    final cache = _cache;
    if (cache == null) return const [];
    final txs = await cache.getCollection(_userId, 'personal_transaction');
    return [
      for (final t in txs)
        if ((t['category'] ?? '').toString().trim().isNotEmpty)
          (t['category'] ?? '').toString().trim(),
    ];
  }

  /// Pure-local categories (no network): the user's stored categories plus
  /// the distinct categories of the locally mirrored transactions. Used for
  /// instant page opens and as the offline fallback of [getCategories].
  /// Never throws for missing data.
  Future<List<SpendingCategory>> getLocalCategories() async {
    try {
      return _mergeCategories(
          await _storedCategories(), await _localCategoryNames());
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpendingCategory>> getCategories() async {
    List<String> server;
    try {
      final raw = await _api.list(ApiEndpoints.personalFinanceCategories);
      server = raw.map((e) => e.toString()).toList();
    } catch (e) {
      // Offline/slow network: derive from the local mirror so category UIs
      // open instantly instead of awaiting (then failing) a network call.
      if (!isConnectivityError(e)) rethrow;
      return getLocalCategories();
    }
    List<String> local = const [];
    try {
      local = await _localCategoryNames();
    } catch (_) {}
    List<SpendingCategory> stored = const [];
    try {
      stored = await _storedCategories();
    } catch (_) {}
    return _mergeCategories(stored, [...server, ...local]);
  }

  /// How many local transactions and recurring rules use [cat] (by its
  /// Arabic or English name — transactions store the category name).
  Future<int> categoryUsageCount(SpendingCategory cat) async {
    final cache = _cache;
    if (cache == null) return 0;
    var n = 0;
    for (final type in const [
      'personal_transaction',
      'personal_recurring_transaction',
    ]) {
      for (final row in await cache.getCollection(_userId, type)) {
        if (_catMatches(cat, (row['category'] ?? '').toString())) n++;
      }
    }
    return n;
  }

  void _validateCategory(SpendingCategory cat) {
    if (cat.name.trim().isEmpty || cat.nameAr.trim().isEmpty) {
      throw const CategoryException('NAME_REQUIRED',
          'اسم التصنيف بالعربية والإنجليزية مطلوب', 'Arabic and English names are required');
    }
  }

  Future<void> _ensureUniqueCategory(SpendingCategory cat, {String? exceptId}) async {
    final all = await getLocalCategories();
    for (final c in all) {
      if (c.id == exceptId) continue;
      if (_catMatches(c, cat.name) || _catMatches(c, cat.nameAr)) {
        throw CategoryException('DUPLICATE', 'يوجد تصنيف بهذا الاسم: ${c.nameAr}',
            'A category with this name already exists: ${c.name}');
      }
    }
  }

  CategoryException _categoryInUse(SpendingCategory cat, int count) =>
      CategoryException(
          'CATEGORY_IN_USE',
          'التصنيف «${cat.nameAr}» مستخدم في $count عملية، لذلك لا يمكن حذفه.',
          'Category "${cat.name}" is used by $count operations, so it cannot be deleted.');

  Map<String, dynamic> _categoryRow(SpendingCategory cat, String id, {String? createdAt}) => {
        'id': id,
        ...cat.toJson(),
        'name': cat.name.trim(),
        'name_ar': cat.nameAr.trim(),
        'created_at': createdAt ?? DateTime.now().toIso8601String(),
      };

  /// Adds a category on the device. Returns the new category (with id).
  /// Throws [CategoryException] for empty or duplicate names.
  Future<SpendingCategory> addCategory(SpendingCategory cat) async {
    final cache = _cache;
    if (cache == null) {
      throw const CategoryException('NO_STORAGE', 'التخزين المحلي غير متاح', 'Local storage is unavailable');
    }
    _validateCategory(cat);
    await _ensureUniqueCategory(cat);
    final stored = await _storedCategories();
    final id = 'cat_${_newUuid()}';
    final row = _categoryRow(
        SpendingCategory(
          id: id, name: cat.name, nameAr: cat.nameAr, icon: cat.icon,
          color: cat.color, isActive: cat.isActive,
          sortOrder: stored.isEmpty ? 0 : stored.last.sortOrder + 1,
        ),
        id);
    await cache.upsertItem(_userId, categoryEntityType, id, row);
    return SpendingCategory.fromJson(row);
  }

  /// Edits a category. A derived category (only a transaction name so far)
  /// becomes a stored one. A category used by transactions/recurring rules
  /// must keep the name they reference (renaming would split it).
  Future<SpendingCategory> updateCategory(SpendingCategory cat) async {
    final cache = _cache;
    if (cache == null) {
      throw const CategoryException('NO_STORAGE', 'التخزين المحلي غير متاح', 'Local storage is unavailable');
    }
    _validateCategory(cat);
    final all = await getLocalCategories();
    SpendingCategory? existing;
    for (final c in all) {
      if (c.id == cat.id) {
        existing = c;
        break;
      }
    }
    if (existing == null) {
      throw const CategoryException('NOT_FOUND', 'التصنيف غير موجود', 'Category not found');
    }
    await _ensureUniqueCategory(cat, exceptId: existing.id);
    final used = await categoryUsageCount(existing);
    final keepsName = _catMatches(cat, existing.nameAr) || _catMatches(cat, existing.name);
    if (used > 0 && !keepsName) {
      throw CategoryException(
          'CATEGORY_IN_USE',
          'التصنيف «${existing.nameAr}» مستخدم في $used عملية؛ أبقِ أحد اسميه كما هو.',
          'Category "${existing.name}" is used by $used operations; keep one of its names.');
    }
    final stored = (await _storedCategories()).where((c) => c.id == existing!.id);
    final isStored = stored.isNotEmpty;
    final id = isStored ? existing.id : 'cat_${_newUuid()}';
    String? createdAt;
    if (isStored) {
      final rows = await cache.getCollection(_userId, categoryEntityType);
      for (final r in rows) {
        if ('${r['id']}' == id) createdAt = r['created_at']?.toString();
      }
    }
    final row = _categoryRow(
        SpendingCategory(
          id: id, name: cat.name, nameAr: cat.nameAr, icon: cat.icon,
          color: cat.color, isActive: cat.isActive,
          sortOrder: isStored ? stored.first.sortOrder : existing.sortOrder,
        ),
        id,
        createdAt: createdAt);
    await cache.upsertItem(_userId, categoryEntityType, id, row);
    return SpendingCategory.fromJson(row);
  }

  /// Deletes a category. Blocked (CATEGORY_IN_USE) while transactions or
  /// recurring rules use it — nothing is reassigned silently.
  Future<void> deleteCategory(String id) async {
    final cache = _cache;
    if (cache == null) {
      throw const CategoryException('NO_STORAGE', 'التخزين المحلي غير متاح', 'Local storage is unavailable');
    }
    SpendingCategory? existing;
    for (final c in await getLocalCategories()) {
      if (c.id == id) {
        existing = c;
        break;
      }
    }
    if (existing == null) {
      throw const CategoryException('NOT_FOUND', 'التصنيف غير موجود', 'Category not found');
    }
    final used = await categoryUsageCount(existing);
    final isStored = (await _storedCategories()).any((c) => c.id == id);
    if (used > 0) throw _categoryInUse(existing, used);
    if (!isStored) {
      // Derived from transactions on the server (not yet on this device).
      throw CategoryException('CATEGORY_IN_USE',
          'التصنيف «${existing.nameAr}» مأخوذ من معاملاتك، لذلك لا يمكن حذفه.',
          'Category "${existing.name}" comes from your transactions, so it cannot be deleted.');
    }
    await cache.removeItem(_userId, categoryEntityType, id);
  }
}

/// Typed failure of a category add/edit/delete. [code] is stable for UI and
/// Sara; [messageAr]/[messageEn] are user-facing.
class CategoryException implements Exception {
  final String code;
  final String messageAr;
  final String messageEn;
  const CategoryException(this.code, this.messageAr, this.messageEn);

  @override
  String toString() => messageAr;
}
