"""Create fresh users and a real employment link on the dedicated QA API."""

import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import random
import socket
import time
from urllib.parse import urlsplit
from uuid import UUID, uuid4

from run_directory_pilot_lab import MANAGED_ENROLL_ROOT, QA_ORIGIN, business_probe_email
from verify_directory_signup import claims
from verify_original_signup import create_account


BASE = "http://127.0.0.1:18083/api/v1"


def assign_phone(request, token, preferred):
    """Reserved fictional NANP lines only. Taken lines are skipped and the
    per-user phone change limit is respected, never worked around."""
    lines = list(dict.fromkeys(
        [preferred, *(f"+120255501{line:02d}" for line in random.sample(range(100), 99))]
    ))
    last = None
    index = 0
    while index < len(lines):
        try:
            request("/auth/me/phone", {"country": "US", "phone": lines[index]}, token=token)
            return lines[index]
        except ValueError as error:
            last = error
            if "got 429" in str(error):
                time.sleep(65)
            else:
                index += 1
    raise RuntimeError("No free fictional QA phone line") from last


async def provision_cash(org, branch, devices, *, managed_email=None):
    """QA-only genesis checkpoint; the normal login is not an admission."""
    from sqlalchemy import insert, text
    from app.core.database import engine
    from app.domain.services import local_business_cash as cash

    scope = cash.CashScope(UUID(org), UUID(branch))
    owner_id = UUID(devices[0]["profile"]["id"])
    account_id = uuid4()
    async with engine.begin() as conn:
        if managed_email is not None:
            enrolled = await conn.scalar(text("""
                SELECT 1 FROM fyona_qa_business_ledger_scope l
                JOIN fyona_qa_directory_scope d USING (organization_id, account_id, branch_id)
                JOIN users u ON u.id=l.account_id AND u.organization_id=l.organization_id
                WHERE l.organization_id=:org AND l.branch_id=:branch AND l.account_id=:owner
                  AND u.email=:email AND u.role='owner' AND u.status='active'
                FOR SHARE OF l, d, u
            """), {"org": scope.workspace_id, "branch": scope.branch_id,
                   "owner": owner_id, "email": managed_email})
            if enrolled is None:
                raise RuntimeError("Managed cash is restricted to the new probe's own ledger")
        await conn.execute(insert(cash.scopes).values(**scope.key()))
        await cash.enable_settlement_protocol(conn, scope)
        await conn.execute(insert(cash.resources).values(
            **scope.key(), account_id=account_id, currency="SAR",
            available_minor=150000, allow_negative=False,
        ))
        await cash.replace_grant(conn, scope, owner_id, version=1, can_read=True, can_withdraw=True)
        checkpoint = await cash.cash_checkpoint(conn, scope)
        for device in devices:
            assert UUID(device["profile"]["id"]) == owner_id
            session = UUID(claims(device["token"])["sid"])
            if managed_email is not None:
                assert await conn.scalar(text("""
                    SELECT 1 FROM user_sessions
                    WHERE id=:session AND user_id=:owner AND is_active AND expires_at > now()
                    FOR SHARE
                """), {"session": session, "owner": owner_id}) == 1
            await cash.admit_replica(conn, scope, cash.CashReplica(owner_id, session),
                                     sequence=checkpoint.sequence, digest=checkpoint.digest,
                                     grant_version=1)
    await engine.dispose()
    return {"account": str(account_id), "checkpoint": {
        "sequence": checkpoint.sequence, "digest": checkpoint.digest,
    }}


def branch_till():
    """The link needs no operator plan: the till holder reports what it
    counted. This fixture only names the local account the test creates."""
    return {"account": str(uuid4())}


