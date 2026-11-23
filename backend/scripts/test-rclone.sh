#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)

# Test the exact rclone command from the script
LATEST_ENC=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
echo "Latest encrypted: $LATEST_ENC"

FNAME=$(basename "$LATEST_ENC")
echo "Filename: $FNAME"

B2_BUCKET="fyona-backups"
B2_DEST="b2:${B2_BUCKET}/postgres/daily/${FNAME}"
echo "B2 destination: $B2_DEST"

echo "=== Testing rclone copyto ==="
rclone copyto "$LATEST_ENC" "$B2_DEST" 2>&1
echo "RC: $?"

echo "=== B2 contents ==="
rclone ls b2:fyona-backups/postgres/daily/ 2>&1
