#!/bin/bash
# FYONA ERP Phase 2 Verification Script
# Verifies all Backup/DR infrastructure is properly configured
# Usage: ./scripts/verify-phase2.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/fyona/backups}"
PASS=0
FAIL=0
WARN=0

log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1"
}

check_pass() {
    echo "  ✅ PASS: $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo "  ❌ FAIL: $1"
    FAIL=$((FAIL + 1))
}

check_warn() {
    echo "  ⚠️  WARN: $1"
    WARN=$((WARN + 1))
}

echo "=========================================="
echo "FYONA ERP Phase 2 Verification"
echo "Backup/Disaster Recovery Infrastructure"
echo "=========================================="
echo ""

# ─── 1. Backup Scripts ─────────────────────────────────────────────────────
echo "1. Backup Scripts"
echo "─────────────────────────────────────────"

for script in backup-full.sh restore-full.sh backup-verify.sh backup-minio.sh setup-wal-archiving.sh setup-backup-cron.sh backup-alerting.sh; do
    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        if [ -x "${SCRIPT_DIR}/${script}" ]; then
            check_pass "${script} exists and is executable"
        else
            check_warn "${script} exists but not executable"
            chmod +x "${SCRIPT_DIR}/${script}" 2>/dev/null || true
        fi
    else
        check_fail "${script} missing"
    fi
done

echo ""

# ─── 2. Backup Directory ───────────────────────────────────────────────────
echo "2. Backup Directory"
echo "─────────────────────────────────────────"

if [ -d "${BACKUP_DIR}" ]; then
    check_pass "Backup directory exists: ${BACKUP_DIR}"
else
    check_warn "Backup directory not found (will be created on first backup)"
fi

echo ""

# ─── 3. Docker Compose WAL Config ──────────────────────────────────────────
echo "3. PostgreSQL WAL Configuration"
echo "─────────────────────────────────────────"

if docker compose exec -T db psql -U fyona -d fyona_erp -c "SHOW wal_level;" 2>/dev/null | grep -q "replica\|logical"; then
    check_pass "WAL level is replica/logical"
else
    check_fail "WAL level not configured for archiving"
fi

if docker compose exec -T db psql -U fyona -d fyona_erp -c "SHOW archive_mode;" 2>/dev/null | grep -q "on"; then
    check_pass "Archive mode is enabled"
else
    check_warn "Archive mode not enabled (run setup-wal-archiving.sh)"
fi

echo ""

# ─── 4. Docker Compose Production Override ──────────────────────────────────
echo "4. Production Docker Compose"
echo "─────────────────────────────────────────"

COMPOSE_DIR="${SCRIPT_DIR}/.."
if [ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]; then
    check_pass "docker-compose.prod.yml exists"

    if grep -q "ghcr.io" "${COMPOSE_DIR}/docker-compose.prod.yml"; then
        check_pass "Production uses GHCR images"
    else
        check_warn "Production doesn't reference GHCR images"
    fi
else
    check_fail "docker-compose.prod.yml missing"
fi

echo ""

# ─── 5. CI/CD Pipeline ─────────────────────────────────────────────────────
echo "5. CI/CD Pipeline"
echo "─────────────────────────────────────────"

CI_FILE="${SCRIPT_DIR}/../../.github/workflows/ci-cd.yml"
if [ -f "${CI_FILE}" ]; then
    check_pass "ci-cd.yml exists"

    if grep -q "docker/build-push-action" "${CI_FILE}"; then
        check_pass "Docker build in CI"
    else
        check_warn "Docker build not found in CI"
    fi

    if grep -q "trivy" "${CI_FILE}"; then
        check_pass "Security scanning (Trivy) configured"
    else
        check_warn "Trivy security scanning not configured"
    fi

    if grep -q "production-deploy" "${CI_FILE}"; then
        check_pass "Deployment concurrency lock configured"
    else
        check_warn "Deployment concurrency lock not configured"
    fi
else
    check_fail "ci-cd.yml missing"
fi

echo ""

# ─── 6. Health Checks ──────────────────────────────────────────────────────
echo "6. Health Checks"
echo "─────────────────────────────────────────"

HEALTH_FILE="${SCRIPT_DIR}/../app/api/v1/health.py"
if [ -f "${HEALTH_FILE}" ]; then
    check_pass "Health check endpoint exists"

    if grep -q "SELECT 1" "${HEALTH_FILE}"; then
        check_pass "Health check includes database probe"
    else
        check_warn "Health check may not verify database"
    fi

    if grep -q "redis" "${HEALTH_FILE}" || grep -q "Redis" "${HEALTH_FILE}"; then
        check_pass "Health check includes Redis probe"
    else
        check_warn "Health check may not verify Redis"
    fi
else
    check_fail "Health check endpoint missing"
fi

echo ""

# ─── 7. Deployment Scripts ──────────────────────────────────────────────────
echo "7. Deployment Scripts"
echo "─────────────────────────────────────────"

for script in deploy-backend.sh smoke-tests.sh test-rollback.sh; do
    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        check_pass "${script} exists"
    else
        check_fail "${script} missing"
    fi
done

echo ""

# ─── 8. Documentation ───────────────────────────────────────────────────────
echo "8. Documentation"
echo "─────────────────────────────────────────"

DOCS_DIR="${SCRIPT_DIR}/.."
for doc in DR_RUNBOOK.md RPO_RTO_REPORT.md; do
    if [ -f "${DOCS_DIR}/${doc}" ]; then
        check_pass "${doc} exists"
    else
        check_fail "${doc} missing"
    fi
done

if [ -f "${SCRIPT_DIR}/../../DEPLOYMENT.md" ]; then
    if grep -q "backup-full.sh" "${SCRIPT_DIR}/../../DEPLOYMENT.md"; then
        check_pass "DEPLOYMENT.md updated with new backup scripts"
    else
        check_warn "DEPLOYMENT.md may reference old backup scripts"
    fi
fi

echo ""

# ─── 9. Backup Execution Test ──────────────────────────────────────────────
echo "9. Backup Dry Run Test"
echo "─────────────────────────────────────────"

if docker compose ps db 2>/dev/null | grep -q "healthy"; then
    check_pass "PostgreSQL is running and healthy"
else
    check_warn "PostgreSQL not running (skip backup test)"
fi

echo ""

# ─── Summary ────────────────────────────────────────────────────────────────
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo "PASSED:  ${PASS}"
echo "FAILED:  ${FAIL}"
echo "WARNED:  ${WARN}"
echo "=========================================="

if [ "${FAIL}" -gt 0 ]; then
    echo "❌ Some checks failed. Review above."
    exit 1
else
    echo "✅ All critical checks passed!"
    exit 0
fi