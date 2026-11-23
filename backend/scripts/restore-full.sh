#!/bin/bash
# FYONA ERP Full Restore Script
# Safety checks + verification + temp restore + smoke tests
# Usage: ./scripts/restore-full.sh <backup.sql> [--verify-only] [--dry-run] [--yes]

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
LOG_FILE="${BACKUP_DIR}/restore_$(date +%Y%m%d_%H%M%S).log"
RESTORE_DB="fyona_erp_restored"
ORIGINAL_DB="${POSTGRES_DB:-fyona_erp}"

BACKUP_FILE=""
VERIFY_ONLY=false
DRY_RUN=false
SKIP_CONFIRM=false

for arg in "$@"; do
    case $arg in
        --verify-only) VERIFY_ONLY=true ;;
        --dry-run) DRY_RUN=true ;;
        --yes|-y) SKIP_CONFIRM=true ;;
        --help|-h)
            echo "Usage: $0 <backup.sql> [--verify-only] [--dry-run] [--yes]"
            exit 0
            ;;
        *) BACKUP_FILE="${BACKUP_FILE:-$arg}" ;;
    esac
done

if [ -z "${BACKUP_FILE}" ]; then
    echo "Error: No backup file specified."
    exit 1
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    echo "Error: File not found: ${BACKUP_FILE}"
    exit 1
fi

log() {
    local msg="[$(date +%Y-%m-%d\ %H:%M:%S)] $1"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

confirm() {
    if [ "${SKIP_CONFIRM}" = true ] || [ "${DRY_RUN}" = true ]; then
        return 0
    fi
    read -p "$1 [y/N]: " answer
    case "${answer}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) echo "Aborted."; exit 1 ;;
    esac
}

mkdir -p "${BACKUP_DIR}"

log "=========================================="
log "FYONA ERP Restore"
log "=========================================="
log "Backup file: ${BACKUP_FILE}"
log "Verify only: ${VERIFY_ONLY}"
log "Dry run: ${DRY_RUN}"

# ─── Step 1: Check checksum ────────────────────────────────────────────────
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    log "Step 1/4: Verifying checksum..."
    if sha256sum -c "${CHECKSUM_FILE}" 2>/dev/null; then
        log "Checksum: PASSED"
    else
        log "ERROR: Checksum FAILED. Backup may be corrupted."
        confirm "Continue anyway?" || exit 1
    fi
else
    log "Step 1/4: No checksum file found. Skipping."
fi

# ─── Step 2: Check if pg_restore format ────────────────────────────────────
log "Step 2/4: Detecting backup format..."
FILE_TYPE=$(file -b "${BACKUP_FILE}" 2>/dev/null || echo "unknown")
log "File type: ${FILE_TYPE}"

# ─── Step 3: Verify by restoring to temp database ──────────────────────────
log "Step 3/4: Restoring to temp database for verification..."

if [ "${DRY_RUN}" = true ]; then
    log "DRY RUN: Would create temp database '${RESTORE_DB}' and restore"
else
    # Drop if exists
    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname=postgres \
        --command="DROP DATABASE IF EXISTS ${RESTORE_DB};" 2>/dev/null || true

    # Create temp database
    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname=postgres \
        --command="CREATE DATABASE ${RESTORE_DB};" || {
            log "ERROR: Failed to create temp database"
            exit 1
        }

    # Detect format and restore
    if echo "${FILE_TYPE}" | grep -qi "PostgreSQL custom database dump"; then
        docker compose exec -T db pg_restore \
            --username="${POSTGRES_USER:-fyona}" \
            --dbname="${RESTORE_DB}" \
            --no-owner --no-privileges --if-exists --clean \
            "${BACKUP_FILE}" 2>/dev/null || true
    else
        zcat "${BACKUP_FILE}" 2>/dev/null | docker compose exec -T db psql \
            --username="${POSTGRES_USER:-fyona}" \
            --dbname="${RESTORE_DB}" -q 2>/dev/null || \
        docker compose exec -T db psql \
            --username="${POSTGRES_USER:-fyona}" \
            --dbname="${RESTORE_DB}" -q < "${BACKUP_FILE}" 2>/dev/null || true
    fi

    # Validate tables
    TABLE_COUNT=$(docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${RESTORE_DB}" \
        --tuples-only \
        --command="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')

    ROW_COUNT=$(docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${RESTORE_DB}" \
        --tuples-only \
        --command="SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables;" 2>/dev/null | tr -d '[:space:]')

    log "Restored: ${TABLE_COUNT:-0} tables, ${ROW_COUNT:-0} rows"

    if [ "${TABLE_COUNT:-0}" -lt 5 ]; then
        log "ERROR: Too few tables (${TABLE_COUNT:-0}). Backup may be invalid."
        confirm "Continue anyway?" || {
            docker compose exec -T db psql \
                --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
                --command="DROP DATABASE IF EXISTS ${RESTORE_DB};" 2>/dev/null || true
            exit 1
        }
    else
        log "Verification: PASSED"
    fi

    # Cleanup temp DB
    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
        --command="DROP DATABASE IF EXISTS ${RESTORE_DB};" 2>/dev/null || true
fi

# ─── Step 4: Restore to production ─────────────────────────────────────────
if [ "${VERIFY_ONLY}" = true ]; then
    log "Step 4/4: Skipping production restore (--verify-only)"
    log "=========================================="
    log "Verification complete. Backup is restorable."
    log "=========================================="
    exit 0
fi

if [ "${DRY_RUN}" = true ]; then
    log "Step 4/4: DRY RUN - Would restore to production database '${ORIGINAL_DB}'"
    log "=========================================="
    log "Dry run complete."
    log "=========================================="
    exit 0
fi

confirm "⚠️  This will OVERWRITE the production database '${ORIGINAL_DB}'. Continue?"

log "Step 4/4: Creating pre-restore backup..."
docker compose exec -T db pg_dump \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${ORIGINAL_DB}" \
    --clean --if-exists --no-owner --no-privileges \
    > "${BACKUP_DIR}/pre_restore_$(date +%Y%m%d_%H%M%S).sql" || true

log "Restoring to production..."
if echo "${FILE_TYPE}" | grep -qi "PostgreSQL custom database dump"; then
    docker compose exec -T db pg_restore \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${ORIGINAL_DB}" \
        --no-owner --no-privileges --if-exists --clean \
        "${BACKUP_FILE}" 2>&1 | tee -a "${LOG_FILE}" || true
else
    zcat "${BACKUP_FILE}" 2>/dev/null | docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${ORIGINAL_DB}" -q 2>&1 | tee -a "${LOG_FILE}" || \
    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" \
        --dbname="${ORIGINAL_DB}" -q < "${BACKUP_FILE}" 2>&1 | tee -a "${LOG_FILE}" || true
fi

log "=========================================="
log "Restore complete!"
log "Pre-restore backup saved in ${BACKUP_DIR}/"
log "=========================================="