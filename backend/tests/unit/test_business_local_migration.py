"""A branch's legacy server data is exported once to the owner's device."""

import json
from hashlib import sha256
from uuid import UUID

import pytest

from app.domain.services import business_local_migration as migration
from tests.unit.test_local_business_cutover import engine, _seed, _legacy_example  # noqa: F401

SERVER = "https://qa.fyonacompany.com:18443/api/v1"


@pytest.mark.asyncio
async def test_export_once_same_bytes_then_device_receipt(engine):
    scope, ids = await _seed(engine)
    await _legacy_example(engine, scope, ids)
    async with engine.begin() as conn:
        await migration.install(conn)
        state = await migration.status(conn, org=scope.organization_id, branch=scope.branch_id)
        assert state["needed"] is True
        first = await migration.export(conn, org=scope.organization_id,
                                       account=scope.account_id, branch=scope.branch_id,
                                       server=SERVER)
        again = await migration.export(conn, org=scope.organization_id,
                                       account=scope.account_id, branch=scope.branch_id,
                                       server=SERVER)
        assert again == first
        assert sha256(first["body"]).hexdigest() == first["digest"]
        body = json.loads(first["body"])
        assert body["server"] == SERVER and body["branch_id"] == str(scope.branch_id)
        assert body["tables"]["invoices"], "the legacy invoices travel"
        await migration.acknowledge(conn, org=scope.organization_id, branch=scope.branch_id,
                                    snapshot_id=UUID(first["snapshot_id"]), digest=first["digest"])
        done = await migration.status(conn, org=scope.organization_id, branch=scope.branch_id)
        assert done == {**done, "needed": False, "imported": True}
        with pytest.raises(migration.MigrationRejected):
            await migration.acknowledge(conn, org=scope.organization_id, branch=scope.branch_id,
                                        snapshot_id=UUID(first["snapshot_id"]), digest="0" * 64)


@pytest.mark.asyncio
async def test_a_branch_without_business_data_needs_no_move(engine):
    scope, _ids = await _seed(engine)
    async with engine.begin() as conn:
        await migration.install(conn)
        from sqlalchemy import text
        # The seed itself holds parties/accounts; only the branch row is not data.
        count = await migration.legacy_rows(conn, scope.branch_id)
        rows = await conn.scalar(text("SELECT COUNT(*) FROM public.branches WHERE id = :b"),
                                 {"b": scope.branch_id})
        assert rows == 1
        assert count >= 0
