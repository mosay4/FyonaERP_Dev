"""Admin endpoints for managing exchange rates (any currency).

Only platform admins can manage these rates.
The rates set here override auto-fetched rates in CentralFXEngine.
All changes are logged to ExchangeRateHistory for audit trail.
"""
import uuid
import json
from datetime import datetime, timezone
from decimal import Decimal
from typing import Literal
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, AwareDatetime, ConfigDict
from sqlalchemy import select, delete, func
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_user_id, require_admin_perm
from ...api.responses import ok, created, no_content
from ...core.database import get_db
from ...domain.entities.finance_entities import AdminExchangeRate, ExchangeRateHistory
from ...domain.services.currency_service import CentralFXEngine

router = APIRouter(tags=["Admin - Exchange Rates"])


# ── Schemas ──

class AdminRateCreate(BaseModel):
    currency_code: str = Field(..., description="Currency code, e.g. YER_OLD, YER_NEW, SYP, EUR")
    base_currency: str = Field(default="USD", description="Base currency for rate")
    rate_type: str = Field(default="average", description="buy / sell / average")
    buy_rate: float = Field(..., gt=0)
    sell_rate: float = Field(..., gt=0)
    average_rate: float = Field(..., gt=0)


class AdminRateUpdate(BaseModel):
    buy_rate: float | None = Field(default=None, gt=0)
    sell_rate: float | None = Field(default=None, gt=0)
    average_rate: float | None = Field(default=None, gt=0)
    is_active: bool | None = None
    rate_type: str | None = None


class HistoricalRateCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)
    currency_code: str = Field(min_length=3, max_length=20, pattern=r'^[A-Za-z_]+$')
    base_currency: Literal['USD', 'SAR'] = 'USD'
    average_rate: Decimal = Field(gt=0, le=1000000, allow_inf_nan=False)
    effective_at: AwareDatetime
    evidence_reference: str = Field(min_length=5, max_length=500)
    reason: str = Field(min_length=5, max_length=1000)


@router.post('/admin/exchange-rates/history')
async def document_historical_rate(
    body: HistoricalRateCreate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm('exchange_rates', 'create')),
    db: AsyncSession = Depends(get_db),
):
    effective = body.effective_at.astimezone(timezone.utc)
    if effective > datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail='لا يجوز توثيق سعر تاريخي بتاريخ مستقبلي')
    code = body.currency_code.strip().upper()
    if code == 'YER' or (code == body.base_currency and body.average_rate != 1):
        raise HTTPException(status_code=400, detail='استخدم YER_OLD أو YER_NEW، وUSD مقابل نفسه يساوي 1 فقط')
    row = ExchangeRateHistory(
        currency_code=code, base_currency=body.base_currency, rate_type='average',
        buy_rate=float(body.average_rate), sell_rate=float(body.average_rate),
        average_rate=float(body.average_rate), effective_at=effective,
        source='admin-historical', provider='documented',
        changed_by=uuid.UUID(_user_id),
        metadata_json=json.dumps({'evidence_reference': body.evidence_reference,
                                  'reason': body.reason}),
    )
    db.add(row)
    await db.flush()
    return created({'id': str(row.id), 'effective_at': effective.isoformat(),
                    'recorded_at': row.created_at.isoformat()})


# ── Endpoints ──

@router.get("/admin/exchange-rates")
async def list_admin_rates(
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "read")),
    db: AsyncSession = Depends(get_db),
):
    """List all admin-managed exchange rates."""
    result = await db.execute(select(AdminExchangeRate).order_by(AdminExchangeRate.currency_code))
    rows = result.scalars().all()
    return ok(data=[
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
            "is_active": r.is_active,
            "changed_by": str(r.changed_by) if r.changed_by else None,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "updated_at": r.updated_at.isoformat() if r.updated_at else None,
        }
        for r in rows
    ])


