#!/bin/bash
# FYONA ERP Database Restore Script
# Usage: ./scripts/restore.sh <backup_file.sql.gz>

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <backup_file.sql.gz>"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "${BACKUP_FILE}" ]; then
    echo "Error: File ${BACKUP_FILE} not found!"
    exit 1
fi

echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Starting restore from: ${BACKUP_FILE}"

# Decompress and restore
zcat "${BACKUP_FILE}" | docker compose exec -T db psql \
    --username="${POSTGRES_USER:-fyona}" \
    --dbname="${POSTGRES_DB:-fyona_erp}"

echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Restore complete."
