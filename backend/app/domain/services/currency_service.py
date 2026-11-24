import os
import math
import time
import json
import asyncio
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any, List, Tuple

import httpx
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from .yemen_exchange_provider import YemenExchangeProvider, YerRatesResult, YerCurrencyRate
from ..entities.finance_entities import AdminExchangeRate, ExchangeRateHistory, ExchangeRateStore
from app.core.database import async_session_factory
from app.core.logging import get_logger

logger = get_logger(__name__)


class RateFreshness:
    FRESH = "fresh"
    STALE = "stale"
    EXPIRED = "expired"
    UNAVAILABLE = "unavailable"


class CentralFXEngine:
    """Centralized Foreign Exchange Engine — single source of truth.

    Architecture:
      Admin / External Provider
        → Backend FX Engine (this)
          → Exchange Rate Store (DB + in-memory cache)
            → Backend API
              → Flutter CurrencyEngine (cache only)

    Rules:
      - NEVER DESTROY THE ORIGINAL CURRENCY
      - All rates validated before use
      - Stale/explicitly tracked via freshness
      - Last Known Good Rate used on failure
      - All changes logged to ExchangeRateHistory
    """

    _instance: Optional["CentralFXEngine"] = None
    _cache: Optional[Dict[str, Any]] = None
    _cache_time: float = 0
    _CACHE_TTL: int = 3600  # 1 hour
    _STALE_THRESHOLD: int = 7200  # 2 hours → stale
    _EXPIRED_THRESHOLD: int = 86400  # 24 hours → expired

    @classmethod
    def get_instance(cls) -> "CentralFXEngine":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    # ── Rate Validation ──

    @staticmethod
    def _validate_rate(rate: Any, currency: str = "") -> bool:
        """Reject invalid rates: 0, negative, NaN, Infinity."""
        if rate is None:
            return False
        try:
            r = float(rate)
        except (TypeError, ValueError):
            logger.warning("rate_validation_failed", currency=currency, rate=rate, reason="not_a_number")
            return False
        if math.isnan(r) or math.isinf(r):
            logger.warning("rate_validation_failed", currency=currency, rate=rate, reason="nan_or_inf")
            return False
        if r <= 0:
            logger.warning("rate_validation_failed", currency=currency, rate=rate, reason="non_positive")
            return False
        return True

    @staticmethod
    def _validate_rate_sanity(rate: float, prev_rate: Optional[float], currency: str) -> bool:
        """Reject rates that changed unreasonably (>50% in one update)."""
        if prev_rate is None or prev_rate <= 0:
            return True
        change_pct = abs(rate - prev_rate) / prev_rate
        if change_pct > 0.5:
            logger.warning(
                "rate_sanity_check_failed",
                currency=currency,
                new_rate=rate,
                prev_rate=prev_rate,
                change_pct=round(change_pct * 100, 1),
            )
            return False
        return True

    # ── Freshness ──

    def _get_freshness(self, fetched_at: Optional[datetime]) -> str:
        if fetched_at is None:
            return RateFreshness.UNAVAILABLE
        age = (datetime.now(timezone.utc) - fetched_at).total_seconds()
        if age < self._CACHE_TTL:
            return RateFreshness.FRESH
        if age < self._STALE_THRESHOLD:
            return RateFreshness.STALE
        if age < self._EXPIRED_THRESHOLD:
            return RateFreshness.EXPIRED
        return RateFreshness.UNAVAILABLE

    # ── Core API ──

    def __init__(self):
        self._cache = None
        self._cache_time = 0
        self._refresh_task = None
        self._last_refresh_attempt = 0

    async def _stored_snapshot(self) -> Dict[str, Any]:
        """Read approved durable observations only; never contact a provider."""
        global_rates = {'USD': 1.0}
        cities = {'YER_OLD': {}, 'YER_NEW': {}}
        observations = {}
        async with async_session_factory() as session:
            rows = (await session.scalars(select(ExchangeRateStore))).all()
            for row in rows:
                code = row.currency_code.strip().upper()
                if row.base_currency != 'USD' or row.source in ('fallback', 'hardcoded', 'seed') or not self._validate_rate(row.average_rate, code):
                    continue
                observations[code] = {
                    'observed_at': row.fetched_at.isoformat() if row.fetched_at else None,
                    'provider': row.provider, 'source': row.source,
                }
                if code in cities:
                    cities[code]['USD'] = {'buy': row.buy_rate, 'sell': row.sell_rate,
                                           'average': row.average_rate}
                elif not code.startswith('YER'):
                    global_rates[code] = float(row.average_rate)
            effective = func.coalesce(ExchangeRateHistory.effective_at, ExchangeRateHistory.created_at)
            pairs = (await session.scalars(select(ExchangeRateHistory).where(
                ExchangeRateHistory.currency_code.in_(list(cities)),
                ExchangeRateHistory.base_currency == 'SAR',
                ExchangeRateHistory.provider == '2dec.net',
                ExchangeRateHistory.source.notin_(['fallback', 'hardcoded', 'seed']),
                effective <= datetime.now(timezone.utc),
            ).order_by(effective.desc(), ExchangeRateHistory.created_at.desc()))).all()
            for row in pairs:
                if 'SAR' not in cities[row.currency_code] and self._validate_rate(row.average_rate):
                    cities[row.currency_code]['SAR'] = {
                        'buy': row.buy_rate, 'sell': row.sell_rate, 'average': row.average_rate}
        admin = await self._load_admin_rates()
        for row in admin:
            code, base = row['currency_code'].upper(), (row.get('base_currency') or 'USD').upper()
            rate = row['average_rate']
            if not self._validate_rate(rate, code):
                continue
            if code in cities and base in ('USD', 'SAR'):
                cities[code][base] = {'buy':row['buy_rate'],'sell':row['sell_rate'],'average':rate}
                if base == 'USD': cities[code].pop('SAR', None)
            elif base == 'USD' and not code.startswith('YER'):
                global_rates[code] = float(rate)
            observations[code] = {'observed_at':row.get('updated_at'),
                                  'provider':'admin','source':'manual'}
        if any(r['currency_code'] == 'SAR' and (r.get('base_currency') or 'USD') == 'USD' for r in admin):
            manual_pairs = {r['currency_code'] for r in admin if r.get('base_currency') == 'SAR'}
            for code in cities:
                if code not in manual_pairs: cities[code].pop('SAR', None)
        dates = [v['observed_at'] for v in observations.values() if v.get('observed_at')]
        observed = max(dates) if dates else None
        global_rates['USD'] = 1.0
        return {
            'global': global_rates,
            'yemen': {'sanaa':cities['YER_OLD'], 'aden':cities['YER_NEW'],
                      'last_updated':observed,
                      'source':'store' if any(cities.values()) else 'unavailable'},
            'meta': {'fetched_at':observed, 'last_checked_at':datetime.now(timezone.utc).isoformat(),
                     'global_source':'store' if len(global_rates)>1 else 'unavailable',
                     'yemen_source':'store' if any(cities.values()) else 'unavailable',
                     'observations':observations},
            'admin_rates':admin,
        }

    async def get_all_rates(self, force_refresh: bool = False) -> Dict[str, Any]:
        """Ordinary readers use storage; only the refresh coordinator fetches."""
        if force_refresh:
            task = self._refresh_task
            if task is None or task.done():
                if self._last_refresh_attempt and time.monotonic()-self._last_refresh_attempt < 30:
                    return self._cache or await self._stored_snapshot()
                self._last_refresh_attempt = time.monotonic()
                task = self._refresh_task = asyncio.create_task(self._refresh_sources())
            return await asyncio.shield(task)
        if self._cache is None or time.time()-self._cache_time > 60:
            try:
                self._cache = await self._stored_snapshot()
                self._cache_time = time.time()
            except Exception:
                if self._cache is None:
                    raise
        return self._cache

    async def _refresh_sources(self):
        global_result, yer_result = await asyncio.gather(
            self._fetch_global_rates(),
            YemenExchangeProvider.get_instance().get_rates(force_refresh=True),
            return_exceptions=True,
        )
        rates, source = ({}, None) if isinstance(global_result, BaseException) else global_result
        sanaa, aden, yer_source = {}, {}, 'fallback'
        if not isinstance(yer_result, BaseException) and yer_result.success and yer_result.source == '2dec.net':
            sanaa, aden = yer_result.to_dict()['sanaa'], yer_result.to_dict()['aden']
            yer_source = '2dec.net'
        await self._persist_store(rates, source, sanaa, aden, yer_source)
        try:
            result = await self._stored_snapshot()
            result['meta']['provider_refresh'] = {
                'global':source is not None, 'yemen':yer_source=='2dec.net'}
        except Exception:
            if self._cache is None:
                raise
            return self._cache
        self._cache, self._cache_time = result, time.time()
        logger.info('currency_snapshot_refreshed', currencies=len(result['global']),
                    global_source=source, yemen_source=yer_source)
        return result

    async def convert(
        self,
        amount: float,
        from_currency: str,
        to_currency: str,
    ) -> Optional[float]:
        """Convert amount between currencies. Returns None if rate unavailable."""
        if from_currency == to_currency:
            return amount
        if not self._validate_rate(amount, from_currency):
            return None

        data = await self.get_all_rates()
        rate = self._find_rate(
            from_currency.upper(),
            to_currency.upper(),
            data.get("global", {}),
            data.get("yemen", {}).get("sanaa", {}),
            data.get("yemen", {}).get("aden", {}),
        )
        if rate is None:
            return None
        result = amount * rate
        # Round to 4 decimal places to avoid floating point issues
        return round(result, 4)

    async def get_rate(
        self,
        from_currency: str,
        to_currency: str,
    ) -> Optional[Dict[str, Any]]:
        """Get rate with full metadata."""
        if from_currency == to_currency:
            return {
                "rate": 1.0,
                "from": from_currency,
                "to": to_currency,
                "source": "identity",
                "freshness": RateFreshness.FRESH,
            }

        data = await self.get_all_rates()
        rate = self._find_rate(
            from_currency.upper(),
            to_currency.upper(),
            data.get("global", {}),
            data.get("yemen", {}).get("sanaa", {}),
            data.get("yemen", {}).get("aden", {}),
        )

        meta = data.get("meta", {})
        fetched_at = meta.get("fetched_at")

        return {
            "rate": rate,
            "from": from_currency.upper(),
            "to": to_currency.upper(),
            "source": meta.get("global_source", "unknown"),
            "freshness": self._get_freshness(
                datetime.fromisoformat(fetched_at) if fetched_at else None
            ),
            "fetched_at": fetched_at,
        }

    # ── Persistent per-currency rate store ──

    async def _persist_store(
        self,
        global_rates: Dict[str, float],
        global_source: Optional[str],
        sanaa_dict: Dict[str, Any],
        aden_dict: Dict[str, Any],
        yer_source: str,
    ) -> None:
        """Upsert auto-fetched rates into the durable store (one row per currency).

        Only genuine provider data is persisted — hardcoded fallbacks are never
        written so the store always keeps the last real rates.
        """
        if global_source is None and yer_source == "fallback":
            return

        entries: List[Dict[str, Any]] = []
        now = datetime.now(timezone.utc)

        if global_source is not None:
            for code, rate in global_rates.items():
                if code.startswith("YER") or not self._validate_rate(rate, code):
                    continue
                entries.append(
                    {
                        "currency_code": code,
                        "buy_rate": float(rate),
                        "sell_rate": float(rate),
                        "average_rate": float(rate),
                        "source": "auto",
                        "provider": global_source,
                    }
                )

        if yer_source != "fallback":
            for code, city_data in (("YER_OLD", sanaa_dict), ("YER_NEW", aden_dict)):
                usd = city_data.get("USD") if city_data else None
                if not usd:
                    continue
                buy = usd.get("buy")
                sell = usd.get("sell")
                avg = usd.get("average")
                if not (buy and sell and avg):
                    continue
                entries.append(
                    {
                        "currency_code": code,
                        "buy_rate": float(buy),
                        "sell_rate": float(sell),
                        "average_rate": float(avg),
                        "source": yer_source,
                        "provider": "2dec.net",
                    }
                )

        if not entries:
            return

        try:
            async with async_session_factory() as session:
                if yer_source != 'fallback':
                    for code, city in [('YER_OLD', sanaa_dict), ('YER_NEW', aden_dict)]:
                        direct = (city.get('SAR') or {}).get('average')
                        if not self._validate_rate(direct, code):
                            continue
                        previous = await session.scalar(select(ExchangeRateHistory).where(
                            ExchangeRateHistory.currency_code == code,
                            ExchangeRateHistory.base_currency == 'SAR',
                        ).order_by(ExchangeRateHistory.created_at.desc()).limit(1))
                        if previous is None or float(previous.average_rate) != float(direct) or \
                                previous.created_at.date() != now.date():
                            session.add(ExchangeRateHistory(currency_code=code,
                                base_currency='SAR', rate_type='average',
                                buy_rate=float((city.get('SAR') or {}).get('buy') or direct),
                                sell_rate=float((city.get('SAR') or {}).get('sell') or direct),
                                average_rate=float(direct), source=yer_source,
                                provider='2dec.net', created_at=now))
                for entry in entries:
                    existing = await session.scalar(
                        select(ExchangeRateStore).where(
                            ExchangeRateStore.currency_code == entry["currency_code"]
                        )
                    )
                    previous = await session.scalar(
                        select(ExchangeRateHistory).where(
                            ExchangeRateHistory.currency_code == entry['currency_code'],
                            ExchangeRateHistory.base_currency == 'USD',
                        ).order_by(ExchangeRateHistory.created_at.desc()).limit(1)
                    )
                    if previous is None or (
                        float(previous.average_rate or 0) != entry['average_rate']
                        or previous.created_at.date() != now.date()
                    ):
                        session.add(ExchangeRateHistory(
                            currency_code=entry['currency_code'], base_currency='USD',
                            rate_type='average', buy_rate=entry['buy_rate'],
                            sell_rate=entry['sell_rate'], average_rate=entry['average_rate'],
                            source=entry['source'], provider=entry['provider'],
                            created_at=now,
                        ))
                    if existing is not None:
                        existing.buy_rate = entry["buy_rate"]
                        existing.sell_rate = entry["sell_rate"]
                        existing.average_rate = entry["average_rate"]
                        existing.source = entry["source"]
                        existing.provider = entry["provider"]
                        existing.fetched_at = now
                    else:
                        session.add(
                            ExchangeRateStore(
                                currency_code=entry["currency_code"],
                                base_currency="USD",
                                buy_rate=entry["buy_rate"],
                                sell_rate=entry["sell_rate"],
                                average_rate=entry["average_rate"],
                                source=entry["source"],
                                provider=entry["provider"],
                                fetched_at=now,
                            )
                        )
                await session.commit()
            logger.info("exchange_rate_store_updated", currencies=len(entries))
        except Exception as e:
            logger.warning("exchange_rate_store_persist_error", error=str(e))

    async def _load_store_global_rates(self) -> Optional[Dict[str, float]]:
        """Recover last known good global rates from the store."""
        try:
            async with async_session_factory() as session:
                rows = await session.scalars(select(ExchangeRateStore))
                result: Dict[str, float] = {}
                for row in rows:
                    code = row.currency_code
                    if code.startswith("YER") or not self._validate_rate(row.average_rate, code):
                        continue
                    result[code] = float(row.average_rate)
                return result if result else None
        except Exception as e:
            logger.warning("exchange_rate_store_load_error", error=str(e))
            return None

    async def _load_store_yer(self) -> Optional[Tuple[Dict, Dict, Optional[str]]]:
        """Recover last known good YER rates (Sanaa/Aden) from the store."""
        try:
            async with async_session_factory() as session:
                rows = await session.scalars(select(ExchangeRateStore))
                sanaa: Dict[str, Dict[str, float]] = {}
                aden: Dict[str, Dict[str, float]] = {}
                provider: Optional[str] = None
                for row in rows:
                    if not self._validate_rate(row.average_rate, row.currency_code):
                        continue
                    datum = {"buy": row.buy_rate, "sell": row.sell_rate, "average": row.average_rate}
                    if row.currency_code == "YER_OLD":
                        sanaa["USD"] = datum
                        provider = row.provider or provider
                    elif row.currency_code == "YER_NEW":
                        aden["USD"] = datum
                        provider = row.provider or provider
                if sanaa or aden:
                    return sanaa, aden, provider
                return None
        except Exception as e:
            logger.warning("exchange_rate_store_yer_load_error", error=str(e))
            return None

    # ── Admin-managed rates ──

    async def _load_admin_rates(self) -> List[Dict[str, Any]]:
        """Load admin-set exchange rates from the database."""
        try:
            async with async_session_factory() as session:
                result = await session.execute(
                    select(AdminExchangeRate).where(AdminExchangeRate.is_active == True)
                )
                rows = result.scalars().all()
                return [
                    {
                        "id": str(r.id),
                        "currency_code": r.currency_code,
                        "base_currency": r.base_currency or "USD",
                        "rate_type": r.rate_type or "average",
                        "buy_rate": r.buy_rate,
                        "sell_rate": r.sell_rate,
                        "average_rate": r.average_rate,
                        "source": r.source or "manual",
                        "provider": r.provider,
                        "updated_at": r.updated_at.isoformat() if r.updated_at else None,
                    }
                    for r in rows
                ]
        except Exception as e:
            logger.warning("admin_rates_load_error", error=str(e))
            return []

    async def log_rate_change(
        self,
        session: AsyncSession,
        currency_code: str,
        buy_rate: float,
        sell_rate: float,
        average_rate: float,
        source: str,
        provider: Optional[str] = None,
        changed_by: Optional[str] = None,
        previous_buy: Optional[float] = None,
        previous_sell: Optional[float] = None,
        previous_average: Optional[float] = None,
        metadata: Optional[Dict] = None,
        base_currency: str = 'USD',
    ) -> None:
        """Log a rate change to the audit trail."""
        entry = ExchangeRateHistory(
            currency_code=currency_code,
            base_currency=base_currency.upper(),
            rate_type="average",
            buy_rate=buy_rate,
            sell_rate=sell_rate,
            average_rate=average_rate,
            source=source,
            provider=provider,
            changed_by=changed_by,
            previous_buy_rate=previous_buy,
            previous_sell_rate=previous_sell,
            previous_average_rate=previous_average,
            metadata_json=json.dumps(metadata) if metadata else None,
        )
        session.add(entry)
        await session.flush()

    # ── Global rates ──

    async def _fetch_global_rates(self) -> Tuple[Dict[str, float], Optional[str]]:
        """Fetch global rates from configured providers (ordered by priority).

        Returns (rates, source_label). source_label is None when every provider
        failed and the hardcoded fallback was used.
        """
        # Same public sources, in the same order, as the app's own fetch
        # (PublicExchangeRates): when one is down the next answers.
        providers = [
            (self._fetch_exchangerate_api, "exchangerate-api.com"),
            (lambda: self._fetch_public_table(
                "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json",
                "fawaz"), "currency-api"),
            (lambda: self._fetch_public_table(
                "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json",
                "fawaz"), "currency-api"),
            (lambda: self._fetch_public_table(
                "https://www.floatrates.com/daily/usd.json", "floatrates"), "floatrates"),
            (lambda: self._fetch_public_table(
                "https://api.frankfurter.dev/v1/latest?base=USD", "frankfurter"), "frankfurter"),
        ]
        for fetcher, name in providers:
            try:
                rates = await fetcher()
            except Exception as e:
                logger.warning("fx_provider_error", provider=name, error=str(e))
                rates = None
            if rates:
                return rates, name
        return {}, None

    async def _fetch_exchangerate_api(self) -> Optional[Dict[str, float]]:
        """exchangerate-api.com — the user-requested source for global currencies.

        Uses the keyed endpoint when EXCHANGE_RATE_API_KEY is configured,
        otherwise the same provider's free open endpoint (no key required).
        YER is intentionally excluded (handled via 2dec.net for both YER_OLD/YER_NEW).
        """
        api_key = os.environ.get("EXCHANGE_RATE_API_KEY", "")
        url = (
            f"https://v6.exchangerate-api.com/v6/{api_key}/latest/USD"
            if api_key
            else "https://open.er-api.com/v6/latest/USD"
        )
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(url)
                if resp.status_code == 200:
                    data = resp.json()
                    if data.get('result') == 'error' or \
                            (data.get('base_code') or data.get('base') or 'USD') != 'USD':
                        return None
                    raw = data.get("conversion_rates") or data.get("rates") or {}
                    if raw.get('USD') != 1:
                        return None
                    if raw:
                        validated = {}
                        for k, v in raw.items():
                            if k.startswith("YER") or not isinstance(v, (int, float)):
                                continue
                            if self._validate_rate(v, k):
                                validated[k] = float(v)
                        return validated if validated else None
        except Exception as e:
            logger.warning("exchangerate_api_error", error=str(e))
        return None

    async def _fetch_public_table(self, url: str, shape: str) -> Optional[Dict[str, float]]:
        """A free, keyless USD table. Needs at least 30 currencies and EUR."""
        try:
            async with httpx.AsyncClient(timeout=10, follow_redirects=True) as client:
                resp = await client.get(url)
            if resp.status_code != 200:
                return None
            data = resp.json()
            raw: Dict[str, object] = {}
            if shape == "fawaz":
                raw = {k.upper(): v for k, v in (data.get("usd") or {}).items()}
            elif shape == "floatrates":
                raw = {str(v.get("code", k)).upper(): v.get("rate")
                       for k, v in data.items() if isinstance(v, dict)}
            elif shape == "frankfurter":
                raw = dict(data.get("rates") or {})
            raw["USD"] = 1
            validated = {}
            for k, v in raw.items():
                if isinstance(v, str):
                    try:
                        v = float(v)
                    except ValueError:
                        continue
                if k.startswith("YER") or not isinstance(v, (int, float)) or isinstance(v, bool):
                    continue
                if self._validate_rate(v, k):
                    validated[k] = float(v)
            if len(validated) < 30 or not validated.get("EUR"):
                return None
            return validated
        except Exception as e:
            logger.warning("public_rate_source_error", source=shape, error=str(e))
        return None

    async def _fetch_egcurrency(self) -> Optional[Dict[str, float]]:
        api_key = os.environ.get("EGCURRENCY_API_KEY", "")
        if not api_key:
            return None
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(
                    "https://egcurrency.com/api/latest",
                    params={"access_key": api_key, "base": "USD"},
                )
                if resp.status_code == 200:
                    data = resp.json()
                    if data.get("success") and "rates" in data:
                        validated = {}
                        for k, v in data["rates"].items():
                            if isinstance(v, (int, float)) and self._validate_rate(v, k):
                                validated[k] = float(v)
                        return validated if validated else None
        except Exception as e:
            logger.warning("egcurrency_error", error=str(e))
        return None

    async def _fetch_exchangerate_host(self) -> Optional[Dict[str, float]]:
        api_key = os.environ.get("EXCHANGE_RATE_HOST_KEY", "")
        if not api_key:
            return None
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(
                    "https://api.exchangerate.host/latest",
                    params={"access_key": api_key, "base": "USD"},
                )
                if resp.status_code == 200:
                    data = resp.json()
                    if data.get("success", True) and "rates" in data:
                        validated = {}
                        for k, v in data["rates"].items():
                            if isinstance(v, (int, float)) and self._validate_rate(v, k):
                                validated[k] = float(v)
                        return validated if validated else None
        except Exception as e:
            logger.warning("exchangerate_host_error", error=str(e))
        return None

    async def _fetch_open_er_api(self) -> Optional[Dict[str, float]]:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get("https://open.er-api.com/v6/latest/USD")
                if resp.status_code == 200:
                    data = resp.json()
                    if data.get("result") == "success":
                        validated = {}
                        for k, v in data.get("rates", {}).items():
                            if isinstance(v, (int, float)) and self._validate_rate(v, k):
                                validated[k] = float(v)
                        return validated if validated else None
        except Exception as e:
            logger.warning("open_er_api_error", error=str(e))
        return None

    # ── Rate finding (same logic as exchange_rates.py, kept in sync) ──

    _YER_BRIDGE_CURRENCIES = {"USD", "SAR"}

    def _find_rate(
        self,
        from_curr: str,
        to_curr: str,
        global_rates: dict,
        yemen_sanaa: dict,
        yemen_aden: dict,
    ) -> Optional[float]:
        from_curr = 'YER_NEW' if from_curr.upper() == 'YER' else from_curr.upper()
        to_curr = 'YER_NEW' if to_curr.upper() == 'YER' else to_curr.upper()
        if from_curr == to_curr:
            return 1.0

        def _yer_avg(city_data: dict) -> Optional[float]:
            r = city_data.get("USD")
            if r:
                avg = r.get("average")
                if avg and self._validate_rate(avg, f"{from_curr}_YER"):
                    return float(avg)
            return None

        def _yer_direct(city_data: dict, curr: str) -> Optional[float]:
            if curr in self._YER_BRIDGE_CURRENCIES:
                r = city_data.get(curr)
                if r:
                    avg = r.get("average")
                    if avg and self._validate_rate(avg, f"{curr}_YER"):
                        return float(avg)
            return None

        # ── YER_OLD (Sanaa) as target ──
        if to_curr == "YER_OLD":
            if from_curr == "YER_NEW":
                avg_new = _yer_avg(yemen_aden)
                avg_old = _yer_avg(yemen_sanaa)
                if avg_new and avg_old and avg_new > 0:
                    return avg_old / avg_new
                return None
            if from_curr in self._YER_BRIDGE_CURRENCIES:
                avg = _yer_direct(yemen_sanaa, from_curr)
                if avg and avg > 0:
                    return avg
            avg_usd = _yer_avg(yemen_sanaa)
            if avg_usd and avg_usd > 0:
                from_per_usd = global_rates.get(from_curr)
                if from_per_usd and from_per_usd > 0:
                    return avg_usd / from_per_usd
            return None

        # ── YER_OLD (Sanaa) as source ──
        if from_curr == "YER_OLD":
            if to_curr == "YER_NEW":
                avg_old = _yer_avg(yemen_sanaa)
                avg_new = _yer_avg(yemen_aden)
                if avg_old and avg_new and avg_old > 0:
                    return avg_new / avg_old
                return None
            if to_curr in self._YER_BRIDGE_CURRENCIES:
                avg = _yer_direct(yemen_sanaa, to_curr)
                if avg and avg > 0:
                    return 1.0 / avg
            avg_usd = _yer_avg(yemen_sanaa)
            if avg_usd and avg_usd > 0:
                to_per_usd = global_rates.get(to_curr)
                if to_per_usd and to_per_usd > 0:
                    return to_per_usd / avg_usd
            return None

        # ── YER_NEW (Aden) as target ──
        if to_curr == "YER_NEW":
            if from_curr in self._YER_BRIDGE_CURRENCIES:
                avg = _yer_direct(yemen_aden, from_curr)
                if avg and avg > 0:
                    return avg
            avg_usd = _yer_avg(yemen_aden)
            if avg_usd and avg_usd > 0:
                from_per_usd = global_rates.get(from_curr)
                if from_per_usd and from_per_usd > 0:
                    return avg_usd / from_per_usd
            return None

        # ── YER_NEW (Aden) as source ──
        if from_curr == "YER_NEW":
            if to_curr in self._YER_BRIDGE_CURRENCIES:
                avg = _yer_direct(yemen_aden, to_curr)
                if avg and avg > 0:
                    return 1.0 / avg
            avg_usd = _yer_avg(yemen_aden)
            if avg_usd and avg_usd > 0:
                to_per_usd = global_rates.get(to_curr)
                if to_per_usd and to_per_usd > 0:
                    return to_per_usd / avg_usd
            return None

        # ── YER_OLD ↔ YER_NEW ──
        if from_curr in ("YER_OLD", "YER_NEW") or to_curr in ("YER_OLD", "YER_NEW"):
            from_avg = _yer_avg(yemen_sanaa) if from_curr == "YER_OLD" else _yer_avg(yemen_aden)
            to_avg = _yer_avg(yemen_sanaa) if to_curr == "YER_OLD" else _yer_avg(yemen_aden)
            if from_avg and to_avg and from_avg > 0:
                return to_avg / from_avg

        # ── Standard global rates (USD base) ──
        from_per_usd = global_rates.get(from_curr)
        to_per_usd = global_rates.get(to_curr)
        if from_per_usd and to_per_usd and from_per_usd > 0:
            return to_per_usd / from_per_usd

        return None


# Keep backward compatibility
CurrencyService = CentralFXEngine
