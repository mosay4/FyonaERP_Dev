#!/bin/bash
# FYONA ERP — VPS Backup/DR Test Script
# Runs all verification tests for the Backup/DR system
# Run this AFTER activation to verify everything works
#
# Usage: bash scripts/vps-test-backup.sh [--full]
#
# --full includes actual backup + restore test (safe, uses temp database)

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_TEST=false
PASS=0
FAIL=0
WARN=0

for arg in "$@"; do
    case $arg in
        --full) FULL_TEST=true ;;
    esac
done

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  WARN: $1"; WARN=$((WARN + 1)); }

echo "=========================================="
echo "FYONA ERP — Backup/DR Test Suite"
echo "=========================================="
echo ""

# ─── Test 1: Backup directories exist ──────────────────────────────────────
echo "1. Backup Directories"
echo "─────────────────────────────────────────"

for dir in "${BACKUP_DIR}" "${BACKUP_DIR}/wal" "${BACKUP_DIR}/minio"; do
    if [ -d "${dir}" ]; then
        pass "Directory exists: ${dir}"
    else
        fail "Directory missing: ${dir}"
    fi
done

echo ""

# ─── Test 2: Script permissions ────────────────────────────────────────────
echo "2. Script Permissions"
echo "─────────────────────────────────────────"

for script in backup-full.sh restore-full.sh backup-verify.sh backup-minio.sh setup-wal-archiving.sh setup-backup-cron.sh; do
    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        if [ -x "${SCRIPT_DIR}/${script}" ]; then
            pass "${script} is executable"
        else
            fail "${script} is NOT executable"
        fi
    else
        fail "${script} not found"
    fi
done

echo ""

# ─── Test 3: PostgreSQL health ─────────────────────────────────────────────
echo "3. PostgreSQL Health"
echo "─────────────────────────────────────────"

if docker compose ps db 2>/dev/null | grep -q "healthy"; then
    pass "PostgreSQL is healthy"
else
    fail "PostgreSQL is NOT healthy"
fi

# Test connection
if docker compose exec -T db psql -U fyona -d fyona_erp -c "SELECT 1;" &>/dev/null; then
    pass "PostgreSQL connection successful"
else
    fail "PostgreSQL connection failed"
fi

echo ""

# ─── Test 4: WAL configuration ─────────────────────────────────────────────
echo "4. WAL Archiving Configuration"
echo "─────────────────────────────────────────"

WAL_LEVEL=$(docker compose exec -T db psql -U fyona -d fyona_erp -t -c "SHOW wal_level;" 2>/dev/null | tr -d '[:space:]')
if [ "${WAL_LEVEL}" = "replica" ] || [ "${WAL_LEVEL}" = "logical" ]; then
    pass "wal_level = ${WAL_LEVEL}"
else
    warn "wal_level = ${WAL_LEVEL} (expected 'replica' or 'logical')"
fi

ARCHIVE_MODE=$(docker compose exec -T db psql -U fyona -d fyona_erp -t -c "SHOW archive_mode;" 2>/dev/null | tr -d '[:space:]')
if [ "${ARCHIVE_MODE}" = "on" ]; then
    pass "archive_mode = on"
else
    warn "archive_mode = ${ARCHIVE_MODE} (expected 'on')"
fi

# Check if WAL archive directory is mounted
MOUNT_CHECK=$(docker compose exec -T db sh -c "test -d /var/lib/postgresql/wal_archive && echo 'mounted' || echo 'missing'" 2>/dev/null || echo "error")
if [ "${MOUNT_CHECK}" = "mounted" ]; then
    pass "WAL archive directory mounted in container"
else
    fail "WAL archive directory NOT mounted"
fi

# Check for WAL files (if archiving is active)
WAL_COUNT=$(docker compose exec -T db sh -c "ls /var/lib/postgresql/wal_archive/ 2>/dev/null | wc -l" 2>/dev/null || echo "0")
if [ "${WAL_COUNT}" -gt 0 ]; then
    pass "WAL files being archived: ${WAL_COUNT} files"
else
    warn "No WAL files archived yet (may need checkpoint)"
fi

echo ""

# ─── Test 5: MinIO health ──────────────────────────────────────────────────
echo "5. MinIO Health"
echo "─────────────────────────────────────────"

