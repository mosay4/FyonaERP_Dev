#!/bin/bash
echo "=== POSTGRES WAL CONFIG ==="
docker exec fyona-db psql -U fyona -d fyona_erp -c "SHOW archive_mode;" -c "SHOW archive_command;" -c "SHOW wal_level;" -c "SHOW max_wal_senders;" 2>&1

echo "=== POSTGRES DATA DIR ==="
docker inspect fyona-db --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{println}}{{end}}' 2>&1

echo "=== MINIO MOUNT ==="
docker inspect fyona-minio --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{println}}{{end}}' 2>&1

echo "=== POSTGRES DATA SIZE ==="
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT pg_size_pretty(pg_database_size('fyona_erp'));" 2>&1

echo "=== POSTGRES TABLE COUNT ==="
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>&1

echo "=== MINIO BUCKETS ==="
docker exec fyona-minio mc ls local/ 2>&1

echo "=== MINIO UPLAODS SIZE ==="
docker exec fyona-minio mc find local/ --bytes 2>&1 | awk '{sum += $1} END {print "Total: " sum " bytes (" sum/1024/1024 " MB)"}'

echo "=== BACKUP SCRIPTS ==="
ls -la /opt/fyona/backend/scripts/backup*.sh 2>&1
ls -la /opt/fyona/backup.sh 2>&1

echo "=== CRONTAB ==="
crontab -l 2>&1

echo "=== B2 CONFIG ==="
cat /opt/fyona/.b2_config 2>&1

echo "=== RABBITMQ/REDIS CHECK ==="
docker inspect fyona-redis --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{println}}{{end}}' 2>&1
