# Stage 2 chat behavior and limits

- Active-chat presence is authenticated against the accepted MerchantLink. A
  Redis key scoped to merchant organization and recipient stores the link ID
  for 30 seconds. The chat sends a 12-second heartbeat and clears on lifecycle
  background, route cover, or disposal. Late clears compare the link ID
  atomically. App-wide online heartbeats do not extend active-chat presence.
  Redis failure defaults to notifications rather than losing them. Heartbeats
  and sends racing with navigation can still produce one notification.
- Fresh matching presence suppresses both the notification outbox event and
  mobile push; inactive, other-chat, killed-app and stale recipients keep the
  existing notification path. Duplicate client IDs do not emit another event.
- Local generated mono PCM cues are 90 ms sent / 130 ms received. They use
  separate low-latency audioplayers, Android notification audio usage and iOS
  ambient audio (best-effort respect for system silent/DND). Sent cues follow
  acceptance, received cues follow the first live bubble render, not history,
  pagination or refresh. Background-upload completion only sounds when this
  chat is visible. Physical-device silent-mode and audio latency validation
  remains necessary; automated tests exercise trigger decisions, not speakers.
- Initial/latest and older pages default to 40, hard maximum 100. Both cursors
  validate conversation membership; timestamp + UUID ordering handles ties.
  The server fetches at most limit+1 rows. No total-history count is required.
- The client keeps a sliding 500-message window, builder-based reversed list,
  bounded text outbox (50), and pruned widget/voice-cache indexes. Older history
  can continue beyond the window; a down-arrow returns to latest after newer
  messages are trimmed. Live polling pauses in that older-history window.
  Polling is non-overlapping every 3 seconds only while visible, with peer /
  recent receipt refresh every 12 seconds. There is no WebSocket infrastructure
  assumption. Media-progress rebuilding is confined to the message list.
- Text sends clear the composer immediately. Text and invoice sends have independent pending/failure
  rows, reuse one client ID, retry transient failures twice at 0.5/1 seconds,
  and expose red manual retry / long-press dismissal. Accepted polling echoes
  remove the pending row. Server uniqueness conflicts recover the accepted
  message inside a savepoint without duplicate notification.
- Image/video/voice/file and album uploads retain one optimistic item and one
  client ID across automatic and explicit retries. Three concurrent uploads,
  50 retained jobs and 32 MiB of retained media bytes bound the foreground
  queue; full queues reject new items with a visible warning. Successful
  uploads are cached across send retries (album prefixes are checkpointed in
  memory), avoiding repeated uploads. Two transient retries use 0.5/1-second
  backoff; terminal failures remain red with explicit retry/dismiss controls.
  Polling echoes acknowledge/remove pending jobs and stop additional retries.
- A five-second foreground lease covers queued and active jobs, including
  quiet network waits. Terminal failures are persisted as paused jobs so the
  background worker cannot silently continue retrying them. Explicit retry
  resumes the same job/client ID. WorkManager's own send attempts are bounded
  to three and permanent HTTP failures stop immediately. Process-death takeover
  still depends on Android WorkManager scheduling and needs device validation.

## Residual risks / operational follow-up

This does not establish million-user capacity. PostgreSQL/Redis concurrency,
FCM killed-app delivery, multi-device navigation, media-worker retry ownership,
and sustained burst/latency/load testing still require a staging environment.
Isolated PostgreSQL runtime tests exercise existing chat behavior but do not
replace concurrent unique-conflict/load testing. Failed foreground rows are
in-memory UI state; restoring those red rows after a process restart and a
retention/cleanup policy for persisted failed media require follow-up. Pending
persisted jobs still support the existing background takeover behavior.
The existing media disk cache lifetime is unchanged (not a new RAM history cache).
Production schema/service changes were not run. Evaluate a composite
`chat_messages(link_id, created_at, id)` index using EXPLAIN under real load.
The current separate link/time indexes remain supported.

## Initial implementation verification artifact (superseded by continuation build)

