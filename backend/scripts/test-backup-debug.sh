#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)

# Run the backup script with verbose output
/opt/fyona/backend/scripts/backup-postgres.sh 2>&1 | grep -E "B2|upload|WARN|ERROR"

echo "=== Check B2 contents ==="
rclone ls b2:fyona-backups/postgres/daily/ 2>&1
