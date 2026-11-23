"""Yemen Exchange Provider — dedicated service for YER rates.

Source-agnostic design: change _SOURCE_URL and _parse_rates() to use a different site.
Currently configured for https://www.2dec.net/rate.html
"""

import re
import time
import logging
from datetime import datetime, timezone
from typing import Dict, Any, Optional, Tuple

import httpx

logger = logging.getLogger(__name__)


class YerCurrencyRate:
    """Single currency rate with buy/sell/average."""

    __slots__ = ("buy", "sell", "average")

    def __init__(self, buy: float, sell: float, average: float):
        self.buy = buy
        self.sell = sell
        self.average = average

    def to_dict(self) -> Dict[str, float]:
        return {"buy": self.buy, "sell": self.sell, "average": self.average}


class YerRatesResult:
    """Structured result from Yemen rate scraping."""

    def __init__(
        self,
        sanaa: Dict[str, YerCurrencyRate],
        aden: Dict[str, YerCurrencyRate],
        last_updated: Optional[str] = None,
        source: str = "unknown",
        success: bool = True,
    ):
        self.sanaa = sanaa
        self.aden = aden
        self.last_updated = last_updated
        self.source = source
        self.success = success

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sanaa": {k: v.to_dict() for k, v in self.sanaa.items()},
            "aden": {k: v.to_dict() for k, v in self.aden.items()},
            "last_updated": self.last_updated,
            "source": self.source,
        }


