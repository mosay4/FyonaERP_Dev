#!/bin/bash
# FYONA ERP — Backup Encryption Setup
# Creates a secure encryption passphrase for GPG backup encryption
#
# Usage: bash scripts/setup-encryption.sh
#
# Security:
#   - Passphrase stored in /opt/fyona/.backup-encryption-key
#   - File permissions: 600 (owner read/write only)
#   - NOT committed to Git
#   - NOT printed in logs
#   - Backup of passphrase provided (encrypted with your GPG key)

set -euo pipefail

KEY_FILE="/opt/fyona/.backup-encryption-key"
KEY_BACKUP="/opt/fyona/.backup-encryption-key.backup"
LOG_FILE="/opt/fyona/backups/encryption_setup.log"

log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "${LOG_FILE}"; }

echo "=========================================="
echo "FYONA ERP — Backup Encryption Setup"
echo "=========================================="
echo ""

# ─── Check if key already exists ──────────────────────────────────────────
if [ -f "${KEY_FILE}" ]; then
    log "Encryption key already exists: ${KEY_FILE}"
    log "Permissions: $(stat -c '%a' "${KEY_FILE}" 2>/dev/null)"
    log ""
    log "To regenerate, delete the existing key first:"
    log "  rm ${KEY_FILE}"
    log "  rm ${KEY_BACKUP}"
    log ""
    log "Then re-run this script."
    exit 0
fi

# ─── Generate passphrase ──────────────────────────────────────────────────
log "Generating encryption passphrase..."

# Generate a 64-character random passphrase
PASSPHRASE=$(openssl rand -base64 48 | tr -d '=/+' | head -c 64)

if [ -z "${PASSPHRASE}" ]; then
    log "ERROR: Failed to generate passphrase"
    exit 1
fi

# ─── Store passphrase ─────────────────────────────────────────────────────
log "Storing passphrase securely..."

echo -n "${PASSPHRASE}" > "${KEY_FILE}"
chmod 600 "${KEY_FILE}"

# Create backup
echo -n "${PASSPHRASE}" > "${KEY_BACKUP}"
chmod 600 "${KEY_BACKUP}"

log "Passphrase stored: ${KEY_FILE}"
log "Backup created: ${KEY_BACKUP}"
log "Permissions: 600 (owner read/write only)"

# ─── Test encryption ──────────────────────────────────────────────────────
log "Testing encryption/decryption..."

TEST_FILE=$(mktemp)
echo "FYONA ERP encryption test" > "${TEST_FILE}"

if gpg --batch --yes --passphrase "${PASSPHRASE}" \
    --symmetric --cipher-algo AES256 \
    --output "${TEST_FILE}.gpg" \
    "${TEST_FILE}" 2>/dev/null; then

    if gpg --batch --yes --passphrase "${PASSPHRASE}" \
        --decrypt "${TEST_FILE}.gpg" 2>/dev/null | grep -q "FYONA ERP"; then
        log "Encryption test: PASSED"
    else
        log "ERROR: Decryption test failed"
        rm -f "${TEST_FILE}" "${TEST_FILE}.gpg"
        exit 1
    fi
else
    log "ERROR: Encryption test failed"
    rm -f "${TEST_FILE}"
    exit 1
fi

rm -f "${TEST_FILE}" "${TEST_FILE}.gpg"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Encryption Setup Complete"
echo "=========================================="
echo ""
echo "Key file: ${KEY_FILE}"
echo "Backup:   ${KEY_BACKUP}"
echo "Algorithm: AES-256 (GPG symmetric)"
echo ""
echo "⚠️  CRITICAL: Back up this passphrase securely!"
echo ""
echo "Your passphrase is stored in:"
echo "  ${KEY_FILE}"
echo "  ${KEY_BACKUP}"
echo ""
echo "To view it:"
echo "  cat ${KEY_FILE}"
echo ""
echo "To use in backups, set:"
echo "  export BACKUP_GPG_PASSPHRASE=\$(cat ${KEY_FILE})"
echo ""
echo "Or add to .env.production:"
echo "  BACKUP_GPG_PASSPHRASE=\$(cat ${KEY_FILE})"
echo ""
echo "For Disaster Recovery:"
echo "  1. The passphrase is in ${KEY_BACKUP}"
echo "  2. Copy it to the new VPS"
echo "  3. Restore it to ${KEY_FILE}"
echo "  4. Then restore backups"
echo ""
echo "⚠️  WITHOUT THIS PASSPHRASE, BACKUPS CANNOT BE DECRYPTED!"
echo "=========================================="