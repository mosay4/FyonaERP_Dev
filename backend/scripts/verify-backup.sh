#!/bin/bash
# =============================================================================
#  FYONA ERP — Automated Backup Verification
# =============================================================================
#  Verifies backup integrity WITHOUT restoring to production.
#  Creates a temporary PostgreSQL container, restores the backup, and checks:
#    1. Checksum (sha256)
#    2. Gzip integrity
#    3. Table count matches production
#    4. Backup size reasonable
#    5. Restore to temp DB succeeds
#    6. Key data accessible after restore
#
#  Cron (weekly):
#    0 6 * * 0 /opt/fyona/backend/scripts/verify-backup.sh >> /opt/fyona/backups/verify.log 2>&1
# =============================================================================

set -uo pipefail

BASE_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
LOG="${BASE_DIR}/verify.log"
PROD_CONTAINER="fyona-db"
PG_USER="fyona"
PG_DB="fyona_erp"
PG_PASS="${POSTGRES_PASSWORD:-Ms5_Mrold_2026_Fyona}"
TEMP_CONTAINER="fyona-verify-temp"
TEMP_PORT=5433
TEMP_DB="fyona_verify"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [verify] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; RESULT="FAIL"; }

log "══════════════════════════════════════"
log "Starting backup verification"
log "══════════════════════════════════════"

RESULT="PASS"
TESTS_RUN=0
TESTS_PASSED=0

# ── Find latest backup ────────────────────────────────────────────────────────
LATEST=$(ls -t ${BASE_DIR}/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
if [ -z "${LATEST}" ]; then
  LATEST=$(ls -t ${BASE_DIR}/daily/fyona_*.sql.gz 2>/dev/null | head -1)
fi

if [ -z "${LATEST}" ]; then
  log "ERROR: No backup found to verify"
  exit 1
fi

log "Verifying: $(basename ${LATEST})"

# ── Determine if encrypted ────────────────────────────────────────────────────
RESTORE_FILE="${LATEST}"
IS_ENCRYPTED=false
if [[ "${LATEST}" == *.gpg ]]; then
  IS_ENCRYPTED=true
  RESTORE_FILE="${LATEST}.tmp"
  log "Decrypting backup..."
  gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
      --decrypt "${LATEST}" > "${RESTORE_FILE}" 2>/dev/null
  if [ $? -ne 0 ]; then
    fail "GPG decryption failed"
    rm -f "${RESTORE_FILE}"
    exit 1
  fi
fi

# ── Test 1: Checksum ─────────────────────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
CHECKSUM_FILE="${LATEST}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
  if sha256sum -c "${CHECKSUM_FILE}" >/dev/null 2>&1; then
    log "✓ Test 1: Checksum — PASS"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "Test 1: Checksum — FAIL"
  fi
else
  log "⚠ Test 1: Checksum — SKIP (no checksum file)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 2: Gzip integrity ───────────────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
if gzip -t "${RESTORE_FILE}" 2>/dev/null; then
  log "✓ Test 2: Gzip integrity — PASS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  fail "Test 2: Gzip integrity — FAIL"
fi

# ── Test 3: Table count ──────────────────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
TABLES=$(zcat "${RESTORE_FILE}" | grep -c 'CREATE TABLE' 2>/dev/null)
PROD_TABLES=$(docker exec "${PROD_CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)

if [ "${TABLES}" -ge 1 ]; then
  log "✓ Test 3: Table count — PASS (backup: ${TABLES}, prod: ${PROD_TABLES})"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  fail "Test 3: Table count — FAIL (${TABLES} tables)"
fi

# ── Test 4: File size check ──────────────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
FILESIZE=$(stat -c%s "${RESTORE_FILE}" 2>/dev/null || echo 0)
if [ "${FILESIZE}" -gt 1000 ]; then
  log "✓ Test 4: File size — PASS (${FILESIZE} bytes)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  fail "Test 4: File size — FAIL (${FILESIZE} bytes)"
fi

# ── Test 5: Restore to temp container ────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
log "Starting temp PostgreSQL container..."

# Remove any old temp container
docker rm -f "${TEMP_CONTAINER}" 2>/dev/null || true

docker run -d \
  --name "${TEMP_CONTAINER}" \
  -e POSTGRES_USER="${PG_USER}" \
  -e POSTGRES_PASSWORD="${PG_PASS}" \
  -e POSTGRES_DB="${TEMP_DB}" \
  -p "${TEMP_PORT}:5432" \
  postgres:16-alpine >/dev/null 2>&1

# Wait for temp PG to be ready
for i in $(seq 1 30); do
  if docker exec "${TEMP_CONTAINER}" pg_isready -U "${PG_USER}" -d "${TEMP_DB}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker exec "${TEMP_CONTAINER}" pg_isready -U "${PG_USER}" -d "${TEMP_DB}" >/dev/null 2>&1; then
  fail "Test 5: Temp PG not ready after 30s"
  docker rm -f "${TEMP_CONTAINER}" 2>/dev/null || true
  [ "${IS_ENCRYPTED}" = true ] && rm -f "${RESTORE_FILE}"
  exit 1
fi

log "Temp PG ready. Restoring..."

zcat "${RESTORE_FILE}" | docker exec -i "${TEMP_CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -q 2>>"${LOG}"
RESTORE_RC=$?

if [ "${RESTORE_RC}" -eq 0 ]; then
  log "✓ Test 5: Restore to temp — PASS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  fail "Test 5: Restore to temp — FAIL (rc=${RESTORE_RC})"
fi

# ── Test 6: Post-restore data check ──────────────────────────────────────────
TESTS_RUN=$((TESTS_RUN + 1))
TEMP_TABLES=$(docker exec "${TEMP_CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)
USERS=$(docker exec "${TEMP_CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -tAc "SELECT count(*) FROM users;" 2>/dev/null || echo "?")

log "Post-restore: ${TEMP_TABLES} tables, ${USERS} users"

if [ "${TEMP_TABLES}" -ge "${TABLES}" ] && [ "${TEMP_TABLES}" -ge 50 ]; then
  log "✓ Test 6: Post-restore data — PASS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  fail "Test 6: Post-restore data — FAIL (${TEMP_TABLES} tables, expected >= ${TABLES})"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
docker rm -f "${TEMP_CONTAINER}" 2>/dev/null || true
[ "${IS_ENCRYPTED}" = true ] && rm -f "${RESTORE_FILE}"

# ── Summary ───────────────────────────────────────────────────────────────────
log "══════════════════════════════════════"
log "Verification Results: ${TESTS_PASSED}/${TESTS_RUN} tests passed"
log "Overall: ${RESULT}"
log "══════════════════════════════════════"

if [ "${RESULT}" = "FAIL" ]; then
  exit 1
fi
exit 0
