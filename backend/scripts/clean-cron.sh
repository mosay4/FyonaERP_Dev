#!/bin/bash
# Clean old FYONA entries and install fresh crontab
EXISTING=$(crontab -l 2>/dev/null | grep -v "FYONA ERP\|backup-postgres\|backup-minio\|backup-offsite\|backup-config\|verify-backup\|Daily PostgreSQL\|Daily MinIO\|Weekly backup\|WAL archive" | grep -v "^$" || true)

CRON_SECTION='
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
0 1 * * * find /opt/fyona/backups/wal -name 0* -mtime +7 -delete 2>/dev/null
'

echo "${EXISTING}${CRON_SECTION}" | crontab -
echo "Crontab installed. Listing:"
crontab -l | grep -E "FYONA|backup-|verify-|WAL|find.*wal" | head -15
