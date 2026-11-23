# Business sync engine (local-first, relay-only server)

Owner decisions (2026-11-23): relay retention 90 days; no extra end-to-end
encryption; backups out of scope (owner will extend the existing manual backup
later); conflicts only when two operations cannot both hold (e.g. the same
remaining cash or the same remaining stock quantity) — the operation that
reaches the server first wins, the other is cancelled and its author gets a
system notification naming who did it first.

## Principles

1. Every Business write commits locally first and shows the existing success
   text. Nothing waits for the network. No text distinguishes online/offline.
2. The server never stores Business state. It is a mailbox + sequencer:
   it stamps each operation with a per-organization sequence number on arrival,
   keeps it until every destination device acknowledged it (max 90 days), then
   deletes it.
3. Every device applies the same operations in the same sequence order with the
   same deterministic rules, so all devices converge to identical state and
   reach identical conflict decisions without the server knowing balances.

## Client

### Capture (generic, no per-button rewrite)
- `DirectoryDatabase._transaction` is the single write path. Replicated tables
  get SQLite triggers (generated from `PRAGMA table_info`) that record every
  INSERT/UPDATE/DELETE row image into `business_sync_changes` together with the
  operation id held in the temp table `business_sync_context`.
- After the transaction body, the captured changes become one operation in
  `business_sync_outbox` (same SQLite transaction → atomic with the write).
- While applying a remote operation the context is marked `remote`, so triggers
  do not re-capture it.

### Operation
`{id, organization, branch, author_user, author_session, author_name, kind,
schema, client_us, changes:[{table, pk, op:'upsert'|'delete', row}]}`

### Apply
- Pull returns operations for this session in sequence order. Own operations
  are recognised by id (recorded in `business_sync_log`) and only acknowledged.
- Remote changes are applied row by row (upsert/delete) under row-level
  last-writer-wins by sequence: a row keeps `last_seq`; a remote change older
  than a pending local change of the same row is skipped.
- Derived columns are never trusted from the wire. After each batch the engine
  recomputes them for the touched entities (account balances and running
  balances from legs; debt `paid_minor` from payment parts; later phases add
  stock and lots).

### Conflicts
- Only sequenced operations up to `confirmed_through` (the sequence up to which
  this session's inbox is drained) are judged, so every device judges the same
  set. Pending local operations stay applied optimistically.
- A resource rule replays the resource's facts in sequence order; the first
  operation that breaks the invariant (and every later one that still breaks
  it) is rejected: its row changes are reverted from the captured before-images,
  dependants are rejected with it, derived values are recomputed, and if the
  author is this device a system notification is stored.
- Phase 1 rule: a debt cannot be paid beyond its total.
  Phase 2: cash/bank cannot go negative unless the branch allows it.
  Phase 3: stock cannot go below zero (same remaining quantity sold twice).

### New / long-absent device
- A session with no cursor, or whose pending deliveries were purged after 90
  days, receives `resync_required`. It first pushes its own outbox, then asks
  the relay for a snapshot; another live device of the organization uploads a
  snapshot operation (all replicated rows of the permitted branches + the
  sequence it reflects) addressed to that session only.

## Server (`backend/app/domain/services/business_relay.py`)
- `business_relay_heads(organization_id, last_seq)` – per-org sequencer.
- `business_relay_ops(id, organization_id, branch_id, seq, actor_user_id,
  actor_session_id, kind, payload, created_us)` – payload is opaque JSON.
- `business_relay_inbox(op_id, session_id)` – one row per destination.
- `business_relay_sessions(session_id, organization_id, cursor_seq,
  resync_required, last_seen_us)`.
- `push` is idempotent by operation id; `pull` returns inbox rows in sequence
  order plus `head`; `ack` deletes inbox rows and purges operations with no
  destination left; a periodic purge drops operations older than 90 days and
  flags their pending sessions `resync_required`.
- Destinations: every active session of the organization's users and active
  branch members, except the author session.

## Phases
1. Engine + relay + parties, debt groups, debts, payments, bank accounts and
   legs (payments post to accounts) + debt over-payment rule + snapshot.
2. Cash/banks/expenses/reconciliation rules (replaces cash relay v3 arbiter).
3. Inventory, invoices, purchases, returns, stock rule.
4. Employees (local ledger for employees, permissions as operations).
5. Branches, inter-branch transfers, reports, all-branches view.
6. Merchant links, chat, attachments, cross-party notifications.
7. UX unification (forbidden texts, no loading, single code path).
8. Launch (remove QA flags, migrate existing server data to devices).
