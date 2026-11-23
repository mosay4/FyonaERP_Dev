#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/backup-config.sh 2>&1
echo "=== B2 CONFIG CONTENTS ==="
rclone ls b2:fyona-backups/config/ 2>&1
