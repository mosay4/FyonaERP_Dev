"""Verify real Mailpit-to-Telegram delivery for the spare QA invite only."""

import json
import os
from pathlib import Path
import re
import secrets
import sys
from urllib.request import ProxyHandler, Request, build_opener

from relay_directory_pilot_otp import RUN, deliver_signup_otp, mailbox, signup_otp
from send_directory_pilot_login import private_sender
from verify_directory_pilot_http import NoRedirect


BASE = "https://qa.fyonacompany.com:18443/api/v1"


def main(receipt_dir):
    assert (RUN / "ready").is_file()
    fixture = json.loads((RUN / "fixture.json").read_text())
    assert fixture["base"] == BASE
    hit, delivery_alias = mailbox(RUN)
    spare = (RUN / "signup-email-3").read_text().strip()
    assert spare != delivery_alias and re.fullmatch(r"signup-[a-f0-9]{24}@example\.test", spare)
    # Don't request a code if the destination hasn't been verified.
    post = private_sender()
    before = signup_otp(hit, spare)
    register = {
        "full_name": "QA OTP Delivery Probe", "email": spare,
        "password": "Qa1!" + secrets.token_hex(12), "preferred_usage_mode": "personal",
    }
    opener = build_opener(ProxyHandler({}), NoRedirect())
    req = Request(BASE + "/auth/register", json.dumps(register).encode(),
                  {"Content-Type": "application/json", "X-Device-Id": "qa-otp-relay-check"})
    with opener.open(req, timeout=15) as response:
        assert response.status == 200
    after = signup_otp(hit, spare)
    assert after is not None and before != after, "No fresh signup OTP in the private mail catcher"
    receipt_dir.mkdir(exist_ok=True)
    assert deliver_signup_otp(post, hit, spare, receipt_dir, probe=True), \
        "Telegram did not confirm the spare signup OTP; no retry of this mail"
    print("Spare invite: live registration OTP delivered from Mailpit to the verified private chat.",
          flush=True)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main(Path(sys.argv[1]))
    except (OSError, KeyError, ValueError, AssertionError) as exc:
        reason = str(exc) if type(exc) in (ValueError, AssertionError) else type(exc).__name__
        raise SystemExit(f"QA OTP delivery probe did not pass: {reason}") from None
