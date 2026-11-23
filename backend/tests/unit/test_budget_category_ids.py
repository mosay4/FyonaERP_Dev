"""Unit tests for honoring client-provided budget category ids.

Offline-created categories carry stable client UUIDs; the server must
materialize the SAME ids (when valid and unused) so transaction links staged
offline stay valid after sync instead of dangling against fresh ids.
"""
from uuid import UUID, uuid4

from app.api.v1.personal_finance import _client_category_id


def test_honors_valid_unused_client_id():
    cid = uuid4()
    taken: set = set()
    assert _client_category_id(str(cid), taken) == cid
    assert cid in taken


def test_mints_fresh_id_for_missing_id():
    taken: set = set()
    got = _client_category_id(None, taken)
    assert isinstance(got, UUID)
    assert got in taken


def test_mints_fresh_id_for_garbage_id():
    taken: set = set()
    got = _client_category_id("not-a-uuid", taken)
    assert isinstance(got, UUID)


def test_mints_fresh_id_on_collision():
    cid = uuid4()
    taken: set = {cid}
    got = _client_category_id(str(cid), taken)
    assert isinstance(got, UUID)
    assert got != cid
    assert got in taken


def test_sequential_categories_keep_distinct_ids():
    c1, c2 = uuid4(), uuid4()
    taken: set = set()
    assert _client_category_id(str(c1), taken) == c1
    assert _client_category_id(str(c2), taken) == c2
    assert _client_category_id(None, taken) not in (c1, c2)
