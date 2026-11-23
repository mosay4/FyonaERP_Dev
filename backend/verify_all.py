"""FYONA ERP - Full API Verification Script
Run on Windows:  python verify_all.py
Requires:       curl installed and in PATH
Backend must be running at http://localhost:8000
"""
import sys, json, subprocess, os, tempfile, shutil

BASE = "http://localhost:8000/api/v1"
TOKEN = None
results = {"pass": [], "fail": []}
DEBUG = True


def debug(msg):
    if DEBUG:
        print(f"  [DEBUG] {msg}")


def run_curl(method, path, data=None, auth=True):
    """Execute curl and return (http_status, parsed_json, raw_body, error_message)."""
    url = f"{BASE}{path}"
    cmd = ["curl", "-s", "-S", "-w", "\n%{http_code}", "-o", "-", "-X", method, url]

    headers = ["Accept: application/json"]
    if auth and TOKEN:
        headers.append(f"Authorization: Bearer {TOKEN}")
    if data is not None:
        headers.append("Content-Type: application/json")
        json_str = json.dumps(data)
        cmd += ["-d", json_str]
        debug(f"Body: {json_str[:200]}")

    for h in headers:
        cmd += ["-H", h]

    debug(f"Command: {' '.join(cmd[:6])} ...")

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
        stdout, stderr = proc.communicate(timeout=15)
        returncode = proc.returncode

        if returncode != 0:
            err_msg = stderr.decode().strip() if stderr else f"curl exit code {returncode}"
            return 0, {}, "", err_msg

        output = stdout.decode(errors="replace").strip()
        if not output:
            return 0, {}, "", "Empty response from server"

        # Last line is HTTP status code
        lines = output.rsplit("\n", 1)
        if len(lines) == 2:
            body_text, status_text = lines
        else:
            body_text = output
            status_text = "0"

        try:
            status = int(status_text.strip())
        except ValueError:
            status = 0

        parsed = {}
        if body_text.strip():
            try:
                parsed = json.loads(body_text)
            except json.JSONDecodeError as e:
                return status, {}, body_text, f"JSON parse error: {e}"

        return status, parsed, body_text, None

    except subprocess.TimeoutExpired:
        return 0, {}, "", "Timeout (15s)"
    except Exception as e:
        return 0, {}, "", str(e)


def test(name, path, method="GET", data=None, auth=True, check_key=None, expect_status=200):
    """Run a test and report pass/fail."""
    print(f"  Testing: {name} ...", end=" ")
    status, parsed, raw, err = run_curl(method, path, data, auth)

    if err:
        print(f"[NET ERR]")
        print(f"    Error: {err}")
        results["fail"].append(f"{name} (network: {err})")
        return status, parsed

    ok = status == expect_status
    if ok and check_key:
        if isinstance(parsed, dict) and check_key not in parsed:
            # Check nested data
            found = False
            for val in parsed.values():
                if isinstance(val, dict) and check_key in val:
                    found = True
                    break
                if isinstance(val, list):
                    for item in val:
                        if isinstance(item, dict) and check_key in item:
                            found = True
                            break
            if not found and check_key not in str(parsed):
                ok = False
        elif check_key not in str(parsed):
            ok = False

    if ok:
        print(f"[PASS] ({status})")
        results["pass"].append(name)
    else:
        print(f"[FAIL]")
        print(f"    Expected status: {expect_status}, got: {status}")
        if check_key:
            print(f"    Expected key: '{check_key}' not found")
        print(f"    Response: {raw[:300]}")
        results["fail"].append(f"{name} (status={status})")

    return status, parsed


# ═══════════════════════════════════════
#  BEGIN TESTS
# ═══════════════════════════════════════

print("=" * 60)
print("  FYONA ERP - FULL API VERIFICATION")
print(f"  Backend: {BASE}")
print("=" * 60)

import random
uid = random.randint(10000, 99999)
EMAIL = f"verify{uid}@test.com"
ORG_NAME = f"Verify Org {uid}"

# ── 1. AUTHENTICATION ──
print(f"\n=== 1. REGISTER ({EMAIL}) ===")

s, reg = test("Register", "/auth/register", "POST",
    {"full_name": "Verifier", "email": EMAIL, "password": "StrongPass1",
     "organization_name": ORG_NAME},
    auth=False, check_key="access_token", expect_status=201)
if s == 201:
    TOKEN = reg.get("access_token", "")
    debug(f"Token obtained: {TOKEN[:40]}...")

if not TOKEN:
    s, log = test("Login", "/auth/login", "POST",
        {"email": EMAIL, "password": "StrongPass1"},
        auth=False, check_key="access_token")
    if s == 200:
        TOKEN = log.get("access_token", "")
        debug(f"Token from login: {TOKEN[:40]}...")

if not TOKEN:
    print("\n[FATAL] Cannot obtain authentication token. Aborting.")
    sys.exit(1)

test("Get Profile", "/auth/me", check_key="full_name")

# ── 2. ACCOUNTING ──
print("\n=== 2. ACCOUNTING ===")
test("Init Chart of Accounts", "/accounting/init", "POST", {}, expect_status=201)
test("List Accounts", "/accounting/accounts", check_key="code")

