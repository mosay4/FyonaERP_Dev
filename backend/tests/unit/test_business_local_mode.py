"""Every active branch of an invited owner's organization is a device branch."""

from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.core import business_local_mode, qa_directory
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_main_and_other_branches_are_all_device_branches(engine, monkeypatch):
    from sqlalchemy.ext.asyncio import async_sessionmaker
    from app.domain.entities.auth_entities import User
    from app.domain.entities.sale_entities import Branch

    email = f"local-{uuid4().hex[:20]}@example.test"
    org, owner, branch, main = await _seed(engine, email)
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    async with async_sessionmaker(engine, expire_on_commit=False)() as db:
        user = await db.get(User, owner)
        for branch_id in (branch, main):
            row = await db.get(Branch, branch_id)
            assert await business_local_mode.whole_organization(db, user, row)
        names = await business_local_mode.branch_names(db, org)
        assert set(names) == {str(branch), str(main)}
        stranger = SimpleNamespace(email="other@example.test", role="owner",
                                   status="active", organization_id=org)
        assert not await business_local_mode.whole_organization(
            db, stranger, await db.get(Branch, main))


def test_the_managed_pinned_account_is_included(monkeypatch):
    org, account = uuid4(), uuid4()
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({"signup-" + "a" * 24 + "@example.test"}))
    monkeypatch.setenv("FYONA_QA_REMOTE", "1")
    import json
    monkeypatch.setenv("FYONA_QA_EXISTING_LEDGER_GRANTS", json.dumps(
        {str(uuid4()): {"account": str(account), "organization": str(org)}}))
    pinned = SimpleNamespace(id=account, organization_id=org, email="directory-owner@example.test",
                             role="owner", status="active")
    other = SimpleNamespace(id=uuid4(), organization_id=org, email="x@example.test",
                            role="owner", status="active")
    assert business_local_mode.enabled_for(pinned)
    assert not business_local_mode.enabled_for(other)
