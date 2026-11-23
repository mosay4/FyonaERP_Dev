"""Subscription invoice API endpoints.

Created when an admin approves a subscription request.
Provides read-only access for users and listing for admins.
"""
import uuid
import logging
from datetime import datetime, timezone, date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select, func, desc
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import require_permission, require_admin_perm, get_current_user_uuid
from ...api.responses import ok
from ...core.database import get_db
from ...domain.entities.subscription_invoice_entities import SubscriptionInvoice
from ...domain.entities.auth_entities import User, Organization

logger = logging.getLogger(__name__)
router = APIRouter()


# ── helpers ──────────────────────────────────────────────────────────────

async def _generate_invoice_number(db: AsyncSession) -> str:
    """Generate INV-YYYYMMDD-NNNN (unique per day, zero-padded).

    Retries up to 5 times on uniqueness conflict (concurrent approvals).
    """
    today = date.today()
    prefix = f"INV-{today.strftime('%Y%m%d')}"
    for attempt in range(5):
        result = await db.execute(
            select(func.count())
            .select_from(SubscriptionInvoice)
            .where(SubscriptionInvoice.invoice_number.like(f"{prefix}%"))
        )
        seq = (result.scalar() or 0) + 1 + attempt
        candidate = f"{prefix}-{seq:04d}"
        check = await db.execute(
            select(func.count())
            .select_from(SubscriptionInvoice)
            .where(SubscriptionInvoice.invoice_number == candidate)
        )
        if (check.scalar() or 0) == 0:
            return candidate
    # Fallback: append timestamp
    import time
    return f"{prefix}-{int(time.time()) % 10000:04d}"


async def _create_subscription_invoice(
    db: AsyncSession,
    *,
    organization_id: uuid.UUID,
    user_id: uuid.UUID,
    request_id: uuid.UUID,
    plan_name: str,
    period: str,
    amount: float,
    currency: str,
    subscription_start_date: datetime,
    subscription_end_date: datetime,
) -> SubscriptionInvoice:
    """Create a subscription invoice (idempotent per org+request)."""
    existing = (
        await db.execute(
            select(SubscriptionInvoice).where(
                SubscriptionInvoice.organization_id == organization_id,
                SubscriptionInvoice.request_id == request_id,
            )
        )
    ).scalar_one_or_none()
    if existing:
        return existing

    inv = SubscriptionInvoice(
        invoice_number=await _generate_invoice_number(db),
        organization_id=organization_id,
        user_id=user_id,
        request_id=request_id,
        plan_name=plan_name,
        period=period,
        amount=amount,
        currency=currency,
        status="paid",
        payment_method="bank_transfer",
        subscription_start_date=subscription_start_date,
        subscription_end_date=subscription_end_date,
    )
    db.add(inv)
    return inv


async def _resolve_org_name(db: AsyncSession, org_id) -> Optional[str]:
    """Fetch organization name for display in invoice."""
    if org_id is None:
        return None
    try:
        org_uuid = uuid.UUID(str(org_id))
    except (ValueError, TypeError):
        return None
    result = await db.execute(select(Organization).where(Organization.id == org_uuid))
    org = result.scalar_one_or_none()
    if not org:
        return None
    return getattr(org, 'name', None) or getattr(org, 'company_name', None)


async def _resolve_user_email(db: AsyncSession, user_id) -> Optional[str]:
    """Fetch user email for invoice contact."""
    if user_id is None:
        return None
    try:
        uid = uuid.UUID(str(user_id))
    except (ValueError, TypeError):
        return None
    result = await db.execute(select(User).where(User.id == uid))
    user = result.scalar_one_or_none()
    if not user:
        return None
    return getattr(user, 'email', None)


async def _batch_resolve_org_names(db: AsyncSession, org_ids: list) -> dict:
    """Batch fetch organization names. Returns {org_id_str: name}."""
    unique_ids = set()
    for oid in org_ids:
        if oid is None:
            continue
        try:
            unique_ids.add(uuid.UUID(str(oid)))
        except (ValueError, TypeError):
            continue
    if not unique_ids:
        return {}
    result = await db.execute(select(Organization).where(Organization.id.in_(unique_ids)))
    return {str(org.id): getattr(org, 'name', None) or getattr(org, 'company_name', None) for org in result.scalars().all()}


