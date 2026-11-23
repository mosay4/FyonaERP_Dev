#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/fyona/deploy.log
log(){ echo "[migrate $(date -u '+%FT%TZ')] $*" | tee -a "$LOG"; }

# Authenticate to GHCR for image pulls
if [ -n "${GHCR_TOKEN:-}" ]; then
    log "Authenticating to GHCR..."
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_ORG:-fyona-erp}" --password-stdin 2>&1 | tail -1
fi

log "starting alembic upgrade head"
cd /opt/fyona/backend

# Ensure we have the latest image
DEPLOY_SHA="${DEPLOY_SHA:-$(cat /opt/fyona/.current-deploy 2>/dev/null || echo 'latest')}"
GHCR_IMAGE="ghcr.io/${GHCR_ORG:-fyona-erp}/fyona-api"
log "Using image: ${GHCR_IMAGE}:${DEPLOY_SHA}"

docker pull "${GHCR_IMAGE}:${DEPLOY_SHA}" 2>&1 || log "WARN: pull failed, using cached image"

docker compose -f docker-compose.yml -f docker-compose.prod.yml \
    --env-file .env.production run --rm \
    -e DEPLOY_SHA="${DEPLOY_SHA}" \
    api alembic upgrade head 2>&1

log "migrations applied successfully"
