#!/bin/bash
# FYONA ERP Backup Verification Script
# Verifies backup integrity, restorability, and content
# Usage: ./scripts/backup-verify.sh <backup_file> [--full]

set -euo pipefail

BACKUP_FILE="${1:-}"
FULL_VERIFY=false
LOG_FILE="/opt/fyona/backups/verify_$(date +%Y%m%d_%H%M%S).log"
RESTORE_DB="fyona_verify_$(date +%Y%m%d_%H%M%S)"

for arg in "$@"; do
    case $arg in
        --full) FULL_VERIFY=true ;;
    esac
done

if [ -z "${BACKUP_FILE}" ]; then
    echo "Usage: $0 <backup_file> [--full]"
    echo ""
    echo "Options:"
    echo "  --full  Full verification including test restore"
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

log "=========================================="
log "Backup Verification: $(basename ${BACKUP_FILE})"
log "=========================================="

PASS=0
FAIL=0

# ─── Test 1: File exists and has content ───────────────────────────────────
log "Test 1: File integrity..."
FILE_SIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}")
if [ "${FILE_SIZE}" -gt 100 ]; then
    log "  PASS: File size ${FILE_SIZE} bytes"
    PASS=$((PASS + 1))
else
    log "  FAIL: File too small (${FILE_SIZE} bytes)"
    FAIL=$((FAIL + 1))
fi

# ─── Test 2: Checksum verification ────────────────────────────────────────
log "Test 2: Checksum..."
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    if sha256sum -c "${CHECKSUM_FILE}" >/dev/null 2>&1; then
        log "  PASS: Checksum matches"
        PASS=$((PASS + 1))
    else
        log "  FAIL: Checksum mismatch"
        FAIL=$((FAIL + 1))
    fi
else
    log "  SKIP: No checksum file"
fi

# ─── Test 3: File type detection ───────────────────────────────────────────
log "Test 3: File format..."
FILE_TYPE=$(file -b "${BACKUP_FILE}" 2>/dev/null || echo "unknown")
if echo "${FILE_TYPE}" | grep -qi "PostgreSQL\|gzip\|ASCII\|text"; then
    log "  PASS: Recognized format (${FILE_TYPE})"
    PASS=$((PASS + 1))
else
    log "  WARN: Unknown format (${FILE_TYPE})"
    PASS=$((PASS + 1))
fi

# ─── Test 4: Content inspection ───────────────────────────────────────────
log "Test 4: Content inspection..."
if echo "${FILE_TYPE}" | grep -qi "gzip"; then
    CONTENT_SAMPLE=$(zcat "${BACKUP_FILE}" 2>/dev/null | head -20)
elif echo "${FILE_TYPE}" | grep -qi "PostgreSQL custom"; then
    CONTENT_SAMPLE=$(pg_restore -l "${BACKUP_FILE}" 2>/dev/null | head -20 || echo "")
else
    CONTENT_SAMPLE=$(head -20 "${BACKUP_FILE}" 2>/dev/null)
fi

if echo "${CONTENT_SAMPLE}" | grep -qi "CREATE\|TABLE\|PostgreSQL"; then
    log "  PASS: Contains SQL content"
    PASS=$((PASS + 1))
else
    log "  FAIL: No SQL content detected"
    FAIL=$((FAIL + 1))
fi

# ─── Test 5: Full restore verification ─────────────────────────────────────
if [ "${FULL_VERIFY}" = true ]; then
    log "Test 5: Test restore to temp database..."

    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
        --command="DROP DATABASE IF EXISTS ${RESTORE_DB};" 2>/dev/null || true

    docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
        --command="CREATE DATABASE ${RESTORE_DB};" || {
            log "  FAIL: Could not create temp database"
            FAIL=$((FAIL + 1))
        }

    if docker compose exec -T db psql \
        --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
        --command="SELECT 1 FROM pg_database WHERE datname = '${RESTORE_DB}';" \
        --tuples-only | grep -q 1; then

        if echo "${FILE_TYPE}" | grep -qi "PostgreSQL custom"; then
            docker compose exec -T db pg_restore \
                --username="${POSTGRES_USER:-fyona}" --dbname="${RESTORE_DB}" \
                --no-owner --no-privileges --if-exists --clean \
                "${BACKUP_FILE}" >/dev/null 2>&1 || true
        else
            zcat "${BACKUP_FILE}" 2>/dev/null | docker compose exec -T db psql \
                --username="${POSTGRES_USER:-fyona}" --dbname="${RESTORE_DB}" -q \
                >/dev/null 2>&1 || \
            docker compose exec -T db psql \
                --username="${POSTGRES_USER:-fyona}" --dbname="${RESTORE_DB}" -q \
                < "${BACKUP_FILE}" >/dev/null 2>&1 || true
        fi

        TABLE_COUNT=$(docker compose exec -T db psql \
            --username="${POSTGRES_USER:-fyona}" --dbname="${RESTORE_DB}" \
            --tuples-only \
            --command="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" \
            2>/dev/null | tr -d '[:space:]')

        ROW_COUNT=$(docker compose exec -T db psql \
            --username="${POSTGRES_USER:-fyona}" --dbname="${RESTORE_DB}" \
            --tuples-only \
            --command="SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables;" \
            2>/dev/null | tr -d '[:space:]')

        log "  Tables: ${TABLE_COUNT:-0}, Rows: ${ROW_COUNT:-0}"

        if [ "${TABLE_COUNT:-0}" -ge 5 ]; then
            log "  PASS: Restore successful"
            PASS=$((PASS + 1))
        else
            log "  FAIL: Too few tables (${TABLE_COUNT:-0})"
            FAIL=$((FAIL + 1))
        fi

        docker compose exec -T db psql \
            --username="${POSTGRES_USER:-fyona}" --dbname=postgres \
            --command="DROP DATABASE IF EXISTS ${RESTORE_DB};" 2>/dev/null || true
    fi
else
    log "Test 5: SKIP (use --full for restore verification)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log ""
log "=========================================="
log "Verification Summary"
log "=========================================="
log "PASSED: ${PASS}"
log "FAILED: ${FAIL}"
log "=========================================="

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0