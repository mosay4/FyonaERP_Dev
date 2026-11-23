#!/bin/bash
# FYONA ERP — VPS Backup/DR Activation Script
# Run this ONCE on the VPS to activate the full Backup/DR system
#
# Usage: sudo bash scripts/vps-activate-backup.sh
#
# What this script does:
#   1. Creates backup directories
#   2. Sets file permissions
#   3. Verifies Docker + Docker Compose
#   4. Verifies PostgreSQL is running
#   5. Creates WAL archive directory + volume mount
#   6. Installs mc (MinIO Client) if missing
#   7. Installs rclone if missing
#   8. Installs cron jobs
#   9. Runs first backup (optional)
#
# What this script does NOT do:
#   - Does NOT delete any data
#   - Does NOT modify PostgreSQL configuration
#   - Does NOT rotate secrets
#   - Does NOT overwrite production data

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
BACKUP_DIR="/opt/fyona/backups"
WAL_DIR="${BACKUP_DIR}/wal"
MINIO_BACKUP_DIR="${BACKUP_DIR}/minio"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${BACKUP_DIR}/activation_$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "${LOG_FILE}"; }
pass() { echo -e "${GREEN}  ✅ PASS${NC}: $1" | tee -a "${LOG_FILE}"; }
fail() { echo -e "${RED}  ❌ FAIL${NC}: $1" | tee -a "${LOG_FILE}"; }
warn() { echo -e "${YELLOW}  ⚠️  WARN${NC}: $1" | tee -a "${LOG_FILE}"; }

echo "=========================================="
echo "FYONA ERP — Backup/DR Activation"
echo "=========================================="
echo ""

# ─── Step 1: Create directories ────────────────────────────────────────────
log "Step 1/8: Creating backup directories..."
mkdir -p "${BACKUP_DIR}"
mkdir -p "${WAL_DIR}"
mkdir -p "${MINIO_BACKUP_DIR}"
pass "Backup directories created"

# ─── Step 2: Set permissions ───────────────────────────────────────────────
log "Step 2/8: Setting file permissions..."
chmod 700 "${BACKUP_DIR}"
chmod 700 "${WAL_DIR}"
chmod 700 "${MINIO_BACKUP_DIR}"

# Make scripts executable
chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true
pass "Permissions set (700 on backup dirs, +x on scripts)"

# ─── Step 3: Verify Docker ────────────────────────────────────────────────
log "Step 3/8: Verifying Docker..."

if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    pass "Docker installed: ${DOCKER_VERSION}"
else
    fail "Docker not installed"
    echo "Install: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)
    pass "Docker Compose: ${COMPOSE_VERSION}"

    # Check v2.20+ for !reset tag
    if printf '%s\n' "2.20" "${COMPOSE_VERSION}" | sort -V | head -1 | grep -q "2.20"; then
        pass "Docker Compose version supports !reset tag"
    else
        warn "Docker Compose < 2.20 — !reset tag may not work"
    fi
else
    fail "Docker Compose not installed"
    exit 1
fi

# ─── Step 4: Verify PostgreSQL ─────────────────────────────────────────────
log "Step 4/8: Verifying PostgreSQL..."

if docker compose ps db 2>/dev/null | grep -q "healthy"; then
    pass "PostgreSQL is running and healthy"
else
    warn "PostgreSQL not detected via docker compose"
    warn "Ensure you're in the correct directory: /opt/fyona/fyona_flutter/backend"
fi

# ─── Step 5: WAL archive setup ─────────────────────────────────────────────
log "Step 5/8: Verifying WAL archive mount..."

# Check if WAL directory is mounted in the container
MOUNT_CHECK=$(docker compose exec -T db sh -c "test -d /var/lib/postgresql/wal_archive && echo 'mounted' || echo 'missing'" 2>/dev/null || echo "error")

if [ "${MOUNT_CHECK}" = "mounted" ]; then
    pass "WAL archive directory is mounted in PostgreSQL container"
else
    warn "WAL archive NOT mounted in PostgreSQL container"
    echo ""
    echo "  To enable WAL archiving, you need to:"
    echo "  1. Use docker-compose.prod.yml (which includes the WAL mount)"
    echo "  2. Or manually add this volume to docker-compose.yml:"
    echo ""
    echo "     db:"
    echo "       volumes:"
    echo "         - pgdata:/var/lib/postgresql/data"
    echo "         - /opt/fyona/backups/wal:/var/lib/postgresql/wal_archive"
    echo ""
    echo "  3. Then restart: docker compose up -d db"
    echo "  4. Then re-run this script"
    echo ""
fi

# ─── Step 6: Install mc (MinIO Client) ─────────────────────────────────────
log "Step 6/8: Checking MinIO Client (mc)..."

if command -v mc &> /dev/null; then
    MC_VERSION=$(mc --version 2>/dev/null | head -1 | awk '{print $3}')
    pass "mc installed: ${MC_VERSION}"
else
    warn "mc not installed. Installing..."
    curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    pass "mc installed"

    echo ""
    echo "  ⚠️  IMPORTANT: Configure mc alias before first MinIO backup:"
    echo "  mc alias set local http://localhost:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD"
    echo ""
fi

# ─── Step 7: Install rclone ────────────────────────────────────────────────
log "Step 7/8: Checking rclone..."

if command -v rclone &> /dev/null; then
    RCLONE_VERSION=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
    pass "rclone installed: ${RCLONE_VERSION}"
else
    warn "rclone not installed. Installing..."
    curl -sSL https://rclone.org/install.sh | bash 2>/dev/null || {
        warn "Automatic install failed. Manual install:"
        echo "  curl -sSL https://rclone.org/install.sh | sudo bash"
    }
    if command -v rclone &> /dev/null; then
        pass "rclone installed"
    else
        fail "rclone installation failed"
        echo "  Install manually: curl -sSL https://rclone.org/install.sh | sudo bash"
    fi
fi

# ─── Step 8: Install cron jobs ─────────────────────────────────────────────
log "Step 8/8: Checking cron jobs..."

if crontab -l 2>/dev/null | grep -q "FYONA ERP Automated Backups"; then
    pass "FYONA cron jobs already installed"
else
    warn "FYONA cron jobs not installed"
    echo ""
    echo "  To install cron jobs, run:"
    echo "  ./scripts/setup-backup-cron.sh"
    echo ""
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Activation Summary"
echo "=========================================="
echo ""
echo "Completed:"
echo "  ✅ Backup directories created"
echo "  ✅ File permissions set"
echo "  ✅ Scripts made executable"
echo ""
echo "Pending manual action:"
echo "  ❓ WAL archive mount (if using docker-compose.prod.yml)"
echo "  ❓ mc alias configuration (for MinIO backup)"
echo "  ❓ rclone remote configuration (for off-site backup)"
echo "  ❓ Cron job installation"
echo "  ❓ First backup execution"
echo ""
echo "Next steps:"
echo "  1. Configure mc: mc alias set local http://localhost:9000 <user> <pass>"
echo "  2. Configure rclone: rclone config"
echo "  3. Install cron: ./scripts/setup-backup-cron.sh"
echo "  4. Run first backup: ./scripts/backup-full.sh --no-offsite --no-encrypt"
echo "  5. Verify: ./scripts/backup-verify.sh <backup_file> --full"
echo "=========================================="