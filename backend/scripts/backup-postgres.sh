#!/bin/bash
# =============================================================================
#  FYONA ERP — Production PostgreSQL Backup
# =============================================================================
#  Modes:
#    (default)  Daily logical backup (pg_dump)
#    --base     Weekly physical base backup (pg_basebackup)
#    --verify   Verify latest backup integrity
#
#  Architecture:
#    Daily pg_dump   → local + GPG + B2  (fast restore, last 7 days)
#    Weekly base     → local + GPG + B2  (PITR starting point, 4 weeks)
#    WAL archiving   → local + B2 copy   (PITR within 7 days)
#    Monthly pg_dump → B2 only           (compliance, 12 months)
#
#  Retention:
#    Daily:   7 local + 7 B2
#    Weekly:  8 local + 8 B2
#    Monthly: 12 B2
#    Base:    4 local + 12 B2
#    WAL:     7 days local, copied hourly to B2
# =============================================================================

set -uo pipefail

CONTAINER="${POSTGRES_CONTAINER:-fyona-db}"
PG_USER="${POSTGRES_USER:-fyona}"
PG_DB="${POSTGRES_DB:-fyona_erp}"
BASE_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || echo '')}"
B2_BUCKET="${BACKUP_B2_BUCKET:-fyona-backups}"
RCLONE="/usr/bin/rclone"

DAILY_RETENTION="${BACKUP_DAILY_RETENTION:-7}"
WEEKLY_RETENTION="${BACKUP_WEEKLY_RETENTION:-8}"
BASE_RETENTION="${BASE_RETENTION_LOCAL:-4}"

MODE="daily"
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    MODE="base"; shift ;;
    --monthly) MODE="monthly"; shift ;;
    --verify)  MODE="verify"; shift ;;
    *) echo "Usage: $0 [--base|--monthly|--verify]"; exit 1 ;;
  esac
done

DATE=$(date +%Y-%m-%d)
TIME=$(date +%Y%m%d_%H%M%S)
LOG="${BASE_DIR}/backup.log"
mkdir -p "${BASE_DIR}/daily" "${BASE_DIR}/weekly" "${BASE_DIR}/monthly" "${BASE_DIR}/base" "${BASE_DIR}/pre_restore"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pg-backup] $*" | tee -a "${LOG}"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! docker exec "${CONTAINER}" pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
  fail "PostgreSQL not ready"
fi
if [ -z "${GPG_PASSPHRASE}" ]; then
  log "WARN: No GPG passphrase — backups will not be encrypted"
fi

# ── VERIFY MODE ───────────────────────────────────────────────────────────────
if [ "${MODE}" = "verify" ]; then
  log "=== VERIFICATION MODE ==="
  LATEST=$(ls -t ${BASE_DIR}/daily/fyona_*.sql.gz 2>/dev/null | head -1)
  if [ -z "${LATEST}" ]; then fail "No daily backup found"; fi

  log "Verifying: ${LATEST}"

  # 1. Checksum
  if [ -f "${LATEST}.sha256" ]; then
    sha256sum -c "${LATEST}.sha256" >/dev/null 2>&1 && log "Checksum: PASS" || fail "Checksum: FAIL"
  fi

  # 2. Gzip integrity
  gzip -t "${LATEST}" 2>/dev/null && log "Gzip: PASS" || fail "Gzip: FAIL"

  # 3. Table count
  TABLES=$(zcat "${LATEST}" | grep -c 'CREATE TABLE' 2>/dev/null)
  log "Tables: ${TABLES}"
  [ "${TABLES}" -lt 1 ] && fail "No tables found"

  # 4. Size check
  SIZE=$(stat -c%s "${LATEST}")
  [ "${SIZE}" -lt 1000 ] && fail "File too small (${SIZE} bytes)"
  log "Size: ${SIZE} bytes — OK"

  log "=== VERIFICATION PASSED ==="
  exit 0
fi

