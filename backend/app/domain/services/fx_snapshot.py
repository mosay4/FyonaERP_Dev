"""Convert invoice-line amounts using the FROZEN per-line FX snapshot.

A sale/purchase line stores `original_unit_price` (in `price_currency`),
`exchange_rate_used` (`1 price_currency = exchange_rate_used invoice currency`)
and `unit_price` (the final, possibly manually-adjusted price in the invoice
currency). Reporting/costing that must express a line in the product's ORIGINAL
currency therefore divides by the SAVED rate — the exact value at operation
time — instead of re-converting with today's live rate. Live rates are only
used for the leg the snapshot cannot cover (e.g. original → an unrelated
display currency). Stored data is never mutated.
"""
from decimal import Decimal
from typing import Optional


async def live_rate(from_ccy: str, to_ccy: str) -> Optional[float]:
    from_ccy = (from_ccy or "").strip().upper()
    to_ccy = (to_ccy or "").strip().upper()
    if not from_ccy or not to_ccy:
        return None
    if from_ccy == to_ccy:
        return 1.0
    try:
        from app.domain.services.currency_service import CentralFXEngine

        res = await CentralFXEngine.get_instance().get_rate(from_ccy, to_ccy)
        r = (res or {}).get("rate")
        return float(r) if r and float(r) > 0 else None
    except Exception:
        return None


async def convert_invoice_amount(
    amount,
    invoice_ccy: str,
    target_ccy: str,
    price_currency: Optional[str] = None,
    exchange_rate_used=None,
) -> Optional[Decimal]:
    """Express `amount` (denominated in `invoice_ccy`) in `target_ccy`.

    Prefers the frozen snapshot. With the invariant
    ``amount_invoice = amount_original * exchange_rate_used`` the original value
    is ``amount_invoice / exchange_rate_used`` — historically exact. Only when
    the target differs from the original currency is a live rate used for that
    final leg.

    Returns ``None`` when the conversion is IMPOSSIBLE (different currencies and
    neither a frozen rate nor a live/saved rate). Callers MUST treat ``None`` as
    "unknown" and never substitute the original amount or a 1:1 rate.
    """
    a = Decimal(str(amount or 0))
    inv = (invoice_ccy or "").strip().upper()
    tgt = (target_ccy or "").strip().upper()
    if a == 0:
        return Decimal("0")
    if inv == tgt:
        return a
    pcy = (price_currency or "").strip().upper()
    try:
        r_used = Decimal(str(exchange_rate_used)) if exchange_rate_used else None
    except Exception:
        r_used = None
    if pcy and r_used and r_used > 0:
        base = a / r_used  # in price_currency — historical, exact
        if pcy == tgt:
            return base
        lr = await live_rate(pcy, tgt)
        if lr:
            return base * Decimal(str(lr))
        # Snapshot got us to price_currency but the last leg is unknown.
        return None
    # No usable snapshot: live/saved rate for the direct leg, else unknown.
    lr = await live_rate(inv, tgt)
    if lr:
        return a * Decimal(str(lr))
    return None
