#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)

# Simulate what the backup script does
LATEST_ENC=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
echo "Latest encrypted: $LATEST_ENC"

B2_BUCKET="fyona-backups"
B2_DEST="b2:${B2_BUCKET}/postgres/daily/$(basename ${LATEST_ENC})"
echo "B2 destination: $B2_DEST"

echo "=== Testing with set -x ==="
set -x
rclone copyto "${LATEST_ENC}" "${B2_DEST}" 2>&1
RC=$?
set +x
echo "RC: $RC"
