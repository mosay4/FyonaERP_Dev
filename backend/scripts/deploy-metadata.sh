#!/bin/bash
# FYONA ERP — Deployment Metadata Tracker
# Records deployment information to a file that survives container restarts.
#
# Usage:
#   deploy-metadata.sh record <sha> <image_tag> <status> <previous_sha>
#   deploy-metadata.sh current
#   deploy-metadata.sh history [n]
#   deploy-metadata.sh rollback-info

META_FILE="/opt/fyona/deploy.history"

mkdir -p "$(dirname "${META_FILE}")"

record() {
    # Args: sha, status, previous_sha
    local sha="$1"
    local status="$2"
    local prev="$3"
    local ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local entry="${ts}|${sha}|${status}|${prev}"

    echo "${entry}" >> "${META_FILE}"

    # Keep last 50 entries
    tail -50 "${META_FILE}" > "${META_FILE}.tmp"
    mv "${META_FILE}.tmp" "${META_FILE}"

    # Also write current deployment info
    echo "${sha}" > /opt/fyona/.current-deploy
    echo "${ts}" > /opt/fyona/.current-deploy-time

    echo "RECORDED ${sha} status=${status} prev=${prev}"
}

case "${1:-current}" in
    record)
        record "$2" "$3" "$4"
        ;;
    current)
        if [ -f /opt/fyona/.current-deploy ]; then
            SHA=$(cat /opt/fyona/.current-deploy)
            TS=$(cat /opt/fyona/.current-deploy-time 2>/dev/null || echo "unknown")
            echo "current_sha=${SHA}"
            echo "deployed_at=${TS}"
        else
            echo "no deployment recorded"
        fi
        ;;
    history)
        N="${2:-10}"
        tail -n "${N}" "${META_FILE}" 2>/dev/null || echo "no history"
        ;;
    rollback-info)
        # Show last successful deployment (for rollback reference)
        grep '|SUCCESS' "${META_FILE}" 2>/dev/null | tail -1 | while IFS='|' read ts sha status prev; do
            echo "rollback_target_sha=${sha}"
            echo "rollback_target_time=${ts}"
            echo "previous_sha=${prev}"
        done
        ;;
    *)
        echo "Usage: $0 {record <sha> <status> <prev_sha>|current|history [n]|rollback-info}"
        exit 1
        ;;
esac
