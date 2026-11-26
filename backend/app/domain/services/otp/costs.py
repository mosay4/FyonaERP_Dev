"""Cost guard: per-message estimates + daily/monthly budgets (USD).

Spend is the sum of ``otp_deliveries.cost_usd`` (set when a provider
ACCEPTED a message) in the UTC day / month. A send is allowed only if the
estimate fits the channel budget AND the global budget. Admin overrides in
``otp_budgets`` win over the env defaults.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal
from functools import lru_cache
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.domain.entities.auth2_entities import OtpBudget, OtpDelivery

CHANNELS = ("sms", "whatsapp", "global")


@lru_cache(maxsize=8)
def _table(raw: str) -> dict:
    try:
        data = json.loads(raw) if raw else {}
        return {str(k).upper(): float(v) for k, v in data.items()}
    except (ValueError, TypeError, AttributeError):
        return {}


def estimate(channel: str, country: Optional[str]) -> float:
    c = (country or "").upper()
    if channel == "whatsapp":
        return _table(settings.AUTH_OTP_COST_WHATSAPP_BY_COUNTRY).get(
            c, settings.AUTH_OTP_COST_WHATSAPP_DEFAULT_USD)
    if channel == "sms":
        return _table(settings.AUTH_OTP_COST_SMS_BY_COUNTRY).get(
            c, settings.AUTH_OTP_COST_SMS_DEFAULT_USD)
    return 0.0


def _defaults() -> dict:
    return {
        "sms": (settings.AUTH_OTP_BUDGET_SMS_DAILY_USD, settings.AUTH_OTP_BUDGET_SMS_MONTHLY_USD),
        "whatsapp": (settings.AUTH_OTP_BUDGET_WHATSAPP_DAILY_USD,
                     settings.AUTH_OTP_BUDGET_WHATSAPP_MONTHLY_USD),
        "global": (settings.AUTH_OTP_BUDGET_GLOBAL_DAILY_USD,
                   settings.AUTH_OTP_BUDGET_GLOBAL_MONTHLY_USD),
    }


async def budgets(db: AsyncSession) -> dict:
    out = {k: {"daily_usd": float(d), "monthly_usd": float(m)} for k, (d, m) in _defaults().items()}
    rows = (await db.execute(select(OtpBudget))).scalars().all()
    for row in rows:
        if row.channel in out:
            if row.daily_usd is not None:
                out[row.channel]["daily_usd"] = float(row.daily_usd)
            if row.monthly_usd is not None:
                out[row.channel]["monthly_usd"] = float(row.monthly_usd)
    return out


async def set_budget(db: AsyncSession, channel: str, *, daily_usd: Optional[float],
                     monthly_usd: Optional[float], by=None) -> None:
    if channel not in CHANNELS:
        raise ValueError("unknown channel")
    row = await db.get(OtpBudget, channel)
    if row is None:
        row = OtpBudget(channel=channel)
        db.add(row)
    if daily_usd is not None:
        row.daily_usd = Decimal(str(max(daily_usd, 0)))
    if monthly_usd is not None:
        row.monthly_usd = Decimal(str(max(monthly_usd, 0)))
    row.updated_by = by
    await db.flush()


def _day_start(now: datetime) -> datetime:
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def _month_start(now: datetime) -> datetime:
    return _day_start(now).replace(day=1)


async def spent(db: AsyncSession, channel: Optional[str], since: datetime) -> float:
    q = select(func.coalesce(func.sum(OtpDelivery.cost_usd), 0)).where(
        OtpDelivery.created_at >= since)
    if channel and channel != "global":
        q = q.where(OtpDelivery.channel == channel)
    value = (await db.execute(q)).scalar()
    return float(value or 0)


async def spend_summary(db: AsyncSession, now: Optional[datetime] = None) -> dict:
    now = now or datetime.now(timezone.utc)
    b = await budgets(db)
    out = {}
    for channel in CHANNELS:
        day = await spent(db, channel, _day_start(now))
        month = await spent(db, channel, _month_start(now))
        out[channel] = {
            "spent_today_usd": round(day, 5),
            "spent_month_usd": round(month, 5),
            **b[channel],
        }
    return out


async def allowed(db: AsyncSession, channel: str, country: Optional[str],
                  now: Optional[datetime] = None) -> bool:
    now = now or datetime.now(timezone.utc)
    est = estimate(channel, country)
    b = await budgets(db)
    for scope in (channel, "global"):
        lim = b.get(scope)
        if not lim:
            continue
        if await spent(db, scope, _day_start(now)) + est > lim["daily_usd"] + 1e-9:
            return False
        if await spent(db, scope, _month_start(now)) + est > lim["monthly_usd"] + 1e-9:
            return False
    return True
