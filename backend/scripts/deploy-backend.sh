#!/bin/bash
# ── FYONA ERP — Production Deploy Script ──
# Pulls images from GHCR (never builds on VPS), runs health checks,
# smoke tests, and auto-rollbacks on failure.
#
# Called by GitHub Actions CI/CD with DEPLOY_SHA set.
# Uses image versioning (SHA tags), never 'latest'.
# Enforces single-deployment lock using flock.
#
# Safety:
#   - Production database is NEVER modified
#   - Images are pulled from GHCR, never built on VPS
#   - Rollback uses previous image SHA tag (not latest)

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ── Configuration ──
DEST="/opt/fyona/backend"
LOG="/var/log/fyona/deploy.log"
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_READY_URL="http://127.0.0.1:8000/api/v1/health/ready"
HEALTH_LIVE_URL="http://127.0.0.1:8000/api/v1/health/live"
SMOKE_SCRIPT="${DEST}/scripts/smoke-tests.sh"
META_SCRIPT="${DEST}/scripts/deploy-metadata.sh"
SERVICES="api celery-worker celery-beat"
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.prod.yml"
LOCK_FILE="/opt/fyona/deploy.lock"
LOCK_TIMEOUT=30

GHCR_ORG="${GHCR_ORG:-fyona-erp}"
DEPLOY_SHA="${DEPLOY_SHA:?DEPLOY_SHA is required}"
GHCR_IMAGE="ghcr.io/${GHCR_ORG}/fyona-api"
ENV_FILE="${ENV_FILE:-.env.production}"
DEPLOY_GIT_SHA="${DEPLOY_GIT_SHA:-${DEPLOY_SHA}}"
DEPLOY_TIME="${DEPLOY_TIME:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

# ── Load backup encryption passphrase (for smoke tests that may need it) ──
if [ -f /opt/fyona/.backup-encryption-key ]; then
    export BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key)
fi

log(){ echo "[deploy $(date -u '+%FT%TZ')] $*" | tee -a "$LOG"; }

# ── Deployment Lock (using flock held by this process) ──
acquire_lock() {
    log "Acquiring deployment lock..."
    exec 200>"${LOCK_FILE}"
    for i in $(seq 1 ${LOCK_TIMEOUT}); do
        if flock -n 200; then
            echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|$$|acquired" > "${LOCK_FILE}.meta"
            log "LOCK_ACQUIRED pid=$$"
            return 0
        fi
        sleep 1
    done
    log "ERROR: Another deployment is in progress (timeout ${LOCK_TIMEOUT}s). Aborting."
    return 1
}

release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "${LOCK_FILE}.meta"
    log "LOCK_RELEASED"
}

lock_status() {
    if [ -f "${LOCK_FILE}.meta" ]; then
        local meta
        meta=$(cat "${LOCK_FILE}.meta" 2>/dev/null || echo "unknown")
        local time
        local pid
        time=$(echo "${meta}" | cut -d'|' -f1)
        pid=$(echo "${meta}" | cut -d'|' -f2)
        echo "LOCK_HELD since=${time} pid=${pid}"
    else
        echo "LOCK_FREE"
    fi
}

# Acquire lock and set trap for cleanup
acquire_lock || {
    exit 1
}
trap 'release_lock 2>/dev/null || true' EXIT INT TERM

# ── Rollback: revert to last-known-good SHA tag ──
rollback(){
    local prev_sha
    prev_sha=$(bash "${META_SCRIPT}" rollback-info 2>/dev/null | grep '^rollback_target_sha=' | cut -d= -f2)

    if [ -z "${prev_sha}" ]; then
        log "ROLLBACK_ABORTED: no previous successful deployment found"
        return 1
    fi

    log "Rolling back to SHA ${prev_sha}..."
    bash "${META_SCRIPT}" record "${prev_sha}" "ROLLING_BACK" "${DEPLOY_SHA}"

    cd "$DEST"
    DEPLOY_SHA="${prev_sha}" GHCR_ORG="${GHCR_ORG}" docker compose $COMPOSE_FILES \
        --env-file "$ENV_FILE" pull $SERVICES 2>&1

    DEPLOY_SHA="${prev_sha}" GHCR_ORG="${GHCR_ORG}" docker compose $COMPOSE_FILES \
        --env-file "$ENV_FILE" up -d --no-deps --force-recreate $SERVICES 2>&1

    # Wait for health check (up to 90s)
    log "Waiting for rollback health check..."
    for i in $(seq 1 45); do
    health_status=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_READY_URL" 2>/dev/null || echo "000")
        health_status="${health_status:-000}"
        if [ "$health_status" = "200" ]; then
            log "ROLLBACK_OK sha=${prev_sha} (after $((i*2))s)"
            bash "${META_SCRIPT}" record "${prev_sha}" "SUCCESS" "${DEPLOY_SHA}"
            return 0
        fi
        sleep 2
    done

    log "ROLLBACK_HEALTH_FAILED — manual intervention required"
    bash "${META_SCRIPT}" record "${prev_sha}" "FAILED" "${DEPLOY_SHA}"
    return 1
}