@router.get("/admin/exchange-rates/history")
async def list_rate_history(
    currency_code: str | None = None,
    page: int = 1,
    per_page: int = 50,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "read")),
    db: AsyncSession = Depends(get_db),
):
    """View exchange rate change history (audit trail)."""
    q = select(ExchangeRateHistory).order_by(ExchangeRateHistory.created_at.desc())
    if currency_code:
        q = q.where(ExchangeRateHistory.currency_code == currency_code.upper())
    q = q.offset((page - 1) * per_page).limit(per_page)
    result = await db.execute(q)
    rows = result.scalars().all()

    count_q = select(func.count()).select_from(ExchangeRateHistory)
    if currency_code:
        count_q = count_q.where(ExchangeRateHistory.currency_code == currency_code.upper())
    total = (await db.execute(count_q)).scalar() or 0

    return ok(data={
        "items": [
            {
                "id": str(r.id),
                "currency_code": r.currency_code,
                "base_currency": r.base_currency,
                "rate_type": r.rate_type,
                "buy_rate": r.buy_rate,
                "sell_rate": r.sell_rate,
                "average_rate": r.average_rate,
                "source": r.source,
                "provider": r.provider,
                "changed_by": str(r.changed_by) if r.changed_by else None,
                "previous_buy_rate": r.previous_buy_rate,
                "previous_sell_rate": r.previous_sell_rate,
                "previous_average_rate": r.previous_average_rate,
                "created_at": r.created_at.isoformat() if r.created_at else None,
                "effective_at": r.effective_at.isoformat() if r.effective_at else None,
            }
            for r in rows
        ],
        "total": total,
        "page": page,
        "per_page": per_page,
    })


@router.post("/admin/exchange-rates")
async def create_admin_rate(
    body: AdminRateCreate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "create")),
    db: AsyncSession = Depends(get_db),
):
    """Set or update an admin exchange rate (upsert by currency_code)."""

    code = body.currency_code.upper()

    # Validate rates
    for name, val in [("buy_rate", body.buy_rate), ("sell_rate", body.sell_rate), ("average_rate", body.average_rate)]:
        if val <= 0:
            raise HTTPException(status_code=400, detail=f"{name} يجب أن يكون أكبر من صفر")
        if val > 1000000:
            raise HTTPException(status_code=400, detail=f"{name} يبدو مرتفعاً جداً")

    # Upsert
    existing = await db.execute(
        select(AdminExchangeRate).where(AdminExchangeRate.currency_code == code)
    )
    row = existing.scalar_one_or_none()

    # Capture previous rates for audit
    prev_buy = row.buy_rate if row else None
    prev_sell = row.sell_rate if row else None
    prev_avg = row.average_rate if row else None

    if row:
        row.buy_rate = body.buy_rate
        row.sell_rate = body.sell_rate
        row.average_rate = body.average_rate
        row.base_currency = body.base_currency.upper()
        row.rate_type = body.rate_type
        row.source = "manual"
        row.is_active = True
        row.changed_by = uuid.UUID(_user_id)
    else:
        row = AdminExchangeRate(
            id=uuid.uuid4(),
            currency_code=code,
            base_currency=body.base_currency.upper(),
            rate_type=body.rate_type,
            buy_rate=body.buy_rate,
            sell_rate=body.sell_rate,
            average_rate=body.average_rate,
            source="manual",
            is_active=True,
            changed_by=uuid.UUID(_user_id),
        )
        db.add(row)

    await db.flush()

    # Audit trail
    fx = CentralFXEngine.get_instance()
    await fx.log_rate_change(
        session=db,
        currency_code=code,
        buy_rate=body.buy_rate,
        sell_rate=body.sell_rate,
        average_rate=body.average_rate,
        source="manual",
        provider=None,
        changed_by=_user_id,
        previous_buy=prev_buy,
        previous_sell=prev_sell,
        previous_average=prev_avg,
        base_currency=body.base_currency,
    )

    # Bust the currency cache so next request picks up the new rate
    CentralFXEngine.get_instance()._cache = None

    return created(data={
        "id": str(row.id),
        "currency_code": row.currency_code,
        "base_currency": row.base_currency,
        "rate_type": row.rate_type,
        "buy_rate": row.buy_rate,
        "sell_rate": row.sell_rate,
        "average_rate": row.average_rate,
        "source": row.source,
        "is_active": row.is_active,
    })


