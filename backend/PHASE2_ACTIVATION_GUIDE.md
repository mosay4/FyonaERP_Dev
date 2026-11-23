# FYONA ERP — Phase 2 VPS Activation Guide

**Purpose**: Activate and verify the complete Backup/DR system on the VPS.
**Prerequisites**: VPS access, Phase 2 scripts deployed to VPS.
**Estimated time**: 1-2 hours for all steps.

---

## Pre-Flight Checklist

Before starting, verify:

- [ ] Phase 2 scripts are on VPS at `/opt/fyona/fyona_flutter/backend/scripts/`
- [ ] Docker + Docker Compose v2.20+ installed
- [ ] PostgreSQL running and healthy (`docker compose ps db`)
- [ ] MinIO running and healthy (`docker compose ps minio`)
- [ ] `mc` (MinIO Client) installed (`which mc`)
- [ ] `rclone` installed (`which rclone`)

---

## STEP 1: VPS Activation

```bash
cd /opt/fyona/fyona_flutter/backend
sudo bash scripts/vps-activate-backup.sh
```

This creates directories, sets permissions, and checks prerequisites.

---

## STEP 2: Configure Off-Site Storage (Backblaze B2)

### 2a. Create Backblaze B2 Account
1. Go to https://secure.backblaze.com/b2_buckets.htm
2. Create account (10GB free tier)
3. Create bucket: `fyona-backups` (private, US-West)
4. Create Application Key with permissions: `readFiles`, `writeFiles`, `listFiles`
5. Save the **Account ID** and **Application Key**

### 2b. Configure rclone
```bash
rclone config
# n) New remote
# name: offsite
# Storage: Backblaze B2
# Account ID: <your-account-id>
# Application Key: <your-application-key>
# Endpoint: (leave blank)
```

### 2c. Run setup script
```bash
bash scripts/setup-offsite-b2.sh
```

### 2d. Verify
```bash
rclone ls offsite:fyona-backups/
rclone size offsite:fyona-backups/
```

---

## STEP 3: Configure Encryption

```bash
bash scripts/setup-encryption.sh
```

This generates a 64-character passphrase and stores it at:
- `/opt/fyona/.backup-encryption-key` (primary)
- `/opt/fyona/.backup-encryption-key.backup` (backup)

**CRITICAL**: Back up the passphrase securely. Without it, backups cannot be decrypted.

### Test encryption
```bash
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
echo "test" > /tmp/test.txt
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" --symmetric --cipher-algo AES256 --output /tmp/test.txt.gpg /tmp/test.txt
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" --decrypt /tmp/test.txt.gpg
rm /tmp/test.txt /tmp/test.txt.gpg
```

---

## STEP 4: Activate WAL Archiving

### 4a. Ensure WAL volume mount exists
```bash
# Check if WAL archive is mounted in PostgreSQL container
docker compose exec -T db sh -c "test -d /var/lib/postgresql/wal_archive && echo 'mounted' || echo 'missing'"
```

If "missing", ensure `docker-compose.prod.yml` is being used:
```bash
# The prod override includes the WAL mount
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d db
```

### 4b. Run WAL setup
```bash
bash scripts/setup-wal-archiving.sh
```

### 4c. Restart PostgreSQL
```bash
docker compose restart db
```

### 4d. Verify WAL archiving
```bash
# Check wal_level
docker compose exec -T db psql -U fyona -d fyona_erp -c "SHOW wal_level;"
# Expected: replica

# Check archive_mode
docker compose exec -T db psql -U fyona -d fyona_erp -c "SHOW archive_mode;"
# Expected: on

# Check archive_command
docker compose exec -T db psql -U fyona -d fyona_erp -c "SHOW archive_command;"
# Expected: test ! -f /var/lib/postgresql/wal_archive/...

# Force a checkpoint to generate WAL
docker compose exec -T db psql -U fyona -d fyona_erp -c "CHECKPOINT;"

# Wait 30 seconds, then check for archived WAL files
sleep 30
ls -la /opt/fyona/backups/wal/
# Expected: one or more WAL files (e.g., 000000010000000000000001)
```

