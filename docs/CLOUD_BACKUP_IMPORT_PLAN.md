# FYONA — Backup v2, Cloudflare storage, Smart import (execution plan)

Owner order: 26-11-2026 (execution, not study). Study: ../verification/claude-phase24/FYONA-engineering-study.md
Rollback point: tag `stable-r23-2026-11-26`, branch `backup/stable-r23-2026-11-26`,
offline copy `/root/fyona-rollback/stable-r23-2026-11-26` (verified restore: see ROLLBACK.md there).
Test data is disposable (owner): no migration of old test images/backups.

## Cloudflare (verified 26-11-2026)
- Account `565ff3f4…`, bucket `fyona-storage` (public r2.dev access: disabled).
- Secrets ONLY in `/var/lib/private/fyona-directory-qa-enroll/run/cloudflare.env` (nobody:nogroup 600):
  CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (the owner's paste had 76 chars; the
  real key is the first 64 — verified put/get/delete), R2_BUCKET, CLOUDFLARE_R2_TOKEN (valid, no bucket
  admin), CLOUDFLARE_WORKERS_TOKEN (valid user token; can manage Workers and read/write R2 bucket settings).
- Never in Flutter, GitHub, logs. Devices only ever get short-lived presigned URLs from the FYONA server.

## Decisions
1. **Server stays the authority**: auth, permissions, ordering (sequencer), conflicts, dedupe, devices.
   Cloudflare = bytes only (R2). No Workers/DO/Queues/D1 needed for v1 (no logic moves there).
2. **Sync payloads stay on the server** (decision, not deferred risk): once images leave the ledger,
   ops are small JSON; moving them to R2 adds 2+ requests per op (cost + latency) and splits the atomic
   sequencer write. Revisit only with measured payload sizes. Sequencer/inbox/90-day retention unchanged.
3. **Media layer** (shared by sync, chat, backup, import): content-addressed files.
   - Device: `<app support>/media/<aa>/<sha256>`; DB stores `media:<sha256>` (+ `media_files` index: sha, size, mime, state).
   - R2 keys (tenant-isolated, unguessable path + signed access only):
     `t/<tenant>/m/<sha256>` where tenant = `o_<orgId>` (Business) | `u_<userId>` (Personal) | `c_<linkId>` (chat).
   - Server endpoints: presign upload (PUT, 10 min, size+sha bound via signed headers), commit (HEAD verify),
     presign download (GET, 5 min) — each checks the caller's access to the tenant (branch permission for Business).
   - Dedupe only within a tenant (isolation > storage). Images keep quality (max 2048 px, JPEG q90 / PNG kept).
4. **Backup v2** (Personal + Business, one engine):
   - Change capture: SQLite triggers on every data table write `_bk_changes(seq, tbl, op, rowid, row_json)` in the
     SAME transaction as the user's write → durable the moment the operation is saved.
   - Versions = full snapshot (consistent read tx at change seq S) + delta segments (changes > S), JSONL → gzip →
     ChaCha20-Poly1305 in 1 MiB frames. Media copied into the backup namespace (encrypted, content-addressed).
   - Destinations: device folder and/or R2 `b/<tenant>/<backupId>/…` (separate from media/chat).
   - Background: debounced flush after writes + on pause/resume + Android WorkManager / iOS background URLSession
     for uploads; a "last good backup" health line + warning after 7 days without success.
   - Keys: random 256-bit backup key in Keystore/Keychain; recovery = 24-char recovery code (shown once) and/or
     user password (Argon2id) wrapping the key; wrapped key stored with the backup. Server never sees the key.
   - Restore: verify manifest + every frame MAC + media hashes + row counts/balances BEFORE touching live data;
     restore into a fresh database, then swap; device re-registers as a NEW replica (no replay of old ops);
     employee grants re-validated online; older-than-live backups need explicit owner confirmation.
5. **Accounting export** (separate from backup): ZIP with CSV (UTF-8 BOM) + XLSX + images + manifest/README;
   "balances only" = opening balances at a cut-off date with a check row.
6. **Smart import**: deterministic on-device engine (CSV/XLSX/JSON/XML/SQLite/SQL-INSERT/ZIP); Sara (DeepSeek)
   only maps columns from a ≤30-row sample; preview → user approval → one import batch id; opening balances +
   read-only archive for history; undo by batch. PDF: text tables only when reliably extractable (else refused clearly).

## Phases (each = tests + commit + Telegram report)
0. Rollback point — DONE 26-11 (verified).
1. Cloudflare connectivity + server R2 client + presign/commit endpoints + real R2 integration tests.
2. Media layer on device (store, uploader with resume, cache, product/unit images as refs).
3. Backup v2 engine (capture, snapshot, segments, crypto, local + R2, restore, verification) + UI.
4. Accounting export + UI.
5. Chat media → R2 (server disk no longer holds chat files).
6. Smart import engine + Sara column mapping + UI.
7. CI (new suites), load/size measurements, APK, final report.
