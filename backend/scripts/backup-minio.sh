#!/bin/bash
# =============================================================================
#  FYONA ERP — Production MinIO Backup
# =============================================================================
#  Modes:
#    (default)  Daily incremental mirror
#    --full     Weekly full mirror + compress + encrypt + B2
#    --monthly  Monthly full + B2 (compliance)
#
#  Architecture:
#    Versioning: enabled on all buckets (version history preserved)
#    Daily:   mc mirror → local (7 days) → B2 encrypted
#    Weekly:  mc mirror → tar.gz + GPG → B2 (8 weeks)
#    Monthly: tar.gz + GPG → B2 (12 months)
# =============================================================================

set -uo pipefail

CONTAINER="${MINIO_CONTAINER:-fyona-minio}"
MC="/usr/local/bin/mc"
BACKUP_DIR="${BACKUP_DIR:-/opt/fyona/backups/minio}"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/bin/rclone"

MODE="daily"
while [ $# -gt 0 ]; do
  case "$1" in
    --full)    MODE="weekly"; shift ;;
    --monthly) MODE="monthly"; shift ;;
    *) echo "Usage: $0 [--full|--monthly]"; exit 1 ;;
  esac
done

DATE=$(date +%Y-%m-%d)
TIME=$(date +%Y%m%d_%H%M%S)
LOG="${BACKUP_DIR}/backup.log"
mkdir -p "${BACKUP_DIR}/daily" "${BACKUP_DIR}/weekly" "${BACKUP_DIR}/monthly"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [minio-backup] $*" | tee -a "${LOG}"; }
fail() { log "ERROR: $*"; exit 1; }

log "=== Starting MinIO backup (mode: ${MODE}) ==="

# ── Prerequisites ─────────────────────────────────────────────────────────────
if [ ! -x "${MC}" ]; then fail "mc not found at ${MC}"; fi

# Ensure mc alias is configured
if ! ${MC} ls local/ >/dev/null 2>&1; then
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-ms5}"
  MINIO_ROOT_PASS="${MINIO_ROOT_PASSWORD:-Ms5_Mrold_1212}"
  ${MC} alias set local "http://localhost:9000" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASS}" >/dev/null 2>&1
fi

# ── Enable versioning on all buckets ──────────────────────────────────────────
BUCKETS=$(${MC} ls local/ 2>/dev/null | awk '{print $NF}' | grep -v '^$' || true)
BUCKET_COUNT=$(echo "${BUCKETS}" | grep -c . 2>/dev/null || echo 0)
BUCKET_COUNT=$(echo "${BUCKET_COUNT}" | tr -d '[:space:]')
log "Buckets found: ${BUCKET_COUNT}"

if [ "${BUCKET_COUNT}" = "0" ]; then
  log "MinIO is empty — skipping backup."
  log "=== MinIO backup complete (no data) ==="
  exit 0
fi

for bucket in ${BUCKETS}; do
  [ -z "${bucket}" ] && continue
  ${MC} version enable "local/${bucket}" >/dev/null 2>&1
done

# ── DAILY: incremental mirror + B2 ────────────────────────────────────────────
if [ "${MODE}" = "daily" ]; then
  MIRROR_PATH="${BACKUP_DIR}/daily/${DATE}"
  log "Daily mirror → ${MIRROR_PATH}"

  for bucket in ${BUCKETS}; do
    [ -z "${bucket}" ] && continue
    mkdir -p "${MIRROR_PATH}/${bucket}"
    ${MC} mirror --overwrite "local/${bucket}" "${MIRROR_PATH}/${bucket}/" >>"${LOG}" 2>&1
    log "  ${bucket}: $(du -sh "${MIRROR_PATH}/${bucket}" 2>/dev/null | awk '{print $1}')"
  done

  TOTAL=$(du -sh "${MIRROR_PATH}" 2>/dev/null | awk '{print $1}')
  log "Daily backup: ${TOTAL}"

  # Upload to B2 (encrypted tar.gz)
  if [ -n "${GPG_PASSPHRASE}" ]; then
    ARCHIVE="${BACKUP_DIR}/daily/fyona_minio_${DATE}.tar.gz"
    tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}/daily" "${DATE}" 2>>"${LOG}"
    ENC="${ARCHIVE}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${ARCHIVE}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/minio/daily/$(basename ${ENC})" 2>>"${LOG}" && \
      log "B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/minio/daily/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${ARCHIVE}" "${ENC}" "${ENC}.sha256"
  fi

  # Retention: keep 7 days locally
  find "${BACKUP_DIR}/daily" -maxdepth 1 -type d -name "20*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true
fi

# ── WEEKLY: full + compress + encrypt + B2 ────────────────────────────────────
if [ "${MODE}" = "weekly" ]; then
  WEEK_NAME="fyona_minio_${DATE}_${TIME}"
  WEEK_PATH="${BACKUP_DIR}/weekly/${WEEK_NAME}"

  log "Weekly full backup → ${WEEK_PATH}"
  mkdir -p "${WEEK_PATH}"

  for bucket in ${BUCKETS}; do
    [ -z "${bucket}" ] && continue
    ${MC} mirror "local/${bucket}" "${WEEK_PATH}/${bucket}/" >>"${LOG}" 2>&1
    log "  ${bucket}: $(du -sh "${WEEK_PATH}/${bucket}" 2>/dev/null | awk '{print $1}')"
  done

  # Compress
  ARCHIVE="${BACKUP_DIR}/weekly/${WEEK_NAME}.tar.gz"
  tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}/weekly" "${WEEK_NAME}" 2>>"${LOG}"
  rm -rf "${WEEK_PATH}"

  SIZE=$(stat -c%s "${ARCHIVE}" 2>/dev/null || echo 0)
  log "Archive: ${ARCHIVE} (${SIZE} bytes)"

  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${ARCHIVE}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${ARCHIVE}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/minio/weekly/$(basename ${ENC})" 2>>"${LOG}" && \
      log "B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/minio/weekly/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${ARCHIVE}" "${ENC}" "${ENC}.sha256"
  fi

  # Retention: 8 weeks locally
  find "${BACKUP_DIR}/weekly" -maxdepth 1 -name "*.tar.gz*" -mtime +56 -delete 2>/dev/null || true
  find "${BACKUP_DIR}/weekly" -maxdepth 1 -type d -name "fyona_minio_*" -mtime +56 -exec rm -rf {} + 2>/dev/null || true
fi

# ── MONTHLY: full + B2 ────────────────────────────────────────────────────────
if [ "${MODE}" = "monthly" ]; then
  MONTH_NAME="fyona_minio_${DATE}"
  log "Monthly backup → ${MONTH_NAME}"

  MIRROR_PATH="${BACKUP_DIR}/monthly/${MONTH_NAME}"
  mkdir -p "${MIRROR_PATH}"

  for bucket in ${BUCKETS}; do
    [ -z "${bucket}" ] && continue
    ${MC} mirror "local/${bucket}" "${MIRROR_PATH}/${bucket}/" >>"${LOG}" 2>&1
  done

  ARCHIVE="${BACKUP_DIR}/monthly/${MONTH_NAME}.tar.gz"
  tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}/monthly" "${MONTH_NAME}" 2>>"${LOG}"
  rm -rf "${MIRROR_PATH}"

  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${ARCHIVE}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${ARCHIVE}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/minio/monthly/$(basename ${ENC})" 2>>"${LOG}" && \
      log "Monthly B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/minio/monthly/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${ARCHIVE}" "${ENC}" "${ENC}.sha256"
  fi
fi

log "=== MinIO backup complete (${MODE}) ==="