def create_branch_pair(root, *, managed):
    request, session, login = create_account(
        root, slot=5, name="متجر الفروع", device="Paired branches device",
        preferred_usage_mode="business",
        managed_probe=managed, managed_link_probe=managed,
    )
    token = session["access_token"]
    assign_phone(request, token, "+12025550155" if managed else "+12025550145")
    profile = request("/auth/me", token=token)
    request("/subscription/trial", {}, token=token)
    request("/subscription/business-setup/complete", {}, token=token)
    branch, second, connected = [request("/branches", {"name": name}, token=token)
                                 for name in ("فرع التجربة الأول", "فرع التجربة الثاني", "فرع متصل")]
    scopes = [request("/branches/select", {"branch_id": row["id"]}, token=token)["token"]
              for row in (branch, second, connected)]
    for scope in scopes[:2]:
        wire = claims(scope)
        assert wire["qa_directory"] and wire["qa_business_ledger"]
        assert wire["qa_writer_session"] == claims(token)["sid"]
        assert set(wire["qa_transfer_branches"]) == {branch["id"], second["id"]}
    assert claims(scopes[2]).get("qa_business_ledger") is not True
    request(f"/branches/{branch['id']}/reset", {}, token=token, status=409)
    request("/branches/reset-all", {}, token=token, status=409)
    other_login = request("/auth/login", login,
                           headers={"X-Device-Name": "Every device of the account",
                                    "X-Device-Fingerprint": "second-device-of-the-account"})
    other = claims(request("/branches/select", {"branch_id": branch["id"]},
                           token=other_login["access_token"])["token"])
    assert set(other["qa_transfer_branches"]) == {branch["id"], second["id"]}
    assert other["qa_writer_session"] == claims(other_login["access_token"])["sid"]
    print("PASS: two registered branches work on every device of the account; "
          "the connected third branch stays outside the device store.", flush=True)
    return {
        **login, "token": token, "refresh": session["refresh_token"],
        "profile": profile, "scope": scopes[0], "second_scope": scopes[1],
        "code": request("/me/code", token=token)["code"], "branches": [branch, second, connected],
        "subscription": request("/subscription/status", token=token),
    }