if docker compose ps minio 2>/dev/null | grep -q "healthy"; then
    pass "MinIO is healthy"
else
    fail "MinIO is NOT healthy"
fi

if command -v mc &> /dev/null; then
    pass "mc (MinIO Client) installed"

    # Test mc alias
    if mc ls local/ &>/dev/null; then
        pass "mc alias 'local' configured and working"

        BUCKETS=$(mc ls local/ 2>/dev/null | awk '{print $NF}' | wc -l)
        pass "MinIO buckets accessible: ${BUCKETS} buckets"
    else
        fail "mc alias 'local' not configured or MinIO not reachable"
    fi
else
    fail "mc (MinIO Client) not installed"
fi

echo ""

# ─── Test 6: rclone ────────────────────────────────────────────────────────
echo "6. Off-Site Storage (rclone)"
echo "─────────────────────────────────────────"

if command -v rclone &> /dev/null; then
    pass "rclone installed"

    REMOTES=$(rclone listremotes 2>/dev/null | wc -l)
    if [ "${REMOTES}" -gt 0 ]; then
        pass "rclone remotes configured: ${REMOTES}"
    else
        fail "No rclone remotes configured"
    fi
else
    fail "rclone not installed"
fi

echo ""

# ─── Test 7: Cron jobs ─────────────────────────────────────────────────────
echo "7. Automated Cron Jobs"
echo "─────────────────────────────────────────"

if crontab -l 2>/dev/null | grep -q "FYONA ERP Automated Backups"; then
    pass "FYONA cron jobs installed"

    # Count jobs
    JOB_COUNT=$(crontab -l 2>/dev/null | grep -c "backup-\|cleanup\|verify" || echo "0")
    pass "Number of cron jobs: ${JOB_COUNT}"
else
    fail "FYONA cron jobs NOT installed"
fi

echo ""

# ─── Test 8: Backup script functionality ────────────────────────────────────
echo "8. Backup Script Dry Run"
echo "─────────────────────────────────────────"

# Test backup script syntax
if bash -n "${SCRIPT_DIR}/backup-full.sh" 2>/dev/null; then
    pass "backup-full.sh syntax valid"
else
    fail "backup-full.sh has syntax errors"
fi

if bash -n "${SCRIPT_DIR}/restore-full.sh" 2>/dev/null; then
    pass "restore-full.sh syntax valid"
else
    fail "restore-full.sh has syntax errors"
fi

if bash -n "${SCRIPT_DIR}/backup-verify.sh" 2>/dev/null; then
    pass "backup-verify.sh syntax valid"
else
    fail "backup-verify.sh has syntax errors"
fi

echo ""

# ─── Test 9: Full backup + restore (if --full) ─────────────────────────────
if [ "${FULL_TEST}" = true ]; then
    echo "9. Full Backup + Restore Test"
    echo "─────────────────────────────────────────"

    echo "  Running backup..."
    if "${SCRIPT_DIR}/backup-full.sh" --no-offsite --no-encrypt 2>&1 | tee -a "${BACKUP_DIR}/test_backup.log"; then
        pass "Backup completed successfully"

        # Find the backup file
        LATEST=$(ls -t "${BACKUP_DIR}"/fyona_db_*.sql 2>/dev/null | head -1)
        if [ -n "${LATEST}" ]; then
            pass "Backup file created: ${LATEST}"

            # Verify
            echo "  Verifying backup..."
            if "${SCRIPT_DIR}/backup-verify.sh" "${LATEST}" --full 2>&1 | tee -a "${BACKUP_DIR}/test_verify.log"; then
                pass "Backup verification passed"
            else
                fail "Backup verification failed"
            fi
        else
            fail "No backup file found after backup"
        fi
    else
        fail "Backup failed"
    fi

    echo ""
else
    echo "9. Full Backup + Restore Test: SKIPPED (use --full to enable)"
    echo ""
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "PASSED:  ${PASS}"
echo "FAILED:  ${FAIL}"
echo "WARNED:  ${WARN}"
echo "=========================================="

if [ "${FAIL}" -gt 0 ]; then
    echo "❌ Some tests failed. Review above."
    exit 1
else
    echo "✅ All critical tests passed!"
    exit 0
fi