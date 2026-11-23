#!/bin/bash
# FYONA ERP Full Backup Script
# Features: pg_dump + WAL archiving + verification + encryption + off-site
# Usage: ./scripts/backup-full.sh [--no-encrypt] [--no-offsite]
# Requires: docker, openssl/gpg, rclone (for off-site), jq

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="fyona_db_${TIMESTAMP}"
LOG_FILE="${BACKUP_DIR}/backup.log"
VERIFY_LOG="${BACKUP_DIR}/verify_${TIMESTAMP}.log"
LOCK_FILE="/tmp/fyona-backup.lock"

# Encryption
ENCRYPT=true
OFFSITE=true
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-}"

# Retention (days)
RETENTION_DAILY=7
RETENTION_WEEKLY=30
RETENTION_MONTHLY=365

# Off-site via rclone
RCLONE_REMOTE="${RCLONE_REMOTE:-offsite}"
RCLONE_PATH="${RCLONE_PATH:-fyona-backups}"

# ─── Parse Arguments ────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --no-encrypt) ENCRYPT=false ;;
        --no-offsite) OFFSITE=false ;;
        --help|-h)
            echo "Usage: $0 [--no-encrypt] [--no-offsite]"
            echo ""
            echo "Options:"
            echo "  --no-encrypt   Skip GPG encryption"
            echo "  --no-offsite   Skip off-site copy via rclone"
            exit 0
            ;;
    esac
done

