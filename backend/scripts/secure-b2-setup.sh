#!/bin/bash
# FYONA ERP — Secure B2 Interactive Setup
# Prompts for B2 credentials WITHOUT echoing to terminal
# Credentials are NEVER written to Git, logs, or source code
# rclone.conf is created with 600 permissions

set -euo pipefail

RCLONE="/usr/bin/rclone"
CONFIG_DIR="${HOME}/.config/rclone"
CONFIG_FILE="${CONFIG_DIR}/rclone.conf"
BUCKET="${1:-fyona-backups}"

echo "=============================================="
echo "FYONA ERP — Backblaze B2 Configuration (Secure)"
echo "=============================================="
echo ""
echo "This script will configure rclone for B2."
echo "Credentials will be hidden and never logged."
echo "Bucket: ${BUCKET}"
echo ""

# ─── Secure credential input (no echo) ────────────────────────────────────────
read -s -p "B2 Key ID (starts with 01...): " B2_KEY_ID
echo ""
read -s -p "B2 Application Key (starts with K00...): " B2_APPLICATION_KEY
echo ""
echo ""

# Validate inputs
if [ -z "${B2_KEY_ID}" ] || [ -z "${B2_APPLICATION_KEY}" ]; then
    echo "ERROR: Both credentials are required. Aborting."
    exit 1
fi

# ─── Configure rclone ───────────────────────────────────────────────────────
echo "Configuring rclone..."

mkdir -p "${CONFIG_DIR}"
chmod 700 "${CONFIG_DIR}"

# Write rclone config
cat > "${CONFIG_FILE}" << EOF
[b2]
type = b2
provider = B2
account = ${B2_KEY_ID}
key = ${B2_APPLICATION_KEY}
endpoint =
location =
acl =
hard_delete = false
server_side_acls =
upload_cutoff = 0
versions =
EOF

chmod 600 "${CONFIG_FILE}"

# ─── Verify connectivity (NO credential display) ─────────────────────────────
echo ""
echo "Verifying connectivity to B2..."
echo ""
echo "Available buckets:"
${RCLONE} lsd b2: 2>&1

echo ""
echo "Checking bucket '${BUCKET}'..."
if ${RCLONE} ls "b2:${BUCKET}" 2>&1; then
    echo "Bucket '${BUCKET}' exists and is accessible."
else
    echo "Bucket '${BUCKET}' does not exist. Creating..."
    ${RCLONE} mkdir "b2:${BUCKET}" 2>&1
    echo "Bucket created."
fi

# ─── Final security verification ────────────────────────────────────────────
echo ""
echo "Security verification:"
echo "  rclone.conf permissions: $(stat -c '%a' "${CONFIG_FILE}")"
echo "  rclone.conf owner: $(stat -c '%U' "${CONFIG_FILE}")"
echo ""

# Clear clipboard (if any)
B2_KEY_ID=""
B2_APPLICATION_KEY=""
unset B2_KEY_ID B2_APPLICATION_KEY

echo "=============================================="
echo "✅ B2 configuration complete."
echo "   Bucket: ${BUCKET}"
echo "   Config: ${CONFIG_FILE} (perms 600)"
echo "   Credentials NOT stored in Git or logs."
echo "=============================================="