# ── Pre-flight checks ──
log "Pre-flight checks..."

[ -f "$ENV_FILE" ] || { log "ERROR: no env file at $ENV_FILE"; exit 1; }

# Authenticate to GHCR for image pulls
if [ -n "${GHCR_TOKEN:-}" ]; then
    log "Authenticating to GHCR..."
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_ORG:-fyona-erp}" --password-stdin 2>&1 | tail -1
fi

cd "$DEST"

# ── Record current deployment (for rollback) ──
CURRENT_SHA=$(cat /opt/fyona/.current-deploy 2>/dev/null || echo "none")
log "Current deployment: ${CURRENT_SHA}"
log "New deployment: ${DEPLOY_SHA} (git: ${DEPLOY_GIT_SHA})"
log "Deploy time: ${DEPLOY_TIME}"

# ── Pull new images from GHCR ──
log "Pulling ${GHCR_IMAGE}:${DEPLOY_SHA} from GHCR..."
docker pull "${GHCR_IMAGE}:${DEPLOY_SHA}" || { log "ERROR: docker pull failed"; exit 1; }

# ── Graceful shutdown: send SIGTERM to current containers ──
log "Stopping current containers..."
DEPLOY_SHA="$DEPLOY_SHA" GHCR_ORG="$GHCR_ORG" docker compose $COMPOSE_FILES \
    --env-file "$ENV_FILE" stop $SERVICES 2>&1 || true

# ── Deploy new containers ──
log "Starting new containers with SHA=${DEPLOY_SHA}..."
DEPLOY_SHA="$DEPLOY_SHA" GHCR_ORG="$GHCR_ORG" docker compose $COMPOSE_FILES \
    --env-file "$ENV_FILE" up -d --no-deps $SERVICES 2>&1
log "Containers started."

# ── Health gate: wait for readiness (up to 90s) ──
log "Waiting for health check (readiness probe)..."
HEALTH_OK=false
for i in $(seq 1 45); do
    health_status=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_READY_URL" 2>/dev/null || echo "000")
    if [ "$health_status" = "200" ]; then
        HEALTH_OK=true
        log "Health check passed (after $((i*2))s)"
        break
    fi
    sleep 2
done

if [ "$HEALTH_OK" != "true" ]; then
    log "HEALTH_FAILED — attempting rollback"
    DEPLOY_SHA="$DEPLOY_SHA" GHCR_ORG="$GHCR_ORG" docker compose $COMPOSE_FILES --env-file "$ENV_FILE" logs --tail 80 api >> "$LOG" 2>&1 || true
    if rollback; then exit 0; else exit 1; fi
fi

# ── Celery gate: verify workers are running ──
CELERY_FAIL=""
for ctr in fyona-celery fyona-celery-beat; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null || echo 'missing')" != "true" ]; then
        log "CELERY_NOT_RUNNING: $ctr"
        CELERY_FAIL=1
    fi
done
if [ -n "$CELERY_FAIL" ]; then
    log "CELERY_GATE_FAILED — attempting rollback"
    if rollback; then exit 0; else exit 1; fi
fi

# ── Smoke tests ──
log "Running smoke tests..."
if [ -f "$SMOKE_SCRIPT" ] && [ -x "$SMOKE_SCRIPT" ]; then
    if ! bash "$SMOKE_SCRIPT"; then
        log "SMOKE_TESTS_FAILED — attempting rollback"
        if rollback; then exit 0; else exit 1; fi
    fi
else
    log "WARN: smoke script not found or not executable at $SMOKE_SCRIPT"
fi

# ── Record successful deployment ──
bash "${META_SCRIPT}" record "${DEPLOY_GIT_SHA}" "SUCCESS" "${CURRENT_SHA}"