async def _batch_resolve_user_emails(db: AsyncSession, user_ids: list) -> dict:
    """Batch fetch user emails. Returns {user_id_str: email}."""
    unique_ids = set()
    for uid in user_ids:
        if uid is None:
            continue
        try:
            unique_ids.add(uuid.UUID(str(uid)))
        except (ValueError, TypeError):
            continue
    if not unique_ids:
        return {}
    result = await db.execute(select(User).where(User.id.in_(unique_ids)))
    return {str(user.id): getattr(user, 'email', None) for user in result.scalars().all()}


# ── user-facing: get own invoice ─────────────────────────────────────────

@router.get("/subscription-invoices/{invoice_id}")
async def get_subscription_invoice(
    invoice_id: str,
    current_user: User = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        inv_uuid = uuid.UUID(invoice_id)
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="معرف الفاتورة غير صالح")

    result = await db.execute(
        select(SubscriptionInvoice).where(SubscriptionInvoice.id == inv_uuid)
    )
    inv = result.scalar_one_or_none()
    if not inv:
        raise HTTPException(status_code=404, detail="الفاتورة غير موجودة")

    # Authorization: only the owner or an admin may view
    if inv.user_id != current_user:
        from ...domain.entities.auth_entities import AdminPermission
        perm_check = await db.execute(
            select(AdminPermission).where(
                AdminPermission.user_id == current_user,
            )
        )
        if not perm_check.scalar_one_or_none():
            raise HTTPException(status_code=403, detail="غير مصرح لك بعرض هذه الفاتورة")

    org_name = await _resolve_org_name(db, inv.organization_id)
    user_email = await _resolve_user_email(db, inv.user_id)
    return ok(_invoice_dict(inv, organization_name=org_name, user_email=user_email))


# ── user-facing: list own invoices ───────────────────────────────────────

@router.get("/subscription-invoices")
async def list_subscription_invoices(
    current_user: User = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(SubscriptionInvoice)
        .where(SubscriptionInvoice.user_id == current_user)
        .order_by(desc(SubscriptionInvoice.created_at))
    )
    invoices = result.scalars().all()
    org_ids = [i.organization_id for i in invoices]
    user_ids = [i.user_id for i in invoices if i.user_id]
    org_names = await _batch_resolve_org_names(db, org_ids)
    user_emails = await _batch_resolve_user_emails(db, user_ids)
    return ok([_invoice_dict(i, organization_name=org_names.get(str(i.organization_id)), user_email=user_emails.get(str(i.user_id))) for i in invoices])


# ── admin: list all invoices ─────────────────────────────────────────────

@router.get("/admin/subscription-invoices")
async def admin_list_subscription_invoices(
    plan_name: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    payment_method: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "read")),
):
    q = select(SubscriptionInvoice).order_by(desc(SubscriptionInvoice.created_at))
    if plan_name:
        q = q.where(SubscriptionInvoice.plan_name == plan_name)
    if status:
        q = q.where(SubscriptionInvoice.status == status)
    if payment_method:
        q = q.where(SubscriptionInvoice.payment_method == payment_method)
    result = await db.execute(q)
    invoices = result.scalars().all()
    org_ids = [i.organization_id for i in invoices]
    user_ids = [i.user_id for i in invoices if i.user_id]
    org_names = await _batch_resolve_org_names(db, org_ids)
    user_emails = await _batch_resolve_user_emails(db, user_ids)
    return ok([_invoice_dict(i, organization_name=org_names.get(str(i.organization_id)), user_email=user_emails.get(str(i.user_id))) for i in invoices])


# ── serializer ───────────────────────────────────────────────────────────

def _invoice_dict(inv: SubscriptionInvoice, *, organization_name: Optional[str] = None, user_email: Optional[str] = None) -> dict:
    return {
        "id": str(inv.id),
        "invoice_number": inv.invoice_number,
        "organization_id": str(inv.organization_id),
        "organization_name": organization_name,
        "user_email": user_email,
        "user_id": str(inv.user_id) if inv.user_id else None,
        "request_id": str(inv.request_id) if inv.request_id else None,
        "plan_name": inv.plan_name,
        "period": inv.period,
        "amount": float(inv.amount) if inv.amount else 0,
        "currency": inv.currency,
        "status": inv.status,
        "payment_method": inv.payment_method,
        "bank_name": inv.bank_name,
        "card_brand": inv.card_brand,
        "provider_payment_id": inv.provider_payment_id,
        "subscription_start_date": inv.subscription_start_date.isoformat() if inv.subscription_start_date else None,
        "subscription_end_date": inv.subscription_end_date.isoformat() if inv.subscription_end_date else None,
        "created_at": inv.created_at.isoformat() if inv.created_at else None,
    }