# ── DAILY LOGICAL BACKUP ──────────────────────────────────────────────────────
if [ "${MODE}" = "daily" ]; then
  DEST="${BASE_DIR}/daily"
  BACKUP="${DEST}/fyona_${DATE}_${TIME}.sql.gz"
  TMP="${BACKUP}.tmp"

  log "Starting daily logical backup → ${BACKUP}"

  docker exec "${CONTAINER}" pg_dump \
    -U "${PG_USER}" -d "${PG_DB}" \
    --clean --if-exists --no-owner --no-privileges \
    2>"${TMP}.err" | gzip > "${TMP}"

  RC=${PIPESTATUS[0]}
  if [ "${RC}" -ne 0 ]; then
    cat "${TMP}.err" 2>/dev/null >> "${LOG}"
    rm -f "${TMP}" "${TMP}.err"
    fail "pg_dump failed (rc=${RC})"
  fi
  rm -f "${TMP}.err"

  [ ! -s "${TMP}" ] && rm -f "${TMP}" && fail "Empty backup"
  gzip -t "${TMP}" 2>/dev/null || { rm -f "${TMP}"; fail "Gzip corrupt"; }

  mv "${TMP}" "${BACKUP}"
  sha256sum "${BACKUP}" > "${BACKUP}.sha256"

  SIZE=$(stat -c%s "${BACKUP}")
  TABLES=$(zcat "${BACKUP}" | grep -c 'CREATE TABLE' 2>/dev/null)
  log "Backup OK: ${SIZE} bytes, ${TABLES} tables"

  # GPG encrypt
  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${BACKUP}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${BACKUP}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"
    log "Encrypted: ${ENC} ($(stat -c%s ${ENC}) bytes)"

    # Upload encrypted to B2
    B2_DEST="b2:${B2_BUCKET}/postgres/daily/$(basename ${ENC})"
    if ${RCLONE} copyto "${ENC}" "${B2_DEST}" 2>>"${LOG}"; then
      log "B2 upload OK → ${B2_DEST}"
    else
      log "WARN: B2 upload failed"
    fi
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/postgres/daily/$(basename ${ENC}.sha256)" 2>/dev/null || true

    # Remove unencrypted local after B2 upload
    rm -f "${BACKUP}" "${BACKUP}.sha256"
  fi

  # Symlink latest
  ln -sf "${BACKUP}.gpg" "${BASE_DIR}/fyona_db_latest.sql.gz.gpg" 2>/dev/null || true
fi

# ── MONTHLY LOGICAL BACKUP ────────────────────────────────────────────────────
if [ "${MODE}" = "monthly" ]; then
  DEST="${BASE_DIR}/monthly"
  BACKUP="${DEST}/fyona_${DATE}_${TIME}.sql.gz"

  log "Starting monthly logical backup → ${BACKUP}"

  docker exec "${CONTAINER}" pg_dump \
    -U "${PG_USER}" -d "${PG_DB}" \
    --clean --if-exists --no-owner --no-privileges \
    2>/dev/null | gzip > "${BACKUP}"

  [ ! -s "${BACKUP}" ] && fail "Empty backup"
  gzip -t "${BACKUP}" 2>/dev/null || fail "Gzip corrupt"

  sha256sum "${BACKUP}" > "${BACKUP}.sha256"
  SIZE=$(stat -c%s "${BACKUP}")
  TABLES=$(zcat "${BACKUP}" | grep -c 'CREATE TABLE' 2>/dev/null)
  log "Monthly backup: ${SIZE} bytes, ${TABLES} tables"

  if [ -n "${GPG_PASSPHRASE}" ]; then
    ENC="${BACKUP}.gpg"
    gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
        --symmetric --cipher-algo AES256 --output "${ENC}" "${BACKUP}" 2>>"${LOG}"
    sha256sum "${ENC}" > "${ENC}.sha256"

    ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/postgres/monthly/$(basename ${ENC})" 2>>"${LOG}" && \
      log "Monthly B2 upload OK"
    ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/postgres/monthly/$(basename ${ENC}.sha256)" 2>/dev/null || true
    rm -f "${BACKUP}" "${BACKUP}.sha256" "${ENC}" "${ENC}.sha256"
  fi
fi

