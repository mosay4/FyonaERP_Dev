#!/bin/bash
# =============================================================================
#  FYONA ERP — Off-site Backup Orchestrator
# =============================================================================
#  Uploads WAL segments + config files to Backblaze B2 for PITR and DR.
#  Runs hourly via cron.
#
#  What it uploads:
#    1. New WAL segments (for PITR within 7 days)
#    2. Config backup (env, compose, migrations)
#
#  It does NOT re-upload daily/monthly backups — those are handled by
#  backup-postgres.sh directly.
#
#  Cron:
#    15 * * * * /opt/fyona/backend/scripts/backup-offsite.sh >> /opt/fyona/backups/offsite.log 2>&1
# =============================================================================

set -uo pipefail

BASE_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/bin/rclone"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
LOG="${BASE_DIR}/offsite.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [offsite] $*" | tee -a "${LOG}"; }

log "=== Starting off-site sync ==="

# ── 1. Upload WAL segments (for PITR) ────────────────────────────────────────
WAL_DIR="${BASE_DIR}/wal"
WAL_UPLOADED=0
WAL_SKIPPED=0

if [ -d "${WAL_DIR}" ]; then
  for wal in "${WAL_DIR}"/0*; do
    [ -z "${wal}" ] && continue
    [ -f "${wal}" ] || continue
    WAL_NAME=$(basename "${wal}")

    # Check if already on B2
    if ${RCLONE} check "${wal}" "b2:${B2_BUCKET}/postgres/wal/${WAL_NAME}" 2>/dev/null; then
      WAL_SKIPPED=$((WAL_SKIPPED + 1))
      continue
    fi

    # Upload WAL file
    if ${RCLONE} copyto "${wal}" "b2:${B2_BUCKET}/postgres/wal/${WAL_NAME}" 2>>"${LOG}"; then
      WAL_UPLOADED=$((WAL_UPLOADED + 1))
    else
      log "WARN: WAL upload failed: ${WAL_NAME}"
    fi
  done
  log "WAL: ${WAL_UPLOADED} uploaded, ${WAL_SKIPPED} skipped"
else
  log "WARN: WAL directory not found"
fi

# ── 2. Config backup ─────────────────────────────────────────────────────────
CONFIG_DIR="${BASE_DIR}/config"
mkdir -p "${CONFIG_DIR}"
CONFIG_FILE="${CONFIG_DIR}/fyona_config_${TIMESTAMP}.tar.gz"

cd /opt/fyona || exit 1

tar -czf "${CONFIG_FILE}" \
  --exclude='*.log' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='*.egg-info' \
  --exclude='.venv' \
  backend/.env.production \
  backend/docker-compose.yml \
  backend/docker-compose.prod.yml \
  backend/alembic.ini \
  backend/alembic/ \
  backend/app/core/version.py \
  backend/app/main.py \
  backend/scripts/ \
  backend/requirements.txt \
  2>>"${LOG}"

if [ -s "${CONFIG_FILE}" ]; then
  sha256sum "${CONFIG_FILE}" > "${CONFIG_FILE}.sha256"

  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${CONFIG_FILE}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${CONFIG_FILE}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/config/$(basename ${ENC})" 2>>"${LOG}" && \
      log "Config B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/config/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}.sha256" "${ENC}" "${ENC}.sha256"
  else
    ${RCLONE} copyto "${CONFIG_FILE}" "b2:${B2_BUCKET}/config/$(basename ${CONFIG_FILE})" 2>>"${LOG}" && \
      log "Config B2 upload OK"
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}.sha256"
  fi
else
  log "WARN: Config backup empty"
fi

# ── 3. Cleanup old local config backups (keep 7 days) ─────────────────────────
find "${CONFIG_DIR}" -name "fyona_config_*.tar.gz*" -mtime +7 -delete 2>/dev/null || true

# ── 4. B2 WAL retention (7 days) ─────────────────────────────────────────────
${RCLONE} delete "b2:${B2_BUCKET}/postgres/wal/" --min-age=168h 2>/dev/null || true

log "=== Off-site sync complete ==="
