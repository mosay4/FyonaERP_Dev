# FYONA ERP — Disaster Recovery Runbook

## Prerequisites
- VPS: root@YOUR_VPS_IP (set VPS_HOST env var)
- B2 bucket: `fyona-backups` (rclone configured)
- GPG key: `/opt/fyona/.backup-encryption-key`
- PostgreSQL container: `fyona-db` (user: `fyona`, db: `fyona_erp`)

---

## Scenario 1: Database Loss (Container Crash / Data Corruption)

**RTO: ~2 minutes | RPO: up to 24 hours (pg_dump) or seconds (WAL)**

### T0 — Detect
```bash
docker ps | grep fyona-db
docker logs fyona-db --tail 20
```

### T1 — Restore
```bash
# Find latest backup
ls -lt /opt/fyona/backups/daily/fyona_*.sql.gz.gpg | head -1

# Decrypt + restore (replace BACKUP_FILE with actual filename)
BACKUP_FILE=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg | head -1)
gpg --batch --yes --decrypt --passphrase-file /opt/fyona/.backup-encryption-key \
  --output /tmp/restore.sql.gz "$BACKUP_FILE"
gunzip -c /tmp/restore.sql.gz | docker exec -i fyona-db psql -U fyona -d fyona_erp
rm /tmp/restore.sql.gz
```

### T2 — Verify
```bash
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT count(*) FROM users;"
```

### T3 — Restart Services
```bash
cd /opt/fyona && docker-compose restart api
```

### T4 — Confirm
```bash
curl -s http://localhost:8000/health || curl -s http://localhost:8000/docs
```

---

## Scenario 2: Point-in-Time Recovery (PITR)

**RTO: ~5 minutes | RPO: seconds (WAL-based)**

### T0 — Identify target time
```bash
# Determine when corruption started
docker logs fyona-db --since="2h" | grep -i error
```

### T1 — Stop application
```bash
cd /opt/fyona && docker-compose stop api celery-worker celery-beat
```

### T2 — Take safety dump
```bash
docker exec fyona-db pg_dump -U fyona -d fyona_erp -Fc -f /tmp/safety_dumpFc
docker cp fyona-db:/tmp/safety_dumpFc /opt/fyona/backups/safety_dump_$(date +%Y%m%d_%H%M%S).Fc
```

### T3 — Base backup restore
```bash
LATEST_BASE=$(ls -t /opt/fyona/backups/base/fyona_base_*.tar.gz 2>/dev/null | head -1)
if [ -z "$LATEST_BASE" ]; then
    # Download from B2
    rclone copy b2:fyona-backups/postgres/base/latest/base.tar.gz /tmp/
    LATEST_BASE=/tmp/base.tar.gz
fi

# Stop DB, replace data, setup recovery
docker stop fyona-db
HOST_DATA=$(docker inspect fyona-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')
rm -rf ${HOST_DATA}/*
tar -xzf $LATEST_BASE -C ${HOST_DATA}/
```

### T4 — Configure recovery
```bash
touch ${HOST_DATA}/recovery.signal
cat > ${HOST_DATA}/postgresql.auto.conf << EOF
restore_command = 'cp /opt/fyona/backups/wal_archive/%f %p'
recovery_target_time = 'YYYY-MM-DD HH:MM:SS'
recovery_target_action = 'promote'
EOF
chown -R 999:999 ${HOST_DATA}
docker start fyona-db
```

### T5 — Verify & restart
```bash
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT count(*) FROM users;"
cd /opt/fyona && docker-compose start api celery-worker celery-beat
```

---

## Scenario 3: Full VPS Loss

**RTO: ~15 minutes | RPO: up to 24 hours**

### T0 — New VPS setup
```bash
# Provision new Ubuntu VPS with Docker + Docker Compose
apt update && apt install -y docker.io docker-compose jq curl gnupg bc
```

### T1 — Install rclone + configure B2
```bash
apt install -y rclone
cat > /root/.config/rclone/rclone.conf << 'EOF'
[b2]
type = b2
account = YOUR_B2_ACCOUNT_ID
key = YOUR_B2_APP_KEY
EOF
```

### T2 — Create encryption key
```bash
# Restore key from secure backup or create new
echo "YOUR_BACKUP_PASSPHRASE" > /opt/fyona/.backup-encryption-key
chmod 600 /opt/fyona/.backup-encryption-key
```

### T3 — Restore from B2
```bash
mkdir -p /opt/fyona/backups/daily
rclone copy b2:fyona-backups/postgres/daily/ /opt/fyona/backups/daily/
# Decrypt + restore
LATEST=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg | head -1)
gpg --batch --yes --decrypt --passphrase-file /opt/fyona/.backup-encryption-key \
  --output /tmp/restore.sql.gz "$LATEST"
gunzip -c /tmp/restore.sql.gz | docker exec -i fyona-db psql -U fyona -d fyona_erp
```

### T4 — Restore MinIO (if needed)
```bash
rclone copy b2:fyona-backups/minio/ /opt/fyona/backups/minio/
# Use mc to restore
mc mirror /opt/fyona/backups/minio/ fyona-minio/
```

### T5 — Restore config
```bash
rclone copy b2:fyona-backups/config/ /opt/fyona/backups/config/
LATEST_CONFIG=$(ls -t /opt/fyona/backups/config/fyona_config_*.tar.gz.gpg | head -1)
gpg --batch --yes --decrypt --passphrase-file /opt/fyona/.backup-encryption-key \
  --output /tmp/config.tar.gz "$LATEST_CONFIG"
tar -xzf /tmp/config.tar.gz -C /opt/fyona/
```

### T6 — Deploy application
```bash
cd /opt/fyona
git clone https://github.com/YOUR_REPO.git .
docker-compose up -d
```

### T7 — Verify
```bash
curl -s http://localhost:8000/health
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT count(*) FROM users;"
```

---

## Scenario 4: Container Failure (Non-Data)

**RTO: ~30 seconds | RPO: 0**

### T0 — Detect
```bash
docker ps -a | grep fyona
docker logs fyona-db --tail 20
```

### T1 — Restart
```bash
cd /opt/fyona && docker-compose restart
```

### T2 — If restart fails, recreate
```bash
docker-compose up -d --force-recreate db
```

### T3 — Verify
```bash
docker ps | grep fyona
curl -s http://localhost:8000/health
```

---

## Emergency Contacts
- B2 Console: https://secure.backblaze.com/b2_buckets.htm
- VPS Console: via hosting provider
- GitHub Repo: check repository settings

## Backup Inventory
- PostgreSQL daily: `/opt/fyona/backups/daily/` + B2 `postgres/daily/`
- PostgreSQL weekly: `/opt/fyona/backups/weekly/` + B2 `postgres/weekly/`
- WAL archive: `/opt/fyona/backups/wal/` + B2 `postgres/wal/`
- MinIO: `/opt/fyona/backups/minio/` + B2 `minio/daily/`
- Config: `/opt/fyona/backups/config/` + B2 `config/`
- B2 bucket: `fyona-backups`
