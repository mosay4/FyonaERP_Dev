from fastapi import APIRouter, Depends, Query

from ...api.deps import get_current_user_id
from ...api.responses import ok
from ...domain.services.currency_service import CurrencyService

router = APIRouter(tags=["Currency"])

_YER_BRIDGE_CURRENCIES = {"USD", "SAR"}


@router.get("/personal/exchange-rates")
async def get_exchange_rates(
    force_refresh: bool = Query(False, description="Force refresh from sources"),
    _user_id: str = Depends(get_current_user_id),
):
    """Return all exchange rates: global (exchangerate.host) + Yemen (2dec.net).

    Response:
      {
        "global": { "USD": 1.0, "SAR": 3.75, ... },
        "yemen": {
          "sanaa": { "USD": {"buy": 533, "sell": 535, "average": 534}, ... },
          "aden":  { "USD": {"buy": 1550, "sell": 1558, "average": 1554}, ... },
          "last_updated": "...",
          "source": "2dec.net"
        }
      }
    """
    service = CurrencyService.get_instance()
    data = await service.get_all_rates(force_refresh=force_refresh)
    return ok(data=data)


@router.get("/personal/exchange-rates/rate")
async def get_single_rate(
    from_currency: str = Query(..., description="Source currency code"),
    to_currency: str = Query(..., description="Target currency code"),
    _user_id: str = Depends(get_current_user_id),
):
    """Get a single conversion rate between two currencies."""
    service = CurrencyService.get_instance()
    data = await service.get_all_rates()

    from_upper = from_currency.upper()
    to_upper = to_currency.upper()

    if from_upper == to_upper:
        return ok(data={"rate": 1.0, "from": from_upper, "to": to_upper})

    global_rates = data.get("global", {})
    yemen_sanaa = data.get("yemen", {}).get("sanaa", {})
    yemen_aden = data.get("yemen", {}).get("aden", {})

    rate = _find_rate(
        from_upper, to_upper, global_rates, yemen_sanaa, yemen_aden
    )

    if rate is None:
        return ok(data={"rate": None, "from": from_upper, "to": to_upper, "available": False})

    return ok(data={"rate": rate, "from": from_upper, "to": to_upper, "available": True})


@router.post("/personal/exchange-rates/refresh")
async def refresh_rates(
    _user_id: str = Depends(get_current_user_id),
):
    """Force refresh all exchange rates from external sources."""
    service = CurrencyService.get_instance()
    data = await service.get_all_rates(force_refresh=True)
    return ok(data=data, message="Rates refreshed")


def _find_rate(
    from_curr: str,
    to_curr: str,
    global_rates: dict,
    yemen_sanaa: dict,
    yemen_aden: dict,
) -> float | None:
    """Find conversion rate using global + Yemen data.

    Business rule: only USD and SAR use direct 2dec.net YER rates.
    All other currencies go through USD as bridge:
      from_curr → USD (via global_rates) → YER (via 2dec.net)
    """
    if from_curr == to_curr:
        return 1.0

    def _yer_avg(city_data: dict) -> float | None:
        r = city_data.get("USD")
        if r:
            return r.get("average")
        return None

    def _yer_direct(city_data: dict, curr: str) -> float | None:
        if curr in _YER_BRIDGE_CURRENCIES:
            r = city_data.get(curr)
            if r:
                return r.get("average")
        return None

    # ── YER_OLD (Sanaa) as target ──
    if to_curr == "YER_OLD":
        if from_curr == "YER_NEW":
            avg_new = _yer_avg(yemen_aden)
            avg_old = _yer_avg(yemen_sanaa)
            if avg_new and avg_old and avg_new > 0:
                return avg_old / avg_new
            return None
        if from_curr in _YER_BRIDGE_CURRENCIES:
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
        if to_curr in _YER_BRIDGE_CURRENCIES:
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
        if from_curr in _YER_BRIDGE_CURRENCIES:
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
        if to_curr in _YER_BRIDGE_CURRENCIES:
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