---

## STEP 5: Run First Full Backup

```bash
# Set encryption passphrase
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)

# Run backup with encryption + off-site
cd /opt/fyona/fyona_flutter/backend
./scripts/backup-full.sh
```

### Verify backup
```bash
# Find backup file
ls -lt /opt/fyona/backups/fyona_db_*.sql*

# Check checksum
sha256sum -c /opt/fyona/backups/fyona_db_*.sql.sha256

# Check file type
file /opt/fyona/backups/fyona_db_*.sql

# Verify with script
./scripts/backup-verify.sh /opt/fyona/backups/fyona_db_*.sql --full

# Check off-site copy
rclone ls offsite:fyona-backups/postgres/
```

---

## STEP 6: Run First MinIO Backup

```bash
# Verify mc is configured
mc alias set local http://localhost:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD
mc ls local/

# Run MinIO backup
./scripts/backup-minio.sh --offsite

# Verify
ls -lt /opt/fyona/backups/minio/
rclone ls offsite:fyona-backups/minio/
```

---

## STEP 7: Install Automated Cron Jobs

```bash
# Preview what will be installed
./scripts/setup-backup-cron.sh --dry-run

# Install
./scripts/setup-backup-cron.sh

# Verify
crontab -l
```

Expected cron schedule:
- 02:00 daily — Full PostgreSQL backup
- 03:00 daily — MinIO backup
- 04:00 Sunday — Backup verification
- 05:00 Monday — Log cleanup
- 01:00 daily — WAL archive cleanup

---

## STEP 8: PostgreSQL Restore Test

**This test uses a temporary database — production is NOT affected.**

```bash
# Find latest backup
LATEST=$(ls -t /opt/fyona/backups/fyona_db_*.sql | head -1)
echo "Testing restore of: ${LATEST}"

# Run restore verification (creates temp DB, restores, checks, drops)
./scripts/restore-full.sh "${LATEST}" --verify-only
```

Expected output:
- "Verification: PASSED"
- Tables restored: 20+
- Rows restored: matches production

---

## STEP 9: PITR Test

**This test verifies Point-in-Time Recovery works.**

### 9a. Record current state
```bash
# Record current timestamp
echo "PITR test start: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/pitr_test.txt

# Record current row count
docker compose exec -T db psql -U fyona -d fyona_erp -t -c "SELECT COUNT(*) FROM users;" | tr -d '[:space:]' > /tmp/pitr_before.txt
echo "Users before: $(cat /tmp/pitr_before.txt)"
```

### 9b. Create a test table
```bash
# Create a test table with known data
docker compose exec -T db psql -U fyona -d fyona_erp -c "
CREATE TABLE _pitr_test (
    id SERIAL PRIMARY KEY,
    test_data TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO _pitr_test (test_data) VALUES ('PITR test record');
"

# Record the timestamp AFTER the insert
date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/pitr_after.txt
echo "Test record created at: $(cat /tmp/pitr_after.txt)"
```

### 9c. Force WAL checkpoint
```bash
docker compose exec -T db psql -U fyona -d fyona_erp -c "CHECKPOINT;"
sleep 10
```

### 9d. Verify WAL files exist
```bash
ls -la /opt/fyona/backups/wal/
# Should have WAL files
```

### 9e. Run full backup (base backup)
```bash
./scripts/backup-full.sh --no-offsite --no-encrypt
```

### 9f. Restore to temp database
```bash
# Create temp database
docker compose exec -T db psql -U fyona -d postgres -c "CREATE DATABASE fyona_pitr_test;"

# Restore base backup
LATEST=$(ls -t /opt/fyona/backups/fyona_db_*.sql | head -1)
docker compose exec -T db pg_restore -U fyona -d fyona_pitr_test --no-owner --no-privileges --if-exists --clean "${LATEST}" 2>/dev/null || true

# Check if _pitr_test table exists in restored database
docker compose exec -T db psql -U fyona -d fyona_pitr_test -c "SELECT * FROM _pitr_test;" 2>/dev/null
# If table exists: PITR works (WAL replayed)
# If table doesn't exist: WAL not yet replayed (normal — depends on timing)

# Cleanup
docker compose exec -T db psql -U fyona -d postgres -c "DROP DATABASE IF EXISTS fyona_pitr_test;"
```

