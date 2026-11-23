# FYONA ERP — Disaster Recovery Runbook

## Overview

This runbook provides step-by-step instructions for recovering FYONA ERP from complete VPS loss or major system failure.

**Current Architecture:**
- PostgreSQL 16 (78 tables, 13MB data)
- MinIO (S3-compatible object storage)
- Redis (caching/session — ephemeral, not critical)
- Backend API (FastAPI + Docker)
- Celery workers (background tasks)
- Backblaze B2 off-site backups

**Recovery Targets:**
- **RPO**: < 10 minutes (WAL-based PITR)
- **RTO**: < 30 minutes (automated restore)

---

## Scenario 1: PostgreSQL Data Loss (Database Corruption)

### Symptoms
- API returning 500 errors
- Database connection errors in logs
- Data missing or corrupted

### Recovery Steps

```bash
# 1. Stop the API
cd /opt/fyona/backend
docker compose stop api celery-worker celery-beat

# 2. Verify latest backup
/opt/fyona/backend/scripts/verify-backup.sh

# 3. Restore from latest daily backup
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
/opt/fyona/backend/scripts/restore-pg.sh --latest --yes

# 4. Restart services
docker compose up -d

# 5. Verify health
curl -sf http://localhost:8000/api/v1/health/live
curl -sf http://localhost:8000/api/v1/health/ready

# 6. Run smoke tests
/opt/fyona/backend/scripts/smoke-tests.sh
```

---

## Scenario 2: Point-in-Time Recovery (PITR)

Use when you need to recover to a specific point in time (e.g., after accidental data deletion).

### Prerequisites
- Base backup exists in `/opt/fyona/backups/base/`
- WAL segments exist in `/opt/fyona/backups/wal/`
- WAL segments uploaded to B2 hourly

### Recovery Steps

```bash
# 1. Identify target time
TARGET_TIME="2026-08-17 18:00:00"  # Adjust as needed

# 2. Stop API
docker compose stop api celery-worker celery-beat

# 3. Get latest base backup
LATEST_BASE=$(ls -t /opt/fyona/backups/base/fyona_base_*.tar.gz.gpg 2>/dev/null | head -1)
echo "Latest base backup: $LATEST_BASE"

# 4. Create temp directory for restore
mkdir -p /tmp/pg_pitr_restore

# 5. Decrypt and extract base backup
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" \
    --decrypt "$LATEST_BASE" | tar -xzf - -C /tmp/pg_pitr_restore

# 6. Create recovery signal file
touch /tmp/pg_pitr_restore/recovery.signal

# 7. Create recovery.conf
cat > /tmp/pg_pitr_restore/postgresql.auto.conf << EOF
restore_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF

# 8. Stop PostgreSQL
docker compose stop db

# 9. Backup current data
docker volume rename backend_pgdata backend_pgdata_backup_$(date +%Y%m%d) 2>/dev/null || true

# 10. Restore base backup
docker volume create backend_pgdata
docker run --rm \
  -v /tmp/pg_pitr_restore:/backup \
  -v backend_pgdata:/var/lib/postgresql/data \
  postgres:16-alpine \
  bash -c "cp -a /backup/* /var/lib/postgresql/data/"

# 11. Fix permissions
docker run --rm \
  -v backend_pgdata:/var/lib/postgresql/data \
  postgres:16-alpine \
  chown -R postgres:postgres /var/lib/postgresql/data

# 12. Start PostgreSQL (recovery mode)
docker compose up -d db
sleep 5

# 13. Check recovery status
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT pg_is_in_recovery();"

# 14. Once recovery completes, promote
docker exec fyona-db psql -U fyona -d fyona_erp -c "SELECT pg_wal_replay_resume();"

# 15. Start services
docker compose up -d api celery-worker celery-beat

# 16. Verify
curl -sf http://localhost:8000/api/v1/health/ready
/opt/fyona/backend/scripts/smoke-tests.sh
```

---

## Scenario 3: Complete VPS Loss

### Prerequisites
- B2 bucket `fyona-backups` accessible
- rclone configured with B2 credentials
- New VPS with Docker + Docker Compose installed

### Recovery Steps

