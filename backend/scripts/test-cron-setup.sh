#!/bin/bash
/opt/fyona/backend/scripts/setup-backup-cron.sh 2>&1
echo "=== FINAL CRONTAB ==="
crontab -l 2>&1
