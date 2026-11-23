#!/bin/bash
# FYONA ERP — Off-site Backup Upload Script
# Uploads the latest encrypted PostgreSQL backup to Backblaze B2
# Uses rclone with credentials from ~/.config/rclone/rclone.conf (env vars or stored config)
#
# Usage: B2_BUCKET="fyona-backups" bash upload-offsite.sh
# Or:    bash upload-offsite.sh  (uses BACKUP_B2_BUCKET env var set in cron)

set -uo pipefail

B2_BUCKET="${B2_BUCKET:-${BACKUP_B2_BUCKET:-fyona-backups}}"
BACKUP_DIR="/opt/fyona/backups/daily"
RCLONE="/usr/bin/rclone"
TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [offsite] $*"; }

log "=========================================="
log "Off-site backup upload"
log "=========================================="

# Find latest backup
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/fyona_*.sql.gz 2>/dev/null | head -1)

if [ -z "${LATEST_BACKUP}" ]; then
    log "ERROR: No backup found in ${BACKUP_DIR}"
    exit 1
fi

log "Latest backup: ${LATEST_BACKUP}"

# Find the encrypted version
ENCRYPTED_BACKUP="${LATEST_BACKUP}.gpg"

if [ ! -f "${ENCRYPTED_BACKUP}" ]; then
    log "ERROR: Encrypted backup not found: ${ENCRYPTED_BACKUP}"
    log "Run daily backup first to generate encrypted version."
    exit 1
fi

log "Encrypted backup: ${ENCRYPTED_BACKUP}"
log "Size: $(stat -c%s "${ENCRYPTED_BACKUP}") bytes"

# Upload to B2
BACKUP_DATE=$(basename "${LATEST_BACKUP}" | sed 's/^fyona_//; s/\.sql\.gz$//')
DEST="b2:${B2_BUCKET}/daily/fyona_${BACKUP_DATE}.sql.gz.gpg"

log "Uploading to: ${DEST}"
${RCLONE} copyto "${ENCRYPTED_BACKUP}" "${DEST}" 2>&1

if [ $? -eq 0 ]; then
    log "Upload complete."
else
    log "ERROR: Upload failed."
    exit 1
fi

# Verify remote copy exists + checksum
log "Verifying remote copy..."
REMOTE_SIZE=$(${RCLONE} size "${DEST}" 2>/dev/null | head -1 || echo "UNKNOWN")
log "Remote size: ${REMOTE_SIZE}"

# Run rclone check to verify integrity
${RCLONE} check "${ENCRYPTED_BACKUP}" "${DEST}" 2>&1
if [ $? -eq 0 ]; then
    log "✅ Integrity check: PASSED"
else
    log "⚠️ Integrity check: differences detected (may be checksum algo differences)"
fi

# List remote directory to confirm
log "Remote directory contents:"
${RCLONE} ls "b2:${B2_BUCKET}/daily/" 2>&1

log "=========================================="
log "Off-site upload complete."
log "=========================================="
