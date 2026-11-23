#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/verify-backup.sh 2>&1
