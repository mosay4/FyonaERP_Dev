"""REST writes to the legacy Business stores are refused for device branches."""

from types import SimpleNamespace

import pytest

from app.core import business_local_guard as guard_mod
from app.domain.services.branch_service import issue_scope_token
from uuid import uuid4


def _request(method, path, token=None):
    headers = {"X-Branch-Token": token} if token else {}
    return SimpleNamespace(method=method, url=SimpleNamespace(path=path), headers=headers)


@pytest.mark.asyncio
async def test_device_branch_writes_are_refused_and_reads_pass(monkeypatch):
    local = issue_scope_token(uuid4(), uuid4(), uuid4(), False,
                              qa_directory=True, qa_business_ledger=True)
    passed = []

    async def nxt(request):
        passed.append(request.url.path)
        return "ok"

    async def not_local(request):
        return False

    monkeypatch.setattr(guard_mod, "_organization_is_local", not_local)
    refused = await guard_mod.guard(_request("POST", "/api/v1/invoices", local), nxt)
    assert refused.status_code == 403
    assert (await guard_mod.guard(_request("POST", "/api/v1/employees/x/salary", local), nxt)).status_code == 403
    # Reads, relays, linking and employee identity are not ledger writes.
    for method, path in (("GET", "/api/v1/invoices"), ("POST", "/api/v1/business-relay/push"),
                         ("POST", "/api/v1/peer-relay/push"), ("POST", "/api/v1/employees"),
                         ("POST", "/api/v1/branches")):
        assert await guard_mod.guard(_request(method, path, local), nxt) == "ok"
    # A connected (non-device) branch keeps its REST writers.
    connected = issue_scope_token(uuid4(), uuid4(), uuid4(), False)
    assert await guard_mod.guard(_request("POST", "/api/v1/invoices", connected), nxt) == "ok"
