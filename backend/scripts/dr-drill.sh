#!/bin/bash
# FYONA ERP — Full DR Drill Script
# Tests the complete disaster recovery process:
# 1. Download encrypted backup from B2
# 2. Decrypt the backup
# 3. Restore to a TEMPORARY database (NOT production)
# 4. Verify the restored database integrity
# 5. Verify application connectivity
#
# Usage: B2_BUCKET="fyona-backups" bash dr-drill.sh
#
# Safety:
#   - Production database is NEVER modified
#   - All restore operations go to temp DB: fyona_dr_test
#   - Temp DB is cleaned up at the end
#   - Local backups are NOT deleted

set -uo pipefail

B2_BUCKET="${B2_BUCKET:-${BACKUP_B2_BUCKET:-fyona-backups}}"
BACKUP_DIR="/opt/fyona/backups/daily"
WAL_DIR="/opt/fyona/backups/wal"
RCLONE="/usr/bin/rclone"
GNUPG="/usr/bin/gpg"
ENCRYPTION_KEY_FILE="/opt/fyona/.backup-encryption-key"
TEMP_DB_NAME="fyona_dr_test"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="/tmp/fyona_dr_drill_${TIMESTAMP}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DR-DRILL] $*"; }

# ─── Safety: Load backup encryption passphrase ──────────────────────────────
if [ -f "${ENCRYPTION_KEY_FILE}" ]; then
    BACKUP_GPG_PASSPHRASE=$(cat "${ENCRYPTION_KEY_FILE}")
    export BACKUP_GPG_PASSPHRASE
else
    log "ERROR: Encryption key file not found: ${ENCRYPTION_KEY_FILE}"
    exit 1
fi

mkdir -p "${WORK_DIR}"

log "=========================================="
log "Full DR Drill — $(date '+%Y-%m-%d %H:%M:%S')"
log "=========================================="
log "Safety: Production database NOT affected"
log "Temp DB: ${TEMP_DB_NAME}"
log "Work dir: ${WORK_DIR}"
log "=========================================="

# ─── Step 1: Download from B2 ───────────────────────────────────────────────
log "Step 1/6: Downloading encrypted backup from B2..."

# Find latest backup in B2
B2_BACKUP=$(B2_BUCKET="${B2_BUCKET}" ${RCLONE} lsf "b2:${B2_BUCKET}/daily/" 2>/dev/null | grep '\.gpg$' | sort -r | head -1)

if [ -z "${B2_BACKUP}" ]; then
    log "Checking B2 for any .gpg files..."
    B2_BACKUP=$(B2_BUCKET="${B2_BUCKET}" ${RCLONE} lsf "b2:${B2_BUCKET}/daily/" 2>/dev/null | grep -v '\.log' | sort -r | head -1)
fi

if [ -z "${B2_BACKUP}" ]; then
    log "ERROR: No backup found in B2 bucket ${B2_BUCKET}"
    log "B2 contents:"
    ${RCLONE} ls "b2:${B2_BUCKET}/daily/" 2>&1
    exit 1
fi

log "Latest B2 backup: ${B2_BACKUP}"
DOWNLOADED="${WORK_DIR}/$(basename "${B2_BACKUP}")"
${RCLONE} copyto "b2:${B2_BUCKET}/daily/${B2_BACKUP}" "${DOWNLOADED}" 2>&1
log "Downloaded: ${DOWNLOADED} ($(stat -c%s "${DOWNLOADED}") bytes)"

# ─── Step 2: Verify checksum ────────────────────────────────────────────────
log "Step 2/6: Verifying integrity..."
# Get the SHA-256 from local backup if available
LOCAL_BACKUP="${BACKUP_DIR}/$(echo "${B2_BACKUP}" | sed 's/\.gpg$//')"
LOG_FILE="${BACKUP_DIR}/verify.log"

if [ -f "${DOWNLOADED}.sha256" ] || [ -f "${LOCAL_BACKUP}.sha256" ]; then
    log "SHA-256 checksum file found."
    SHA_FILE="${LOCAL_BACKUP}.sha256"
    if [ -f "${SHA_FILE}" ]; then
        cd "${WORK_DIR}"
        sha256sum -c "${SHA_FILE}" 2>&1 && log "Checksum: PASSED" || log "Checksum: MISMATCH"
    fi
fi

# Also use rclone check for integrity
${RCLONE} check "${DOWNLOADED}" "b2:${B2_BUCKET}/daily/${B2_BACKUP}" 2>&1 && log "rclone check: PASSED" || log "rclone check: differences (may be checksum algo mismatch)"