@router.patch("/admin/exchange-rates/{rate_id}")
async def update_admin_rate(
    rate_id: str,
    body: AdminRateUpdate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "update")),
    db: AsyncSession = Depends(get_db),
):
    """Partially update an admin exchange rate."""

    result = await db.execute(
        select(AdminExchangeRate).where(AdminExchangeRate.id == rate_id)
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="سعر الصرف غير موجود")

    # Capture previous rates
    prev_buy = row.buy_rate
    prev_sell = row.sell_rate
    prev_avg = row.average_rate

    if body.buy_rate is not None:
        row.buy_rate = body.buy_rate
    if body.sell_rate is not None:
        row.sell_rate = body.sell_rate
    if body.average_rate is not None:
        row.average_rate = body.average_rate
    if body.is_active is not None:
        row.is_active = body.is_active
    if body.rate_type is not None:
        row.rate_type = body.rate_type
    row.changed_by = uuid.UUID(_user_id)

    await db.flush()

    # Audit trail
    fx = CentralFXEngine.get_instance()
    await fx.log_rate_change(
        session=db,
        currency_code=row.currency_code,
        buy_rate=row.buy_rate,
        sell_rate=row.sell_rate,
        average_rate=row.average_rate,
        source="manual",
        provider=None,
        changed_by=_user_id,
        previous_buy=prev_buy,
        previous_sell=prev_sell,
        previous_average=prev_avg,
        base_currency=row.base_currency or 'USD',
    )

    CentralFXEngine.get_instance()._cache = None

    return ok(data={
        "id": str(row.id),
        "currency_code": row.currency_code,
        "base_currency": row.base_currency,
        "rate_type": row.rate_type,
        "buy_rate": row.buy_rate,
        "sell_rate": row.sell_rate,
        "average_rate": row.average_rate,
        "source": row.source,
        "is_active": row.is_active,
    })


@router.delete("/admin/exchange-rates/{rate_id}")
async def delete_admin_rate(
    rate_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "delete")),
    db: AsyncSession = Depends(get_db),
):
    """Delete an admin exchange rate (reverts to auto-fetched)."""

    result = await db.execute(
        select(AdminExchangeRate).where(AdminExchangeRate.id == rate_id)
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="سعر الصرف غير موجود")

    # Audit trail before delete
    fx = CentralFXEngine.get_instance()
    await fx.log_rate_change(
        session=db,
        currency_code=row.currency_code,
        buy_rate=row.buy_rate,
        sell_rate=row.sell_rate,
        average_rate=row.average_rate,
        source="manual_deleted",
        provider=None,
        changed_by=_user_id,
        metadata={"action": "rate_deleted"},
    )

    await db.delete(row)
    CentralFXEngine.get_instance()._cache = None

    return no_content(message="تم حذف سعر الصرف")


@router.post("/admin/exchange-rates/refresh")
async def refresh_all_rates(
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("exchange_rates", "update")),
):
    """Force refresh global rates (open.er-api, keyless) + Yemen (2dec.net,
    store backstop, admin overrides). Needs no API key."""
    fx = CentralFXEngine.get_instance()
    data = await fx.get_all_rates(force_refresh=True)
    meta = data.get("meta") or {}
    yemen = data.get("yemen") or {}
    return ok(data={
        "global_source": meta.get("global_source"),
        "yemen_source": meta.get("yemen_source"),
        "global_currencies": len(data.get("global") or {}),
        "last_updated": yemen.get("last_updated"),
        "admin_rates_count": meta.get("admin_rates_count", 0),
    }, message="تم تحديث أسعار الصرف")
