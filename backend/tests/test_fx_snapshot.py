"""Unit tests for the frozen per-line FX snapshot conversion.

These verify the exact arithmetic used by product statistics / Falcon so that
historical figures use the SAVED rate at operation time, not today's live rate.
"""
from decimal import Decimal

import pytest

from app.domain.services import fx_snapshot


@pytest.mark.asyncio
async def test_same_currency_is_unchanged():
    assert await fx_snapshot.convert_invoice_amount(
        100, "SAR", "SAR"
    ) == Decimal("100")


@pytest.mark.asyncio
async def test_target_equal_to_invoice_currency_is_unchanged():
    # Even with a snapshot present, invoice -> invoice is 1:1.
    assert await fx_snapshot.convert_invoice_amount(
        6800, "YER_OLD", "YER_OLD", "SAR", 136
    ) == Decimal("6800")


@pytest.mark.asyncio
async def test_snapshot_converts_back_to_price_currency():
    # Scenario 1: 50 SAR -> 6800 YER_OLD at 136. Back to SAR uses the SAVED
    # rate (6800 / 136 = 50) — NOT a live rate.
    out = await fx_snapshot.convert_invoice_amount(
        6800, "YER_OLD", "SAR", "SAR", 136
    )
    assert out == Decimal("50")


@pytest.mark.asyncio
async def test_manual_edited_amount_converted_historically():
    # Merchant edited 6800 -> 7000 YER_OLD; revenue in SAR = 7000 / 136.
    out = await fx_snapshot.convert_invoice_amount(
        7000, "YER_OLD", "SAR", "SAR", 136
    )
    assert abs(out - (Decimal("7000") / Decimal("136"))) < Decimal("0.0001")


@pytest.mark.asyncio
async def test_no_snapshot_falls_back_to_live(monkeypatch):
    async def _fake(from_ccy, to_ccy):
        assert (from_ccy, to_ccy) == ("USD", "SAR")
        return 3.75

    monkeypatch.setattr(fx_snapshot, "live_rate", _fake)
    out = await fx_snapshot.convert_invoice_amount(
        100, "USD", "SAR", None, None
    )
    assert out == Decimal("375.0")


@pytest.mark.asyncio
async def test_unknown_live_rate_returns_none(monkeypatch):
    async def _none(from_ccy, to_ccy):
        return None

    monkeypatch.setattr(fx_snapshot, "live_rate", _none)
    # Impossible conversion MUST be None — never the original amount or 1:1.
    out = await fx_snapshot.convert_invoice_amount(
        250, "USD", "SAR", None, None
    )
    assert out is None


@pytest.mark.asyncio
async def test_snapshot_with_unknown_last_leg_returns_none(monkeypatch):
    async def _none(from_ccy, to_ccy):
        return None

    monkeypatch.setattr(fx_snapshot, "live_rate", _none)
    # Snapshot reaches SAR but SAR->AED is unknown => None (not 50).
    out = await fx_snapshot.convert_invoice_amount(
        6800, "YER_OLD", "AED", "SAR", 136
    )
    assert out is None


@pytest.mark.asyncio
async def test_snapshot_to_unrelated_currency_uses_live_for_last_leg(monkeypatch):
    async def _live(from_ccy, to_ccy):
        if (from_ccy, to_ccy) == ("SAR", "AED"):
            return 0.98
        return None

    monkeypatch.setattr(fx_snapshot, "live_rate", _live)
    # 6800 YER_OLD -> SAR (=50) -> AED (×0.98) = 49.
    out = await fx_snapshot.convert_invoice_amount(
        6800, "YER_OLD", "AED", "SAR", 136
    )
    assert abs(out - Decimal("49.0")) < Decimal("0.0001")
