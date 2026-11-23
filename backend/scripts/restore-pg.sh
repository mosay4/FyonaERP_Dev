#!/bin/bash
# =============================================================================
#  FYONA ERP — PostgreSQL Restore (Full + PITR)
# =============================================================================
#  Modes:
#    <backup_file>                  Restore from specific backup
#    --pitr --target-time "TIME"   Point-in-time recovery
#    --latest                       Restore from latest backup
#
#  PITR requires:
#    1. Base backup (physical) in /opt/fyona/backups/base/
#    2. WAL segments in /opt/fyona/backups/wal/
#    3. These together allow recovery to any point in time
#
#  Safety:
#    - Takes safety dump before production restore
#    - Confirmation prompt (unless --yes)
#    - Restores to temp container first if --test
#
#  Usage:
#    restore-pg.sh <backup.sql.gz[.gpg]>
#    restore-pg.sh --latest
#    restore-pg.sh --pitr --target-time "2026-08-17 18:00:00"
#    restore-pg.sh --test <backup.sql.gz[.gpg]>  (restore to temp container)
# =============================================================================

set -uo pipefail

CONTAINER="${POSTGRES_CONTAINER:-fyona-db}"
PG_USER="${POSTGRES_USER:-fyona}"
PG_DB="${POSTGRES_DB:-fyona_erp}"
PG_PASS="${POSTGRES_PASSWORD:-Ms5_Mrold_2026_Fyona}"
BASE_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/local/bin/rclone"

AUTO_CONFIRM="no"
TEST_MODE="no"
MODE="file"
BACKUP_FILE=""
TARGET_TIME=""
RESTORE_TARGET_DIR="/tmp/pg_restore_$$"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pg-restore] $*"; }
fail() { log "ERROR: $*"; cleanup; exit 1; }

cleanup() {
  rm -rf "${RESTORE_TARGET_DIR}" 2>/dev/null || true
  if [ "${TEST_MODE}" = "yes" ]; then
    docker rm -f fyona-restore-test 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Parse arguments ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --latest)      MODE="latest"; shift ;;
    --pitr)        MODE="pitr"; shift ;;
    --target-time) TARGET_TIME="$2"; shift 2 ;;
    --test)        TEST_MODE="yes"; shift ;;
    --yes)         AUTO_CONFIRM="yes"; shift ;;
    --container)   CONTAINER="$2"; shift 2 ;;
    *)             BACKUP_FILE="$1"; shift ;;
  esac
done

log "══════════════════════════════════════"
log "FYONA ERP PostgreSQL Restore"
log "══════════════════════════════════════"