```bash
# ── PHASE 1: New VPS Setup ──

# 1. Install Docker
curl -fsSL https://get.docker.com | sh
apt install -y docker-compose-plugin

# 2. Install rclone
apt install -y rclone

# 3. Configure rclone for B2
rclone config
# → new remote → name: b2 → provider: Backblaze B2
# → Enter application key ID and application key

# 4. Configure mc (MinIO Client)
curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc
mc alias set local http://localhost:9000 <MINIO_ROOT_USER> <MINIO_ROOT_PASSWORD>

# ── PHASE 2: Restore Configuration ──

# 5. Create directory structure
mkdir -p /opt/fyona/backend
mkdir -p /opt/fyona/backups/{daily,weekly,monthly,base,wal,config,pre_restore}

# 6. Download and restore configuration
rclone copy b2:fyona-backups/config/ /tmp/config_restore/
LATEST_CONFIG=$(ls -t /tmp/config_restore/fyona_config_*.tar.gz.gpg 2>/dev/null | head -1)

export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key 2>/dev/null || read -sp "Encryption key: " && echo)
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" \
    --decrypt "$LATEST_CONFIG" | tar -xzf - -C /opt/fyona

# 7. Recreate encryption key
echo "$BACKUP_GPG_PASSPHRASE" > /opt/fyona/.backup-encryption-key
chmod 600 /opt/fyona/.backup-encryption-key

# ── PHASE 3: Restore PostgreSQL ──

# 8. Download latest backup
rclone copy b2:fyona-backups/postgres/daily/ /opt/fyona/backups/daily/

# 9. Start PostgreSQL
cd /opt/fyona/backend
docker compose up -d db
sleep 10

# 10. Restore database
LATEST_DB=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz.gpg 2>/dev/null | head -1)
/opt/fyona/backend/scripts/restore-pg.sh "$LATEST_DB" --yes

# ── PHASE 4: Restore MinIO ──

# 11. Start MinIO
docker compose up -d minio
sleep 5

# 12. Download MinIO backup
rclone copy b2:fyona-backups/minio/daily/ /tmp/minio_restore/

# 13. Restore MinIO
LATEST_MINIO=$(ls -t /tmp/minio_restore/fyona_minio_*.tar.gz.gpg 2>/dev/null | head -1)
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" \
    --decrypt "$LATEST_MINIO" | tar -xzf - -C /tmp/minio_data

# 14. Upload to MinIO
mc mirror /tmp/minio_data/ local/fyona-files/

# ── PHASE 5: Start All Services ──

# 15. Start everything
docker compose up -d

# 16. Verify health
curl -sf http://localhost:8000/api/v1/health/live
curl -sf http://localhost:8000/api/v1/health/ready

# 17. Run smoke tests
/opt/fyona/backend/scripts/smoke-tests.sh

# 18. Restore cron jobs
crontab -l > /tmp/crontab.txt
# Add FYONA backup cron entries
crontab /tmp/crontab.txt

echo "FYONA ERP restored successfully!"
```

---

## Scenario 4: Docker Container Failure

### Symptoms
- Container keeps restarting
- Container health check failing

### Recovery Steps

```bash
# 1. Check container logs
docker logs --tail 50 fyona-api

# 2. Restart specific service
docker compose restart api

# 3. If still failing, rebuild and restart
docker compose build --no-cache api
docker compose up -d api

# 4. If database is the issue
docker compose restart db
sleep 10
docker exec fyona-db pg_isready -U fyona -d fyona_erp
```

---

## Backup Verification Schedule

| Task | Frequency | Script | Cron |
|------|-----------|--------|------|
| Gzip integrity | Daily | `backup-postgres.sh --verify` | Automatic |
| Full restore test | Weekly | `verify-backup.sh` | Sunday 06:00 |
| WAL sync to B2 | Hourly | `backup-offsite.sh` | Every hour |
| Config backup | Daily | `backup-config.sh` | 05:00 |
| MinIO backup | Daily | `backup-minio.sh` | 03:00 |
| MinIO weekly full | Weekly | `backup-minio.sh --full` | Sunday 03:30 |

---

## Emergency Contacts

- **VPS Provider**: [Your VPS provider]
- **Backblaze B2**: [Your B2 account]
- **GitHub**: [Your GitHub repo]
- **Domain DNS**: [Your DNS provider]

---

## Post-Recovery Checklist

- [ ] All containers running and healthy
- [ ] API health endpoints responding
- [ ] Database tables intact (78 tables)
- [ ] Users data accessible
- [ ] MinIO buckets restored
- [ ] Cron jobs reinstalled
- [ ] SSL certificates valid
- [ ] DNS records pointing correctly
- [ ] Smoke tests passing (20/20)
- [ ] Monitoring alerts cleared

---

*Last updated: $(date)*
*Version: 1.0*
