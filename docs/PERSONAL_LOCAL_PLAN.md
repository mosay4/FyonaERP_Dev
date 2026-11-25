# Personal → device-only (server = relay) — plan (2026-11-25)

Owner rule: ALL Personal user data lives only on the user's devices (encrypted). The server only relays changes between the same user's devices and deletes them once every destination acknowledged. Same policy as Business.

## Findings
- Personal mirror `personal_entity_cache` is in plain sqflite `fyona_erp.db` (lib/core/database/tables.dart:615, database_helper.dart). Trees (financial_tree_storage.dart) and account types (account_type_store.dart) are in SharedPreferences. Only Business uses SQLCipher (directory_database.dart:100-140).
- Server tables (backend/app/domain/entities/personal_entities.py): bank_accounts, transactions, savings_goals, debts, debt_payments, budgets, budget_categories, recurring_transactions; + sync_batches/sync_logs entries (personal_sync.py:99).
- Write path: screen → personal_providers → PersonalFinanceService → PersonalCacheRepository.commitOfflineWrite/commitMirrorOnly/commitTransferAtomic (personal_cache_repository.dart:552,678,713) → outbox → SyncEngine._replay (sync_engine.dart:439-700) → REST /personal/finance/* ; pull via /sync/pull.
- Server-only reads in client: budget aggregation (service ~2070), debt payments (~1665), categories (~2502), ensureCashAccounts (~706), resetAccount (~1993), restore (backup_service.dart:1812).
- Server consumers: Sara SaraContextBuilder (sara_agent_service.py:1131-1398), server ToolExecutor reads (2171-3060), prepare_personal_banking (3125), sara_analytics.build_financial_analytics (206-360); workers tasks.py:383 (_check_low_balance), 469 (_check_budget_alerts); admin_personal.py:152-622; /personal/finance/reset (3027), restore (3365); backups.py (plaintext JSON snapshot).

## Stages
1. Encrypted Personal ledger (SQLCipher, per user, same key-store pattern as directory_database) behind the existing PersonalCacheRepository API; one-time move from plain cache + prefs (trees, account types, rates); copy → verify → wipe plain rows.
2. Backend personal relay: backend/app/domain/services/personal_relay.py + api/v1/personal_relay.py, modelled on business_relay.py (per-user seq, inbox per other replica, delete on ack keeping id/seq tombstone, RETENTION 90d + resync_required, snapshot request/serve/applied, retire, replicas). Separate tables personal_relay_*. Auth get_current_user_uuid. Opaque payloads.
3. Client relay runtime: each commit* mutation set = one op (same transaction) into ledger outbox; push/pull loop (10 s, reconnect, resume); apply in seq order; idempotent op_id; counters as deltas; other fields last-writer-by-seq; tombstones win; new device → snapshot request, else local backup restore. Behind a flag; old server sync stays parallel until cutover.
4. Make server-only reads local (aggregation, debt payments, categories, ensureCashAccounts, reset, restore).
5. Sara Personal device loop (generalize BusinessDeviceLoop; server returns device_calls for personal read tools when header x-fyona-device-sara + local mode; /ai/continue); port analytics to Dart (personal_analytics.dart) with parity tests.
6. Cutover: personal_local_mode.py flag, personal_local_migration.py (status/export stable bytes + digest/ack/purge children-first incl. sync logs), client drain old outbox → import baseline → verify → ack → purge; personal_local_guard.py refusing personal writes for local users; min app version gate; admin_personal counts only/410; workers skip local users.
7. QA soak then purge.

Owner decision (2026-11-25): leave backups (server and local, Business and Personal) untouched for now; the owner will give a full backup design after the sync/architecture work. Do not change backups.py or backup_service behaviour beyond keeping restore working with the new ledger.

## Stage 2 done — relay API (prefix /api/v1/personal-relay, Bearer JWT, extra fields forbidden, responses {success,message,data})
Limits: MAX_PAYLOAD 16 MiB/op, MAX_SNAPSHOT 48 MiB, MAX_BATCH 200, RETENTION 90 d. Payload = base64 string (ciphertext) or JSON; pull always returns base64.
- POST /register {replica_id} → {replica_id, resync_required, head}. First replica false; later new/rejoined replicas true.
- POST /push {replica_id, items:[{id: uuid, kind:"ops", payload}]} → {items:[{id, seq}]}. Retry returns original seq (tombstone). Lone device: payload dropped, tombstone kept.
- POST /pull {replica_id, wait?0-25, limit?1-200} → {items:[{id, seq|null, kind, replica_id(author), payload b64}], drained, head, resync_required}. Control items first, then ops by seq; never own ops.
- POST /ack {replica_id, ids} → {purged}. Last ack deletes payload (id/seq tombstone stays).
- POST /snapshot/request {replica_id} → {requested, resync_required}; other live replicas get kind "snapshot_request" payload {"replica_id": requester}. None live → resync cleared, requested=false.
- POST /snapshot/serve {replica_id, target, payload} → {sent}; only to a waiting replica; one pending per target; target receives kind "snapshot", seq null.
- POST /snapshot/applied {replica_id} → {} (deletes snapshot blob + requests, clears resync).
- POST /retire {replica_id} → {}; kicked sessions auto-retire.
- GET /replicas → counts/metadata only.
Client must: put last applied seq inside snapshot blob; receiver skips ops ≤ that seq; if resync stays true, request snapshot or offer local backup restore.
Files: backend/app/domain/services/personal_relay.py, api/v1/personal_relay.py, tests/unit/test_personal_relay.py; hourly purge task purge_personal_relay.
