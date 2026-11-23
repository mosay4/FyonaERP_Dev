"""Live isolated signup, trial, branch creation and HTTPS enrollment verification."""

from base64 import urlsafe_b64decode
from pathlib import Path
import json
import os
import sys

from verify_original_signup import create_account


def claims(token):
    part = token.split(".")[1]
    return json.loads(urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def main(root):
    request, session, login = create_account(root, slot=2)
    user, token = session["user"], session["access_token"]
    email = request("/auth/me", token=token)["email"]
    assert email == login["email"]
    request("/auth/me/phone", {"country": "US", "phone": "+12025550139"}, token=token)
    request("/subscription/trial", {}, token=token)
    status = request("/subscription/status", token=token)
    assert status["is_trial"] and status["sections"]["business"]["active"]
    organization = user["organization_id"]
    a = request("/branches", {"name": "Offline Pilot QA"}, token=token)["id"]
    b = request("/branches", {"name": "Connected Branch QA"}, token=token)["id"]
    identity = {"organization_id": organization}
    sa = request("/branches/select", {**identity, "branch_id": a}, token=token)["token"]
    sb = request("/branches/select", {**identity, "branch_id": b}, token=token)["token"]
    broad = request("/branches/select", {**identity, "all": True}, token=token)["token"]
    assert claims(sa)["qa_directory"] is True
    assert "qa_directory" not in claims(sb)
    assert "qa_directory" not in claims(broad)

    def scoped(path, data=None, status=200, scope=sa):
        return request(path, data, token=token, status=status,
                       headers={"X-Branch-Token": scope})

    for path in ("/customers", "/suppliers"):
        assert scoped(path)["items"] == []
        scoped(path, {"name": "Server must refuse parallel directory writes"}, status=403)
        scoped(path, {"name": "Unchanged connected directory"}, status=201, scope=sb)
        assert scoped(path)["items"] == []
    assert session["user"]["role"] == "owner"

    print("New signup passed trial and branch creation; only its first concrete branch "
          "carries the signed QA directory grant. Parallel writes are refused; connected writes work.")
    out = {**login, "account": user["id"], "organization": organization,
           "first_branch": a, "other_branch": b}
    (root / "enrollment-probe.json").write_text(json.dumps(out) + "\n")


if __name__ == "__main__":
    os.umask(0o077)
    main(Path(sys.argv[1]))