_, acc = test("Create Account", "/accounting/accounts", "POST",
    {"code": "6000", "name": "Test Account", "type": "expense"},
    check_key="id", expect_status=201)
acc_id = acc.get("id", "")
if acc_id:
    test("Get Account", f"/accounting/accounts/{acc_id}", check_key="name")

# ── 3. CUSTOMERS ──
print("\n=== 3. CUSTOMERS ===")
_, cust = test("Create Customer", "/customers", "POST",
    {"name": "API Test Customer", "phone": "0555111111"},
    check_key="id", expect_status=201)
cust_id = cust.get("id", "")
test("List Customers", "/customers", check_key="items")
if cust_id:
    test("Get Customer", f"/customers/{cust_id}", check_key="name")
    test("Update Customer", f"/customers/{cust_id}", "PUT", {"name": "Updated Name"}, check_key="name")
    test("Delete Customer", f"/customers/{cust_id}", "DELETE", expect_status=204)

# ── 4. SUPPLIERS ──
print("\n=== 4. SUPPLIERS ===")
_, supp = test("Create Supplier", "/suppliers", "POST",
    {"name": "API Test Supplier"}, check_key="id", expect_status=201)
supp_id = supp.get("id", "")
test("List Suppliers", "/suppliers", check_key="items")

# ── 5. CATEGORIES ──
print("\n=== 5. CATEGORIES ===")
_, cat = test("Create Category", "/categories", "POST",
    {"name": "API Test Category"}, check_key="id", expect_status=201)

# ── 6. PRODUCTS ──
print("\n=== 6. PRODUCTS ===")
_, prod = test("Create Product", "/products", "POST",
    {"name": "API Test Product", "price": 99.99, "sku": f"APITEST{os.urandom(2).hex()}"},
    check_key="id", expect_status=201)
test("List Products", "/products", check_key="items")

# ── 7. INVOICES ──
print("\n=== 7. INVOICES ===")
_, inv = test("Create Invoice (Draft)", "/invoices", "POST",
    {"items": [{"description": "Invoice Item", "quantity": 3, "unit_price": 45}]},
    check_key="id", expect_status=201)
inv_id = inv.get("id", "")
if inv_id:
    test("Get Invoice", f"/invoices/{inv_id}", check_key="invoice_number")
    test("Confirm Invoice", f"/invoices/{inv_id}/status", "POST",
        {"action": "confirm"}, check_key="status")

# ── 8. SALES ──
print("\n=== 8. SALES ===")
_, so = test("Create Sales Order", "/sales/orders", "POST",
    {"items": [{"description": "Sales Item", "quantity": 1, "unit_price": 150}]},
    check_key="id", expect_status=201)

# ── 9. PURCHASES ──
print("\n=== 9. PURCHASES ===")
_, po = test("Create Purchase Order", "/purchases/orders", "POST",
    {"items": [{"description": "Purchase Item", "quantity": 10, "unit_price": 25}]},
    check_key="id", expect_status=201)

# ── 10. HR ──
print("\n=== 10. HR ===")
_, emp = test("Create Employee", "/hr/employees", "POST",
    {"employee_code": "VER001", "full_name": "Verify Employee"},
    check_key="id", expect_status=201)
test("List Employees", "/hr/employees", check_key="items")

# ── 11. REPORTS ──
print("\n=== 11. REPORTS ===")
test("Dashboard KPI", "/reports/kpi", check_key="total_customers")

# ── 12. AI & SYNC ──
print("\n=== 12. AI & SYNC ===")
test("AI Insights", "/ai/insights", check_key="insights")
test("Sync Health", "/sync/health", auth=False, check_key="sync_api_version")
test("Sync Status", "/sync/status", check_key="sync_enabled")

# ── 13. SECURITY ──
print("\n=== 13. SECURITY ===")
s, _, _, err = run_curl("GET", "/customers", auth=False)
if err:
    print(f"  [NET ERR] No Auth: {err}")
    results["fail"].append("No Auth Returns 401 (network error)")
elif s == 401:
    print(f"  [PASS] No Auth Returns 401")
    results["pass"].append("No Auth Returns 401")
else:
    print(f"  [FAIL] No Auth: expected 401, got {s}")
    results["fail"].append(f"No Auth Returns 401 (got {s})")

s, _, _, err = run_curl("GET", "/customers", auth=True)
if s == 200:
    print(f"  [PASS] Auth Works (200)")
    results["pass"].append("Auth Works")
else:
    print(f"  [FAIL] Auth: expected 200, got {s}")
    results["fail"].append(f"Auth Works (got {s})")

# ── SUMMARY ──
print(f"\n{'=' * 60}")
print(f"  VERIFICATION COMPLETE")
print(f"{'=' * 60}")
print(f"  PASS: {len(results['pass'])}")
print(f"  FAIL: {len(results['fail'])}")
if results["fail"]:
    print(f"  FAILED TESTS:")
    for f in results["fail"]:
        print(f"    - {f}")
    print(f"\n  Review failed tests above.")
    sys.exit(1)
else:
    print(f"  ALL TESTS PASSED - BACKEND IS STABLE")
    sys.exit(0)
