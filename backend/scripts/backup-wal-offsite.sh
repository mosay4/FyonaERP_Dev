#!/bin/bash
# =============================================================================
#  FYONA ERP — Off-site WAL Upload Script
# =============================================================================
#  Uploads PostgreSQL WAL segments to Backblaze B2 for PITR recovery.
#  This runs hourly to keep B2 synchronized with local WAL archive.
#
#  Only NEW WAL files are uploaded (based on modification time / file existence
#  on B2). Uses rclone check to avoid re-uploading.
#
#  Cron (hourly):
#    15 * * * * /opt/fyona/backend/scripts/backup-wal-offsite.sh >> /opt/fyona/backups/wal_offsite.log 2>&1
# =============================================================================

set -uo pipefail

WAL_LOCAL_DIR="${BACKUP_DIR:-/opt/fyona/backups}/wal"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/local/bin/rclone"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/opt/fyona/backups/wal_offsite.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [wal-offsite] $*" | tee -a "${LOG_FILE}"
}

log "Starting WAL off-site upload..."

if [ ! -d "${WAL_LOCAL_DIR}" ]; then
  log "ERROR: WAL directory not found: ${WAL_LOCAL_DIR}"
  exit 1
fi

WAL_COUNT=$(find "${WAL_LOCAL_DIR}" -type f -name '0*' | wc -l)
log "Local WAL files: ${WAL_COUNT}"

if [ "${WAL_COUNT}" -eq 0 ]; then
  log "No WAL files to upload."
  exit 0
fi

# Upload each WAL file individually (for PITR granularity)
UPLOADED=0
SKIPPED=0
FAILED=0

for wal_file in "${WAL_LOCAL_DIR}"/0*; do
  [ -z "${wal_file}" ] && continue
  [ -f "${wal_file}" ] || continue

  WAL_NAME=$(basename "${wal_file}")
  B2_PATH="b2:${B2_BUCKET}/wal/${WAL_NAME}"

  # Check if already on B2
  if ${RCLONE} check "${wal_file}" "${B2_PATH}" 2>/dev/null; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Upload (encrypt first if GPG passphrase is set)
  if [ -n "${GPG_PASSPHRASE}" ]; then
    TMP_ENC=$(mktemp)
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 \
        --output "${TMP_ENC}" \
        "${wal_file}" 2>/dev/null

    if ${RCLONE} copyto "${TMP_ENC}" "b2:${B2_BUCKET}/wal/${WAL_NAME}.gpg" 2>>"${LOG_FILE}"; then
      UPLOADED=$((UPLOADED + 1))
      log "  uploaded: ${WAL_NAME}.gpg"
    else
      FAILED=$((FAILED + 1))
      log "  FAILED: ${WAL_NAME}"
    fi
    rm -f "${TMP_ENC}"
  else
    if ${RCLONE} copyto "${wal_file}" "${B2_PATH}" 2>>"${LOG_FILE}"; then
      UPLOADED=$((UPLOADED + 1))
      log "  uploaded: ${WAL_NAME}"
    else
      FAILED=$((FAILED + 1))
      log "  FAILED: ${WAL_NAME}"
    fi
  fi
done

log "WAL off-site upload complete: ${UPLOADED} uploaded, ${SKIPPED} skipped, ${FAILED} failed."

# Retention on B2: keep WAL files for 7 days
${RCLONE} delete "b2:${B2_BUCKET}/wal/" --min-age=168h 2>/dev/null || true

log "Done."
