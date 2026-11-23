#!/bin/bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)

# Run backup with verbose rclone
BACKUP_DIR="/opt/fyona/backups"
CONTAINER="fyona-db"
PG_USER="fyona"
PG_DB="fyona_erp"
B2_BUCKET="fyona-backups"
RCLONE="/usr/local/bin/rclone"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%Y%m%d_%H%M%S)
BACKUP="${BACKUP_DIR}/daily/fyona_${DATE}_${TIME}.sql.gz"

echo "=== 1. pg_dump ==="
docker exec "${CONTAINER}" pg_dump -U "${PG_USER}" -d "${PG_DB}" --clean --if-exists --no-owner --no-privileges 2>/dev/null | gzip > "${BACKUP}"
echo "Backup: ${BACKUP} ($(stat -c%s ${BACKUP}) bytes)"

echo "=== 2. Encrypt ==="
ENC="${BACKUP}.gpg"
gpg --batch --yes --passphrase "${BACKUP_GPG_PASSPHRASE}" --symmetric --cipher-algo AES256 --output "${ENC}" "${BACKUP}" 2>&1
echo "Encrypted: ${ENC} ($(stat -c%s ${ENC}) bytes)"

echo "=== 3. rclone debug ==="
B2_DEST="b2:${B2_BUCKET}/postgres/daily/$(basename ${ENC})"
echo "Source: ${ENC}"
echo "Dest: ${B2_DEST}"
echo "Source exists: $([ -f ${ENC} ] && echo yes || echo no)"

# Try upload with verbose
rclone -vv copyto "${ENC}" "${B2_DEST}" 2>&1
echo "RC: $?"

echo "=== 4. Verify B2 ==="
rclone ls b2:fyona-backups/postgres/daily/ 2>&1

# Cleanup
rm -f "${BACKUP}" "${ENC}" "${ENC}.sha256"
