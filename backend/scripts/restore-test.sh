#!/bin/bash
# FYONA ERP — Safe PostgreSQL Restore Test
# Tests that a backup can be restored WITHOUT touching production.
# Uses a temporary database: fyona_restore_test

set -uo pipefail

BACKUP_FILE="${1:-/opt/fyona/backups/daily/fyona_2026-08-17.sql.gz}"
GPG_PASSPHRASE=""

# Load encryption key if backup is encrypted
if [[ "${BACKUP_FILE}" == *.gpg ]]; then
    GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
    export BACKUP_GPG_PASSPHRASE="${GPG_PASSPHRASE}"
fi

TEMP_DB="fyona_restore_test"
PG_USER="${POSTGRES_USER:-fyona}"
PG_DB="${POSTGRES_DB:-fyona_erp}"
CONTAINER="fyona-db"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=========================================="
log "PostgreSQL Restore Test (SAFE)"
log "=========================================="
log "Backup file: ${BACKUP_FILE}"
log "Temp DB: ${TEMP_DB}"
log "Production DB: NOT TOUCHED"
log "=========================================="

# ─── Step 1: Drop temp DB if exists ────────────────────────────────────────
log "Step 1/5: Cleaning up any existing temp database..."
docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${TEMP_DB};" 2>&1 || true

# ─── Step 2: Create temp DB ────────────────────────────────────────────────
log "Step 2/5: Creating temporary database..."
docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${TEMP_DB};" 2>&1

# ─── Step 3: Decrypt backup if needed ──────────────────────────────────────
log "Step 3/5: Preparing backup for restore..."
if [ -f "${BACKUP_FILE}.gpg" ]; then
    log "Decrypting GPG backup..."
    TEMP_DECRYPTED=$(mktemp)
    if ! docker exec -T "${CONTAINER}" bash -c "gpg --batch --yes --passphrase '${GPG_PASSPHRASE}' --decrypt /dev/stdin > /dev/stdout" < "${BACKUP_FILE}.gpg" 2>/dev/null > "${TEMP_DECRYPTED}.gz"; then
        # Fallback: decrypt on host
        gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" --decrypt "${BACKUP_FILE}.gpg" 2>/dev/null | gzip > "${TEMP_DECRYPTED}.gz"
    fi
    RESTORE_FILE="${TEMP_DECRYPTED}.gz"
    log "Backup decrypted: ${RESTORE_FILE}"
else
    RESTORE_FILE="${BACKUP_FILE}"
fi

# ─── Step 4: Restore to temp DB ────────────────────────────────────────────
log "Step 4/5: Restoring to temporary database..."
# Decompress and restore
zcat "${RESTORE_FILE}" | docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -q 2>&1 | tail -5

# ─── Step 5: Verify ────────────────────────────────────────────────────────
log "Step 5/5: Verifying restored data..."

TABLE_COUNT=$(docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')

USER_COUNT=$(docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -tAc \
    "SELECT count(*) FROM users;" 2>/dev/null | tr -d '[:space:]')

BUSINESS_COUNT=$(docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d "${TEMP_DB}" -tAc \
    "SELECT count(*) FROM businesses;" 2>/dev/null | tr -d '[:space:]')

echo ""
log "=========================================="
log "Restore Verification Results"
log "=========================================="
log "Tables restored:  ${TABLE_COUNT:-0} (expected: 78)"
log "Users restored:   ${USER_COUNT:-0}"
log "Businesses:       ${BUSINESS_COUNT:-0}"
log "=========================================="

if [ "${TABLE_COUNT:-0}" -ge 70 ]; then
    log "RESTORE TEST: PASSED"
    TEST_RESULT="PASSED"
else
    log "RESTORE TEST: FAILED (too few tables)"
    TEST_RESULT="FAILED"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────
log "Cleaning up..."
if [ -n "${TEMP_DECRYPTED:-}" ]; then
    rm -f "${TEMP_DECRYPTED}" "${TEMP_DECRYPTED}.gz" 2>/dev/null || true
fi
docker exec -i "${CONTAINER}" psql -U "${PG_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${TEMP_DB};" 2>&1 || true

log "Temporary database dropped. Production database untouched."
log "Restore test complete: ${TEST_RESULT}"

if [ "${TEST_RESULT}" = "PASSED" ]; then
    exit 0
else
    exit 1
fi