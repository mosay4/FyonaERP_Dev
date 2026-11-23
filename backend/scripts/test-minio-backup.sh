#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/backup-minio.sh 2>&1
echo "=== B2 MINIO CONTENTS ==="
rclone ls b2:fyona-backups/minio/ 2>&1 || echo "(empty - MinIO has no data)"