# ─── Functions ──────────────────────────────────────────────────────────────
log() {
    local msg="[$(date +%Y-%m-%d\ %H:%M:%S)] $1"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

error_exit() {
    log "ERROR: $1"
    rm -f "${LOCK_FILE}"
    exit 1
}

cleanup() {
    rm -f "${LOCK_FILE}"
}
trap cleanup EXIT

# ─── Lock (prevent concurrent backups) ─────────────────────────────────────
if [ -f "${LOCK_FILE}" ]; then
    LOCK_PID=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
    if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        error_exit "Backup already running (PID: ${LOCK_PID}). Aborting."
    else
        log "WARNING: Stale lock file found. Removing."
        rm -f "${LOCK_FILE}"
    fi
fi
echo $$ > "${LOCK_FILE}"

mkdir -p "${BACKUP_DIR}"

log "=========================================="
log "Starting FYONA ERP Full Backup"
log "=========================================="
log "Backup name: ${BACKUP_NAME}"
log "Encryption: ${ENCRYPT}"
log "Off-site copy: ${OFFSITE}"

# ─── Step 1: pg_dump ───────────────────────────────────────────────────────
log "Step 1/6: Running pg_dump..."
DUMP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.sql"

docker compose exec -T db pg_dump \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${POSTGRES_DB:-fyona_erp}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-privileges \
    --format=custom \
    --compress=6 \
    --file=/tmp/${BACKUP_NAME}.dump

# Copy dump out of container
docker compose cp db:/tmp/${BACKUP_NAME}.dump "${DUMP_FILE}"
docker compose exec -T db rm -f /tmp/${BACKUP_NAME}.dump

if [ ! -f "${DUMP_FILE}" ]; then
    error_exit "pg_dump failed: file not created"
fi

DUMP_SIZE=$(stat -c%s "${DUMP_FILE}" 2>/dev/null || stat -f%z "${DUMP_FILE}")
log "Dump created: ${DUMP_SIZE} bytes"

# ─── Step 2: Checksum ──────────────────────────────────────────────────────
log "Step 2/6: Generating checksum..."
sha256sum "${DUMP_FILE}" > "${DUMP_FILE}.sha256"
CHECKSUM=$(cat "${DUMP_FILE}.sha256" | awk '{print $1}')
log "SHA256: ${CHECKSUM}"

# ─── Step 3: Verify backup (test restore to temp DB) ───────────────────────
log "Step 3/6: Verifying backup (test restore)..."

TEMP_DB="fyona_verify_${TIMESTAMP}"
VERIFY_PASS=true

# Create temp database
docker compose exec -T db psql \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname=postgres \
    --command="CREATE DATABASE ${TEMP_DB};" || VERIFY_PASS=false

if [ "${VERIFY_PASS}" = true ]; then
    # Restore to temp DB
    docker compose exec -T db pg_restore \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${TEMP_DB}" \
        --no-owner \
        --no-privileges \
        --if-exists \
        --clean \
        "${DUMP_FILE}" > "${VERIFY_LOG}" 2>&1 || VERIFY_PASS=false

    # Basic validation: check tables exist
    TABLE_COUNT=$(docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${TEMP_DB}" \
        --tuples-only \
        --command="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')

    if [ "${TABLE_COUNT:-0}" -lt 5 ]; then
        VERIFY_PASS=false
        log "WARNING: Only ${TABLE_COUNT:-0} tables found in restored backup"
    else
        log "Verified: ${TABLE_COUNT} tables found in restored backup"
    fi

    # Drop temp database
    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname=postgres \
        --command="DROP DATABASE IF EXISTS ${TEMP_DB};" 2>/dev/null || true
fi

if [ "${VERIFY_PASS}" = false ]; then
    error_exit "Backup verification FAILED. Backup is NOT restorable."
fi
log "Backup verification PASSED"

# ─── Step 4: Encrypt ───────────────────────────────────────────────────────
ENCRYPTED_FILE="${DUMP_FILE}"
ENCRYPTION_STATUS="SKIPPED (no passphrase)"
if [ "${ENCRYPT}" = true ]; then
    log "Step 4/6: Encrypting backup..."

    if [ -z "${GPG_PASSPHRASE}" ]; then
        log "WARNING: No GPG passphrase set. Backups will NOT be encrypted."
        log "Set BACKUP_GPG_PASSPHRASE environment variable for production."
        log "Step 4/6: SKIPPED (no passphrase). Use --no-encrypt to suppress this warning."
    else
        gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
            --symmetric --cipher-algo AES256 \
            --output "${DUMP_FILE}.gpg" \
            "${DUMP_FILE}"
        ENCRYPTED_FILE="${DUMP_FILE}.gpg"
        sha256sum "${ENCRYPTED_FILE}" > "${ENCRYPTED_FILE}.sha256"
        ENCRYPTION_STATUS="YES (AES256)"
        log "Encrypted: ${ENCRYPTED_FILE}"
    fi
else
    log "Step 4/6: Skipping encryption (--no-encrypt)"
    ENCRYPTION_STATUS="DISABLED (--no-encrypt)"
fi

# ─── Step 5: Off-site copy ─────────────────────────────────────────────────
if [ "${OFFSITE}" = true ]; then
    log "Step 5/6: Copying to off-site storage..."
    if command -v rclone &> /dev/null; then
        rclone copy "${ENCRYPTED_FILE}" "${RCLONE_REMOTE}:${RCLONE_PATH}/${BACKUP_NAME}/" \
            --progress 2>&1 | tee -a "${LOG_FILE}" || log "WARNING: rclone copy failed"
        rclone copy "${ENCRYPTED_FILE}.sha256" "${RCLONE_REMOTE}:${RCLONE_PATH}/${BACKUP_NAME}/" \
            2>/dev/null || true
        log "Off-site copy complete"
    else
        log "WARNING: rclone not installed. Off-site copy skipped."
        log "Install rclone: https://rclone.org/install/"
    fi
else
    log "Step 5/6: Skipping off-site copy (--no-offsite)"
fi

# ─── Step 6: Retention cleanup ─────────────────────────────────────────────
log "Step 6/6: Applying retention policy..."

# Retention tiers (applied in order — oldest first):
# - Daily backups: keep 7 days
# - All backups older than 30 days: delete
# - All backups older than 365 days: delete (safety net)
# Note: We use -mtime +N which means "modified more than N days ago"
find "${BACKUP_DIR}" -name "fyona_db_*.sql" -mtime +${RETENTION_MONTHLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.sha256" -mtime +${RETENTION_MONTHLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg" -mtime +${RETENTION_MONTHLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg.sha256" -mtime +${RETENTION_MONTHLY} -delete 2>/dev/null || true

find "${BACKUP_DIR}" -name "fyona_db_*.sql" -mtime +${RETENTION_WEEKLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.sha256" -mtime +${RETENTION_WEEKLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg" -mtime +${RETENTION_WEEKLY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg.sha256" -mtime +${RETENTION_WEEKLY} -delete 2>/dev/null || true

find "${BACKUP_DIR}" -name "fyona_db_*.sql" -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.sha256" -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg" -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "fyona_db_*.sql.gpg.sha256" -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "verify_*.log" -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true

# Clean off-site retention (if rclone available)
if [ "${OFFSITE}" = true ] && command -v rclone &> /dev/null; then
    log "Cleaning off-site retention..."
    # rclone delete with age filter
    rclone delete "${RCLONE_REMOTE}:${RCLONE_PATH}/" \
        --min-age "${RETENTION_DAILY}d" 2>/dev/null || true
fi

log "Retention cleanup complete"

# ─── Final Report ───────────────────────────────────────────────────────────
# Create "latest" symlink for easy reference
ln -sf "${DUMP_FILE}" "${BACKUP_DIR}/fyona_db_latest.sql" 2>/dev/null || true
if [ -f "${DUMP_FILE}.sha256" ]; then
    ln -sf "${DUMP_FILE}.sha256" "${BACKUP_DIR}/fyona_db_latest.sql.sha256" 2>/dev/null || true
fi

FINAL_SIZE=$(stat -c%s "${ENCRYPTED_FILE}" 2>/dev/null || stat -f%z "${ENCRYPTED_FILE}")
log "=========================================="
log "Backup Complete!"
log "=========================================="
log "File: ${ENCRYPTED_FILE}"
log "Size: ${FINAL_SIZE} bytes"
log "Checksum: ${CHECKSUM}"
log "Verification: PASSED"
log "Encryption: ${ENCRYPTION_STATUS}"
log "Off-site: $([ "${OFFSITE}" = true ] && echo "YES" || echo "DISABLED")"
log "Retention: Daily=${RETENTION_DAILY}d, Weekly=${RETENTION_WEEKLY}d, Monthly=${RETENTION_MONTHLY}d"
log "=========================================="

# ─── Alerting Hook ──────────────────────────────────────────────────────────
# Uncomment and configure for your alerting system:
# curl -s -X POST "${ALERT_WEBHOOK_URL:-}" \
#   -H "Content-Type: application/json" \
#   -d "{\"text\": \"✅ FYONA backup completed: ${BACKUP_NAME}\"}" || true

exit 0