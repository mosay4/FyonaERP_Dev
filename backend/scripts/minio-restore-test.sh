#!/bin/bash
# FYONA ERP — Safe MinIO Restore Test
# Creates a temp bucket with test data, backs up, restores to another temp bucket
# Production MinIO data is NEVER modified

set -uo pipefail

MC="/usr/local/bin/mc"
TEMP_BUCKET="fyona-restore-test"
TEMP_RESTORE_BUCKET="fyona-restore-verify"
BACKUP_DIR="/opt/fyona/backups/minio"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=========================================="
log "MinIO Restore Test (SAFE)"
log "=========================================="
log "Production data: NOT TOUCHED"
log "Temp buckets used: ${TEMP_BUCKET}, ${TEMP_RESTORE_BUCKET}"
log "=========================================="

# ─── Step 1: Create temp bucket with test data ────────────────────────────
log "Step 1/4: Creating test data in temp bucket..."
$MC mb "local/${TEMP_BUCKET}" 2>&1
# Create a test file
echo "FYONA MinIO backup test file" > /tmp/fyona_minio_test.txt
$MC cp /tmp/fyona_minio_test.txt "local/${TEMP_BUCKET}/test_file.txt" 2>&1
$MC cp /tmp/fyona_minio_test.txt "local/${TEMP_BUCKET}/test_file2.txt" 2>&1
log "Test data created."
log "Files in temp bucket:"
$MC ls "local/${TEMP_BUCKET}" 2>&1

# ─── Step 2: Run MinIO backup ──────────────────────────────────────────────
log "Step 2/4: Running MinIO backup..."
mkdir -p "${BACKUP_DIR}/${TIMESTAMP}"
$MC mirror "local/${TEMP_BUCKET}" "${BACKUP_DIR}/${TIMESTAMP}/${TEMP_BUCKET}/" 2>&1
log "Backup created at: ${BACKUP_DIR}/${TIMESTAMP}/${TEMP_BUCKET}/"
ls -la "${BACKUP_DIR}/${TIMESTAMP}/${TEMP_BUCKET}/" 2>&1

# ─── Step 3: Restore to a different temp bucket ──────────────────────────
log "Step 3/4: Restoring to temp bucket..."
$MC mb "local/${TEMP_RESTORE_BUCKET}" 2>&1
$MC mirror "${BACKUP_DIR}/${TIMESTAMP}/${TEMP_BUCKET}/" "local/${TEMP_RESTORE_BUCKET}/" 2>&1
log "Restore complete."

# ─── Step 4: Verify ────────────────────────────────────────────────────────
log "Step 4/4: Verifying restoration..."
SOURCE_COUNT=$($MC ls "local/${TEMP_BUCKET}" 2>/dev/null | wc -l)
RESTORE_COUNT=$($MC ls "local/${TEMP_RESTORE_BUCKET}" 2>/dev/null | wc -l)

log "Source files: ${SOURCE_COUNT}"
log "Restored files: ${RESTORE_COUNT}"

if [ "${SOURCE_COUNT}" -ge 2 ] && [ "${RESTORE_COUNT}" -ge 2 ] && [ "${SOURCE_COUNT}" = "${RESTORE_COUNT}" ]; then
    log "=========================================="
    log "MinIO RESTORE TEST: PASSED"
    log "=========================================="
else
    log "=========================================="
    log "MinIO RESTORE TEST: FAILED"
    log "Source: ${SOURCE_COUNT}, Restored: ${RESTORE_COUNT}"
    log "=========================================="
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────
log "Cleaning up temp buckets..."
$MC rm --recursive --force "local/${TEMP_BUCKET}" 2>&1
$MC rb "local/${TEMP_BUCKET}" 2>&1
$MC rm --recursive --force "local/${TEMP_RESTORE_BUCKET}" 2>&1
$MC rb "local/${TEMP_RESTORE_BUCKET}" 2>&1
rm -f /tmp/fyona_minio_test.txt

log "Cleanup complete."
log "MinIO restore test done."
