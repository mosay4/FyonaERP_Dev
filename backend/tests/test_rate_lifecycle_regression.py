import asyncio
import json
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal

import pytest

from app.api.v1.business_reports import _result
from app.domain.services.currency_service import CentralFXEngine
from app.domain.services.yemen_exchange_provider import YemenExchangeProvider, YerRatesResult, YerCurrencyRate
from app.domain.services.report_fx import FxResolver


class MemoryEngine(CentralFXEngine):
    def __init__(self):
        super().__init__()
        self.stored = {'global':{'USD':1,'SAR':3.75,'EUR':.92},
          'yemen':{'source':'store','sanaa':{'USD':{'average':534},'SAR':{'average':140}},
                   'aden':{'USD':{'average':1600},'SAR':{'average':410}}},
          'meta':{'global_source':'store','fetched_at':'2026-10-23T00:00:00+00:00'}}
        self.fetches = 0

    async def _stored_snapshot(self):
        return deepcopy(self.stored)

    async def _fetch_global_rates(self):
        self.fetches += 1
        await asyncio.sleep(.01)
        return {'USD':1,'SAR':4}, 'exchangerate-api.com'

    async def _persist_store(self, global_rates, global_source, sanaa, aden, yer_source):
        if global_source:
            self.stored['global'].update(global_rates)
        if yer_source == '2dec.net':
            self.stored['yemen']['sanaa'].update(sanaa)
            self.stored['yemen']['aden'].update(aden)


@pytest.mark.asyncio
async def test_readers_do_not_fetch_and_refresh_is_single_flight(monkeypatch):
    class Yemen:
        calls = 0
        async def get_rates(self, force_refresh=False):
            self.calls += 1
            await asyncio.sleep(.01)
            return YerRatesResult({}, {'USD':YerCurrencyRate(1700,1700,1700)}, source='2dec.net')
    yemen = Yemen()
    monkeypatch.setattr(YemenExchangeProvider,'get_instance',lambda:yemen)
    engine = MemoryEngine()
    for _ in range(10):
        assert (await engine.get_all_rates())['global']['SAR'] == 3.75
    assert engine.fetches == 0
    results = await asyncio.gather(*[engine.get_all_rates(force_refresh=True) for _ in range(20)])
    assert engine.fetches == yemen.calls == 1
    assert all(r['global']['SAR'] == 4 for r in results)
    assert results[0]['global']['EUR'] == .92
    assert results[0]['yemen']['sanaa']['USD']['average'] == 534
    assert results[0]['yemen']['aden']['USD']['average'] == 1700
    await engine.get_all_rates(force_refresh=True)
    assert engine.fetches == 1


@pytest.mark.asyncio
async def test_source_outage_preserves_saved_rates_not_hardcoded_values(monkeypatch):
    class Yemen:
        async def get_rates(self, force_refresh=False):
            raise OSError('offline')
    monkeypatch.setattr(YemenExchangeProvider,'get_instance',lambda:Yemen())
    engine = MemoryEngine()
    async def unavailable():
        return {}, None
    engine._fetch_global_rates = unavailable
    original = await engine.get_all_rates()
    offline = await engine.get_all_rates(force_refresh=True)
    assert offline['global'] == original['global']
    assert offline['yemen'] == original['yemen']
    assert offline['meta']['provider_refresh'] == {'global':False,'yemen':False}
    missing = YemenExchangeProvider()._get_fallback()
    assert not missing.success and not missing.sanaa and not missing.aden


@pytest.mark.asyncio
async def test_latest_saved_valuation_includes_all_user_example_operations(monkeypatch):
    engine = MemoryEngine()
    monkeypatch.setattr(CentralFXEngine,'get_instance',lambda:engine)
    db = type('DB',(),{'info':{'report_fx_policy':'latest_approved'}})()
    fx = FxResolver(db)
    operations = [
        ('32','USD','2026-10-13'),('577.5','YER_OLD','2026-10-10'),
        ('12000','YER_OLD','2026-10-13'),('19.06','USD','2026-10-09'),
        ('8','USD','2026-10-13'),('150','YER_OLD','2026-10-08'),
        ('8','USD','2026-10-12'),('27603','YER_NEW','2026-10-09'),
    ]
    values=[]
    for amount,code,day in operations:
        values.append(await fx.convert(Decimal(amount),code,'SAR',
            datetime.fromisoformat(day).replace(tzinfo=timezone.utc)))
    assert all(v is not None for v in values)
    expected = (Decimal('67.06')*Decimal('3.75') +
                Decimal('12727.5')/Decimal('140') + Decimal('27603')/Decimal('410'))
    assert sum(values,Decimal(0)) == expected
    response = _result(db,{'currency':'SAR','total':float(expected)})
    payload=json.loads(response.body)
    assert payload['data']['totals_complete'] is True
    assert payload['data']['fx_valuation']['basis'] == 'latest_approved'
    assert engine.fetches == 0


@pytest.mark.asyncio
async def test_yemen_failed_refresh_cannot_replace_good_cache(monkeypatch):
    provider = YemenExchangeProvider()
    provider._cache = YerRatesResult({'USD':YerCurrencyRate(500,502,501)},
        {'USD':YerCurrencyRate(1500,1502,1501)},
        last_updated='2026-01-01T00:00:00Z',source='2dec.net',success=True)
    async def failed(): return provider._get_fallback()
    provider._fetch_with_retry=failed
    result=await provider.get_rates(force_refresh=True)
    assert result.source=='cache'
    assert result.sanaa['USD'].average==501
    assert result.aden['USD'].average==1501
    assert result.last_updated=='2026-01-01T00:00:00Z'


@pytest.mark.asyncio
async def test_exchangerate_api_is_the_only_global_network_source(monkeypatch):
    engine=CentralFXEngine()
    async def primary(): return {'USD':1,'SAR':3.75}
    monkeypatch.setattr(engine,'_fetch_exchangerate_api',primary)
    rates,source=await engine._fetch_global_rates()
    assert rates['SAR']==3.75 and source=='exchangerate-api.com'
    async def unavailable(): return None
    monkeypatch.setattr(engine,'_fetch_exchangerate_api',unavailable)
    rates,source=await engine._fetch_global_rates()
    assert rates=={} and source is None
