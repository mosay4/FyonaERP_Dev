#!/bin/bash
# =============================================================================
#  FYONA ERP — Backup Cron Setup
# =============================================================================
#  Installs all backup-related cron jobs for:
#    - PostgreSQL daily/weekly/monthly backups
#    - WAL hourly sync to B2
#    - MinIO daily/weekly/monthly backups
#    - Config daily backup
#    - Weekly verification
#
#  Usage:
#    /opt/fyona/backend/scripts/setup-backup-cron.sh
#    /opt/fyona/backend/scripts/setup-backup-cron.sh --dry-run
# =============================================================================

set -uo pipefail

DRY_RUN="no"
[ "${1:-}" = "--dry-run" ] && DRY_RUN="yes"

BACKUP_DIR="/opt/fyona/backups"
SCRIPTS_DIR="/opt/fyona/backend/scripts"
LOG="${BACKUP_DIR}/cron_setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron-setup] $*"; }

log "══════════════════════════════════════"
log "FYONA ERP — Backup Cron Setup"
log "══════════════════════════════════════"

# ── Check prerequisites ──────────────────────────────────────────────────────
if [ ! -f "/opt/fyona/.backup-encryption-key" ]; then
  log "ERROR: Encryption key not found at /opt/fyona/.backup-encryption-key"
  exit 1
fi

for script in backup-postgres.sh backup-minio.sh backup-offsite.sh backup-config.sh verify-backup.sh; do
  if [ ! -x "${SCRIPTS_DIR}/${script}" ]; then
    log "ERROR: Script not found or not executable: ${SCRIPTS_DIR}/${script}"
    exit 1
  fi
done

log "All scripts found."

# ── Build new crontab ─────────────────────────────────────────────────────────
# Start with existing crontab (preserving non-FYONA entries)
EXISTING=$(crontab -l 2>/dev/null | grep -v "FYONA ERP" | grep -v "backup-postgres\|backup-minio\|backup-offsite\|backup-config\|verify-backup\|WAL archive" | grep -v "^$" || true)

# Build FYONA cron section
CRON_SECTION=$(cat << 'CRON_HEADER'
# ══════════════════════════════════════════════════════════════
# FYONA ERP — Production Backup Cron Jobs
# ══════════════════════════════════════════════════════════════

# PostgreSQL: Daily logical backup (encrypted) at 02:30
30 2 * * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-postgres.sh >> /opt/fyona/backups/backup.log 2>&1

# PostgreSQL: Weekly physical base backup (Sunday 03:00)
0 3 * * 0 BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-postgres.sh --base >> /opt/fyona/backups/backup.log 2>&1

# PostgreSQL: Monthly logical backup (1st of month 04:00)
0 4 1 * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-postgres.sh --monthly >> /opt/fyona/backups/backup.log 2>&1

# PostgreSQL: Weekly verification (Sunday 06:00)
0 6 * * 0 BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/verify-backup.sh >> /opt/fyona/backups/verify.log 2>&1

# MinIO: Daily incremental backup at 03:00
0 3 * * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-minio.sh >> /opt/fyona/backups/minio_backup.log 2>&1

# MinIO: Weekly full backup (Sunday 03:30)
30 3 * * 0 BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-minio.sh --full >> /opt/fyona/backups/minio_backup.log 2>&1

# MinIO: Monthly backup (1st of month 04:30)
30 4 1 * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-minio.sh --monthly >> /opt/fyona/backups/minio_backup.log 2>&1

# Off-site: WAL sync + config backup (every hour at :15)
15 * * * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backend/scripts/backup-offsite.sh >> /opt/fyona/backups/offsite.log 2>&1

# WAL local cleanup (daily 01:00, keep 7 days)
0 1 * * * find /opt/fyona/backups/wal -name '0*' -mtime +7 -delete 2>/dev/null

# ══════════════════════════════════════════════════════════════
CRON_HEADER
)

# Combine
NEW_CRONTAB="${EXISTING}
${CRON_SECTION}"

if [ "${DRY_RUN}" = "yes" ]; then
  log "DRY RUN — would install:"
  echo "${NEW_CRONTAB}"
  exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "${NEW_CRONTAB}" | crontab -

log "Crontab installed successfully."
log ""
log "Installed jobs:"
crontab -l | grep -E "backup-|verify-|WAL archive|FYONA" || echo "(none found)"
log ""
log "Verify with: crontab -l"
