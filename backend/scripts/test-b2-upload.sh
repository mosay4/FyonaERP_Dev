#!/bin/bash
echo "=== Testing B2 upload of encrypted backup ==="
LATEST=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
echo "Latest: $LATEST"
if [ -n "$LATEST" ]; then
  FNAME=$(basename "$LATEST")
  echo "Uploading: $FNAME"
  rclone copyto "$LATEST" "b2:fyona-backups/postgres/daily/$FNAME" 2>&1
  echo "Upload RC: $?"
  echo "B2 contents:"
  rclone ls b2:fyona-backups/postgres/daily/ 2>&1
else
  echo "No encrypted backup found"
fi
