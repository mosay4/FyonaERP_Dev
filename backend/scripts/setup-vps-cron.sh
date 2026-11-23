#!/bin/bash
# FYONA ERP — VPS Cron Installation Script
# Preserves non-FYONA cron entries, replaces FYONA entries
set -uo pipefail

# ─── Step 1: Get existing crontab (excluding FYONA entries) ─────────────────
EXISTING=$(crontab -l 2>/dev/null | grep -v '/opt/fyona/backup.sh' | grep -v 'FYONA ERP' || true)

# ─── Step 2: Write new crontab to temp file ────────────────────────────────
TMPFILE=$(mktemp)

# Write existing entries first
echo "$EXISTING" > "$TMPFILE"
echo "" >> "$TMPFILE"

# FYONA backup jobs
echo "# ─── FYONA ERP Automated Backups ──" >> "$TMPFILE"
echo "# Daily PostgreSQL backup (encrypted) at 02:30" >> "$TMPFILE"
echo '30 2 * * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backup.sh >> /opt/fyona/backups/backup.log 2>&1' >> "$TMPFILE"
echo "" >> "$TMPFILE"
echo "# Daily MinIO backup at 03:00" >> "$TMPFILE"
echo '0  3 * * * /opt/fyona/backend/scripts/backup-minio.sh >> /opt/fyona/backups/minio_backup.log 2>&1' >> "$TMPFILE"
echo "" >> "$TMPFILE"
echo "# Weekly backup verification (Sunday 04:00)" >> "$TMPFILE"
echo '0  4 * * 0 LATEST=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz 2>/dev/null | head -1); if [ -n "$LATEST" ]; then gzip -t "$LATEST" 2>>/opt/fyona/backups/verify.log && echo "Verify OK: $LATEST" >> /opt/fyona/backups/verify.log || echo "Verify FAIL: $LATEST" >> /opt/fyona/backups/verify.log; fi' >> "$TMPFILE"
echo "" >> "$TMPFILE"
echo "# WAL archive cleanup (daily 01:00, keep 7 days)" >> "$TMPFILE"
echo '0  1 * * * find /opt/fyona/backups/wal -name '\''0*'\'' -mtime +7 -delete 2>/dev/null' >> "$TMPFILE"

# ─── Step 3: Install crontab ────────────────────────────────────────────────
crontab "$TMPFILE"
rm -f "$TMPFILE"

# ─── Step 4: Verify ────────────────────────────────────────────────────────
echo "Cron jobs installed. Current crontab:"
crontab -l
