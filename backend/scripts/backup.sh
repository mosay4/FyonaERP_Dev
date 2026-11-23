#!/bin/bash
# FYONA ERP Database Backup Script
# Wrapper for backup-full.sh (backward compatible)
# Usage: ./scripts/backup.sh [output_dir]
# Default output: ./backups/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-./backups}"

# Delegate to full backup script
exec "${SCRIPT_DIR}/backup-full.sh" --no-offsite --no-encrypt
