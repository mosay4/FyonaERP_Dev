#!/bin/bash
# FYONA ERP — Deployment Lock Utility
# Prevents concurrent production deployments using flock-based file locking.
#
# The lock is acquired via a subshell that holds the fd open. The caller
# (deploy-backend.sh) sources this file to access the lock functions.
#
# Usage (sourced from deploy-backend.sh):
#   source /opt/fyona/backend/scripts/deploy-lock.sh
#   lock_acquire   # Blocks up to LOCK_TIMEOUT, exits on timeout
#   lock_release   # Releases the lock
#   lock_status    # Prints lock status

LOCK_FILE="${LOCK_FILE:-/opt/fyona/deploy.lock}"
LOCK_TIMEOUT=30
LOCK_FD=200

lock_acquire() {
    # Open fd 200 for the lock file (if not already open)
    exec 200>"${LOCK_FILE}"

    # Try to acquire with retry loop
    for i in $(seq 1 ${LOCK_TIMEOUT}); do
        if flock -n 200; then
            # Write metadata for status tracking
            echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|$$|acquired" > "${LOCK_FILE}.meta"
            echo "LOCK_ACQUIRED pid=$$"
            return 0
        fi
        sleep 1
    done

    # Timeout
    local holder
    holder=$(cat "${LOCK_FILE}.meta" 2>/dev/null | head -1)
    local held_since
    held_since=$(echo "${holder}" | cut -d'|' -f1)
    echo "LOCK_TIMEOUT: deployment already in progress (started: ${held_since})" >&2
    return 1
}

lock_release() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "${LOCK_FILE}.meta"
    echo "LOCK_RELEASED"
}

lock_status() {
    if [ -f "${LOCK_FILE}.meta" ]; then
        local meta
        meta=$(cat "${LOCK_FILE}.meta" 2>/dev/null || echo "unknown")
        local time
        local pid
        time=$(echo "${meta}" | cut -d'|' -f1)
        pid=$(echo "${meta}" | cut -d'|' -f2)
        if kill -0 "${pid}" 2>/dev/null; then
            echo "LOCK_HELD since=${time} pid=${pid} (process running)"
        else
            echo "LOCK_STALE since=${time} pid=${pid} (process exited — stale lock)"
        fi
    else
        echo "LOCK_FREE"
    fi
}

# If called directly (not sourced), run the requested action
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-status}" in
        acquire)
            lock_acquire && exit 0 || exit 1
            ;;
        release)
            lock_release
            ;;
        status)
            lock_status
            ;;
        *)
            echo "Usage: $0 {acquire|release|status}"
            echo "  Or source this file from deploy-backend.sh:"
            echo "  source $0; lock_acquire; ...; lock_release"
            exit 1
            ;;
    esac
fi