# ── BASE BACKUP (physical) ────────────────────────────────────────────────────
if [ "${MODE}" = "base" ]; then
  BASE_NAME="fyona_base_${DATE}_${TIME}"
  BASE_PATH="${BASE_DIR}/base/${BASE_NAME}"

  log "Starting physical base backup → ${BASE_PATH}"

  # pg_basebackup
  docker exec "${CONTAINER}" pg_basebackup \
    -U "${PG_USER}" -D /tmp/base_backup \
    -Ft -z -P -Xs -R \
    2>>"${LOG}"

  if [ $? -eq 0 ] && docker exec "${CONTAINER}" ls /tmp/base_backup/base.tar.gz >/dev/null 2>&1; then
    mkdir -p "${BASE_PATH}"
    docker cp "${CONTAINER}:/tmp/base_backup/." "${BASE_PATH}/"
    docker exec "${CONTAINER}" rm -rf /tmp/base_backup

    ARCHIVE="${BASE_DIR}/base/${BASE_NAME}.tar.gz"
    tar -czf "${ARCHIVE}" -C "${BASE_DIR}/base" "${BASE_NAME}" 2>>"${LOG}"
    rm -rf "${BASE_PATH}"

    sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"
    SIZE=$(stat -c%s "${ARCHIVE}")
    log "Base backup: ${SIZE} bytes"

    if [ -n "${GPG_PASSPHRASE}" ]; then
      ENC="${ARCHIVE}.gpg"
      gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" \
          --symmetric --cipher-algo AES256 --output "${ENC}" "${ARCHIVE}" 2>>"${LOG}"
      sha256sum "${ENC}" > "${ENC}.sha256"
      log "Encrypted base: ${ENC}"

      ${RCLONE} copyto "${ENC}" "b2:${B2_BUCKET}/postgres/base/$(basename ${ENC})" 2>>"${LOG}" && \
        log "Base B2 upload OK"
      ${RCLONE} copyto "${ENC}.sha256" "b2:${B2_BUCKET}/postgres/base/$(basename ${ENC}.sha256)" 2>/dev/null || true
      rm -f "${ARCHIVE}" "${ARCHIVE}.sha256"
    fi
  else
    log "WARN: pg_basebackup failed. WAL archiving still provides PITR."
    docker exec "${CONTAINER}" rm -rf /tmp/base_backup 2>/dev/null || true
  fi

  # Retention: keep 4 weeks locally
  ls -1t "${BASE_DIR}/base/"fyona_base_*.tar.gz.gpg 2>/dev/null | tail -n +$((BASE_RETENTION + 1)) | xargs -r rm -f
  ls -1t "${BASE_DIR}/base/"fyona_base_*.tar.gz 2>/dev/null | tail -n +$((BASE_RETENTION + 1)) | xargs -r rm -f
fi

# ── RETENTION (local) ────────────────────────────────────────────────────────
ls -1t "${BASE_DIR}/daily/"fyona_*.sql.gz.gpg 2>/dev/null | tail -n +$((DAILY_RETENTION + 1)) | xargs -r rm -f
ls -1t "${BASE_DIR}/daily/"fyona_*.sql.gz 2>/dev/null | tail -n +$((DAILY_RETENTION + 1)) | xargs -r rm -f
ls -1t "${BASE_DIR}/daily/"fyona_*.sha256 2>/dev/null | tail -n +$((DAILY_RETENTION + 1)) | xargs -r rm -f
ls -1t "${BASE_DIR}/weekly/"fyona_*.sql.gz.gpg 2>/dev/null | tail -n +$((WEEKLY_RETENTION + 1)) | xargs -r rm -f
ls -1t "${BASE_DIR}/weekly/"fyona_*.sql.gz 2>/dev/null | tail -n +$((WEEKLY_RETENTION + 1)) | xargs -r rm -f
ls -1t "${BASE_DIR}/weekly/"fyona_*.sha256 2>/dev/null | tail -n +$((WEEKLY_RETENTION + 1)) | xargs -r rm -f

# WAL retention (7 days)
find "${BASE_DIR}/wal" -name '0*' -mtime +7 -delete 2>/dev/null || true

log "Backup complete (${MODE})."
