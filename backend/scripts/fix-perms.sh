#!/bin/bash
echo "=== Setting permissions ==="
chmod +x /opt/fyona/backend/scripts/backup-postgres.sh
chmod +x /opt/fyona/backend/scripts/backup-offsite.sh
chmod +x /opt/fyona/backend/scripts/backup-minio.sh
chmod +x /opt/fyona/backend/scripts/backup-config.sh
chmod +x /opt/fyona/backend/scripts/verify-backup.sh
chmod +x /opt/fyona/backend/scripts/restore-pg.sh
chmod +x /opt/fyona/backend/scripts/setup-backup-cron.sh

echo "=== Syntax check ==="
for f in backup-postgres.sh backup-offsite.sh backup-minio.sh backup-config.sh verify-backup.sh restore-pg.sh setup-backup-cron.sh; do
  if bash -n "/opt/fyona/backend/scripts/${f}" 2>&1; then
    echo "${f}: OK"
  else
    echo "${f}: SYNTAX ERROR"
  fi
done
