#!/bin/bash
echo "═══════════════════════════════════════════"
echo "FYONA ERP — VPS AUDIT"
echo "Date: $(date)"
echo "═══════════════════════════════════════════"

echo ""
echo "── 1. POSTGRESQL WAL CONFIG ──"
docker exec fyona-db psql -U fyona -d fyona_erp -c "SHOW archive_mode;" -c "SHOW archive_command;" -c "SHOW wal_level;" -c "SHOW max_wal_senders;" -c "SHOW max_replication_slots;" 2>&1

echo ""
echo "── 2. POSTGRESQL DATA SIZE ──"
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT pg_size_pretty(pg_database_size('fyona_erp'));" 2>&1
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT count(*) as tables FROM information_schema.tables WHERE table_schema='public';" 2>&1

echo ""
echo "── 3. DOCKER VOLUMES ──"
docker volume ls 2>&1

echo ""
echo "── 4. DOCKER MOUNTS (FYONA containers) ──"
for c in fyona-db fyona-api fyona-minio fyona-redis; do
  echo "[$c]"
  docker inspect "$c" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{println}}{{end}}' 2>&1
done

echo ""
echo "── 5. DISK USAGE ──"
df -h / 2>&1
echo "---"
echo "Docker:"
docker system df 2>&1

echo ""
echo "── 6. EXISTING BACKUPS ──"
ls -la /opt/fyona/backups/ 2>&1
echo "--- daily ---"
ls -la /opt/fyona/backups/daily/ 2>&1
echo "--- weekly ---"
ls -la /opt/fyona/backups/weekly/ 2>&1
echo "--- WAL ---"
ls -la /opt/fyona/backups/wal/ 2>&1
echo "--- minio ---"
ls -la /opt/fyona/backups/minio/ 2>&1
echo "--- base ---"
ls -la /opt/fyona/backups/base/ 2>&1 || echo "(no base dir)"

echo ""
echo "── 7. CRONTAB ──"
crontab -l 2>&1

echo ""
echo "── 8. ENCRYPTION KEY ──"
ls -la /opt/fyona/.backup-encryption-key 2>&1
cat /opt/fyona/.backup-encryption-key 2>&1

echo ""
echo "── 9. B2 CONFIG ──"
rclone config show 2>&1
echo "--- B2 buckets ---"
rclone lsd b2: 2>&1
echo "--- B2 contents ---"
rclone ls b2: 2>&1 || echo "(empty)"

echo ""
echo "── 10. MC (MinIO Client) ──"
which mc 2>&1
mc alias list 2>&1 || echo "no aliases"
echo "--- MinIO buckets ---"
mc ls local/ 2>&1 || echo "(empty or alias not configured)"

echo ""
echo "── 11. RCLONE VERSION ──"
rclone version 2>&1 | head -3

echo ""
echo "── 12. EXISTING BACKUP SCRIPTS ──"
ls -la /opt/fyona/backup.sh /opt/fyona/restore.sh 2>&1
ls -la /opt/fyona/backend/scripts/backup*.sh 2>&1
ls -la /opt/fyona/backend/scripts/restore*.sh 2>&1
ls -la /opt/fyona/backend/scripts/verify*.sh 2>&1

echo ""
echo "═══════════════════════════════════════════"
echo "AUDIT COMPLETE"
echo "═══════════════════════════════════════════"