def main(root, output, *, managed, link_probe=False):
    base = f"{QA_ORIGIN}/api/v1" if managed else BASE
    if json.loads((root / "fixture.json").read_text())["base"] != base:
        raise SystemExit("The Business probe must use its dedicated QA origin")
    managed_email = None
    if managed:
        pg, *_ = json.loads((root / "ports.json").read_text())
        db = urlsplit(os.environ["DATABASE_URL"])
        if (root.resolve() != MANAGED_ENROLL_ROOT or output.exists()
                or not output.parent.resolve().name.startswith("fyona-business-run.")
                or output.parent.resolve().parent != Path("/tmp/opencode")
                or (db.hostname, db.port, db.username, db.path)
                != ("127.0.0.1", pg, "directory_pilot", "/directory_pilot")
                or db.password != (root / "db-password").read_text().strip()):
            raise SystemExit("Use only the private managed QA probe slots and database")
        managed_email = business_probe_email(root, 1, link=link_probe).read_text().strip()
    elif (os.environ.get("FYONA_QA_BUSINESS_SCENARIOS") != "1"
          or set(socket.if_nameindex()) != {(1, "lo")}):
        raise SystemExit("Use only the fresh loopback Business delivery lab")
    os.umask(0o077)
    actors = {}
    transports = {}
    for slot, (role, name) in enumerate((
        ("owner", "متجر الندى للأدوات"),
        ("employee", "سالم الحربي"),
        ("buyer", "مها الناصر"),
        ("supplier", "مستودع الأفق"),
    ), start=1):
        request, session, login = create_account(
            root, slot=slot, name=name, device=f"Business QA {role} A",
            preferred_usage_mode="business" if role == "owner" else "personal",
            managed_probe=managed, managed_link_probe=link_probe,
        )
        token = session["access_token"]
        # Reserved fictional North American numbers; OTP email goes to Mailpit.
        prefix = "+1202555015" if link_probe else "+1202555014"
        assign_phone(request, token, f"{prefix}{slot}")
        profile = request("/auth/me", token=token)
        code = request("/me/code", token=token)["code"]
        assert profile["id"] == session["user"]["id"]
        actors[role] = {**login, "profile": profile, "code": code, "token": token,
                        "refresh": session["refresh_token"]}
        transports[role] = request
    assert len({actor["profile"]["id"] for actor in actors.values()}) == 4

    owner = actors["owner"]
    owner_request = transports["owner"]
    owner_token = owner["token"]
    org = owner["profile"]["organization_id"]
    owner_request("/subscription/trial", {}, token=owner_token)
    owner_request("/subscription/business-setup/complete", {}, token=owner_token)
    status = owner_request("/subscription/status", token=owner_token)
    assert status["is_trial"] and status["sections"]["business"]["active"]
    branch, sibling, connected = [owner_request("/branches", {"name": name}, token=owner_token)
                                   for name in ("Riyadh QA", "Jeddah QA", "Dammam QA")]
    choice = {"organization_id": org, "branch_id": branch["id"]}
    owner_scope = owner_request("/branches/select", choice, token=owner_token)["token"]
    sibling_scope = owner_request(
        "/branches/select", {**choice, "branch_id": sibling["id"]}, token=owner_token,
    )["token"]
    off_scope = owner_request(
        "/branches/select", {**choice, "branch_id": connected["id"]}, token=owner_token,
    )["token"]
    assert claims(owner_scope).get("qa_business_ledger") is True
    assert claims(sibling_scope).get("qa_business_ledger") is True
    assert claims(off_scope).get("qa_business_ledger") is not True
    for route in ("/customers", "/suppliers"):
        owner_request(route, {"name": "Unchanged connected directory"},
                      status=201, token=owner_token, headers={"X-Branch-Token": off_scope})
        assert owner_request(route, token=owner_token,
                             headers={"X-Branch-Token": owner_scope})["items"] == []
    owner["scope"] = owner_scope
    owner_b = owner_request(
        "/auth/login", {"email": owner["email"], "password": owner["password"]},
        headers={"X-Device-Name": "Business QA owner B", "X-Device-Fingerprint": "business-qa-owner-b"},
    )
    second = {**owner, "token": owner_b["access_token"], "refresh": owner_b["refresh_token"]}
    second["scope"] = owner_request("/branches/select", choice, token=second["token"])["token"]
    assert claims(owner["token"])["sid"] != claims(second["token"])["sid"]
    actors["owner_b"] = second
    if managed and not link_probe:
        till = asyncio.run(provision_cash(org, branch["id"], [owner, second],
                                          managed_email=managed_email))
    else:
        till = branch_till()
        for device in (owner, second):
            device["scope"] = owner_request("/branches/select", choice, token=device["token"])["token"]
            signed = claims(device["scope"])
            assert signed.get("qa_cash_link") and signed["qa_writer_session"] == claims(device["token"])["sid"]
        owner_scope = owner["scope"]

    staff = actors["employee"]
    staff_request = transports["employee"]
    hired = owner_request(
        "/employees", {"full_name": staff["profile"]["full_name"], "salary": "4200.00",
                       "salary_currency": "SAR", "link_code": staff["code"],
                       "branch_ids": [branch["id"]]}, status=201, token=owner_token,
        headers={"X-Branch-Token": owner_scope},
    )
    invitation = hired["invitation"]["id"]
    assert hired["invitation"]["status"] == "pending"
    staff_request("/branches/select", choice, status=403, token=staff["token"])
    staff_request(f"/employees/invitations/{invitation}/respond", {"accept": True},
                  status=404, token=actors["supplier"]["token"])
    accepted = staff_request(f"/employees/invitations/{invitation}/respond", {"accept": True},
                             token=staff["token"])
    employee_id = hired["employee"]["id"]
    assert accepted["status"] == "accepted" and accepted["employee_id"] == employee_id
    staff_scope = staff_request("/branches/select", choice, token=staff["token"])["token"]
    assert claims(staff_scope)["qa_employee_finance"]["employee_id"] == employee_id
    assert claims(staff_scope).get("qa_directory") is not True
    staff_request("/branches/select", {**choice, "branch_id": sibling["id"]}, status=403,
                  token=staff["token"])
    staff["scope"] = staff_scope
    print("PASS: four real QA signups; one ledger branch, one non-enrolled branch; "
          "employment accepted only by the intended employee.", flush=True)

    branch_pair = create_branch_pair(root, managed=managed) if not managed or link_probe else None
    pending = output.with_suffix(".pending")
    with pending.open("x") as handle:
        handle.write(json.dumps({
            "base": base, "managed_probe": managed, "managed_link_probe": link_probe,
            "actors": actors, "organization": org,
            "branch": branch, "sibling": sibling, "connected": connected,
            "employee": employee_id,
            "subscription": status, "invitation": invitation, "till": till, "branch_pair": branch_pair,
        }) + "\n")
    pending.replace(output)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("root", type=Path)
    mode = cli.add_mutually_exclusive_group()
    mode.add_argument("--managed-output", type=Path)
    mode.add_argument("--managed-link-output", type=Path)
    args = cli.parse_args()
    external = args.managed_link_output or args.managed_output
    main(args.root, external or args.root / "business-scenarios.json",
         managed=external is not None, link_probe=args.managed_link_output is not None)
