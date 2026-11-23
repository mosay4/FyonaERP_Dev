#!/usr/bin/env python3
"""
FYONA ERP — Milestone 2 Verification Script (Fixed)
Run: python scripts/verify_m2.py

Uses UUID-based emails to avoid conflicts.
Fixes PYTHONPATH for Docker container scripts.
Fixes Celery ping command.
"""

import subprocess
import json
import sys
import uuid

API_BASE = "http://localhost:8000/api/v1"
API_SVC = "api"
UID = uuid.uuid4().hex[:8]  # Unique suffix per run
EMAIL = f"verify-{UID}@test.com"
PASS = 0
FAIL = 0


def run(cmd_str):
    """Run shell command and return (exit_code, output)."""
    try:
        r = subprocess.run(
            cmd_str, capture_output=True, text=True, timeout=60, shell=True
        )
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return -1, "ERROR: Timeout"
    except Exception as e:
        return -1, f"ERROR: {e}"


def docker_exec(cmd_str):
    """Run command inside the api container with correct PYTHONPATH."""
    code, out = run(f"docker compose exec -e PYTHONPATH=/app {API_SVC} {cmd_str}")
    return code, out


def api_call(method, path, data=None, token=None, extra_headers=None):
    """Make HTTP request to the API."""
    import urllib.request
    import urllib.error

    url = f"{API_BASE}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if extra_headers:
        headers.update(extra_headers)
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode()
            return resp.status, json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        content = e.read().decode()
        try:
            return e.code, json.loads(content)
        except json.JSONDecodeError:
            return e.code, {"detail": content[:300]}
    except Exception as e:
        return 0, {"detail": str(e)}


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ✅ {name}")
    else:
        FAIL += 1
        detail_str = f" — {detail}" if detail else ""
        print(f"  ❌ {name}{detail_str}")
        # Truncate detail for readability
        if len(detail_str) > 200:
            print(f"     ...{detail_str[-200:]}")


# ── 1. Alembic ──
print("\n1. Alembic Migration Status")
code, out = docker_exec("alembic current 2>&1")
check("Alembic responds", code == 0, out[:200])

print("\n2. Alembic Upgrade (idempotent)")
code, out = docker_exec("alembic upgrade head 2>&1")
# Exit code 0 means success regardless of INFO messages
check("Migration applied successfully", code == 0, out[:300])

# ── 2. FastAPI Import (use script file to avoid quoting issues) ──
print("\n3. FastAPI Import")
code, out = docker_exec("python scripts/_check_fastapi.py 2>&1")
check("FastAPI loads", code == 0, out[:500])

# ── 3. Celery ──
print("\n4. Celery Worker Ping")
# First check worker logs for startup errors
log_code, log_out = run("docker compose logs celery-worker --tail=30 2>&1")
if "Error" in log_out or "Traceback" in log_out:
    print(f"  ⚠️  Worker log errors:\n{log_out[:500]}")
    # Try ping from worker container directly
    code, out = run(
        "docker compose exec celery-worker celery -A app.workers inspect ping 2>&1"
    )
else:
    code, out = run(
        "docker compose exec celery-worker celery -A app.workers inspect ping 2>&1"
    )
check(
    "Worker responds",
    code == 0 or "pong" in out or "1 host" in out or "celery@" in out,
    out[:500],
)

# ── 4. Register (uses UNIQUE email each run) ──
print("\n5. POST /auth/register")
status, data = api_call(
    "POST",
    "/auth/register",
    {
        "full_name": "مستخدم التحقق",
        "email": EMAIL,
        "password": "TestPass123",
        "organization_name": f"شركة اختبار {UID}",
        "preferred_usage_mode": "business",
    },
)
ACCESS = data.get("access_token", "")
REFRESH = data.get("refresh_token", "")
check("Register returns 201", status == 201, f"Got {status}: {data.get('detail','')}")
check("Has access_token", bool(ACCESS))
check("Has refresh_token", bool(REFRESH))
check("Has user data", "user" in data)

if not ACCESS:
    print("  ⚠️  Register failed — skipping dependent checks")