class YemenExchangeProvider:
    """Source-agnostic provider for Yemen YER rates.

    To change the source in the future:
      1. Update _SOURCE_URL
      2. Override _parse_rates(html) with new parsing logic
      3. Override _extract_last_updated(html) if timestamp format differs
    """

    _instance: Optional["YemenExchangeProvider"] = None

    # ── Source configuration (change these to swap source) ──
    _SOURCE_URL = "https://www.2dec.net/rate.html"
    _SOURCE_NAME = "2dec.net"
    _TIMEOUT = 10
    _MAX_RETRIES = 2
    _RETRY_DELAY = 2

    # ── Cache ──
    _cache: Optional[YerRatesResult] = None
    _cache_time: float = 0
    _CACHE_TTL: int = 3600

    # ── Arabic currency name → ISO code ──
    _AR_NAME_MAP: Dict[str, str] = {
        "دولار امريكي": "USD",
        "ريال سعودي": "SAR",
        "يورو": "EUR",
        "درهم اماراتي": "AED",
        "جنيه مصري": "EGP",
        "ريال عماني": "OMR",
        "ريال قطري": "QAR",
        "رمبي صيني": "CNY",
        "جنية استرليني": "GBP",
        "دولار كندي": "CAD",
        "دولار استرالي": "AUD",
        "فرنك سويسري": "CHF",
        "دينار جزائري": "DZD",
        "دينار ليبي": "LYD",
        "ليرة تركي": "TRY",
        "رينغيت ماليزي": "MYR",
        "روبية هندي": "INR",
        "بير اثيوبي": "ETB",
        "فرنك جيبوتي": "DJF",
        "دينار كويتي": "KWD",
        "دينار اردني": "JOD",
        "دينار بحريني": "BHD",
        "روبية باكستاني": "PKR",
        "ين ياباني": "JPY",
        "وان كوري": "KRW",
        "جنيه إسترليني": "GBP",
    }

    @classmethod
    def get_instance(cls) -> "YemenExchangeProvider":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    async def get_rates(self, force_refresh: bool = False) -> YerRatesResult:
        """Get YER rates. Uses cache when available and not expired."""
        if (
            not force_refresh
            and self._cache is not None
            and self._cache.success
            and (time.time() - self._cache_time) < self._CACHE_TTL
        ):
            return self._cache

        result = await self._fetch_with_retry()

        if result.success:
            self._cache = result
            self._cache_time = time.time()
        elif self._cache is not None:
            logger.warning(
                "yemen_rates_fetch_failed_using_cache",
                extra={'source': self._SOURCE_NAME},
            )
            result = YerRatesResult(
                sanaa=self._cache.sanaa, aden=self._cache.aden,
                last_updated=self._cache.last_updated, source='cache', success=True)

        return result

    async def _fetch_with_retry(self) -> YerRatesResult:
        """Fetch with retry logic. On complete failure, return fallback."""
        last_error = None

        for attempt in range(self._MAX_RETRIES + 1):
            try:
                async with httpx.AsyncClient(
                    timeout=self._TIMEOUT,
                    headers={"User-Agent": "FyonaERP/1.0"},
                ) as client:
                    resp = await client.get(self._SOURCE_URL)
                    if resp.status_code == 200:
                        result = self._parse_rates(resp.text)
                        if result is not None:
                            logger.info(
                                "yemen_rates_fetched",
                                extra={
                                    "sanaa_count": len(result.sanaa),
                                    "aden_count": len(result.aden),
                                    "source": self._SOURCE_NAME,
                                    "last_updated": result.last_updated,
                                },
                            )
                            return result
                        else:
                            logger.warning(
                                "yemen_rates_parse_failed",
                                extra={
                                    "attempt": attempt,
                                    "source": self._SOURCE_NAME,
                                },
                            )
                    else:
                        logger.warning(
                            "yemen_rates_http_error",
                            extra={
                                "status": resp.status_code,
                                "attempt": attempt,
                                "source": self._SOURCE_NAME,
                            },
                        )
            except Exception as e:
                last_error = e
                logger.warning(
                    "yemen_rates_fetch_error",
                    extra={
                        "attempt": attempt,
                        "error": str(e),
                        "source": self._SOURCE_NAME,
                    },
                )

            if attempt < self._MAX_RETRIES:
                import asyncio
                await asyncio.sleep(self._RETRY_DELAY * (attempt + 1))

        logger.error(
            "yemen_rates_all_retries_failed",
            extra={
                "error": str(last_error),
                "returning_fallback": True,
            },
        )
        return self._get_fallback()

    def _get_fallback(self) -> YerRatesResult:
        return YerRatesResult(
            sanaa={},
            aden={},
            last_updated=None,
            source="fallback",
            success=False,
        )

    # ── HTML parsing (override this method to change source) ──

    _SECTION_HEADER_RE = re.compile(
        r'<h2\s+class="city-name">\s*([^<]+?)\s*</h2>', re.DOTALL
    )

    def _parse_rates(self, html: str) -> Optional[YerRatesResult]:
        """Parse HTML and extract YER rates for Sanaa and Aden.

        Returns None if parsing fails (caller should retry or use cache).
        Override this method + _extract_last_updated() to change source.
        """
        try:
            headers = list(self._SECTION_HEADER_RE.finditer(html))
            header_map = {m.group(1).strip(): m for m in headers}

            sanaa = self._parse_section(html, header_map.get("صنعاء"))
            aden = self._parse_section(html, header_map.get("عدن"))

            if not sanaa and not aden:
                return None

            last_updated = self._extract_last_updated(html)

            return YerRatesResult(
                sanaa=sanaa,
                aden=aden,
                last_updated=last_updated,
                source=self._SOURCE_NAME,
                success=True,
            )
        except Exception as e:
            logger.warning("yemen_rates_parse_exception", extra={"error": str(e)})
            return None

    def _parse_section(
        self, html: str, header_match: Optional[re.Match]
    ) -> Dict[str, YerCurrencyRate]:
        """Parse a city section starting from its <h2> header to the next <h2>."""
        rates: Dict[str, YerCurrencyRate] = {}
        if header_match is None:
            return rates

        start = header_match.end()
        next_header = self._SECTION_HEADER_RE.search(html, start)
        end = next_header.start() if next_header else len(html)

        section = html[start:end]

        rows = re.findall(r"<tr>(.*?)</tr>", section, re.DOTALL)
        for row in rows:
            name_match = re.search(
                r'class="currency-name"[^>]*>([^<]+)<', row
            )
            if not name_match:
                continue
            ar_name = name_match.group(1).strip()
            code = self._AR_NAME_MAP.get(ar_name)
            if not code:
                continue

            prices = re.findall(
                r'class="price-value[^"]*">\s*([\d,.]+)\s*<', row
            )
            if len(prices) >= 2:
                sell = float(prices[0].replace(",", ""))
                buy = float(prices[1].replace(",", ""))
                if sell > 0 and buy > 0:
                    avg = round((sell + buy) / 2, 4)
                    rates[code] = YerCurrencyRate(buy=buy, sell=sell, average=avg)

        return rates

    def _extract_last_updated(self, html: str) -> Optional[str]:
        """Extract last update timestamp from HTML.

        2dec.net format: 'HH:MM:SS YYYY-MM-DD'
        Override this method if source uses a different format.
        """
        matches = re.findall(
            r'class="update-date"[^>]*>([^<]+)<', html
        )
        if not matches:
            return None

        timestamps = []
        for raw in matches:
            raw = raw.strip()
            try:
                dt = datetime.strptime(raw, "%H:%M:%S %Y-%m-%d")
                timestamps.append(dt.isoformat())
            except ValueError:
                continue

        if timestamps:
            return max(timestamps)

        return matches[0].strip() if matches else None
