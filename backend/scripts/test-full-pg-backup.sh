#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/backup-postgres.sh 2>&1 | tee /tmp/pg_backup_test.log
echo "=== B2 CONTENTS ==="
rclone ls b2:fyona-backups/postgres/daily/ 2>&1
echo "=== LOCAL FILES ==="
ls -la /opt/fyona/backups/daily/ 2>&1
