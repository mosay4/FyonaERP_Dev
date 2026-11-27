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

## Phase 3 — Backup v2 (implemented)

Code: `lib/core/backup/` (engine, crypto, service, worker, cloud, coordinator,
bridges, providers, presentation). Tests: `test/backup/`. CI job `backup-media`.

* **Capture**: SQL triggers on every data table of the ledger write the row to
  `_bk_changes` inside the user's own transaction (a saved operation is in the
  log at the same instant; a rolled-back one never is). Values are encoded by
  their actual type (text stays text, blobs `{"$b":hex}`) so a trigger can
  never fail a user write. Measured cost: within noise (~2 ms per sale either way).
* **Set** = fuzzy non-blocking snapshot (keyset paging, own connection, background
  isolate) + ordered change parts + encrypted media + wrapped key + `manifest.enc`
  written LAST. A set without its manifest does not exist for restore. New set
  every 7 days / 200 parts; 3 newest kept (device and cloud).
* **Container** `FYBK` v2: 1 MiB ChaCha20-Poly1305 frames; AAD binds file id,
  frame index and "last" flag → flip, truncation, reordering, wrong key all refused.
* **Keys**: random 256-bit key in the platform keystore (`fyona_backup_v2`).
  Wrapped with a 120-bit recovery code (Crockford, shown once) and an optional
  password — Argon2id (19 MiB, t=2) + ChaCha20-Poly1305, off the UI isolate.
  FYONA never sees key, code or password.
* **Cloud**: local set folder mirrored to R2 (`area: b`) by presigned URLs,
  manifest last; offline → device copy continues, cloud catches up.
