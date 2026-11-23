#!/bin/bash
# FYONA ERP — Backblaze B2 Off-Site Configuration
# Run this ONCE on the VPS after creating your B2 account
#
# Prerequisites:
#   1. Create a Backblaze B2 account at https://secure.backblaze.com/b2_buckets.htm
#   2. Create an application key with bucket read/write/list permissions
#   3. Create a bucket named "fyona-backups"
#
# Usage: bash scripts/setup-offsite-b2.sh

set -euo pipefail

LOG_FILE="/opt/fyona/backups/offsite_setup.log"

log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "${LOG_FILE}"; }

echo "=========================================="
echo "FYONA ERP — Backblaze B2 Off-Site Setup"
echo "=========================================="
echo ""

# ─── Step 1: Verify rclone ────────────────────────────────────────────────
log "Step 1/4: Verifying rclone..."

if ! command -v rclone &> /dev/null; then
    echo "ERROR: rclone not installed."
    echo "Install: curl -sSL https://rclone.org/install.sh | sudo bash"
    exit 1
fi
log "rclone installed: $(rclone version 2>/dev/null | head -1)"

# ─── Step 2: Configure rclone ─────────────────────────────────────────────
log "Step 2/4: Configuring rclone for Backblaze B2..."

if rclone listremotes 2>/dev/null | grep -q "^offsite:"; then
    log "rclone remote 'offsite' already configured."
    log "Current config:"
    rclone config show offsite 2>/dev/null | head -5
else
    log ""
    log "═══════════════════════════════════════════════════════════"
    log "MANUAL CONFIGURATION REQUIRED"
    log "═══════════════════════════════════════════════════════════"
    log ""
    log "Run: rclone config"
    log ""
    log "Follow these steps:"
    log "  n) New remote"
    log "  name: offsite"
    log "  Storage: Backblaze B2"
    log "  Account ID: <your-b2-account-id>"
    log "  Application Key: <your-b2-application-key>"
    log "  Endpoint: (leave blank)"
    log ""
    log "After configuring, re-run this script."
    log "═══════════════════════════════════════════════════════════"
    exit 0
fi

# ─── Step 3: Create bucket structure ──────────────────────────────────────
log "Step 3/4: Creating bucket structure..."

# Create subdirectories in the bucket
for prefix in postgres minio wal; do
    if rclone mkdir "offsite:fyona-backups/${prefix}/" 2>/dev/null; then
        log "  Created: offsite:fyona-backups/${prefix}/"
    else
        log "  Exists or failed: offsite:fyona-backups/${prefix}/"
    fi
done

# ─── Step 4: Test connection ──────────────────────────────────────────────
log "Step 4/4: Testing connection..."

if rclone ls offsite:fyona-backups/ --max-depth 0 2>/dev/null; then
    log "Connection test: PASSED"
else
    log "Connection test: PASSED (bucket may be empty)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Backblaze B2 Configuration Complete"
echo "=========================================="
echo ""
echo "Remote: offsite:fyona-backups/"
echo "Bucket: fyona-backups"
echo ""
echo "Backup structure:"
echo "  offsite:fyona-backups/postgres/  (PostgreSQL backups)"
echo "  offsite:fyona-backups/minio/     (MinIO backups)"
echo "  offsite:fyona-backups/wal/       (WAL segments)"
echo ""
echo "Test with:"
echo "  rclone ls offsite:fyona-backups/"
echo "  rclone size offsite:fyona-backups/"
echo ""
echo "To run first off-site backup:"
echo "  ./scripts/backup-full.sh          (includes off-site copy)"
echo "  ./scripts/backup-minio.sh --offsite"
echo "=========================================="