- `PYTHONPATH=. venv/bin/python -m unittest tests.test_chat_stage2 -q`
  from `backend`: exit 0, 3 isolated acceptance tests.
- `flutter test --no-pub test/chat_page_test.dart test/chat_timeline_test.dart
  --reporter expanded`: exit 0, 4 tests, including a 5,000-message fake server,
  bounded initial pagination, lazy rendering, retry-key reuse and sound gating.
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`: exit 0,
  zero errors; 4,070 warnings/info diagnostics remain across the workspace.
  Strict default analysis is not clean (warnings/info are not suppressed from
  the diagnostic stream, only made nonfatal).
- Hardened `/home/abdulrhman2/fyona-erp-build.sh`: exit 0, built as
  `abdulrhman2` only after the above tests and zero-error analysis.
- Fresh, ZIP-integrity-checked artifact:
  `build/app/outputs/flutter-apk/app-release.apk`, 31,801,269 bytes.
- SHA-256:
  `b250d379a044f7ea7f6b0971a528c11150a2698d4b4a392785fc23d41606bb6f`.
- No Telegram command, deployment, production migration or service restart.

The continuation completes invoice/media foreground failure/retry UX and adds
unit/widget coverage for retry success, optimistic dedupe, bounded burst
concurrency and worker terminal-state guards. Device/staging validation and
infrastructure load testing remain necessary before claiming production-scale
notification/audio guarantees. See the continuation verification below for
the current artifact rather than the superseded SHA above.

## Continuation verification (2026-10-26, current APK)

- `PYTHONPATH=. venv/bin/python -m unittest tests.test_chat_stage2 -q`:
  exit 0, 3 Stage 2 acceptance tests.
- Existing runtime tests were executed unchanged via
  `DATABASE_URL="postgresql+asyncpg:///fyona_chat_test?host=/tmp/fyona-chat-pg.0uKyHQ&port=55439" PYTHONPATH=. venv/bin/python tests/run_chat_runtime_isolated.py`:
  exit 0; chat runtime 14/14, edit/delete/direction 8/8, album 4/4 checks.
  The harness rejects non-test databases and loads notification/HR/branch
  metadata before creating the disposable PostgreSQL schema. The temporary
  cluster listened on its private Unix socket only and was stopped afterward.
  No production database or service was changed. Initial harness missing-model
  errors were corrected before the successful run.
- `flutter test --no-pub test/chat_page_test.dart test/chat_timeline_test.dart test/chat_upload_manager_test.dart test/chat_background_upload_test.dart --reporter expanded`:
  exit 0, all 16 relevant chat unit/widget tests passed. Includes invoice/file
  red-row retry UI against 5,000-message history; every media kind and albums;
  stable IDs and cached uploads; duplicate retry/echo guards; a 1,000-enqueue
  burst capped at 50 pending / three concurrent; and worker terminal guards.
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`:
  exit 0, **0 errors**; 4,079 warning/info diagnostics remain workspace-wide.
  Default strict analysis is not claimed clean.
- Only after those checks:
  `bash /home/abdulrhman2/fyona-erp-build.sh`: exit 0, release ARM64 build
  as `abdulrhman2`. Start epoch 1793005321; fresh APK mtime
  `2026-10-26 09:06:39.207513972 +0000`, later than its dedicated build marker.
- `unzip -tq build/app/outputs/flutter-apk/app-release.apk`: exit 0.
- `/opt/sdk/android/build-tools/36.0.0/apksigner verify --verbose build/app/outputs/flutter-apk/app-release.apk`:
  exit 0, APK signature scheme v2 verified, one signer.
- Current APK: `build/app/outputs/flutter-apk/app-release.apk`.
- Size: **31,806,069 bytes**.
- SHA-256: `802261b7544905c53f4c9ba3b79a22b30da1fec5fa20af63d99e2391dfaabe27`.
- No Telegram send was attempted. Residual risks are the device, process-death,
  failed-row restoration/media retention and infrastructure/load follow-ups
  above, not a claim of million-user capacity.
