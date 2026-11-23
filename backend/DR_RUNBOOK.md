# FYONA ERP — Disaster Recovery Runbook

## Overview
This runbook provides step-by-step procedures for recovering FYONA ERP from various disaster scenarios.

**Target RPO**: 24 hours (daily backups)  
**Target RTO**: 2 hours  
**Last Updated**: 2026-08-17

---

## Table of Contents
1. [Scenario 1: Database Corruption](#scenario-1-database-corruption)
2. [Scenario 2: Complete VPS Loss](#scenario-2-complete-vps-loss)
3. [Scenario 3: MinIO Data Loss](#scenario-3-minio-data-loss)
4. [Scenario 4: Application Failure](#scenario-4-application-failure)
5. [Contact Information](#contact-information)

---

## Scenario 1: Database Corruption

### Symptoms
- Application errors related to data integrity
- `pg_dump` fails or produces corrupt output
- PostgreSQL logs show corruption errors

### Recovery Steps

#### Step 1: Stop the Application
```bash
cd /opt/fyona/fyona_flutter/backend
docker compose stop api celery-worker celery-beat
```

#### Step 2: Assess Damage
```bash
# Check PostgreSQL logs
docker compose logs --tail=100 db

# Attempt to connect
docker compose exec -T db psql -U fyona -d fyona_erp -c "SELECT 1;"
```

#### Step 3: Identify Last Good Backup
```bash
# List available backups (newest first)
ls -lt /opt/fyona/backups/fyona_db_*.sql*

# Get the latest backup file
LATEST=$(ls -t /opt/fyona/backups/fyona_db_*.sql 2>/dev/null | head -1)
echo "Latest backup: ${LATEST}"

# Verify backup integrity
./scripts/backup-verify.sh "${LATEST}" --full
```

#### Step 4: Restore from Backup
```bash
# Get latest backup
LATEST=$(ls -t /opt/fyona/backups/fyona_db_*.sql 2>/dev/null | head -1)

# Interactive restore (will prompt for confirmation)
./scripts/restore-full.sh "${LATEST}"

# Or non-interactive
./scripts/restore-full.sh "${LATEST}" --yes
```

#### Step 5: Restart Application
```bash
docker compose up -d
# Wait for health checks
sleep 30
docker compose ps
```

#### Step 6: Verify Recovery
```bash
# Run smoke tests
./scripts/smoke-tests.sh

# Check application health
curl -f http://localhost:8001/health
```

---

## Scenario 2: Complete VPS Loss

### Prerequisites
- Access to GitHub repository
- Access to GHCR (Docker images)
- Access to off-site backup storage
- New VPS with Docker + Docker Compose

### Recovery Steps

#### Step 1: Provision New VPS
```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
# Install Docker Compose plugin
apt install docker-compose-plugin
```

#### Step 2: Clone Repository
```bash
cd /opt
git clone https://github.com/<org>/fyona_flutter.git
cd fyona_flutter/backend
```

#### Step 3: Configure Environment
```bash
# Copy production env template
cp .env.production.example .env.production

# Edit with production secrets
nano .env.production
```

#### Step 4: Restore Database from Off-Site
```bash
# Check rclone configuration
rclone listremotes

# List available off-site backups
rclone ls offsite:fyona-backups/ --max-depth 1

# Copy latest backup from off-site
rclone copy offsite:fyona-backups/ ./offsite_restore/ --max-depth 1

# Find the backup file
LATEST=$(find ./offsite_restore/ -name "fyona_db_*.sql" -o -name "fyona_db_*.sql.gpg" | head -1)

# Restore (if encrypted, decrypt first)
# gpg --batch --passphrase "YOUR_PASSPHRASE" --decrypt "${LATEST}" > decrypted.sql
./scripts/restore-full.sh "${LATEST}" --yes
```

#### Step 5: Restore MinIO Data
```bash
# If MinIO data was backed up off-site
rclone copy offsite:fyona-backups/minio/ ./minio_restore/ --max-depth 1

# Start MinIO and restore
docker compose up -d minio
# Wait for MinIO to be healthy
sleep 10

# Configure mc alias (use production credentials, not defaults)
mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
mc mirror ./minio_restore/ local/fyona-bucket/
```

#### Step 6: Deploy Application
```bash
# Pull latest images from GHCR
export DEPLOY_SHA=rollback
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Or deploy specific version
export DEPLOY_SHA=<git-sha>
./scripts/deploy-backend.sh
```

#### Step 7: Verify Full Recovery
```bash
./scripts/smoke-tests.sh
curl -f http://localhost:8001/health/ready
```

---

## Scenario 3: MinIO Data Loss

### Recovery Steps

#### Step 1: Assess Damage
```bash
# Check MinIO status
docker compose exec -T minio mc alias set local http://localhost:9000 minioadmin minioadmin
mc ls local/
```

#### Step 2: Restore from Backup
```bash
./scripts/backup-minio.sh  # First, backup what's left

# Restore from off-site
rclone copy offsite:fyona-backups/minio/latest/ ./minio_restore/
mc mirror ./minio_restore/ local/fyona-bucket/
```

#### Step 3: Verify
```bash
mc ls local/fyona-bucket/
```

---

## Scenario 4: Application Failure

### Symptoms
- API returns 500 errors
- Health checks failing
- Container restart loops

### Recovery Steps

#### Step 1: Check Logs
```bash
docker compose logs --tail=200 api
docker compose logs --tail=100 celery-worker
```

#### Step 2: Try Restart
```bash
docker compose restart api celery-worker
sleep 30
docker compose ps
```

#### Step 3: If Restart Fails, Redeploy
```bash
./scripts/deploy-backend.sh
```

#### Step 4: If Still Failing, Rollback
```bash
./scripts/test-rollback.sh
# If rollback test passes:
docker compose stop api
# Edit .env to set DEPLOY_SHA=rollback
docker compose up -d api
```

---

## Contact Information

| Role | Name | Contact |
|------|------|---------|
| Primary Admin | [Name] | [Email/Phone] |
| Backup Admin | [Name] | [Email/Phone] |
| Hosting Provider | [Provider] | [Support URL] |

---

## Recovery Time Log

| Date | Scenario | RTO Achieved | Notes |
|------|----------|--------------|-------|
| | | | |

---

## Regular Testing Schedule

- **Monthly**: Verify backups are restorable
- **Quarterly**: Full DR drill (Scenario 2)
- **Annually**: Review and update this runbook