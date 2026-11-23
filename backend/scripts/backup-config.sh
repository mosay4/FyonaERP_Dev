#!/bin/bash
# =============================================================================
#  FYONA ERP — Configuration Backup
# =============================================================================
#  Backs up critical FYONA configuration for DR:
#    - Database migrations (alembic/)
#    - .env.production
#    - docker-compose.yml / docker-compose.prod.yml
#    - Dockerfiles
#    - Deploy scripts
#    - Alembic config
#    - version.py
#
#  This is separate from PostgreSQL/MinIO because it protects the ability
#  to REBUILD the application on a new VPS.
#
#  Cron:
#    0 5 * * * /opt/fyona/backend/scripts/backup-config.sh >> /opt/fyona/backups/config.log 2>&1
# =============================================================================

set -uo pipefail

BASE_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/bin/rclone"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
BACKEND_DIR="/opt/fyona/backend"
LOG="${BASE_DIR}/config.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [config-backup] $*" | tee -a "${LOG}"; }

log "=== Starting config backup ==="

CONFIG_DIR="${BASE_DIR}/config"
mkdir -p "${CONFIG_DIR}"

# ── Collect config files ──────────────────────────────────────────────────────
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
  --exclude='venv' \
  --exclude='*.sql' \
  --exclude='*.sql.gz' \
  --exclude='*.sql.gz.gpg' \
  --exclude='uploads/*' \
  --exclude='backups/*' \
  backend/.env.production \
  backend/Dockerfile \
  backend/docker-compose.yml \
  backend/docker-compose.prod.yml \
  backend/alembic.ini \
  backend/alembic/ \
  backend/app/core/version.py \
  backend/app/main.py \
  backend/scripts/ \
  backend/requirements.txt \
  backend/tests/ \
  backend/.github/ \
  2>>"${LOG}"

if [ -s "${CONFIG_FILE}" ]; then
  SIZE=$(stat -c%s "${CONFIG_FILE}")
  sha256sum "${CONFIG_FILE}" > "${CONFIG_FILE}.sha256"
  log "Config backup: ${CONFIG_FILE} (${SIZE} bytes)"

  # Upload to B2
  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${CONFIG_FILE}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${CONFIG_FILE}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/config/$(basename ${ENC})" 2>>"${LOG}" && \
      log "B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/config/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}.sha256" "${ENC}" "${ENC}.sha256"
  else
    ${RCLONE} copyto "${CONFIG_FILE}" "b2:${B2_BUCKET}/config/$(basename ${CONFIG_FILE})" 2>>"${LOG}" && \
      log "B2 upload OK"
    rm -f "${CONFIG_FILE}" "${CONFIG_FILE}.sha256"
  fi
else
  log "WARN: Config backup empty"
fi

# Retention: keep 7 days locally
find "${CONFIG_DIR}" -name "fyona_config_*.tar.gz*" -mtime +7 -delete 2>/dev/null || true

log "=== Config backup complete ==="
