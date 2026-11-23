#!/bin/bash
# FYONA ERP — MinIO Backup Script
# Backs up all MinIO buckets to local directory
# Usage: /opt/fyona/backend/scripts/backup-minio.sh
# Requires: mc (MinIO Client) at /usr/local/bin/mc

set -uo pipefail

MC="/usr/local/bin/mc"
BACKUP_DIR="/opt/fyona/backups/minio"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${BACKUP_DIR}/backup.log"
mkdir -p "${BACKUP_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "=========================================="
log "MinIO Backup: ${TIMESTAMP}"
log "=========================================="

# Verify mc exists
if [ ! -x "${MC}" ]; then
    log "ERROR: mc (MinIO Client) not found at ${MC}"
    log "Install: curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc"
    exit 1
fi

# Verify mc alias is configured
if ! "${MC}" ls local/ >/dev/null 2>&1; then
    log "ERROR: mc alias 'local' not configured"
    log "Run: mc alias set local http://localhost:9000 ms5 Ms5_Mrold_1212"
    exit 1
fi

# List buckets
BUCKETS=$("${MC}" ls local/ 2>/dev/null | awk '{print $NF}' | grep -v '^$' || true)
BUCKET_COUNT=$(echo "${BUCKETS}" | grep -c . 2>/dev/null || echo "0")
log "Buckets found: ${BUCKET_COUNT}"

if [ "${BUCKET_COUNT}" -eq 0 ]; then
    log "No buckets to backup. MinIO is empty."
    log "=========================================="
    log "MinIO backup complete (no data to backup)"
    log "=========================================="
    exit 0
fi

# Backup each bucket
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"
mkdir -p "${BACKUP_PATH}"
TOTAL_SIZE=0

for bucket in ${BUCKETS}; do
    [ -z "${bucket}" ] && continue
    log "Backing up bucket: ${bucket}"
    "${MC}" mirror "local/${bucket}" "${BACKUP_PATH}/${bucket}/" 2>&1 | tee -a "${LOG_FILE}"
    
    BUCKET_SIZE=$(du -sb "${BACKUP_PATH}/${bucket}" 2>/dev/null | awk '{print $1}' || echo "0")
    TOTAL_SIZE=$((TOTAL_SIZE + BUCKET_SIZE))
    log "  ${bucket}: $(du -sh "${BACKUP_PATH}/${bucket}" 2>/dev/null | awk '{print $1}')"
done

log "Total backed up: $(echo "${TOTAL_SIZE}" | numfmt --to=iec 2>/dev/null || echo "${TOTAL_SIZE} bytes")"

# Apply retention (keep 7 days)
find "${BACKUP_DIR}" -maxdepth 1 -type d -name "20*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

log "=========================================="
log "MinIO backup complete!"
log "Location: ${BACKUP_PATH}/"
log "=========================================="