# ── Log deployed version ──
DEPLOYED_VERSION=$(curl -sf "${HEALTH_URL}" 2>/dev/null || echo "{}")
log "=========================================="
log "DEPLOY_OK"
log "  SHA: ${DEPLOY_SHA}"
log "  Git: ${DEPLOY_GIT_SHA}"
log "  Time: ${DEPLOY_TIME}"
log "  Previous: ${CURRENT_SHA}"
log "  Health: ${DEPLOYED_VERSION}"
log "=========================================="

# ── Deploy FYONA Admin Panel (if files exist on server) ──
ADMIN_DIR="/opt/fyona/admin"
ADMIN_WEB="${ADMIN_DIR}/web"

# Copy admin files from /tmp if CI/CD staged them there
if [ -d "/tmp/fyona-admin" ]; then
    log "Staging admin files from /tmp/fyona-admin..."
    mkdir -p "${ADMIN_DIR}/server" "${ADMIN_WEB}" 2>/dev/null || true
    cp -r /tmp/fyona-admin/server/* "${ADMIN_DIR}/server/" 2>/dev/null || true
    cp -r /tmp/fyona-admin/web/* "${ADMIN_WEB}/" 2>/dev/null || true
    # Copy deploy-admin.sh to /opt/fyona/bin before cleanup
    if [ -f /tmp/fyona-admin/deploy-admin.sh ]; then
        cp /tmp/fyona-admin/deploy-admin.sh /opt/fyona/bin/deploy-admin.sh 2>/dev/null || true
    fi
    rm -rf /tmp/fyona-admin
    log "Admin files staged to ${ADMIN_DIR}"
fi
if [ -f "${ADMIN_DIR}/server/admin_server.py" ]; then
    log "Deploying FYONA Admin Panel..."
    mkdir -p "${ADMIN_DIR}/server" "${ADMIN_WEB}" 2>/dev/null || true
    pip3 install -q fastapi uvicorn httpx 2>/dev/null || true

    # Generate .env with MASTER_KEY from backend
    ADMIN_MASTER=$(grep '^ADMIN_MASTER_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [ -n "$ADMIN_MASTER" ]; then
        printf 'FYONA_API=http://127.0.0.1:8001\nADMIN_EMAIL=admin@fyona.erp\nADMIN_PASSWORD=msf$mrold$fyona_erp\nADMIN_MASTER_KEY=%s\n' "$ADMIN_MASTER" > "${ADMIN_DIR}/server/.env"
    fi

    # Create systemd service
    cat > /etc/systemd/system/fyona-admin.service << 'ADMINEOF'
[Unit]
Description=FYONA Admin Panel
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/fyona/admin/server
ExecStart=/usr/bin/python3 -m uvicorn admin_server:app --host 0.0.0.0 --port 8080 --log-level info
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
ADMINEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable fyona-admin 2>/dev/null || true
    systemctl restart fyona-admin 2>/dev/null || true
    sleep 2
    if curl -sf http://127.0.0.1:8080/api/version > /dev/null 2>&1; then
        log "ADMIN_PANEL_OK: running on port 8080"
    else
        log "ADMIN_PANEL: service restarted (files may not exist yet)"
    fi

    # Configure nginx reverse proxy for admin.dssdfs.fun (needs DNS A record)
    # aaPanel manages nginx in /www/server/panel/vhost/nginx/
    VHOST_DIR="/www/server/panel/vhost/nginx"
    [ ! -d "$VHOST_DIR" ] && VHOST_DIR="/etc/nginx/conf.d"
    NGINX_CONF="${VHOST_DIR}/admin.dssdfs.fun.conf"
    if [ ! -f "$NGINX_CONF" ]; then
        # Find existing SSL cert from api.dssdfs.fun
        SSL_CERT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | head -1)
        SSL_KEY=$(find /etc/letsencrypt/live -name "privkey.pem" 2>/dev/null | head -1)
        if [ -n "$SSL_CERT" ] && [ -f "$SSL_CERT" ]; then
            cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    server_name admin.dssdfs.fun;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name admin.dssdfs.fun;
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    client_max_body_size 50M;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINXEOF
            log "Nginx config created for admin.dssdfs.fun (SSL)"
        else
            cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    server_name admin.dssdfs.fun;
    client_max_body_size 50M;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINXEOF
            log "Nginx config created for admin.dssdfs.fun (HTTP only)"
        fi
        nginx -t 2>&1 && (nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true) || true
    fi
fi

exit 0
