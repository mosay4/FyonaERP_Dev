"""Check the Phase 1 boundaries and the unchanged HTTP paths, with fake data."""

from decimal import Decimal
import json
from pathlib import Path
import secrets
import sys
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


QA_BASES = {
    "http://127.0.0.1:18083/api/v1",
    "https://qa.fyonacompany.com:18443/api/v1",
}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise AssertionError(f"Unexpected QA redirect ({code})")


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: verify_directory_pilot_http.py FIXTURE_JSON [isolation]")
    fixture = json.loads(Path(sys.argv[1]).read_text())
    base = fixture["base"]
    assert base in QA_BASES
    opener = build_opener(ProxyHandler({}), NoRedirect())

    def hit(path, data=None, token=None, scope=None, status=200, method=None):
        headers = {"Content-Type": "application/json", "X-Device-Id": "qa-phase-one-http"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if scope:
            headers["X-Branch-Token"] = scope
        req = Request(base + path, json.dumps(data).encode() if data is not None else None,
                      headers, method=method)
        try:
            with opener.open(req, timeout=12) as resp:
                reply = json.load(resp)
                assert resp.status in ((200, 201) if status == 200 else (status,)), path
                return reply.get("data", reply) if isinstance(reply, dict) else reply
        except HTTPError as e:
            if e.code != status:
                raise AssertionError(f"{path}: got HTTP {e.code}, expected {status}") from None
            return json.load(e)

    def select(token, branch, status=200):
        return hit("/branches/select", {"organization_id": fixture["organization"],
                   "branch_id": branch}, token, status=status)

    def list_rows(payload):
        return payload["items"] if isinstance(payload, dict) else payload

    ready = hit("/health/ready")
    assert ready["status"] == "ready"
    if base.startswith("https:"):
        assert ready["version"]["environment"] == "phase-one-qa"
    owner = hit("/auth/login", fixture["owner"])["access_token"]
    pilot = select(owner, fixture["branch"])["token"]
    for path in ("/customers", "/suppliers"):
        assert list_rows(hit(path, token=owner, scope=pilot)) == []
        hit(path, {"name": "Must not enter the legacy ledger"}, owner, pilot, 403)
    if len(sys.argv) == 3:
        print("Pilot branch REST directory remains empty; direct writes are refused.")
        return

    staff = hit("/auth/login", fixture["staff"])["access_token"]
    select(staff, fixture["branch"], 403)
    limited = select(staff, fixture["other_branch"])["token"]
    for path in ("/customers", "/suppliers"):
        hit(path, token=staff, scope=limited, status=403)
    print("Pilot scope isolated, with direct REST write refused; employee cannot select/read it.")

    branch = fixture["other_branch"]
    scope = select(owner, branch)["token"]
    tag = secrets.token_hex(3)
    a = hit("/customers", {"name": f"Online Customer {tag}"}, owner, scope)
    s = hit("/suppliers", {"name": f"Online Supplier {tag}"}, owner, scope)
    assert list_rows(hit(f"/customers?search={tag}", token=owner, scope=scope))[0]["id"] == a["id"]
    assert list_rows(hit(f"/suppliers?search={tag}", token=owner, scope=scope))[0]["id"] == s["id"]
    product = hit("/products", {"name": f"QA SKU {tag}", "unit": "piece",
                  "price": 15, "cost_price": 10, "stock": 0}, owner, scope)
    account = hit("/banking/accounts", {"bank_name": "QA only", "account_name": tag,
                  "account_number": tag, "currency": "SAR", "balance": 100}, owner, scope)
    buy = hit("/invoices/issue-purchase", {"supplier_id": s["id"],
              "branch_id": branch, "currency": "SAR",
              "items": [{"product_id": product["id"], "quantity": 5, "unit_price": 10}],
              "payments": [{"bank_account_id": account["id"], "amount": 50}]}, owner, scope)
    sale = hit("/invoices/issue-sale", {"customer_id": a["id"],
               "branch_id": branch, "currency": "SAR",
               "items": [{"product_id": product["id"], "quantity": 2, "unit_price": 15}],
               "payments": [{"bank_account_id": account["id"], "amount": 30}]}, owner, scope)
    ret = hit(f"/invoices/{sale['id']}/returns",
              {"lines": [{"invoice_item_id": sale["items"][0]["id"], "quantity": 1}],
               "refund_account_id": account["id"]}, owner, scope)
    observed = hit(f"/products/{product['id']}", token=owner, scope=scope)
    accounts = hit("/banking/accounts", token=owner, scope=scope)
    accounts = accounts if isinstance(accounts, list) else accounts["accounts"]
    assert buy["id"] and sale["id"] and ret
    assert Decimal(str(observed["stock"])) == 4
    assert Decimal(str(next(x for x in accounts if x["id"] == account["id"])["balance"])) == 65
    print("Legacy branch: REST creation/search; purchase 5, sale 2, return 1 => 4 units, SAR 65.")


if __name__ == "__main__":
    main()
