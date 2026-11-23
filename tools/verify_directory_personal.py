"""Run the existing Personal regression against the Phase 1 sandbox only."""

import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.request import ProxyHandler, Request, build_opener

from verify_directory_pilot_http import NoRedirect, QA_BASES


def main():
    fixture_path = Path(sys.argv[1])
    assert fixture_path.with_name("ready").exists(), "Wait until the QA fixture is ready"
    fixture = json.loads(fixture_path.read_text())
    output = Path(sys.argv[2]).resolve()
    output.mkdir(exist_ok=False)
    base = fixture["base"]
    assert base in QA_BASES
    client = build_opener(ProxyHandler({}), NoRedirect())

    def hit(path, payload=None, token=None, device="phase-one-personal-A"):
        headers = {"Content-Type": "application/json", "X-Device-Id": device}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = Request(base + path, json.dumps(payload).encode() if payload is not None else None, headers)
        with client.open(req, timeout=10) as response:
            reply = json.load(response)
            return reply.get("data", reply) if isinstance(reply, dict) else reply

    def transactions(token):
        return hit("/personal/finance/transactions?per_page=10", token=token)["items"]

    account = fixture["staff"]
    ready = hit("/health/ready")
    assert ready["status"] == "ready"
    if base.startswith("https:"):
        assert ready["version"]["environment"] == "phase-one-qa"
    first = hit("/auth/login", account)["access_token"]
    second = hit("/auth/login", account, device="phase-one-personal-B")["access_token"]
    assert not transactions(first), "Run against a fresh test fixture"
    for step in ("stage", "review-offline", "lose-receipt", "retry", "destination"):
        b = step == "destination"
        env = {
            **os.environ, "FYONA_PROBE_MODE": step, "FYONA_PROBE_BASE": base,
            "FYONA_PROBE_TOKEN": second if b else first,
            "FYONA_PROBE_DB": str(output / ("personal-B.sqlite" if b else "personal-A.sqlite")),
        }
        log = output / f"{step}.log"
        with log.open("wb") as report:
            proc = subprocess.run(
                ["flutter", "test", "--no-pub", "--reporter", "expanded",
                 "--dart-define=FYONA_DIRECTORY_PILOT=true",
                 f"--dart-define=FYONA_DIRECTORY_SETUP_URL={base}",
                 "test/e2e/business_directory_personal_guard_test.dart"],
                env=env, stdout=report, stderr=report, timeout=85)
        assert proc.returncode == 0 and f"PROBE_OK {step}" in log.read_text(), str(log)
        if step == "lose-receipt":
            accepted = transactions(first)
            assert len(accepted) == 1
        if step in ("retry", "destination"):
            assert [p["id"] for p in transactions(second)] == [accepted[0]["id"]]
        print(f"Existing Personal live regression: {step} PASS", flush=True)


if __name__ == "__main__":
    os.umask(0o077)
    main()
