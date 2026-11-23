#!/bin/bash
# Test concurrent lock acquisition
set -euo pipefail

LOCK_FILE="/opt/fyona/deploy.lock"

# Clean up any stale lock
rm -f "${LOCK_FILE}" "${LOCK_FILE}.meta"

echo "=== Test 1: Lock acquire + hold ==="
(
    exec 200>"${LOCK_FILE}"
    if flock -n 200; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|test_pid|acquired" > "${LOCK_FILE}.meta"
        echo "LOCK_HELD_BY_TEST"
        sleep 8
    fi
) &
HOLDER_PID=$!
sleep 2

echo "=== Test 2: Lock status while held ==="
cat "${LOCK_FILE}.meta" 2>/dev/null || echo "meta: unknown"

echo "=== Test 3: Second acquire should be blocked ==="
(
    exec 200>"${LOCK_FILE}"
    if flock -n 200; then
        echo "LOCK_ACQUIRED_BY_SECOND"
    else
        echo "LOCK_BLOCKED_AS_EXPECTED"
    fi
) &
SECOND_PID=$!
sleep 2

echo "=== Test 4: First process should still hold lock ==="
cat "${LOCK_FILE}.meta" 2>/dev/null || echo "meta: unknown"

# Cleanup
wait $HOLDER_PID 2>/dev/null
wait $SECOND_PID 2>/dev/null
rm -f "${LOCK_FILE}" "${LOCK_FILE}.meta"

echo "=== Test 5: Lock should be free after release ==="
(
    exec 200>"${LOCK_FILE}"
    if flock -n 200; then
        echo "LOCK_ACQUIRED_AFTER_RELEASE"
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|release_test|acquired" > "${LOCK_FILE}.meta"
    else
        echo "LOCK_STILL_HELD"
    fi
) &
wait $! 2>/dev/null
rm -f "${LOCK_FILE}" "${LOCK_FILE}.meta"

echo "=== ALL LOCK TESTS COMPLETE ==="
