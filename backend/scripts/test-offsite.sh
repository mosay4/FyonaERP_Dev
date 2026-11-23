#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/backup-offsite.sh 2>&1
echo "=== B2 WAL CONTENTS ==="
rclone ls b2:fyona-backups/postgres/wal/ 2>&1