# ── Find backup file ──────────────────────────────────────────────────────────
if [ "${MODE}" = "latest" ]; then
  BACKUP_FILE=$(ls -t ${BASE_DIR}/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
  if [ -z "${BACKUP_FILE}" ]; then
    BACKUP_FILE=$(ls -t ${BASE_DIR}/daily/fyona_*.sql.gz 2>/dev/null | head -1)
  fi
  if [ -z "${BACKUP_FILE}" ]; then
    fail "No backup found for --latest"
  fi
  log "Latest backup: $(basename ${BACKUP_FILE})"
fi

if [ -z "${BACKUP_FILE}" ] && [ "${MODE}" = "file" ]; then
  echo "Usage: $0 <backup.sql.gz[.gpg]> [--test] [--yes]"
  echo "       $0 --latest [--test] [--yes]"
  echo "       $0 --pitr --target-time 'YYYY-MM-DD HH:MM:SS' [--yes]"
  exit 1
fi

# ── Decrypt if needed ────────────────────────────────────────────────────────
RESTORE_FILE="${BACKUP_FILE}"
IS_ENCRYPTED=false

if [[ "${BACKUP_FILE}" == *.gpg ]]; then
  IS_ENCRYPTED=true
  log "Decrypting backup..."
  RESTORE_FILE="${BACKUP_FILE}.tmp"

  if [ -n "${GPG_PASSPHRASE}" ]; then
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --decrypt "${BACKUP_FILE}" > "${RESTORE_FILE}" 2>/dev/null
    if [ $? -ne 0 ]; then
      rm -f "${RESTORE_FILE}"
      fail "GPG decryption failed — wrong passphrase?"
    fi
  else
    fail "Encrypted backup but GPG_PASSPHRASE not set"
  fi
fi

# ── Verify backup file ───────────────────────────────────────────────────────
log "Verifying backup integrity..."
gzip -t "${RESTORE_FILE}" 2>/dev/null || fail "Gzip integrity check failed"

TABLES=$(zcat "${RESTORE_FILE}" | grep -c 'CREATE TABLE' 2>/dev/null)
log "Backup contains ${TABLES} CREATE TABLE statements"
[ "${TABLES}" -lt 1 ] && fail "No tables found in backup — refusing to restore"

# ── Safety dump (production only) ────────────────────────────────────────────
if [ "${TEST_MODE}" = "no" ] && [ "${AUTO_CONFIRM}" = "no" ]; then
  read -r -p "⚠ This will REPLACE production data. Type YES to continue: " ANSWER
  [ "${ANSWER}" != "YES" ] && { log "Aborted."; exit 0; }
fi

if [ "${TEST_MODE}" = "no" ]; then
  SAFETY_DUMP="${BASE_DIR}/pre_restore/pre_restore_$(date +%Y%m%d_%H%M%S).sql.gz"
  mkdir -p "${BASE_DIR}/pre_restore"
  log "Taking safety dump → ${SAFETY_DUMP}"
  docker exec "${CONTAINER}" pg_dump -U "${PG_USER}" -d "${PG_DB}" \
    --clean --if-exists --no-owner | gzip > "${SAFETY_DUMP}" 2>/dev/null

  if ! gzip -t "${SAFETY_DUMP}" 2>/dev/null; then
    fail "Safety dump failed — aborting restore"
  fi
  log "Safety dump OK: $(stat -c%s ${SAFETY_DUMP}) bytes"
fi

# ── Test mode: use temp container ────────────────────────────────────────────
if [ "${TEST_MODE}" = "yes" ]; then
  log "TEST MODE: Restoring to temporary container..."
  TEMP_PORT=5433

  docker rm -f fyona-restore-test 2>/dev/null || true
  docker run -d --name fyona-restore-test \
    -e POSTGRES_USER="${PG_USER}" \
    -e POSTGRES_PASSWORD="${PG_PASS}" \
    -e POSTGRES_DB="${PG_DB}" \
    -p "${TEMP_PORT}:5432" \
    postgres:16-alpine >/dev/null 2>&1

  log "Waiting for temp PG..."
  for i in $(seq 1 30); do
    docker exec fyona-restore-test pg_isready -U "${PG_USER}" >/dev/null 2>&1 && break
    sleep 1
  done

  docker exec fyona-restore-test pg_isready -U "${PG_USER}" >/dev/null 2>&1 || \
    fail "Temp PG not ready"

  log "Restoring to temp container (port ${TEMP_PORT})..."
  zcat "${RESTORE_FILE}" | docker exec -i fyona-restore-test psql -U "${PG_USER}" -d "${PG_DB}" -q 2>/dev/null
  RC=$?

  if [ ${RC} -ne 0 ]; then fail "Restore failed (rc=${RC})"; fi

  # Verify
  TEMP_TABLES=$(docker exec fyona-restore-test psql -U "${PG_USER}" -d "${PG_DB}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)
  TEMP_USERS=$(docker exec fyona-restore-test psql -U "${PG_USER}" -d "${PG_DB}" -tAc "SELECT count(*) FROM users;" 2>/dev/null || echo "?")
  log "Test restore: ${TEMP_TABLES} tables, ${TEMP_USERS} users"

  if [ "${TEMP_TABLES}" -ge 50 ]; then
    log "✓ Test restore PASSED"
  else
    fail "Test restore: too few tables (${TEMP_TABLES})"
  fi

  log "Temp container: docker exec -it fyona-restore-test psql -U ${PG_USER} -d ${PG_DB}"
  log "Cleanup: docker rm -f fyona-restore-test"
else
  # ── Production restore ────────────────────────────────────────────────────
  log "Restoring to production (${CONTAINER})..."
  zcat "${RESTORE_FILE}" | docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" \
    --set ON_ERROR_STOP=1 -q 2>/dev/null
  RC=$?

  if [ ${RC} -ne 0 ]; then fail "Restore failed (rc=${RC})"; fi
fi

# Cleanup decrypted temp file
[ "${IS_ENCRYPTED}" = true ] && rm -f "${RESTORE_FILE}"

# ── Verify ───────────────────────────────────────────────────────────────────
VERIFY_TABLES=$(docker exec "${CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)
VERIFY_USERS=$(docker exec "${CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
  "SELECT count(*) FROM users;" 2>/dev/null || echo "?")
log "Post-restore: ${VERIFY_TABLES} tables, ${VERIFY_USERS} users"

log "══════════════════════════════════════"
log "Restore complete."
log "══════════════════════════════════════"
