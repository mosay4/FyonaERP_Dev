"""Read QA REST after the Android probe; it must not contain device records."""

import json
from pathlib import Path
import re
import sys
from urllib.request import ProxyHandler, Request, build_opener

from verify_directory_pilot_http import NoRedirect
from verify_directory_signup import claims


DEVICE_NAME = re.compile(r"QA (Online|Offline) (Customer|Supplier) \d{6}")


def main(root, evidence):
    base = "https://qa.fyonacompany.com:18443/api/v1"
    fixture = json.loads((root / "fixture.json").read_text())
    assert fixture["base"] == base and (root / "ready").is_file()
    account = json.loads((root / "enrollment-probe.json").read_text())
    assert account["email"] == (root / "signup-email-2").read_text().strip()
    assert (evidence / "connected-isolation.txt").stat().st_size > 0
    names = set(json.loads((evidence / "device-records.json").read_text()))
    assert len(names) == 4 and all(DEVICE_NAME.fullmatch(name) for name in names)
    opener = build_opener(ProxyHandler({}), NoRedirect())

    def hit(path, *, data=None, bearer=None, scope=None):
        headers = {"Content-Type": "application/json", "X-Device-Id": "qa-post-android-isolation"}
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        if scope:
            headers["X-Branch-Token"] = scope
        request = Request(base + path, json.dumps(data).encode() if data is not None else None,
                          headers=headers)
        with opener.open(request, timeout=15) as response:
            reply = json.load(response)
            return reply.get("data", reply)

    auth = hit("/auth/login", data={k: account[k] for k in ("email", "password")})
    identity, token = auth["user"], auth["access_token"]
    assert identity["id"] == account["account"]
    assert identity["organization_id"] == account["organization"]

    def select(key):
        return hit("/branches/select", data={
            "organization_id": account["organization"], "branch_id": account[key],
        }, bearer=token)["token"]

    pilot, connected = select("first_branch"), select("other_branch")
    assert claims(pilot)["qa_directory"] is True
    assert "qa_directory" not in claims(connected)
    for path in ("/customers", "/suppliers"):
        assert hit(path, bearer=token, scope=pilot)["items"] == []
        server_names = {row["name"] for row in hit(path, bearer=token, scope=connected)["items"]}
        assert "Unchanged connected directory" in server_names
        assert not server_names & names and not any(DEVICE_NAME.fullmatch(name) for name in server_names)
    report = "QA HTTPS: after Android, both pilot REST lists are empty and the connected branch excludes all device records."
    (evidence / "rest-after-device.txt").write_text(report + "\n")
    print(report)


if __name__ == "__main__":
    main(*map(Path, sys.argv[1:]))