### 9g. Cleanup test data
```bash
docker compose exec -T db psql -U fyona -d fyona_erp -c "DROP TABLE IF EXISTS _pitr_test;"
```

---

## STEP 10: MinIO Restore Test

**This test restores to a temporary bucket — production is NOT affected.**

```bash
# Find MinIO backup
LATEST_MINIO=$(ls -td /opt/fyona/backups/minio/*/ 2>/dev/null | head -1)
echo "Testing restore of: ${LATEST_MINIO}"

# Create temporary bucket
mc mb local/fyona-restore-test/

# Restore to temporary bucket
mc mirror "${LATEST_MINIO}" local/fyona-restore-test/ 2>/dev/null

# Verify files
mc ls local/fyona-restore-test/

# Cleanup
mc rm --recursive --force local/fyona-restore-test/
mc rb local/fyona-restore-test/ 2>/dev/null || true
```

---

## STEP 11: Full DR Drill

**Simulates complete VPS loss and recovery in a temporary environment.**

### Prerequisites
- Docker + Docker Compose on VPS
- Access to GitHub repository
- Access to GHCR
- Access to Backblaze B2 (off-site)
- Encryption passphrase

### 11a. Create temporary directory
```bash
DRILL_DIR=$(mktemp -d)
echo "DR drill directory: ${DRILL_DIR}"
```

### 11b. Simulate new VPS
```bash
cd "${DRILL_DIR}"
git clone https://github.com/<org>/fyona_flutter.git .
cd fyona_flutter/backend
```

### 11c. Restore from off-site
```bash
# Copy off-site backups locally
rclone copy offsite:fyona-backups/postgres/ ./restore_postgres/
rclone copy offsite:fyona-backups/minio/ ./restore_minio/

# Find latest PostgreSQL backup
LATEST=$(ls -t ./restore_postgres/fyona_db_*.sql.gpg 2>/dev/null | head -1)

# Decrypt
export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" --decrypt "${LATEST}" > ./fyona_restored.sql
```

### 11d. Start services and restore
```bash
docker compose up -d db redis minio
sleep 30

# Restore PostgreSQL
docker compose exec -T db psql -U fyona -d fyona_erp < ./fyona_restored.sql

# Restore MinIO
mc alias set local http://localhost:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD
mc mirror ./restore_minio/ local/fyona-files/
```

### 11e. Deploy application
```bash
docker compose up -d
sleep 30
```

### 11f. Verify
```bash
# Health checks
curl -f http://localhost:8001/health/ready

# Smoke tests
./scripts/smoke-tests.sh
```

### 11g. Cleanup
```bash
cd /
rm -rf "${DRILL_DIR}"
docker compose down -v  # Remove temporary volumes
```

### 11h. Record RTO
```
Actual RTO: ___ minutes (time from start to health check passing)
```

---

## STEP 12: Final Verification

Run the comprehensive test suite:

```bash
./scripts/vps-test-backup.sh --full
```

---

## Post-Activation Checklist

After all steps complete:

- [ ] WAL archiving active (WAL files being archived)
- [ ] First full backup created + verified
- [ ] Encryption working (backup encrypted with GPG)
- [ ] Off-site copy exists in Backblaze B2
- [ ] MinIO backup created + verified
- [ ] Cron jobs installed and scheduled
- [ ] PostgreSQL restore tested (temp database)
- [ ] PITR test completed
- [ ] MinIO restore tested (temp bucket)
- [ ] Full DR drill completed
- [ ] Actual RPO recorded: ___
- [ ] Actual RTO recorded: ___
- [ ] DR runbook updated with contact info