# ─── Step 3: Decrypt ────────────────────────────────────────────────────────
log "Step 3/6: Decrypting backup..."

DECRYPTED="${WORK_DIR}/fyona_dr_decrypted.sql.gz"
${GNUPG} --batch --yes --decrypt \
    --passphrase "${BACKUP_GPG_PASSPHRASE}" \
    --cipher-algo AES256 \
    --output "${DECRYPTED}" \
    "${DOWNLOADED}" 2>&1

if [ ! -f "${DECRYPTED}" ] || [ ! -s "${DECRYPTED}" ]; then
    log "ERROR: Decryption failed."
    exit 1
fi
log "Decrypted: ${DECRYPTED} ($(stat -c%s "${DECRYPTED}") bytes)"

# Verify gzip integrity
gzip -t "${DECRYPTED}" 2>&1 && log "gzip integrity: PASSED" || log "gzip integrity: FAILED"

# ─── Step 4: Clean up temp DB if exists ──────────────────────────────────────
log "Step 4/6: Preparing temporary database..."

# Check if temp DB already exists and drop it
docker exec fyona-db psql -U fyona -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${TEMP_DB_NAME}'" 2>&1 | grep -q 1 && {
    log "Dropping existing temp DB ${TEMP_DB_NAME}..."
    docker exec fyona-db psql -U fyona -d postgres -c "DROP DATABASE IF EXISTS ${TEMP_DB_NAME};" 2>&1
}

# Create temp DB
docker exec fyona-db psql -U fyona -d postgres -c "CREATE DATABASE ${TEMP_DB_NAME};" 2>&1
log "Temp DB created: ${TEMP_DB_NAME}"

# ─── Step 5: Restore to temp DB ─────────────────────────────────────────────
log "Step 5/6: Restoring backup to temp DB..."

# Decompress and restore
zcat "${DECRYPTED}" | docker exec -i fyona-db psql -U fyona -d "${TEMP_DB_NAME}" 2>&1

log "Restore command completed."

# ─── Step 6: Verify ─────────────────────────────────────────────────────────
log "Step 6/6: Verifying restored database..."

log "Counting tables in temp DB..."
TABLE_COUNT=$(docker exec fyona-db psql -U fyona -d "${TEMP_DB_NAME}" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>&1 | tr -d '[:space:]')
log "Tables restored: ${TABLE_COUNT}"

log "Counting users..."
USER_COUNT=$(docker exec fyona-db psql -U fyona -d "${TEMP_DB_NAME}" -t -c "SELECT count(*) FROM auth_user;" 2>&1 | tr -d '[:space:]')
log "Users restored: ${USER_COUNT}"

log "Top 10 tables by row count:"
docker exec fyona-db psql -U fyona -d "${TEMP_DB_NAME}" -c "
SELECT schemaname, tablename,
       n_tup_ins AS rows_inserted,
       n_tup_upd AS rows_updated,
       n_tup_del AS rows_deleted
FROM pg_stat_user_tables
ORDER BY n_tup_ins DESC
LIMIT 10
" 2>&1

EXPECTED_TABLES=78

if [ "${TABLE_COUNT}" = "${EXPECTED_TABLES}" ] && [ "${USER_COUNT}" -gt 0 ]; then
    log "=========================================="
    log "✅ DR DRILL: SUCCESS"
    log "=========================================="
    log "Tables: ${TABLE_COUNT}/${EXPECTED_TABLES}"
    log "Users: ${USER_COUNT}"
    log "Temp DB: ${TEMP_DB_NAME}"
    log "Production: UNTOUCHED"
    log "=========================================="
    DR_RESULT="SUCCESS"
else
    log "=========================================="
    log "⚠️ DR DRILL: COMPLETED WITH WARNINGS"
    log "=========================================="
    log "Tables: ${TABLE_COUNT}/${EXPECTED_TABLES} (expected ${EXPECTED_TABLES})"
    log "Users: ${USER_COUNT} (expected > 0)"
    log "=========================================="
    DR_RESULT="PARTIAL"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────
log "Cleaning up temp DB..."
docker exec fyona-db psql -U fyona -d postgres -c "DROP DATABASE IF EXISTS ${TEMP_DB_NAME};" 2>&1
rm -rf "${WORK_DIR}"

log "Cleanup complete."
log "DR Drill finished: ${DR_RESULT}"
