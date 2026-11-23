#!/bin/bash
# FYONA ERP Backup Alerting Hook
# Sends notifications on backup success/failure
# Usage: source this file, then call: alert_success "message" or alert_failure "message"
# Configuration via environment variables:
#   ALERT_WEBHOOK_URL - Slack/Discord/Telegram webhook URL
#   ALERT_EMAIL       - Email address for notifications
#   ALERT_METHOD      - "webhook", "email", or "both"

set -euo pipefail

ALERT_METHOD="${ALERT_METHOD:-webhook}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_HOSTNAME=$(hostname -f 2>/dev/null || echo "unknown")
ALERT_SERVICE="fyona-erp"

send_webhook() {
    local status="$1"
    local message="$2"
    local color="$3"

    if [ -z "${ALERT_WEBHOOK_URL}" ]; then
        return 0
    fi

    # Slack-compatible payload (also works with Discord)
    PAYLOAD=$(cat <<EOF
{
    "attachments": [{
        "color": "${color}",
        "title": "FYONA ERP Backup ${status}",
        "text": "${message}",
        "fields": [
            {"title": "Host", "value": "${ALERT_HOSTNAME}", "short": true},
            {"title": "Service", "value": "${ALERT_SERVICE}", "short": true},
            {"title": "Time", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": true}
        ]
    }]
}
EOF
)

    curl -s -X POST "${ALERT_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" >/dev/null 2>&1 || true
}

send_email() {
    local status="$1"
    local message="$2"

    if [ -z "${ALERT_EMAIL}" ] || ! command -v mail &> /dev/null; then
        return 0
    fi

    echo "${message}" | mail -s "[FYONA ERP] Backup ${status}" "${ALERT_EMAIL}" 2>/dev/null || true
}

alert_success() {
    local message="$1"
    log_alert "SUCCESS" "${message}"

    case "${ALERT_METHOD}" in
        webhook) send_webhook "SUCCESS" "${message}" "#36a64f" ;;
        email)   send_email "SUCCESS" "${message}" ;;
        both)
            send_webhook "SUCCESS" "${message}" "#36a64f"
            send_email "SUCCESS" "${message}"
            ;;
    esac
}

alert_failure() {
    local message="$1"
    log_alert "FAILURE" "${message}"

    case "${ALERT_METHOD}" in
        webhook) send_webhook "FAILURE" "${message}" "#ff0000" ;;
        email)   send_email "FAILURE" "${message}" ;;
        both)
            send_webhook "FAILURE" "${message}" "#ff0000"
            send_email "FAILURE" "${message}"
            ;;
    esac
}

alert_warning() {
    local message="$1"
    log_alert "WARNING" "${message}"

    case "${ALERT_METHOD}" in
        webhook) send_webhook "WARNING" "${message}" "#ffcc00" ;;
        email)   send_email "WARNING" "${message}" ;;
        both)
            send_webhook "WARNING" "${message}" "#ffcc00"
            send_email "WARNING" "${message}"
            ;;
    esac
}

log_alert() {
    local level="$1"
    local message="$2"
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] [ALERT][${level}] ${message}" >> "${BACKUP_DIR:-/opt/fyona/backups}/alerts.log"
}