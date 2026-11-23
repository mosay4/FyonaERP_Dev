"""FYONA ERP - Direct API Test (uses only urllib)
Generates unique data every run. No curl, no subprocess.
"""
import json, os, random, urllib.request, urllib.error, sys

BASE = "http://localhost:8000/api/v1"
TOKEN = None


def api(method, path, data=None, token=None):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(f"{BASE}{path}", data=body, method=method)
    req.add_header("Accept", "application/json")
    if data:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            parsed = json.loads(raw) if raw else {}
        except:
            parsed = {}
        return e.code, parsed, raw[:400]
    except urllib.error.URLError as e:
        return 0, {}, f"Connection refused: {e.reason}"
    except Exception as e:
        return 0, {}, str(e)


def test(name, path, method="GET", data=None, auth=True, check_key=None, expect=200):
    token = TOKEN if auth else None
    status, parsed, err = api(method, path, data, token)
    if status == expect and (not check_key or check_key in str(parsed)):
        print(f"  [PASS] {name} ({status})")
        return status, parsed
    print(f"  [FAIL] {name}")
    print(f"         Expected {expect}, got {status}, key={check_key}")
    if err:
        print(f"         Error: {err[:300]}")
    else:
        print(f"         Response: {json.dumps(parsed, ensure_ascii=False)[:300]}")
    return status, parsed


n = random.randint(10000, 99999)
EMAIL = f"verify{n}@test.com"
ORG = f"Verify Org {n}"

print("=" * 60)
print("  FYONA ERP - DIRECT API TEST")
print(f"  Email: {EMAIL}")
print(f"  Org:   {ORG}")
print("=" * 60)

# ── Register with unique email AND unique org name ──
print("\n=== 1. REGISTER ===")
s, reg = test("Register", "/auth/register", "POST",
    {"full_name": "Verifier", "email": EMAIL, "password": "StrongPass1",
     "organization_name": ORG},
    auth=False, check_key="access_token", expect=201)
if s == 201:
    TOKEN = reg.get("access_token", "")
    print(f"  Token: {TOKEN[:40]}...")

if not TOKEN:
    print("\n=== REGISTER FAILED. Trying LOGIN ===")
    s, log = test("Login", "/auth/login", "POST",
        {"email": EMAIL, "password": "StrongPass1"},
        auth=False, check_key="access_token", expect=200)
    if s == 200:
        TOKEN = log.get("access_token", "")
        print(f"  Token from login: {TOKEN[:40]}...")

if not TOKEN:
    print("\n  FATAL: Cannot authenticate. Check docker logs:")
    print("  docker compose logs api --tail=40")
    sys.exit(1)

# ── Profile ──
print("\n=== 2. PROFILE ===")
test("Get Current User", "/auth/me", check_key="full_name")

# ── Test all POST endpoints ──
print("\n=== 3. ALL POST ENDPOINTS ===")

tests = [
    ("Init Accounting", "POST", "/accounting/init", {}, 201, "code"),
    ("Create Customer", "POST", "/customers", {"name": f"Customer {n}", "phone": "0555111111"}, 201, "id"),
    ("Create Supplier", "POST", "/suppliers", {"name": f"Supplier {n}"}, 201, "id"),
    ("Create Category", "POST", "/categories", {"name": f"Category {n}"}, 201, "id"),
    ("Create Product", "POST", "/products", {"name": f"Product {n}", "price": 99.99, "sku": f"SKU{n}"}, 201, "id"),
    ("Create Invoice", "POST", "/invoices", {"items": [{"description": "Item", "quantity": 1, "unit_price": 100}]}, 201, "id"),
    ("Create Sales Order", "POST", "/sales/orders", {"items": [{"description": "Item", "quantity": 1, "unit_price": 100}]}, 201, "id"),
    ("Create Purchase Order", "POST", "/purchases/orders", {"items": [{"description": "Item", "quantity": 1, "unit_price": 100}]}, 201, "id"),
    ("Create Employee", "POST", "/hr/employees", {"employee_code": f"E{n}", "full_name": "Test Employee"}, 201, "id"),
]

for name, method, path, data, expected, key in tests:
    test(name, path, method, data, check_key=key, expect=expected)

# ── List endpoints ──
print("\n=== 4. LIST ENDPOINTS ===")
test("List Accounts", "/accounting/accounts", check_key="code")
test("List Customers", "/customers", check_key="items")
test("List Products", "/products", check_key="items")
test("List Employees", "/hr/employees", check_key="items")
test("Dashboard KPI", "/reports/kpi", check_key="total_customers")
test("AI Insights", "/ai/insights", check_key="insights")
test("Sync Health", "/sync/health", auth=False, check_key="sync_api_version")

# ── Security ──
print("\n=== 5. SECURITY ===")
test("No Auth Returns 401", "/customers", auth=False, expect=401)
test("Valid Auth Returns 200", "/customers", auth=True, expect=200)

print(f"\n  DONE")
