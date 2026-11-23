#!/usr/bin/env bash
# ── FYONA ERP Monitoring Stack Deployment ──
# Usage: bash deploy-monitoring.sh [up|down|status|logs]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.monitoring.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }

# ── Preflight checks ──
preflight() {
    # Check .env file
    if [[ ! -f "$ENV_FILE" ]]; then
        err ".env file not found at $ENV_FILE"
        echo "Copy .env.example to .env and fill in the values:"
        echo "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
        echo "  nano ${SCRIPT_DIR}/.env"
        exit 1
    fi

    # Source .env for GF_SECURITY_ADMIN_PASSWORD
    set -a
    source "$ENV_FILE"
    set +a

    if [[ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" ]]; then
        err "GF_SECURITY_ADMIN_PASSWORD is not set in .env"
        exit 1
    fi

    # Check backend is running
    if ! docker ps --format '{{.Names}}' | grep -q 'fyona-api'; then
        warn "fyona-api container not found. Is the backend stack running?"
        echo "  Start with: cd /opt/fyona/backend && docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.production up -d"
        exit 1
    fi

    # Create monitoring_net if it doesn't exist
    if ! docker network ls --format '{{.Name}}' | grep -q 'backend_monitoring_net'; then
        log "Creating monitoring_net..."
        docker network create backend_monitoring_net
    fi
}

# ── Connect backend containers to monitoring network ──
connect_backend() {
    log "Connecting backend containers to monitoring network..."
    local containers=("fyona-api" "fyona-db" "fyona-redis")
    for c in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
            if ! docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "backend_monitoring_net"}}found{{end}}{{end}}' 2>/dev/null | grep -q 'found'; then
                docker network connect backend_monitoring_net "$c" 2>/dev/null || true
                log "  Connected: $c"
            else
                log "  Already connected: $c"
            fi
        else
            warn "  Container not running: $c"
        fi
    done
}

# ── Deploy monitoring stack ──
deploy_up() {
    preflight
    connect_backend

    log "Starting monitoring stack..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

    log "Waiting for Prometheus to be healthy..."
    for i in $(seq 1 30); do
        if docker inspect fyona-prometheus --format '{{.State.Health.Status}}' 2>/dev/null | grep -q 'healthy'; then
            log "Prometheus is healthy"
            break
        fi
        sleep 2
    done

    log "Waiting for Grafana to be healthy..."
    for i in $(seq 1 30); do
        if docker inspect fyona-grafana --format '{{.State.Health.Status}}' 2>/dev/null | grep -q 'healthy'; then
            log "Grafana is healthy"
            break
        fi
        sleep 2
    done

    echo ""
    log "═══════════════════════════════════════════════════════"
    log "  Monitoring stack deployed!"
    log "═══════════════════════════════════════════════════════"
    log ""
    log "  Grafana:   http://localhost:3000"
    log "             user: admin"
    log "             pass: (from .env GF_SECURITY_ADMIN_PASSWORD)"
    log ""
    log "  Prometheus: http://localhost:9090"
    log ""
    log "  Dashboards: FYONA API, System, Database, Redis, Docker"
    log "  Alerts:     Email + Telegram (configure in .env)"
    log ""
    log "  Verify targets: http://localhost:9090/targets"
    log "  Verify alerts:  http://localhost:9090/alerts"
    log "═══════════════════════════════════════════════════════"
}

# ── Tear down ──
deploy_down() {
    log "Stopping monitoring stack..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down

    log "Disconnecting backend containers from monitoring network..."
    local containers=("fyona-api" "fyona-db" "fyona-redis")
    for c in "${containers[@]}"; do
        docker network disconnect backend_monitoring_net "$c" 2>/dev/null || true
    done

    log "Monitoring stack stopped."
}

# ── Status ──
deploy_status() {
    log "═══ Monitoring Stack Status ═══"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
    echo ""
    log "═══ Backend → Monitoring Network ═══"
    docker network inspect backend_monitoring_net --format '{{range .Containers}}  {{.Name}} ({{.IPv4Address}})
{{end}}' 2>/dev/null || echo "  Network not found"
    echo ""
    log "═══ Prometheus Targets ═══"
    curl -s http://localhost:9090/api/v1/targets 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data', {}).get('activeTargets', []):
    print(f\"  {t['labels'].get('job','?'):25s} {t['health']:10s} {t['scrapeUrl']}\")
" 2>/dev/null || echo "  Prometheus not reachable"
}

# ── Logs ──
deploy_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f --tail=50
}

# ── Main ──
case "${1:-up}" in
    up)     deploy_up ;;
    down)   deploy_down ;;
    status) deploy_status ;;
    logs)   deploy_logs ;;
    *)
        echo "Usage: $0 [up|down|status|logs]"
        exit 1
        ;;
esac
