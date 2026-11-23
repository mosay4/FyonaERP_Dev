#!/bin/bash
# FYONA ERP WAL Archive Configuration
# Enables PostgreSQL WAL archiving for Point-in-Time Recovery
# Run ONCE during initial setup, then restart PostgreSQL
# Usage: ./scripts/setup-wal-archiving.sh
#
# PREREQUISITE: docker-compose.yml must mount the WAL archive directory:
#   volumes:
#     - pgdata:/var/lib/postgresql/data
#     - /opt/fyona/backups/wal:/var/lib/postgresql/wal_archive
# Without this mount, the archive_command cannot write outside the container.

set -euo pipefail

WAL_ARCHIVE_DIR="${WAL_ARCHIVE_DIR:-/opt/fyona/backups/wal}"
CONTAINER_WAL_ARCHIVE="/var/lib/postgresql/wal_archive"
LOG_FILE="${WAL_ARCHIVE_DIR}/wal_archive.log"

log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "${LOG_FILE}"
}

log "=========================================="
log "Configuring WAL Archiving for PITR"
log "=========================================="

# ─── Step 1: Verify volume mount exists ────────────────────────────────────
log "Step 1/4: Verifying volume mount..."

MOUNT_CHECK=$(docker compose exec -T db sh -c "test -d ${CONTAINER_WAL_ARCHIVE} && echo 'exists' || echo 'missing'" 2>/dev/null || echo "error")

if [ "${MOUNT_CHECK}" != "exists" ]; then
    log "ERROR: WAL archive directory not mounted at ${CONTAINER_WAL_ARCHIVE}"
    log ""
    log "You MUST add this volume mount to docker-compose.yml under the 'db' service:"
    log ""
    log "  db:"
    log "    volumes:"
    log "      - pgdata:/var/lib/postgresql/data"
    log "      - ${WAL_ARCHIVE_DIR}:${CONTAINER_WAL_ARCHIVE}"
    log ""
    log "After adding the mount, run: docker compose up -d db"
    log "Then re-run this script."
    log "=========================================="
    exit 1
fi
log "Volume mount verified: ${CONTAINER_WAL_ARCHIVE}"

# ─── Step 2: Create WAL archive directory on host ──────────────────────────
log "Step 2/4: Creating WAL archive directory..."
mkdir -p "${WAL_ARCHIVE_DIR}"
log "WAL archive directory: ${WAL_ARCHIVE_DIR}"

# ─── Step 3: Apply PostgreSQL configuration for WAL archiving ──────────────
log "Step 3/4: Applying PostgreSQL configuration..."

docker compose exec -T db psql \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${POSTGRES_DB:-fyona_erp}" \
    --command="
    ALTER SYSTEM SET wal_level = replica;
    ALTER SYSTEM SET archive_mode = on;
    ALTER SYSTEM SET archive_command = 'test ! -f ${CONTAINER_WAL_ARCHIVE}/%f && cp %p ${CONTAINER_WAL_ARCHIVE}/%f';
    ALTER SYSTEM SET archive_timeout = 300;
    ALTER SYSTEM SET max_replication_slots = 4;
    ALTER SYSTEM SET max_wal_senders = 4;
    ALTER SYSTEM SET wal_keep_size = '1GB';
    ALTER SYSTEM SET checkpoint_timeout = '15min';
    ALTER SYSTEM SET checkpoint_completion_target = 0.9;
    " 2>&1 | tee -a "${LOG_FILE}"

# ─── Step 4: Verify configuration ──────────────────────────────────────────
log "Step 4/4: Verifying configuration..."

WAL_LEVEL=$(docker compose exec -T db psql \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${POSTGRES_DB:-fyona_erp}" \
    --tuples-only --command="SHOW wal_level;" 2>/dev/null | tr -d '[:space:]')

ARCHIVE_MODE=$(docker compose exec -T db psql \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${POSTGRES_DB:-fyona_erp}" \
    --tuples-only --command="SHOW archive_mode;" 2>/dev/null | tr -d '[:space:]')

log "wal_level = ${WAL_LEVEL} (will take effect after restart)"
log "archive_mode = ${ARCHIVE_MODE} (will take effect after restart)"

log ""
log "=========================================="
log "PostgreSQL configuration applied."
log ""
log "⚠️  IMPORTANT: WAL changes require a PostgreSQL restart."
log ""
log "Run: docker compose restart db"
log ""
log "After restart, verify with:"
log "  docker compose exec -T db psql -U fyona -d fyona_erp -c \"SHOW wal_level;\""
log "  docker compose exec -T db psql -U fyona -d fyona_erp -c \"SHOW archive_mode;\""
log "  ls -la ${WAL_ARCHIVE_DIR}/"
log "=========================================="