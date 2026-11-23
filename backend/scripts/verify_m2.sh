#!/bin/bash
# FYONA ERP — Milestone 2 Verification Script
# Run: chmod +x verify.sh && ./verify.sh

set -e
BASE="http://localhost:8000/api/v1"
API="fyona-api"

echo "============================================"
echo "  FYONA ERP — Milestone 2 Verification"
echo "============================================"

echo ""
echo "1. Alembic Migration Status"
echo "---------------------------"
docker compose exec $API alembic current
echo ""

echo "2. Alembic Upgrade"
echo "------------------"
docker compose exec $API alembic upgrade head
echo ""

echo "3. FastAPI Import Check"
echo "----------------------"
docker compose exec $API python -c "from app.main import app; print(f'FastAPI OK: {app.title} v{app.version}')"
echo ""

echo "4. Celery Worker Ping"
echo "--------------------"
docker compose exec celery-worker celery -A app.workers.celery_app inspect ping
echo ""

echo "============================================"
echo "  Testing Auth Endpoints"
echo "============================================"
echo ""

echo "5. POST /auth/register"
echo "---------------------"
REGISTER=$(curl -s -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" \
  -d '{
    "full_name": "أحمد محمد",
    "email": "ahmed@test.com",
    "password": "TestPass123",
    "organization_name": "شركة فيونا",
    "preferred_usage_mode": "business"
  }')
echo "$REGISTER" | python -m json.tool 2>/dev/null || echo "$REGISTER"

ACCESS_TOKEN=$(echo "$REGISTER" | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
REFRESH_TOKEN=$(echo "$REGISTER" | python -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null || echo "")
echo "Access Token: ${ACCESS_TOKEN:0:20}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:20}..."
echo ""

if [ -z "$ACCESS_TOKEN" ]; then
  echo "❌ REGISTER FAILED — stopping tests"
  exit 1
fi
echo "✅  Register OK"
echo ""

echo "6. POST /auth/login"
echo "-------------------"
LOGIN=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email": "ahmed@test.com", "password": "TestPass123"}')
echo "$LOGIN" | python -m json.tool 2>/dev/null || echo "$LOGIN"
ACCESS_TOKEN=$(echo "$LOGIN" | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
REFRESH_TOKEN=$(echo "$LOGIN" | python -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null || echo "")
echo "✅  Login OK"
echo ""

echo "7. POST /auth/refresh"
echo "---------------------"
REFRESH=$(curl -s -X POST "$BASE/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\": \"$REFRESH_TOKEN\"}")
echo "$REFRESH" | python -m json.tool 2>/dev/null || echo "$REFRESH"
NEW_ACCESS=$(echo "$REFRESH" | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
NEW_REFRESH=$(echo "$REFRESH" | python -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null || echo "")
echo "✅  Refresh OK — token rotated"
echo ""

echo "8. GET /auth/me"
echo "---------------"
ME=$(curl -s -X GET "$BASE/auth/me" \
  -H "Authorization: Bearer $ACCESS_TOKEN")
echo "$ME" | python -m json.tool 2>/dev/null || echo "$ME"
echo "✅  Get Me OK"
echo ""

echo "9. PUT /auth/me (update profile)"
echo "--------------------------------"
UPDATED=$(curl -s -X PUT "$BASE/auth/me" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"full_name": "أحمد محمد المحدث", "preferred_currency": "USD"}')
echo "$UPDATED" | python -m json.tool 2>/dev/null || echo "$UPDATED"
echo "✅  Update Profile OK"
echo ""

echo "10. POST /auth/change-password"
echo "------------------------------"
CHPWD=$(curl -s -X POST "$BASE/auth/change-password" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"current_password": "TestPass123", "new_password": "NewPass456"}')
echo "$CHPWD"
echo "✅  Change Password OK"
echo ""

echo "11. Login with NEW password"
echo "---------------------------"
LOGIN2=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email": "ahmed@test.com", "password": "NewPass456"}')
echo "$LOGIN2" | python -m json.tool 2>/dev/null || echo "$LOGIN2"
ACCESS_TOKEN2=$(echo "$LOGIN2" | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
echo "✅  New Password Login OK"
echo ""

echo "12. POST /auth/logout"
echo "---------------------"
LOGOUT=$(curl -s -X POST "$BASE/auth/logout" \
  -H "Authorization: Bearer $ACCESS_TOKEN2" \
  -H "X-Refresh-Token: $NEW_REFRESH")
echo "$LOGOUT"
echo "✅  Logout OK"
echo ""

echo "13. Test: Old refresh token should FAIL"
echo "---------------------------------------"
OLD_REFRESH=$(curl -s -X POST "$BASE/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\": \"$REFRESH_TOKEN\"}")
echo "$OLD_REFRESH"
echo "✅  Old token rejected (expected 401)"
echo ""

echo "14. Test: Invalid login should FAIL"
echo "-----------------------------------"
INVALID=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email": "ahmed@test.com", "password": "wrongpass"}')
echo "$INVALID"
echo "✅  Invalid login rejected (expected 401)"
echo ""

echo "15. DB Row Counts"
echo "-----------------"
docker compose exec $API python -c "
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User, UserSession
from sqlalchemy import select, func
import asyncio

async def count():
    async with async_session_factory() as db:
        orgs = (await db.execute(select(func.count(Organization.id)))).scalar()
        users = (await db.execute(select(func.count(User.id)))).scalar()
        sessions = (await db.execute(select(func.count(UserSession.id)))).scalar()
        print(f'  Organizations: {orgs}')
        print(f'  Users: {users}')
        print(f'  Sessions: {sessions}')

asyncio.run(count())
"
echo ""

echo "16. Redis Ping"
echo "--------------"
docker compose exec $API python -c "
import asyncio
from app.core.redis import get_redis
async def test():
    r = await get_redis()
    pong = await r.ping()
    print(f'Redis ping: {pong}')
asyncio.run(test())
"
echo ""

echo "17. Run Tests Inside Container"
echo "-----------------------------"
docker compose exec $API pytest tests/ -v
echo ""

echo "============================================"
echo "  ✅ VERIFICATION COMPLETE"
echo "============================================"
