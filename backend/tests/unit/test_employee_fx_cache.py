import asyncio
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from app.domain.services.currency_service import CentralFXEngine
from app.domain.services.yemen_exchange_provider import YemenExchangeProvider


@pytest.mark.asyncio
async def test_operation_reads_never_contact_either_external_provider(monkeypatch):
    engine = CentralFXEngine()
    stored = {'global': {'USD': 1, 'SAR': 3.75}, 'meta': {'fetched_at': '2026-10-24T00:00:00Z'}}
    loader = AsyncMock(return_value=stored)
    global_source = AsyncMock(side_effect=AssertionError('external global source contacted'))
    yer_source = AsyncMock(side_effect=AssertionError('external Yemen source contacted'))
    monkeypatch.setattr(engine, '_stored_snapshot', loader)
    monkeypatch.setattr(engine, '_fetch_global_rates', global_source)
    monkeypatch.setattr(YemenExchangeProvider.get_instance(), 'get_rates', yer_source)
    assert await engine.get_all_rates() == stored
    assert await engine.get_all_rates() == stored
    loader.assert_awaited_once()
    global_source.assert_not_awaited(); yer_source.assert_not_awaited()
    engine._cache_time = time.time() - 61
    loader.side_effect = RuntimeError('offline store')
    assert await engine.get_all_rates() == stored
    global_source.assert_not_awaited(); yer_source.assert_not_awaited()


@pytest.mark.asyncio
async def test_refresh_coalesces_and_publishes_global_and_yemen_as_one_snapshot(monkeypatch):
    engine = CentralFXEngine()
    old = {'global': {'USD': 1, 'SAR': 3.75}, 'meta': {'fetched_at': 'old'}}
    new = {'global': {'USD': 1, 'SAR': 3.76}, 'yemen': {'sanaa': {'USD': {'average': 534}}, 'aden': {'USD': {'average': 1600}}}, 'meta': {'fetched_at': 'new'}}
    engine._cache = old; engine._cache_time = time.time()
    gate = asyncio.Event()
    async def global_fetch():
        await gate.wait()
        return new['global'], 'global-provider'
    fetch = AsyncMock(side_effect=global_fetch)
    yer = SimpleNamespace(success=True, source='2dec.net', to_dict=lambda: new['yemen'])
    monkeypatch.setattr(engine, '_fetch_global_rates', fetch)
    monkeypatch.setattr(YemenExchangeProvider.get_instance(), 'get_rates', AsyncMock(return_value=yer))
    monkeypatch.setattr(engine, '_persist_store', AsyncMock())
    monkeypatch.setattr(engine, '_stored_snapshot', AsyncMock(return_value=new))
    a = asyncio.create_task(engine.get_all_rates(force_refresh=True))
    b = asyncio.create_task(engine.get_all_rates(force_refresh=True))
    await asyncio.sleep(0)
    assert await engine.get_all_rates() is old
    gate.set()
    result_a, result_b = await asyncio.gather(a, b)
    assert result_a is result_b and result_a['meta']['fetched_at'] == 'new'
    assert 'sanaa' in result_a['yemen'] and 'aden' in result_a['yemen']
    fetch.assert_awaited_once()
