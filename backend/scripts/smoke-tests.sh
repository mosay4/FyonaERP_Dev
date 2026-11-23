#!/bin/bash
# ── FYONA ERP — Post-Deploy Smoke Tests ──
# Verifies that the deployed API is serving requests correctly AND
# that critical functional endpoints are operational.
# Exit 0 = all tests passed, Exit 1 = failure.

set -euo pipefail

BASE_URL="${HEALTH_URL:-http://127.0.0.1:8000}"
API_PREFIX="/api/v1"
PASS=0
FAIL=0
WARN=0

test_endpoint() {
    local method=$1 path=$2 expect_status=$3 desc=$4 body="${5:-}"
    local url="${BASE_URL}${path}"
    local args=(-s -o /dev/null -w "%{http_code}" -X "$method" --max-time 10)

    if [ -n "$body" ]; then
        args+=(-H "Content-Type: application/json" -d "$body")
    fi

    local status
    status=$(curl "${args[@]}" "$url" 2>/dev/null || echo "000")

    if [ "$status" = "$expect_status" ]; then
        echo "  ✓ $desc (HTTP $status)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc — expected $expect_status, got $status"
        FAIL=$((FAIL + 1))
    fi
}

test_json_field() {
    local path=$1 field=$2 expected=$3 desc=$4
    local url="${BASE_URL}${path}"
    local response
    response=$(curl -sf --max-time 10 "$url" 2>/dev/null || echo "{}")
    local value
    value=$(echo "$response" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"//;s/"$//' || echo "")

    if [ "$value" = "$expected" ]; then
        echo "  ✓ $desc (field='$field'='$value')"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc — expected '$expected', got '$value'"
        FAIL=$((FAIL + 1))
    fi
}

test_response_time() {
    local path=$1 max_ms=$2 desc=$3
    local url="${BASE_URL}${path}"
    local time_ms
    time_ms=$(curl -sf -o /dev/null -w "%{time_total}" --max-time 10 "$url" 2>/dev/null || echo "99")
    time_ms=$(echo "$time_ms" | awk '{printf "%d", $1 * 1000}')

    if [ "$time_ms" -lt "$max_ms" ]; then
        echo "  ✓ $desc (${time_ms}ms < ${max_ms}ms)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (${time_ms}ms >= ${max_ms}ms)"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════"
echo "  FYONA ERP — Post-Deploy Smoke Tests"
echo "═══════════════════════════════════════"
echo "Target: $BASE_URL"
echo "Time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ── Section 1: Health & Infrastructure ──
echo "── Health & Infrastructure ──"

# 1. Liveness — process alive (prefixed route under /api/v1)
test_endpoint GET "${API_PREFIX}/health/live" "200" "Liveness check (process alive)"

# 2. Readiness — all critical deps available (prefixed route)
test_endpoint GET "${API_PREFIX}/health/ready" "200" "Readiness check (DB + Redis + MinIO)"

# 3. Full health — verbose dependency checks (top-level route)
test_endpoint GET "/health" "200" "Full health check"

# 4. Health contains dependency checks
test_json_field "/health" "database" "ok" "Health: database = ok"
test_json_field "/health" "redis" "ok" "Health: redis = ok"

# 5. Version — must contain commit SHA
VERSION_RESPONSE=$(curl -sf "${BASE_URL}/version" 2>/dev/null || echo "{}")
if echo "$VERSION_RESPONSE" | grep -q '"commit"'; then
    COMMIT_SHA=$(echo "$VERSION_RESPONSE" | grep -o '"commit"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//;s/"$//')
    APP_VERSION=$(echo "$VERSION_RESPONSE" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//;s/"$//')
    echo "  ✓ Version endpoint (app=${APP_VERSION}, commit=${COMMIT_SHA:0:12})"
    PASS=$((PASS + 1))
else
    echo "  ✗ Version endpoint missing commit SHA"
    FAIL=$((FAIL + 1))
fi

# 6. Response time — health must respond quickly
test_response_time "/health" 3000 "Health response time (<3s)"

echo ""

# ── Section 2: Functional Endpoints (Public, DB-reading) ──
echo "── Functional Endpoints (Public, DB-backed) ──"

# 7. Subscription plans — public, reads from DB
test_endpoint GET "${API_PREFIX}/subscription/plans" "200" "Subscription plans (public, reads DB)"

# 8. Active banners — public, reads from DB
test_endpoint GET "${API_PREFIX}/banners" "200" "Active banners (public, reads DB)"

echo ""

# ── Section 3: Auth Flow ──
echo "── Auth Flow ──"

# 9. Auth login — POST with empty body → 422 (validation error = route exists)
test_endpoint POST "${API_PREFIX}/auth/login" "422" "Auth login endpoint exists"

# 10. Auth register — POST with empty body → 422
test_endpoint POST "${API_PREFIX}/auth/register" "422" "Auth register endpoint exists"

echo ""

# ── Section 4: Auth Middleware (Protected Endpoints) ──
echo "── Auth Middleware ──"

# 11. Protected endpoint without auth → 401
test_endpoint GET "${API_PREFIX}/customers" "401" "Customers endpoint (auth required, got 401)"

# 12. Protected endpoint without auth → 401
test_endpoint GET "${API_PREFIX}/notifications" "401" "Notifications endpoint (auth required, got 401)"

# 13. Protected endpoint without auth → 401
test_endpoint GET "${API_PREFIX}/products" "401" "Products endpoint (auth required, got 401)"

echo ""

# ── Section 5: Response Quality ──
echo "── Response Quality ──"

# 14. Health response is valid JSON with required fields
HEALTH_BODY=$(curl -sf --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo "{}")
if echo "$HEALTH_BODY" | grep -q '"status"' && echo "$HEALTH_BODY" | grep -q '"checks"'; then
    echo "  ✓ Health response has status + checks fields"
    PASS=$((PASS + 1))
else
    echo "  ✗ Health response missing required fields"
    FAIL=$((FAIL + 1))
fi

# 15. API prefix resolves (200 = root handler present and serving JSON)
test_endpoint GET "${API_PREFIX}" "200" "API prefix resolves (root handler)"

echo ""

# ── Section 6: Container Health ──
echo "── Container Health ──"

# 16. API container is running
API_RUNNING=$(docker inspect -f '{{.State.Running}}' fyona-api 2>/dev/null || echo "false")
if [ "$API_RUNNING" = "true" ]; then
    echo "  ✓ API container running"
    PASS=$((PASS + 1))
else
    echo "  ✗ API container not running"
    FAIL=$((FAIL + 1))
fi

# 17. Celery worker running
CELERY_RUNNING=$(docker inspect -f '{{.State.Running}}' fyona-celery 2>/dev/null || echo "false")
if [ "$CELERY_RUNNING" = "true" ]; then
    echo "  ✓ Celery worker running"
    PASS=$((PASS + 1))
else
    echo "  ✗ Celery worker not running"
    FAIL=$((FAIL + 1))
fi

# 18. Celery beat running
BEAT_RUNNING=$(docker inspect -f '{{.State.Running}}' fyona-celery-beat 2>/dev/null || echo "false")
if [ "$BEAT_RUNNING" = "true" ]; then
    echo "  ✓ Celery beat running"
    PASS=$((PASS + 1))
else
    echo "  ✗ Celery beat not running"
    FAIL=$((FAIL + 1))
fi

# ── Section 7: Storage Connectivity ──
echo "── Storage ──"

# 19. MinIO health endpoint reachable
MINIO_HEALTH=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:9000/minio/health/live" 2>/dev/null || echo "000")
if [ "$MINIO_HEALTH" = "200" ]; then
    echo "  ✓ MinIO health OK"
    PASS=$((PASS + 1))
else
    echo "  ✗ MinIO health check failed (HTTP $MINIO_HEALTH)"
    FAIL=$((FAIL + 1))
fi

echo ""

# ── Summary ──
echo "═══════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    echo "SMOKE_TESTS_FAILED"
    exit 1
fi

echo "SMOKE_TESTS_PASSED"
exit 0
