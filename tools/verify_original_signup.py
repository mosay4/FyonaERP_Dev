"""Test the existing signup/OTP/login API in private QA slots."""

import json
from pathlib import Path
import re
import secrets
import sys
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

from run_directory_pilot_lab import MANAGED_ENROLL_ROOT, QA_ORIGIN, business_probe_email
from verify_directory_pilot_http import NoRedirect


def create_account(root, *, slot=None, name="Original Signup Probe",
                   preferred_usage_mode="personal", device=None, managed_probe=False,
                   managed_link_probe=False):
    if managed_link_probe and not managed_probe:
        raise ValueError("The managed link probe requires dedicated managed slots.")
    if not (root / "ready").is_file():
        raise RuntimeError("Wait for the disposable local lab.")
    fixture = json.loads((root / "fixture.json").read_text())
    base = fixture["base"]
    if managed_probe:
        if root.resolve() != MANAGED_ENROLL_ROOT or base != f"{QA_ORIGIN}/api/v1":
            raise ValueError("The managed probe requires the private QA Business slots.")
        invite_path = business_probe_email(root, slot, link=managed_link_probe)
    elif base == "http://127.0.0.1:18083/api/v1" or (base == f"{QA_ORIGIN}/api/v1" and slot in (2, 3)):
        invite_path = root / f"signup-email-{slot}" if slot is not None else None
    else:
        raise ValueError("The signup probe must use an isolated QA test slot.")
    mail = (root / "mailpit-url").read_text().strip()
    url = urlsplit(mail)
    if (url.scheme, url.netloc, url.path, url.query, url.fragment) != (
        "http", f"127.0.0.1:{url.port}", "", "", ""
    ) or not url.port:
        raise ValueError("The mail catcher must be on loopback.")
    opener = build_opener(ProxyHandler({}), NoRedirect())
    tag = secrets.token_hex(4)
    email = invite_path.read_text().strip() if invite_path else f"signup-probe-{tag}@example.test"
    if slot is not None and not re.fullmatch(r"signup-[a-f0-9]{24}@example\.test", email):
        raise ValueError("Unexpected QA invitation")
    password = "Qa1!" + secrets.token_hex(12)

    def request(path, data=None, status=200, token=None, headers=None, method=None):
        origin = mail if path.startswith("/api/v1/") else base
        headers = {"Content-Type": "application/json",
                   "X-Device-Id": "original-update-signup-probe", **(headers or {})}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = Request(origin + path, headers=headers, method=method,
                      data=json.dumps(data).encode() if data is not None else None)
        try:
            with opener.open(req, timeout=14) as response:
                if response.status != status:
                    raise ValueError(f"{path}: expected {status}, got {response.status}")
                body = json.load(response)
        except HTTPError as e:
            if e.code != status:
                raise ValueError(f"{path}: expected {status}, got {e.code}") from None
            body = json.load(e)
        return body.get("data", body)

    register = {
        "full_name": name, "email": email, "password": password,
        "preferred_usage_mode": preferred_usage_mode,
    }
    if slot is not None and not managed_probe:
        request("/auth/register", {**register, "email": "not-invited@example.test"}, status=403)
    request("/auth/register", register)
    mail_request = request
    if (root / "mailpit-access.json").is_file():
        from relay_directory_pilot_otp import mailbox
        mail_request, _ = mailbox(root)
    box = mail_request("/api/v1/messages")
    item = next(m for m in box["messages"] if any(
        t["Address"].lower() == email for t in m["To"]
    ))
    msg_id = item["ID"]
    if not re.fullmatch(r"[\w-]+", msg_id):
        raise ValueError("Unexpected local Mailpit message ID.")
    message = mail_request(f"/api/v1/message/{msg_id}")
    codes = re.findall(r"(?<!\d)\d{6}(?!\d)", message["Text"])
    if len(codes) != 1:
        raise RuntimeError("No unique signup code in the delivered test email.")
    otp = codes[0]
    if not managed_probe:
        request("/auth/verify-registration", {
            "email": email, "otp": "000000" if otp != "000000" else "111111",
        }, status=400)
    registered = request("/auth/verify-registration", {"email": email, "otp": otp})
    if not registered["user"]["email_verified"]:
        raise RuntimeError("The test account is not email-verified.")
    if not managed_probe:
        request("/auth/verify-registration", {"email": email, "otp": otp}, status=400)
    logged_in = request("/auth/login", {"email": email, "password": password},
                        headers={"X-Device-Name": device} if device else None)
    user = request("/auth/me", token=logged_in["access_token"])
    if user["id"] != registered["user"]["id"] or user["email"] != email:
        raise RuntimeError("The existing login returned a different account.")
    print("QA signup, delivered email OTP, password login and authenticated profile passed."
          if managed_probe else "Isolated QA only: existing signup, email OTP, invalid/replayed "
          "OTP rejection, password login and authenticated profile passed.", flush=True)
    return request, logged_in, {"email": email, "password": password}


if __name__ == "__main__":
    create_account(Path(sys.argv[1]))