else:
    # ── 5. Login ──
    print("\n6. POST /auth/login")
    status, data = api_call(
        "POST", "/auth/login", {"email": EMAIL, "password": "TestPass123"}
    )
    ACCESS = data.get("access_token", ACCESS)
    REFRESH = data.get("refresh_token", REFRESH)
    check("Login returns 200", status == 200, f"Got {status}")
    check("Access token returned", bool(ACCESS))

    if not ACCESS:
        print("  ⚠️  Login failed — skipping dependent checks")
    else:
        # ── 6. Refresh ──
        print("\n7. POST /auth/refresh")
        status, data = api_call("POST", "/auth/refresh", {"refresh_token": REFRESH})
        NEW_ACCESS = data.get("access_token", "")
        NEW_REFRESH = data.get("refresh_token", "")
        check("Refresh returns 200", status == 200, f"Got {status}")
        if NEW_ACCESS:
            ACCESS = NEW_ACCESS
        if NEW_REFRESH:
            REFRESH = NEW_REFRESH

        # ── 7. Get Me ──
        print("\n8. GET /auth/me")
        status, data = api_call("GET", "/auth/me", token=ACCESS)
        check("Me returns 200", status == 200, f"Got {status}")
        if status == 200:
            check("Has full_name", bool(data.get("full_name")))
            check("Has email", "verify" in data.get("email", ""))
            check("Has role", bool(data.get("role")))

        # ── 8. Update Me ──
        print("\n9. PUT /auth/me")
        status, data = api_call(
            "PUT",
            "/auth/me",
            {"full_name": "المستخدم المحدث", "preferred_currency": "USD"},
            token=ACCESS,
        )
        check("Update returns 200", status == 200, f"Got {status}")

        # ── 9. Change Password ──
        print("\n10. POST /auth/change-password")
        status, data = api_call(
            "POST",
            "/auth/change-password",
            {"current_password": "TestPass123", "new_password": "NewPass456"},
            token=ACCESS,
        )
        check("Change pwd returns 204", status == 204, f"Got {status}")

        # ── 10. Login with NEW password ──
        print("\n11. Login with NEW password")
        status, data = api_call(
            "POST", "/auth/login", {"email": EMAIL, "password": "NewPass456"}
        )
        check("New pwd login 200", status == 200, f"Got {status}")
        if status == 200:
            ACCESS = data.get("access_token", ACCESS)

        # ── 11. Logout ──
        print("\n12. POST /auth/logout")
        status, data = api_call(
            "POST",
            "/auth/logout",
            token=ACCESS,
            extra_headers={"X-Refresh-Token": REFRESH},
        )
        check("Logout returns 204", status == 204, f"Got {status}")

        # ── 12. Old refresh rejected ──
        print("\n13. OLD refresh token rejected")
        status, data = api_call("POST", "/auth/refresh", {"refresh_token": REFRESH})
        check("Old token 401", status == 401, f"Got {status}")

# ── 13. Invalid login rejected ──
print("\n14. INVALID login rejected")
status, data = api_call("POST", "/auth/login", {"email": EMAIL, "password": "wrong"})
check("Bad login 401", status == 401, f"Got {status}")

# ── 14. DB Row Counts (PYTHONPATH fixed via docker_exec) ──
print("\n15. Database Row Counts")
code, out = docker_exec("python scripts/_count_rows.py 2>&1")
check("DB query runs", code == 0 or "Orgs=" in out, out[:300])
if "Orgs=" in out:
    for line in out.split("\n"):
        if "=" in line:
            print(f"    {line.strip()}")

# ── 15. Redis ──
print("\n16. Redis Ping")
code, out = docker_exec("python scripts/_ping_redis.py 2>&1")
check("Redis responds", "True" in out, out[:200])

# ── 16. Run Tests ──
print("\n17. Running tests inside container...")
code, out = docker_exec("python -m pytest tests/ -v 2>&1")
# Get last 30 lines in pure Python
lines = out.split("\n")
tail = "\n".join(lines[-30:]) if len(lines) > 30 else out
check("All tests pass", code == 0 and "failed" not in out, tail[:500])

# ── Final Report ──
print(f"\n{'='*50}")
print(f"  RESULTS: {PASS} passed, {FAIL} failed")
print(f"{'='*50}")
if FAIL > 0:
    print("  ❌ Some checks FAILED")
    sys.exit(1)
else:
    print("  ✅ ALL CHECKS PASSED — Milestone 2 complete")