* **Restore** never swaps the live database. The set is fully verified (every
  part authenticated, row counts + numeric totals of every table, SQLite
  integrity, user_version) into a NEW file, then applied through the app's
  existing, proven restore paths:
  * Personal → rebuilt v4 snapshot → `BackupService.restoreFromBackup` (same
    validation, merge by stable ids, relay to the user's other devices).
  * Business → per-branch archive → `restoreBackup` (empty branch only, marked
    as recovered: cannot publish to the relay until re-approved). Owner only.
  So no accounting, sync, conflict or permission rule changed.
* Additive changes outside `lib/core/backup`: `_requireMainSchema` ignores
  `_bk_*`; `BackupSnapshotBuilder.build` optional sources; `BackupService`
  read-only `boundIdentity` / `cachedHmacKey`; one entry card on each backup page.

Measured (host CPU, test suite): 100 products 0.25 s / 6 KB; 10k 3.7 s / 373 KB;
100k 38 s / 3.6 MB encrypted (background isolate, UI not blocked).
Kill test: 15 rounds, job killed at random moments — every offered set verified.
~~Known limit: Business restore via the v1 archive is bounded by its 64 MB cap.~~ Removed in 3b.

## Phase 3b — Large backups and restores (no size cap, constant memory)

Where 64 MB came from: (1) `businessBackupMaxBytes`, the cap of the v1 branch archive (a user-chosen,
untrusted file), used by the v2 bridge; (2) the v2 set itself kept every part in memory (snapshot
lines → gzip → seal → bytes); (3) the server signs at most 64 MB per backup object.

What changed (format stays FYBK v2; old sets still restore):
* `backup_stream.dart`: container files are written and read one 1 MiB frame at a time
  (`BackupFileWriter`, `BackupStream.frames`); JSONL records are gzip-streamed into chunk files of
  32 MB (`s.fybk`, `s.1.fybk`, … / `d-<from>-<to>.fybk`, … / `m-<sha>.fybk`, …) — resumable per
  chunk and under the server's object cap. Manifest: `snapshot` is a list; `mparts` counts media chunks.
* Engine: the snapshot is streamed to the writer; change parts are paged (`changeLines`); the
  checkpoint transaction (`head`) only reads counts/totals; a run with no new change does no table scan.
  Restore (`restoreStream`) applies records in batches inside ONE transaction of a NEW file.
* Destinations move files (`putFile`/`getFile`, streamed HTTP up/down); small parts (manifest, key,
  extras) are still read whole, capped at 64 MB.
* Media are verified (SHA-256, streamed) into a staging folder and only adopted by the media store
  after the database copy is verified.
* Business bridge: the archive the app makes itself from the verified copy has a 64 GB sanity
  ceiling (`businessBackupRebuildMaxBytes`; SQLite copies pages on disk). The rebuilt copy is
  deleted before the live restore (disk peak ≈ copy + archive). A user-chosen archive file keeps 64 MB.
* Hostile files: frame length ≤ 1 MiB + tag, record ≤ 64 MB, decompressed ≤ 1100 × file size
  (zip bomb stops early), inflate fed in 16 KB slices (bounded memory), every frame authenticated
  before use, gap / missing chunk / hash mismatch abort before anything is visible.
* Leftovers of an interrupted backup run / restore are removed on the next run.
* Unchanged: accounting, sync, branches, permissions — the live step is still the app's own branch
  restore (empty branch only, one transaction, recovery receipt; a second restore is refused).

Evidence: `test/backup/backup_large_restore_test.dart` (opt-in: `FYONA_LARGE_RESTORE=100,500,1000`,
`FYONA_LARGE_KILLS=n`): two branches, real operations, invoice volume, photos/attachments, backup with
live changes, restore on a new device, SHA-256 per table, balances via the app API, every attachment,
SIGKILL during rebuild and during the live commit. CI: manual job `heavy-backup` (100 + 500 MB).

Remaining limit: the Personal v2 restore goes through the v4 snapshot of the v1 restore (built in
memory). Personal ledgers are small (no stock / invoice volume); a streamed Personal apply is a follow-up.

## Phase 4 — Accounting export (Excel / CSV / opening balances at a cut-off day)

* `business_accounting_export.dart` (ledger extension, read-only, owner only): sheets opening_accounts,
  opening_parties, opening_stock, documents, document_lines, payments, returns, bank_movements.
* Every figure is anchored on today's app value; a past cut-off takes back later events (payments,
  returns replayed with the app's rule "balance first, rest refunded", bank legs, stock movements).
  Documents edited / deleted / cancelled after the cut-off are listed as warnings (today's figures kept).
* `accounting_export_writer.dart`: CSV (UTF-8 BOM, RFC 4180) + XLSX (hand-built SpreadsheetML,
  inline strings, RTL for Arabic, frozen header, 1,048,575 rows per sheet then a continuation sheet),
  formula-injection guard, product photos, manifest.json (rows, SHA-256 per file, control totals,
  warnings, definitions). Streamed to disk; ZIP built in a background isolate.
* UI: "تصدير محاسبي" card on the Business backup screen (owner, device ledger), cut-off date, photos.
* Tests (`test/export`): today = the app's own party balances / account balance / stock; past
  cut-off exact (later payment, return, sale taken back); branch isolation; SHA-256 of every file;
  formula neutralised; XML well-formed, sheet rows = CSV rows; AR + EN; employee refused;
  100 000 invoices streamed (time + memory measured).

## Phase 3c — Restore from a file on the phone, free space, percentage

* **Whole continuous set as ONE file** (`.fyonaset`, `backup_pack.dart`): `FYBKPACK1`, a JSON header
  (names + sizes), then the set's own encrypted parts unchanged. "Save as a file" on each local set
  (Android: Downloads/FYONA ERP, copied natively in 1 MiB blocks; iOS: share sheet; desktop: save dialog)
  and "Restore from a file on this device" on the continuous backup page.
  Reading is untrusted until proven: only the header + `key.json` + `manifest.enc` (≤ 64 MB together)
  are read, then the manifest must open with this device's key or the recovery code/password; after that
  exactly the parts that manifest lists are accepted (any other name, `..`, trailing data: refused) and
  the rest may be as large as the backup (64 GB ceiling). Then the normal verified rebuild + apply.
* **Branch file `.fyonabiz`**: no 64 MB cap for a genuine file. The picked file is untrusted until its
  first page opens with the recovery code (`checkBackupHead`: SQLCipher authenticates the page) — at
  most 1 MiB is read before that, so a wrong file/code is refused at once whatever its size; anything that
  never proves itself still stops at 64 MB. Creating one is no longer capped at 64 MB either; saving it
  streams (never `readAsBytes`).
* **Free space** (`lib/core/storage/free_space.dart`: Android StatFs, iOS volumeAvailableCapacity…,
  Windows GetDiskFreeSpaceEx, Linux/macOS `df`): checked before copying a file (2× its size + 128 MB for a
  branch file), before the rebuild (media + 4× records + 128 MB), before the live apply (copy size +
  128 MB); during the rebuild a monitor stops the job cleanly (`no_space`) if the disk nearly fills.
  The message says how many MB to free. Nothing is changed on refusal.
* **Percentage**: download / reading / media / records / preparing / applying, each 0–100 %; the live
  branch restore copies in slices of 20 000 rows (same order, still ONE transaction) so it reports too.

## Phase 5 — Chat media → Cloudflare R2 (encrypted on the device)

* The sender encrypts each attachment with a fresh random 256-bit key (FYBK frames) and uploads the
  ciphertext with a presigned URL to `t/c_<link>/m/<sha256 of ciphertext>` (participants only).
  The message carries `fyc:<link>/<sha>.<ext>#<key>`; the receiver downloads, checks SHA-256, decrypts,
  keeps the file. Cloudflare only ever holds ciphertext. Background (WorkManager) uploads use the same path.
* Server: `/chat/{link}/media` (disk) retired → 410 `chat_media_moved`; when the server purges a
  message (read + 10 min, or 90 days) its R2 objects are deleted too (only `fyc:` refs of that chat).
* Older `uploads/chat/…` links still download as before. Video thumbnails are no longer made by the
  server (it never sees the file): the bubble shows the generic video tile until the file is on the device.

## Phase 6 — Smart import (deterministic engine + Sara column suggestions)

* `lib/core/import/`: readers (CSV/TSV UTF-8/UTF-16, XLSX, JSON, XML, SQLite read-only, SQL INSERT,
  ZIP of those) with hard limits: own ZIP reader inflating with an output cap (bombs and lying headers
  stop at the limit), ≤ 2000 entries, no nested archives, entry names never used as paths, XML DTD
  entities refused, unknown text encodings refused with a clear message.
* Mapping: deterministic titles (Arabic/English, spelling folded) first; "Ask Sara" sends only the
  titles + ≤ 30 sample rows (values ≤ 60 chars) to `/ai/import-mapping`, which keeps only known fields
  mapped to existing columns. Sara never touches numbers or rows.
* Review window (owner's decision 27-11): its own full-screen window (also opened by Sara via
  `/data-import/smart-import`). Steps: file → tables & columns → review → fingerprint / app PIN → import.
  * Each table of the file gets a destination: customers, suppliers, products, or "not imported"
    (no place in FYONA: nothing from it is saved).
  * Columns: drag a column chip onto a field (dropping on a taken field swaps them), or the swap menu;
    columns with no field are listed in red/yellow as "not saved". Sara can suggest the mapping.
  * Review in two parts — "will be added" and "will not be added" (red rows, yellow reason per row,
    reason filters with counts, skipped tables and columns listed). Any cell can be edited; the whole
    table is checked again (same rules as the import). Search, select all shown, leave out / put back.
    Rows are built lazily (fixed-height list): 100 000 rows load in ~3.7 s, an edit re-checks in ~1 s.
  * Products: name, barcode, code, unit, sale/purchase price, quantity, category (found by name or
    created once), picture (a file inside the same ZIP, verified to be an image; missing → added
    without it, said so), branch (a row for another branch is refused). Customers/suppliers: name,
    type, phone, balance or two "they owe / we owe" columns, currency, branch.
  * Only accepted rows are written. No archive: data with no place in FYONA is never stored.
* Undo by batch only while nothing happened to what it created (`importLaterActivity`: payments, other
  documents, edits, invoices, stock moves) — through `deleteUnlinkedParty` / `deleteProduct`.
* The batch registry (for undo and the double-import check) is a separate encrypted file
  `imports/<workspace>.sqlite` (same key); the imported cards/debts/products are in the ledger (backed up).
* Not in this version: bank/cash account balances (the ledger has no safe undo for an account yet —
  entered by hand) and old invoices as documents (refused as "no place", not stored).


## 27-11 (evening) — Owner's brief: backups without codes, redesign, smart import for the whole database

* **Key management (owner's decision):** every backup — device file or cloud, Personal or Business —
  is encrypted on the device with the ACCOUNT key. The server derives it (HMAC-SHA256) from
  `FYONA_BACKUP_MASTER_KEY`, kept in the server's private secret file (`backup-master-key`, 600) —
  never in the database, never next to the backups. Endpoints: `GET /backups/account-key` (the user),
  `GET /business-storage/account-key` (business owner only). A new device gets it after sign-in; the app
  asks the fingerprint / app PIN before any restore. No recovery code. Cached in the keystore → offline backups.
  Risk stated to the owner: someone holding BOTH the server secret and the stored backups could read them.
* Personal "FYONA server" backups: the device encrypts, the server stores the ciphertext in Cloudflare R2
  (`t/u_<user>/b/personal-v1/…`), not on its disk; older plain versions are re-uploaded encrypted by the app
  and the plain copy deleted. Device files: encrypted envelope (older plain files still read).
* Continuous backup: the set key is also wrapped by the account key; older sets keep their recovery code.
  A branch file's (.fyonabiz) SQLCipher code derives from the business key.
* Business backup screen redesigned (one button: device + FYONA cloud; restore from the device's FYONA folder or
  from FYONA cloud, numbered 1..N, newest highest, date/time/size). Personal keeps its design; its restore shows
  the same numbered lists. Motion for restores and the smart import (real progress, check only after the
  verified result, original soft sounds, mute). "Backup and sync" → "Backup" (sync stays automatic).
* Smart import for the whole database: tables classified (products, units, barcodes, pictures incl. SQLite BLOBs,
  categories, customers, suppliers, accounts; past invoices/vouchers refused — already in today's balances;
  employees/settings/assets: no place), links verified by value matching, own row numbers never taken as links;
  Sara (DeepSeek, live-tested) only for tables the rules leave unclear, every answer re-checked.
  Test: a 12-table legacy POS database with 5 500 products → 5 445 imported with 2 722 units, 1 375 barcodes,
  785 pictures, 40 categories; 1 188 customers, 150 suppliers, 5 accounts; totals exact; another branch untouched;
  same file again refused.
* Speed: rebuild target (scratch, verified at the end) without per-commit sync; cloud parts fetched 3 at a time;
  import analysis reads each column once.
