"""Admin endpoints for platform management.

Covers: plans, subscription requests, API keys, notifications, trash, export, files, orgs.
"""
import logging
import uuid

logger = logging.getLogger(__name__)
import json
import csv
import io
import os
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status, Query, UploadFile, File, Form
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import select, func, or_, desc
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import require_admin_perm, get_current_user_uuid
from uuid import UUID
from ...api.responses import ok, created, no_content
from ...core.database import get_db
from ...core.config import settings
from ...core.paths import UPLOAD_ROOT
from ...domain.entities.auth_entities import User, Organization, Role, AdminPermission
from ...domain.entities.admin_entities import (
    Plan,
    SubscriptionRequest,
    PlatformBankAccount,
    SubscriptionRevenue,
    AdminOperation,
    PlatformNotification,
    TrashItem,
    dumps_features,
    loads_features,
)
from ...domain.entities.notification_entities import AppNotification
from ...domain.entities.subscription_invoice_entities import SubscriptionInvoice
from .subscription_invoices import _generate_invoice_number as _gen_sub_inv_number
from ...domain.entities.payment_entities import StripeSubscription
from ...domain.services.admin_permissions import (
    ADMIN_PERMISSIONS,
    ADMIN_ACTIONS,
    admin_permission_codes,
    all_admin_permission_codes,
    permission_codes_to_rows,
    is_valid_admin_permission,
)
from ...infrastructure.repositories.sql_alchemy_auth_repository import (
    SQLAlchemyRoleRepository,
)
from ...domain.services.admin_settings_service import AdminSettingsService
from ...domain.services.banner_images import (
    banner_image_extension,
    banner_image_path,
    banner_with_image_status,
)

router = APIRouter(tags=["Admin - Platform Management"])

def _settings_svc(db: AsyncSession) -> AdminSettingsService:
    return AdminSettingsService(db)


# ── Helpers ──

# ════════════════════════════════════════════════════════════
#  PLANS MANAGEMENT
# ════════════════════════════════════════════════════════════

class PlanCreate(BaseModel):
    name: str
    name_en: Optional[str] = None
    description: Optional[str] = None
    package_type: Optional[str] = None
    duration_days: Optional[int] = None
    price_monthly: float = 0
    price_yearly: float = 0
    currency: str = "SAR"
    features: list[str] = []
    color: Optional[str] = None
    icon: Optional[str] = None
    is_active: bool = True
    max_users: Optional[int] = None
    max_storage_gb: Optional[int] = None
    stripe_product_id: Optional[str] = None
    stripe_price_id_monthly: Optional[str] = None
    stripe_price_id_yearly: Optional[str] = None

class PlanUpdate(BaseModel):
    name: Optional[str] = None
    name_en: Optional[str] = None
    description: Optional[str] = None
    package_type: Optional[str] = None
    duration_days: Optional[int] = None
    price_monthly: Optional[float] = None
    price_yearly: Optional[float] = None
    currency: Optional[str] = None
    features: Optional[list[str]] = None
    color: Optional[str] = None
    icon: Optional[str] = None
    is_active: Optional[bool] = None
    max_users: Optional[int] = None
    max_storage_gb: Optional[int] = None
    stripe_product_id: Optional[str] = None
    stripe_price_id_monthly: Optional[str] = None
    stripe_price_id_yearly: Optional[str] = None

# Default plans seeded on first access (DB-backed `plans` table)
_DEFAULT_PLANS = [
    {
        "name": "باقة مجانية",
        "name_en": "Free Plan",
        "description": "تجربة مجانية محدودة",
        "package_type": "free",
        "duration_days": 365,
        "price_monthly": 0,
        "price_yearly": 0,
        "currency": "SAR",
        "features": ["empowerment_basic"],
        "color": "#757575",
        "icon": "card_giftcard",
        "is_active": True,
        "max_users": 1,
        "max_storage_gb": 1,
    },
    {
        "name": "باقة شخصية",
        "name_en": "Personal Plan",
        "description": "لإدارة أموالك الشخصية",
        "package_type": "personal",
        "duration_days": 365,
        "price_monthly": 0,
        "price_yearly": 13,
        "currency": "USD",
        "features": ["المحفظة الشخصية", "تسجيل المصاريف", "الأهداف الادخارية", "التقارير المالية"],
        "color": "#1565C0",
        "icon": "person",
        "is_active": True,
        "max_users": 1,
        "max_storage_gb": 5,
    },
    {
        "name": "باقة أعمال",
        "name_en": "Business Plan",
        "description": "لإدارة أعمالك",
        "package_type": "business",
        "duration_days": 365,
        "price_monthly": 0,
        "price_yearly": 15,
        "currency": "USD",
        "features": ["إدارة العملاء والموردين", "الفواتير", "حسابات البنوك", "المصروفات"],
        "color": "#A01530",
        "icon": "business",
        "is_active": True,
        "max_users": 10,
        "max_storage_gb": 50,
    },
    {
        "name": "باقة أعمال + شخصي",
        "name_en": "Business + Personal Plan",
        "description": "تجمع الباقة الشخصية وباقة الأعمال",
        "package_type": "premium",
        "duration_days": 365,
        "price_monthly": 0,
        "price_yearly": 18.3,
        "currency": "USD",
        "features": ["جميع مزايا شخصي وأعمال", "التحليلات المتقدمة", "لوحة موحدة", "أولوية الدعم الفني"],
        "color": "#FFD700",
        "icon": "crown",
        "is_active": True,
        "max_users": 50,
        "max_storage_gb": 200,
    },
]


async def _ensure_plans_seeded(db: AsyncSession):
    existing = (await db.execute(select(func.count(Plan.id)))).scalar() or 0
    if existing:
        # Incremental: add any missing default plans by name
        existing_names = set(
            (await db.execute(select(Plan.name))).scalars().all()
        )
        added = False
        for data in _DEFAULT_PLANS:
            if data["name"] not in existing_names:
                row = dict(data)
                row["features"] = dumps_features(row.get("features"))
                db.add(Plan(**row))
                added = True
        if added:
            await db.commit()
        return
    for data in _DEFAULT_PLANS:
        row = dict(data)
        row["features"] = dumps_features(row.get("features"))
        db.add(Plan(**row))
    await db.commit()


def _validate_package_type(value: Optional[str]) -> None:
    if value is None:
        return
    if value.strip().lower() not in {"free", "personal", "business", "premium"}:
        raise HTTPException(
            status_code=400,
            detail="نوع الباقة يجب أن يكون أحد: free / personal / business / premium",
        )


def _plan_to_dict(p: Plan, subscribers_count: int = 0) -> dict:
    return {
        "id": str(p.id),
        "name": p.name,
        "name_en": p.name_en,
        "description": p.description,
        "package_type": (p.package_type or _plan_package_type(p) or "personal"),
        "duration_days": p.duration_days or 365,
        "price_monthly": p.price_monthly or 0,
        "price_yearly": p.price_yearly or 0,
        "currency": p.currency or "SAR",
        "features": loads_features(p.features),
        "color": p.color,
        "icon": p.icon,
        "is_active": p.is_active,
        "max_users": p.max_users,
        "max_storage_gb": p.max_storage_gb,
        "stripe_product_id": p.stripe_product_id,
        "stripe_price_id_monthly": p.stripe_price_id_monthly,
        "stripe_price_id_yearly": p.stripe_price_id_yearly,
        "subscribers_count": subscribers_count,
        "created_at": p.created_at.isoformat() if p.created_at else None,
        "updated_at": p.updated_at.isoformat() if p.updated_at else None,
    }


async def _plan_subscribers_map(db: AsyncSession) -> dict:
    """Map plan name_en -> subscribers count from organizations table."""
    rows = (
        await db.execute(
            select(Organization.subscription_plan, func.count(Organization.id))
            .group_by(Organization.subscription_plan)
        )
    ).all()
    raw = {r[0]: r[1] for r in rows if r[0]}

    # Fetch all plans to build name_en -> plan name mapping
    plan_rows = (await db.execute(select(Plan.name, Plan.name_en))).all()
    # name_en to subscription_plan value mapping
    _en_to_sub = {
        "Free Plan": "free",
        "Personal Plan": "personal",
        "Business Plan": "business",
        "Business + Personal Plan": "premium",
    }
    result = {}
    for name, name_en in plan_rows:
        sub_key = _en_to_sub.get(name_en, name_en)
        result[name] = raw.get(sub_key, 0)
    return result


async def _get_plan_by_id(db: AsyncSession, plan_id: str):
    try:
        result = await db.execute(select(Plan).where(Plan.id == uuid.UUID(plan_id)))
        return result.scalar_one_or_none()
    except (ValueError, TypeError):
        return None


@router.get("/admin/plans")
async def list_plans(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("plans", "read"))):
    await _ensure_plans_seeded(db)
    result = await db.execute(select(Plan).order_by(Plan.created_at.asc()))
    plans = result.scalars().all()
    subs = await _plan_subscribers_map(db)
    return ok({
        "plans": [_plan_to_dict(p, subs.get(p.name, 0)) for p in plans],
        "total": len(plans),
    })


@router.post("/admin/plans", status_code=201)
async def create_plan(body: PlanCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("plans", "create"))):
    _validate_package_type(body.package_type)
    if body.price_monthly is not None and body.price_monthly < 0:
        raise HTTPException(status_code=400, detail="السعر الشهري يجب أن يكون صفراً أو أكبر")
    if body.price_yearly is not None and body.price_yearly < 0:
        raise HTTPException(status_code=400, detail="السعر السنوي يجب أن يكون صفراً أو أكبر")
    plan = Plan(
        name=body.name,
        name_en=body.name_en,
        description=body.description,
        package_type=(body.package_type or "").strip().lower() or None,
        duration_days=body.duration_days or 365,
        price_monthly=body.price_monthly,
        price_yearly=body.price_yearly,
        currency=body.currency,
        features=dumps_features(body.features),
        color=body.color or "#A01530",
        icon=body.icon or "star",
        is_active=body.is_active,
        max_users=body.max_users,
        max_storage_gb=body.max_storage_gb,
    )
    db.add(plan)
    await db.commit()
    await db.refresh(plan)
    return created(_plan_to_dict(plan))


@router.put("/admin/plans/{plan_id}")
async def update_plan(plan_id: str, body: PlanUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("plans", "update"))):
    plan = await _get_plan_by_id(db, plan_id)
    if not plan:
        raise HTTPException(status_code=404, detail="الباقة غير موجودة")
    _validate_package_type(body.package_type)
    patch = body.model_dump(exclude_none=True)
    if patch.get("price_monthly") is not None and patch["price_monthly"] < 0:
        raise HTTPException(status_code=400, detail="السعر الشهري يجب أن يكون صفراً أو أكبر")
    if patch.get("price_yearly") is not None and patch["price_yearly"] < 0:
        raise HTTPException(status_code=400, detail="السعر السنوي يجب أن يكون صفراً أو أكبر")
    for k, v in patch.items():
        if k == "features":
            v = dumps_features(v)
        if k == "package_type" and isinstance(v, str):
            v = v.strip().lower()
        setattr(plan, k, v)
    plan.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(plan)
    return ok(_plan_to_dict(plan))


@router.delete("/admin/plans/{plan_id}")
async def delete_plan(plan_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("plans", "delete"))):
    plan = await _get_plan_by_id(db, plan_id)
    if not plan:
        raise HTTPException(status_code=404, detail="الباقة غير موجودة")
    # Guard history: block deleting a plan that still has subscribers or requests.
    ptype = _plan_package_type(plan)
    if ptype and ptype != "free":
        used = (
            await db.execute(
                select(func.count(Organization.id)).where(Organization.subscription_plan == ptype)
            )
        ).scalar() or 0
        if used:
            raise HTTPException(status_code=400, detail="لا يمكن حذف باقة عليها اشتراكات فعالة")
    used_req = (
        await db.execute(
            select(func.count(SubscriptionRequest.id)).where(SubscriptionRequest.plan_id == str(plan.id))
        )
    ).scalar() or 0
    if used_req:
        raise HTTPException(status_code=400, detail="لا يمكن حذف باقة مرتبطة بطلبات اشتراك")
    await db.delete(plan)
    await db.commit()
    return no_content()


# ════════════════════════════════════════════════════════════
#  SUBSCRIPTION REQUESTS
# ════════════════════════════════════════════════════════════

def _sub_request_dict(r: SubscriptionRequest, amount: float = 0.0, currency: str = "SAR", user: Optional[User] = None, org_name: Optional[str] = None) -> dict:
    proof_url = f"/uploads/{r.proof_image}" if r.proof_image else None
    proof_paths: list = []
    if r.proof_images:
        try:
            proof_paths = json.loads(r.proof_images)
        except Exception:
            proof_paths = []
    proof_images = [f"/uploads/{p}" for p in proof_paths if p]
    status = (r.status or "pending").lower()
    status_label, status_color = {
        "approved": ("معتمدة", "green"),
        "cancelled": ("تم الإلغاء", "red"),
        "rejected": ("مرفوض", "red"),
        "pending": ("قيد المراجعة", "amber"),
    }.get(status, (status, "grey"))
    return {
        "id": str(r.id),
        "user_id": str(r.user_id) if r.user_id else None,
        "organization_id": str(r.organization_id) if r.organization_id else None,
        "plan_id": r.plan_id,
        "plan_name": r.plan_name,
        "status": status,
        "status_label": status_label,
        "status_color": status_color,
        "message": r.message,
        "proof_image": r.proof_image,
        "proof_image_url": proof_url,
        "proof_images": proof_images,
        "period": r.period,
        "amount": amount,
        "currency": r.currency or currency,
        "user_name": _user_display_name(user),
        "user_email": user.email if user is not None else None,
        "user_phone": user.phone if user is not None else None,
        "org_name": org_name,
        "rejection_reason": r.rejection_reason,
        "created_at": r.created_at.isoformat() if r.created_at else None,
        "reviewed_at": r.reviewed_at.isoformat() if r.reviewed_at else None,
        "reviewed_by": str(r.reviewed_by) if r.reviewed_by else None,
    }


async def _users_and_orgs_maps(db: AsyncSession, requests: list[SubscriptionRequest]) -> tuple[dict, dict]:
    """Batch-load requester users and organizations for a set of requests."""
    user_ids = {r.user_id for r in requests if r.user_id}
    org_ids = {r.organization_id for r in requests if r.organization_id}
    users_map: dict = {}
    orgs_map: dict = {}
    if user_ids:
        rows = await db.execute(select(User).where(User.id.in_(user_ids)))
        users_map = {u.id: u for u in rows.scalars().all()}
    if org_ids:
        rows = await db.execute(select(Organization).where(Organization.id.in_(org_ids)))
        orgs_map = {o.id: o for o in rows.scalars().all()}
    return users_map, orgs_map


def _user_display_name(u: Optional[User]) -> Optional[str]:
    if u is None:
        return None
    for attr in ("full_name", "name", "username"):
        v = getattr(u, attr, None)
        if v:
            return str(v)
    return u.email


async def _get_subscription_request(db: AsyncSession, req_id: str):
    try:
        result = await db.execute(
            select(SubscriptionRequest).where(SubscriptionRequest.id == uuid.UUID(req_id))
        )
        return result.scalar_one_or_none()
    except (ValueError, TypeError):
        return None


@router.get("/admin/subscription-requests")
async def list_subscription_requests(
    status_filter: Optional[str] = Query(None, alias="status"),
    from_date: Optional[str] = Query(None, alias="from"),
    to_date: Optional[str] = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "read")),
):
    # Default view is pending review: an absent status param means "pending".
    # Explicit "all" (or empty) returns every status.
    if status_filter is None:
        status_filter = "pending"
    query = select(SubscriptionRequest).order_by(SubscriptionRequest.created_at.desc())
    if status_filter and status_filter != "all":
        query = query.where(SubscriptionRequest.status == status_filter)
    if from_date:
        try:
            fd = datetime.fromisoformat(from_date)
            query = query.where(SubscriptionRequest.created_at >= fd)
        except ValueError:
            raise HTTPException(status_code=400, detail="from غير صالح")
    if to_date:
        try:
            td = datetime.fromisoformat(to_date)
            query = query.where(SubscriptionRequest.created_at <= td)
        except ValueError:
            raise HTTPException(status_code=400, detail="to غير صالح")
    result = await db.execute(query)
    requests = list(result.scalars().all())
    users_map, orgs_map = await _users_and_orgs_maps(db, requests)
    out = []
    for r in requests:
        amount, cur = await _plan_amount_for(db, r)
        out.append(_sub_request_dict(
            r,
            amount=amount,
            currency=r.currency or cur,
            user=users_map.get(r.user_id),
            org_name=(orgs_map[r.organization_id].name if r.organization_id in orgs_map else None),
        ))
    return ok({
        "requests": out,
        "total": len(requests),
    })


@router.get("/admin/subscription-requests/report")
async def subscription_requests_report(
    from_date: Optional[str] = Query(None, alias="from"),
    to_date: Optional[str] = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "read")),
):
    query = select(SubscriptionRequest)
    try:
        if from_date:
            query = query.where(SubscriptionRequest.created_at >= datetime.fromisoformat(from_date))
        if to_date:
            query = query.where(SubscriptionRequest.created_at <= datetime.fromisoformat(to_date))
    except ValueError:
        raise HTTPException(status_code=400, detail="تواريخ غير صالحة")
    rows = (await db.execute(query)).scalars().all()

    by_status: dict = {}
    amounts: dict = {}
    for r in rows:
        by_status[r.status] = by_status.get(r.status, 0) + 1
        amount, currency = await _plan_amount_for(db, r)
        key = currency or "SAR"
        amounts[key] = amounts.get(key, 0) + float(amount or 0)

    return ok({
        "total": len(rows),
        "by_status": by_status,
        "amounts_by_currency": amounts,
    })


@router.get("/admin/subscriptions/payment-report")
async def subscription_payment_report(
    from_date: Optional[str] = Query(None, alias="from"),
    to_date: Optional[str] = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "read")),
):
    """Paid-subscription report split by channel (local receipt vs card).

    - Local: invoices with payment_method == "bank_transfer" (manual approval).
    - International: invoices with payment_method == "stripe" (card payments).
    - Amounts are grouped per currency; different currencies are never summed.
    """
    stmt = select(SubscriptionInvoice).where(SubscriptionInvoice.status == "paid")
    try:
        if from_date:
            stmt = stmt.where(SubscriptionInvoice.created_at >= datetime.fromisoformat(from_date))
        if to_date:
            stmt = stmt.where(SubscriptionInvoice.created_at <= datetime.fromisoformat(to_date))
    except ValueError:
        raise HTTPException(status_code=400, detail="تواريخ غير صالحة")
    invoices = (await db.execute(stmt.order_by(SubscriptionInvoice.created_at.desc()))).scalars().all()

    local_count = 0
    intl_count = 0
    intl_by_currency: dict = {}
    plan_distribution: dict = {}
    for inv in invoices:
        plan = (inv.plan_name or "unknown").lower()
        plan_distribution[plan] = plan_distribution.get(plan, 0) + 1
        if (inv.payment_method or "") == "stripe":
            intl_count += 1
            cur = (inv.currency or "SAR").upper()
            slot = intl_by_currency.setdefault(cur, {"currency": cur, "amount": 0.0, "count": 0})
            slot["amount"] = round(slot["amount"] + float(inv.amount or 0), 2)
            slot["count"] += 1
        else:
            local_count += 1

    recent = []
    user_ids = {i.user_id for i in invoices[:30] if i.user_id}
    org_ids = {i.organization_id for i in invoices[:30] if i.organization_id}
    user_names: dict = {}
    org_names: dict = {}
    if user_ids:
        for u in (await db.execute(select(User).where(User.id.in_(user_ids)))).scalars().all():
            user_names[u.id] = u.full_name or u.email
    if org_ids:
        for o in (await db.execute(select(Organization).where(Organization.id.in_(org_ids)))).scalars().all():
            org_names[o.id] = o.name
    for inv in invoices[:30]:
        recent.append({
            "invoice_number": inv.invoice_number,
            "channel": "international" if (inv.payment_method or "") == "stripe" else "local",
            "payment_method": inv.payment_method,
            "plan_name": inv.plan_name,
            "period": inv.period,
            "amount": float(inv.amount or 0),
            "currency": (inv.currency or "SAR").upper(),
            "card_brand": inv.card_brand,
            "user_name": user_names.get(inv.user_id),
            "org_name": org_names.get(inv.organization_id),
            "created_at": inv.created_at.isoformat() if inv.created_at else None,
        })

    return ok({
        "local_paid_count": local_count,
        "international_paid_count": intl_count,
        "international_by_currency": sorted(intl_by_currency.values(), key=lambda x: x["currency"]),
        "plan_distribution": [{"plan": k, "count": v} for k, v in sorted(plan_distribution.items())],
        "recent_payments": recent,
        "total": len(invoices),
    })


@router.get("/admin/subscription-requests/{req_id}")
async def get_subscription_request_detail(
    req_id: str,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "read")),
):
    req = await _get_subscription_request(db, req_id)
    if not req:
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    amount, currency = await _plan_amount_for(db, req)
    users_map, orgs_map = await _users_and_orgs_maps(db, [req])
    return ok(_sub_request_dict(
        req,
        amount=amount,
        currency=currency,
        user=users_map.get(req.user_id),
        org_name=(orgs_map[req.organization_id].name if req.organization_id in orgs_map else None),
    ))


async def _apply_plan_to_org(db: AsyncSession, org, plan_id, plan_name, user_id, period: str = "yearly") -> tuple:
    """Activate a subscription plan on an ALREADY-LOCKED organization row.

    Flush-only (no commit): the caller owns the transaction and commits once
    everything (revenue + invoice + notification) is staged.

    Single-active-subscription rule:
    - Same paid plan still active in the future → EXTEND from the current
      end date (renewal stacking, no lost days).
    - Anything else (trial / expired / different plan) → fresh period
      starting now; any trial state is terminated.
    Returns (start, end).
    """
    now = datetime.now(timezone.utc)
    days = 30 if period == "monthly" else 365
    from app.domain.services.section_entitlements import activate
    start, end = activate(org, plan_name or "personal", days=days, now=now)
    await db.flush()
    try:
        sub_plan_id = uuid.UUID(str(plan_id)) if plan_id else None
    except (ValueError, TypeError):
        sub_plan_id = None
    try:
        sub_user_id = uuid.UUID(str(user_id)) if user_id else None
    except (ValueError, TypeError):
        sub_user_id = None
    existing_sub = (
        await db.execute(
            select(StripeSubscription).where(
                StripeSubscription.organization_id == org.id,
                StripeSubscription.status == "active",
                StripeSubscription.plan_name == plan_name,
            )
        )
    ).scalars().first()
    if existing_sub:
        existing_sub.plan_name = plan_name or existing_sub.plan_name
        existing_sub.plan_id = sub_plan_id or existing_sub.plan_id
        existing_sub.current_period_start = start
        existing_sub.current_period_end = end
    else:
        sub = StripeSubscription(
            user_id=sub_user_id,
            organization_id=org.id,
            plan_id=sub_plan_id,
            plan_name=plan_name,
            status="active",
            current_period_start=start,
            current_period_end=end,
        )
        db.add(sub)
    await db.flush()
    return start, end


def _bank_accepted_currencies(bank: PlatformBankAccount) -> list:
    """All currencies a platform bank can receive, uppercased."""
    return [c["currency"] for c in _bank_currency_list(bank)]


async def _notify_user(db: AsyncSession, org_id, user_id, type_: str, title: str, message: str, payload: str = "notifications"):
    """Create an in-app notification for a user/org.

    Returns the notification id so callers can dispatch the email copy in the
    background AFTER commit (keeps the response fast).
    """
    notif = AppNotification(
        organization_id=org_id,
        user_id=user_id,
        type=type_,
        title=title,
        message=message,
        action="open_screen",
        action_payload=payload,
    )
    db.add(notif)
    await db.flush()
    return notif.id


def _dispatch_email_async(notification_id):
    """Fire-and-forget email copy dispatch (never blocks the request)."""
    try:
        import asyncio
        from app.core.database import async_session_factory
        from app.domain.entities.notification_entities import AppNotification as _AN
        from app.domain.services.email_notifications import dispatch_notification_email as _dne

        async def _bg():
            try:
                async with async_session_factory() as s:
                    n = (await s.execute(select(_AN).where(_AN.id == notification_id))).scalar_one_or_none()
                    if n:
                        try:
                            await _dne(s, n)
                        except Exception:  # noqa: BLE001
                            pass
            except Exception:  # noqa: BLE001
                pass

        asyncio.create_task(_bg())
    except Exception:  # noqa: BLE001
        pass


class ApproveSubscriptionBody(BaseModel):
    bank_account_id: Optional[str] = None
    currency: Optional[str] = None
    # Actually-paid amount entered by the admin; overrides the plan price.
    amount: Optional[float] = None
    # Final package chosen by the admin at approval time. Must be an active
    # paid plan (personal | business | premium). Defaults to the request plan.
    plan_id: Optional[str] = None


# Canonical paid package types that can be activated.
_PAID_PACKAGE_TYPES = {"personal", "business", "premium"}

_PLAN_AR = {
    "personal": "الباقة الشخصية",
    "business": "باقة الأعمال",
    "premium": "باقة الأعمال + الشخصية",
    "trial": "التجربة المجانية",
    "free": "الباقة المجانية",
}


def _plan_package_type(plan) -> Optional[str]:
    """Canonical package type for a Plan row (single source of truth)."""
    pt = (getattr(plan, "package_type", None) or "").strip().lower() or None
    if pt:
        return pt
    for cand in (getattr(plan, "name_en", None) or "", getattr(plan, "name", None) or ""):
        low = cand.lower()
        if "free" in low or "مجان" in cand:
            return "free"
        if "personal" in low and "business" in low:
            return "premium"
        if "business" in low or "أعمال" in cand:
            return "business"
        if "personal" in low or "شخص" in cand:
            return "personal"
    return None


async def _plan_amount_for(db: AsyncSession, req: SubscriptionRequest) -> tuple:
    """Return (amount, currency) for a subscription request based on its plan."""
    amount = 0.0
    currency = "SAR"
    plan = await _get_plan_by_id(db, req.plan_id) if req.plan_id else None
    if plan is None and str(req.plan_id or "") in {"1", "2", "3"}:
        # Legacy numeric ids (1=personal, 2=business, 3=premium) map to the
        # seeded plans by creation order.
        result = await db.execute(select(Plan).order_by(Plan.created_at.asc()))
        plans = list(result.scalars().all())
        idx = int(req.plan_id) - 1
        if 0 <= idx < len(plans):
            plan = plans[idx]
    if plan is not None:
        if plan.currency:
            currency = plan.currency
        yearly = float(plan.price_yearly or 0)
        monthly = float(plan.price_monthly or 0)
        if req.period == "yearly":
            amount = yearly if yearly > 0 else monthly
        else:
            amount = monthly if monthly > 0 else yearly
    return amount, currency


@router.put("/admin/subscription-requests/{req_id}/approve")
async def approve_subscription_request(
    req_id: str,
    body: ApproveSubscriptionBody = ApproveSubscriptionBody(),
    admin_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "update")),
):
    # Lock the request row so two admins (or a double-click) cannot approve
    # the same request concurrently.
    try:
        req_uuid = uuid.UUID(str(req_id))
    except (ValueError, TypeError):
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    locked = (
        await db.execute(
            select(SubscriptionRequest)
            .where(SubscriptionRequest.id == req_uuid)
            .with_for_update()
        )
    ).scalar_one_or_none()
    req = locked
    if not req:
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    if req.status == "approved":
        return ok({"status": "approved", "message": "الطلب مقبول مسبقاً"})
    if req.status != "pending":
        raise HTTPException(status_code=400, detail="يمكن قبول الطلبات قيد المراجعة فقط")

    # ── 1. Final package (admin picks; defaults to the request plan) ──
    final_plan = None
    if body.plan_id:
        final_plan = await _get_plan_by_id(db, body.plan_id)
        if not final_plan or not final_plan.is_active:
            raise HTTPException(status_code=400, detail="الباقة المختارة غير موجودة أو غير فعالة")
    else:
        final_plan = await _get_plan_by_id(db, req.plan_id) if req.plan_id else None
        if final_plan is None and str(req.plan_id or "") in {"1", "2", "3"}:
            _ordered = (await db.execute(select(Plan).order_by(Plan.created_at.asc()))).scalars().all()
            _idx = int(req.plan_id) - 1
            if 0 <= _idx < len(_ordered):
                final_plan = _ordered[_idx]
    if final_plan is None:
        raise HTTPException(status_code=400, detail="تعذر تحديد باقة الطلب")
    package_type = _plan_package_type(final_plan)
    if package_type not in _PAID_PACKAGE_TYPES:
        raise HTTPException(status_code=400, detail="يجب اختيار باقة مدفوعة (شخصية / أعمال / أعمال + شخصية)")
    plan_key = package_type
    plan_label = _PLAN_AR.get(plan_key, final_plan.name or plan_key)

    # ── 2. Bank (must exist and be active) ──
    bank_account_id = body.bank_account_id or None
    if not bank_account_id:
        raise HTTPException(status_code=400, detail="يجب اختيار الحساب البنكي للمنصة قبل قبول الطلب")
    try:
        bank_uuid = uuid.UUID(str(bank_account_id))
    except (ValueError, TypeError):
        bank_uuid = None
    bank = None
    if bank_uuid is not None:
        bank_result = await db.execute(select(PlatformBankAccount).where(PlatformBankAccount.id == bank_uuid))
        bank = bank_result.scalar_one_or_none()
    if bank is None:
        raise HTTPException(status_code=400, detail="الحساب البنكي غير موجود")
    if bank.is_active is False:
        raise HTTPException(status_code=400, detail="الحساب البنكي غير فعال")

    # ── 3. Amount (required, must be positive) ──
    if body.amount is None:
        raise HTTPException(status_code=400, detail="يجب إدخال المبلغ المدفوع قبل الاعتماد")
    try:
        amount = float(body.amount)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="المبلغ غير صالح")
    if amount <= 0:
        raise HTTPException(status_code=400, detail="المبلغ يجب أن يكون أكبر من صفر")

    # ── 4. Currency (must be accepted by the chosen bank) ──
    currency = (body.currency or req.currency or bank.currency or "SAR").upper()
    accepted = {c.upper() for c in _bank_accepted_currencies(bank)}
    if currency not in accepted:
        raise HTTPException(
            status_code=400,
            detail=f"عملة {currency} غير مدعومة في بنك {bank.bank_name} — العملات المتاحة: {', '.join(sorted(accepted))}",
        )

    # ── 5. Everything staged in ONE transaction ──
    period = req.period or "yearly"
    start_disp = ""
    end_disp = ""
    try:
        org = await _org_for_request(db, req)
        start, end = await _apply_plan_to_org(
            db,
            org,
            str(final_plan.id),
            plan_key,
            req.user_id,
            period,
        )
        start_disp = str(start)[:10] if start else ""
        end_disp = str(end)[:10] if end else ""

        # Revenue: one row per request (unique index guards races).
        existing_rev = (
            await db.execute(
                select(SubscriptionRevenue).where(SubscriptionRevenue.request_id == req.id)
            )
        ).scalar_one_or_none()
        if existing_rev is None:
            db.add(SubscriptionRevenue(
                request_id=req.id,
                organization_id=req.organization_id,
                user_id=req.user_id,
                bank_account_id=bank.id,
                plan_name=plan_key,
                period=period,
                amount=amount,
                currency=currency,
                note=f"إيراد اشتراك — {plan_label}",
            ))

        req.status = "approved"
        req.plan_id = str(final_plan.id)
        req.plan_name = plan_key
        req.reviewed_at = datetime.now(timezone.utc)
        req.reviewed_by = admin_id

        # Invoice snapshot: frozen payment data (plan / amount / bank).
        # Activation rows stay byte-identical; the number is captured so the
        # unified welcome can deep-link the exact invoice.
        existing_inv = (
            await db.execute(
                select(SubscriptionInvoice).where(
                    SubscriptionInvoice.organization_id == req.organization_id,
                    SubscriptionInvoice.request_id == req.id,
                )
            )
        ).scalar_one_or_none()
        _manual_invoice_no: str | None = None
        if existing_inv is None:
            _manual_invoice_no = await _gen_sub_inv_number(db)
            db.add(SubscriptionInvoice(
                invoice_number=_manual_invoice_no,
                organization_id=req.organization_id,
                user_id=req.user_id,
                request_id=req.id,
                plan_name=plan_key,
                plan_description=final_plan.description,
                period=period,
                amount=amount,
                currency=currency,
                status="paid",
                payment_method="bank_transfer",
                bank_name=bank.bank_name,
                subscription_start_date=start,
                subscription_end_date=end,
            ))
        else:
            try:
                _manual_invoice_no = existing_inv.invoice_number
            except Exception:
                _manual_invoice_no = None
        await db.flush()

        # NOTE: the per-path user welcome row is intentionally NOT created
        # inside this transaction.  The unified welcome (exact frozen copy,
        # idempotent via source_notif_id) is sent AFTER commit, only once the
        # ACTIVE status is durable — see below.  This retires the old
        # per-path welcome to avoid doubles.
        await db.commit()
    except HTTPException:
        await db.rollback()
        raise
    except Exception:
        await db.rollback()
        logger.exception("approve_subscription_failed", req_id=req_id)
        raise HTTPException(status_code=500, detail="تعذر اعتماد الطلب — لم يتم حفظ أي تغيير")
    # Unified welcome: exactly one in-app row + one FCM push for this manual
    # approval (event manual:{request_id}).  DB row first inside the helper,
    # then the push; each guarded separately there.  Never before ACTIVE (the
    # commit above made ACTIVE durable); never breaks the approval response.
    # NO user-facing email: in-app + FCM only.
    try:
        from app.domain.services.subscription_welcome import (
            send_subscription_welcome as _send_welcome,
        )

        await _send_welcome(
            db,
            user_id=req.user_id,
            org_id=req.organization_id,
            event=f"manual:{req.id}",
            invoice_no=_manual_invoice_no,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("manual_welcome_notify_failed", error=str(exc),
                       req_id=str(req_id))
    # Mirror a summary to every platform admin (in-app rows FIRST, then the
    # FCM push — each guarded separately with clear logs): the admins'
    # phone may be the SAME device testing the flow, and admin requests are
    # NOT visible in the subscriber's notification scope.
    try:
        _org = await _org_for_request(db, req)
        _org_disp = (_org.name if _org and _org.name else str(req.organization_id)[:8])
        _admins = (
            await db.execute(
                select(User).where(User.is_platform_admin.is_(True), User.status == "active")
            )
        ).scalars().all()
        for _admin in _admins:
            db.add(AppNotification(
                organization_id=_admin.organization_id,
                user_id=_admin.id,
                type="success",
                title=f"تم اعتماد اشتراك {_org_disp} ✅",
                message=(
                    f"تم تفعيل اشتراك {_org_disp} في {plan_label} — "
                    f"{amount:g} {currency} ({period})، يبدأ {start_disp} وينتهي {end_disp}."
                ),
                action="open_screen",
                action_payload="notifications",
            ))
        await db.commit()
    except Exception as exc:  # noqa: BLE001
        logger.warning("approve_admin_mirror_failed", error=str(exc),
                       req_id=str(req_id))
        try:
            await db.rollback()
        except Exception:
            pass
        _org_disp = str(req.organization_id)[:8]
    try:
        from app.domain.services import push_service
        _org_for_push = _org_disp
        await push_service.notify_platform_admins(
            db,
            title=f"تم اعتماد اشتراك {_org_for_push} ✅",
            body=(
                f"تم تفعيل اشتراك {_org_for_push} في {plan_label}\n"
                f"المبلغ: {amount:g} {currency}\n"
                f"الفترة: {period} ({start_disp} → {end_disp})"
            ),
            action="open_screen",
            action_payload="notifications",
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("approve_admin_push_failed", error=str(exc),
                       req_id=str(req_id))
    return ok({"status": "approved", "plan_applied": True, "revenue_recorded": amount > 0})


@router.put("/admin/subscription-requests/{req_id}/reject")
async def reject_subscription_request(req_id: str, body: dict = {}, admin_id: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("subscription_requests", "update"))):
    req = await _get_subscription_request(db, req_id)
    if not req:
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    reason = (body or {}).get("reason", "")
    req.status = "rejected"
    req.reviewed_at = datetime.now(timezone.utc)
    req.reviewed_by = admin_id
    if reason:
        req.rejection_reason = reason
    notif_id = await _notify_user(
        db, req.organization_id, req.user_id,
        type_="warning",
        title="تم رفض طلب الاشتراك",
        message=reason or "عذراً، لم يتم قبول طلب اشتراكك حالياً. يمكنك التواصل مع الدعم.",
        payload="/subscription/rejected",
    )
    await db.commit()
    if notif_id:
        # NO user-facing email — in-app notification + instant FCM push only.
        pass
    # Push a device notification so the user knows instantly in the app even if
    # they are not looking at any screen right now.
    try:
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=req.user_id,
            title="تم رفض طلب الاشتراك",
            body=reason or "عذراً، لم يتم قبول طلب اشتراكك حالياً. يمكنك التواصل مع الدعم.",
            action="open_screen",
            action_payload="/subscription/rejected",
        )
    except Exception:  # noqa: BLE001 - best effort push
        pass
    # Mirror the rejection to every platform admin (in-app + FCM).
    try:
        _org = await _org_for_request(db, req)
        _org_disp = (_org.name if _org and _org.name else str(req.organization_id)[:8])
        _admins = (
            await db.execute(
                select(User).where(User.is_platform_admin.is_(True), User.status == "active")
            )
        ).scalars().all()
        for _admin in _admins:
            db.add(AppNotification(
                organization_id=_admin.organization_id,
                user_id=_admin.id,
                type="warning",
                title=f"تم رفض اشتراك {_org_disp}",
                message=(
                    f"تم رفض طلب اشتراك {_org_disp}"
                    + (f" — السبب: {reason}" if reason else ".")
                ),
                action="open_screen",
                action_payload="notifications",
            ))
        await db.commit()
        from app.domain.services import push_service
        await push_service.notify_platform_admins(
            db,
            title=f"تم رفض اشتراك {_org_disp}",
            body=reason or "تم رفض طلب الاشتراك — يمكنك التواصل مع الدعم.",
            action="open_screen",
            action_payload="notifications",
        )
    except Exception:  # noqa: BLE001 - best effort push
        pass
    return ok({"status": "rejected", "reason": reason})


class ExtendSubscriptionBody(BaseModel):
    days: int = Field(ge=1, le=3650)


async def _org_for_request(db: AsyncSession, req: SubscriptionRequest) -> Organization:
    try:
        org_uuid = uuid.UUID(str(req.organization_id))
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="الطلب غير مرتبط بمنظمة")
    org = (await db.execute(select(Organization).where(Organization.id == org_uuid))).scalar_one_or_none()
    if org is None:
        raise HTTPException(status_code=404, detail="المنظمة غير موجودة")
    return org


def _aware_dt(value):
    """Normalize a DB datetime to timezone-aware UTC (columns may come back naive)."""
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


@router.put("/admin/subscription-requests/{req_id}/cancel-subscription")
async def cancel_request_subscription(
    req_id: str,
    admin_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "update")),
):
    req = await _get_subscription_request(db, req_id)
    if not req:
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    if req.status != "approved":
        raise HTTPException(status_code=400, detail="يمكن إلغاء الاشتراك للطلبات المقبولة فقط")

    # Mark the request itself as cancelled so the admin console stops showing
    # the old green "معتمدة" badge and can render a red "تم الإلغاء" state.
    req.status = "cancelled"

    org = await _org_for_request(db, req)
    now = datetime.now(timezone.utc)
    from app.domain.services.section_entitlements import cancel, package_key
    cancel(org, package_key(req.plan_name))
    # Cancel any active billing subscription rows as well.
    subs = (
        await db.execute(
            select(StripeSubscription).where(
                StripeSubscription.organization_id == org.id,
                StripeSubscription.status == "active",
                StripeSubscription.plan_name == req.plan_name,
            )
        )
    ).scalars().all()
    for s in subs:
        s.status = "cancelled"
        s.current_period_end = now

    notif_id = await _notify_user(
        db, req.organization_id, req.user_id,
        type_="warning",
        title="تم إلغاء الاشتراك",
        message=f"تم إلغاء اشتراك ({req.plan_name or req.plan_id}) من قبل إدارة المنصة. توقف استخدام التطبيق حتى تشترك مجدداً وتتم الموافقة. للاستفسار تواصل مع الدعم.",
        payload="/subscription",
    )
    await db.commit()
    if notif_id:
        # NO user-facing email — in-app notification + instant FCM push only.
        pass
    try:
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=req.user_id,
            title="تم إلغاء الاشتراك",
            body="تم إلغاء اشتراكك من قبل الإدارة — اشترك مجدداً للمتابعة.",
            action="open_screen",
            action_payload="/subscription",
        )
    except Exception:  # noqa: BLE001 - best effort push
        pass
    return ok({"status": "cancelled", "organization_id": str(org.id)})


@router.post("/admin/subscription-requests/{req_id}/extend")
async def extend_request_subscription(
    req_id: str,
    body: ExtendSubscriptionBody,
    admin_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("subscription_requests", "update")),
):
    req = await _get_subscription_request(db, req_id)
    if not req:
        raise HTTPException(status_code=404, detail="الطلب غير موجود")
    if req.status != "approved":
        raise HTTPException(status_code=400, detail="يمكن إضافة أيام للطلبات المقبولة فقط")

    org = await _org_for_request(db, req)
    now = datetime.now(timezone.utc)
    from app.domain.services.section_entitlements import activate
    try:
        _, new_end = activate(org, req.plan_name, days=int(body.days), now=now)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    base = new_end - timedelta(days=int(body.days))

    subs = (
        await db.execute(
            select(StripeSubscription).where(
                StripeSubscription.organization_id == org.id,
                StripeSubscription.status == "active",
                StripeSubscription.plan_name == req.plan_name,
            )
        )
    ).scalars().all()
    for s in subs:
        s.current_period_end = new_end

    _base_label = base.date().isoformat()
    _end_label = new_end.date().isoformat()
    notif_id = await _notify_user(
        db, req.organization_id, req.user_id,
        type_="success",
        title="تم تمديد اشتراكك",
        message=f"مددت الإدارة اشتراكك ({req.plan_name or req.plan_id}) بإضافة {body.days} يوم: من {_base_label} إلى {_end_label}.",
        payload="/subscription",
    )
    await db.commit()
    from app.domain.services.merchant_subscription_service import notify_merchant_renewal
    await notify_merchant_renewal(db, org)
    if notif_id:
        # NO user-facing email — in-app notification + instant FCM push only.
        pass
    try:
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=req.user_id,
            title="تم تمديد اشتراكك",
            body=f"تمت إضافة {body.days} يوم إلى باقتك — من {_base_label} إلى {_end_label}.",
            action="open_screen",
            action_payload="/subscription",
        )
    except Exception:  # noqa: BLE001 - best effort push
        pass
    return ok({
        "status": org.subscription_status,
        "subscription_start_date": (org.subscription_start_date.isoformat() if org.subscription_start_date else None),
        "previous_end_date": base.isoformat(),
        "subscription_end_date": new_end.isoformat(),
        "added_days": int(body.days),
    })


# ════════════════════════════════════════════════════════════
#  PLATFORM ACCOUNTING (banks + subscription revenues)
# ════════════════════════════════════════════════════════════

class PlatformBankCreate(BaseModel):
    bank_name: str
    account_holder_name: Optional[str] = None
    account_number: Optional[str] = None
    iban: Optional[str] = None
    country: str = "SA"
    currency: str = "SAR"
    opening_balance: float = 0
    currencies: Optional[list] = None
    notes: Optional[str] = None
    is_active: bool = True
    sort_order: int = 0

class PlatformBankUpdate(BaseModel):
    bank_name: Optional[str] = None
    account_holder_name: Optional[str] = None
    account_number: Optional[str] = None
    iban: Optional[str] = None
    country: Optional[str] = None
    currency: Optional[str] = None
    opening_balance: Optional[float] = None
    currencies: Optional[list] = None
    notes: Optional[str] = None
    is_active: Optional[bool] = None
    sort_order: Optional[int] = None


async def _bank_currency_balances(db: AsyncSession, bank_id) -> dict:
    """Current balance per currency = revenue sum grouped by currency."""
    rows = await db.execute(
        select(SubscriptionRevenue.currency, func.coalesce(func.sum(SubscriptionRevenue.amount), 0))
        .where(SubscriptionRevenue.bank_account_id == bank_id)
        .group_by(SubscriptionRevenue.currency)
    )
    return {r[0] or "SAR": float(r[1]) for r in rows.all()}


def _bank_currency_list(b: PlatformBankAccount) -> list:
    """Parse the stored per-currency config; fall back to the legacy single
    currency when no multi-currency list was ever set."""
    if b.currencies:
        try:
            parsed = json.loads(b.currencies)
            cleaned = [
                {"currency": str(c.get("currency") or "SAR").upper(),
                 "opening_balance": float(c.get("opening_balance") or 0)}
                for c in parsed if isinstance(c, dict) and c.get("currency")
            ]
            if cleaned:
                return cleaned
        except Exception:  # noqa: BLE001
            pass
    return [{"currency": (b.currency or "SAR").upper(), "opening_balance": float(b.opening_balance or 0)}]


def _encode_bank_currencies(currencies: Optional[list]) -> Optional[str]:
    """Validate + JSON-encode the per-currency config, or None."""
    if not currencies:
        return None
    try:
        cleaned = [
            {"currency": str(c.get("currency") or "SAR").upper(),
             "opening_balance": float(c.get("opening_balance") or 0)}
            for c in currencies if isinstance(c, dict) and c.get("currency")
        ]
        return json.dumps(cleaned, ensure_ascii=False) if cleaned else None
    except Exception:  # noqa: BLE001
        return None


def _bank_currencies_payload(b: PlatformBankAccount, revenue_by_currency: dict, ops_by_currency: Optional[dict] = None) -> list:
    """Full per-currency view: opening + booked revenue + admin ops per currency.

    Grouping key is (bank id, currency code) — currencies are never merged:
    30 SAR + 7000 YER renders as two independent cards, never 7030.
    """
    ops_by_currency = ops_by_currency or {}
    out = []
    for c in _bank_currency_list(b):
        cur = c["currency"]
        opening = c["opening_balance"]
        booked = revenue_by_currency.get(cur, 0.0)
        ops = ops_by_currency.get(cur.upper(), {"in": 0.0, "out": 0.0, "net": 0.0})
        out.append({
            "currency": cur,
            "opening_balance": round(opening, 2),
            "booked": round(booked, 2),
            "ops_in": round(ops.get("in", 0.0), 2),
            "ops_out": round(ops.get("out", 0.0), 2),
            "balance": round(opening + booked + ops.get("net", 0.0), 2),
        })
    # Include any currency that received revenue but isn't configured yet.
    for cur, booked in revenue_by_currency.items():
        if cur.upper() not in {x["currency"].upper() for x in out}:
            ops = ops_by_currency.get(cur.upper(), {"in": 0.0, "out": 0.0, "net": 0.0})
            out.append({"currency": cur.upper(), "opening_balance": 0, "booked": round(booked, 2),
                        "ops_in": round(ops.get("in", 0.0), 2), "ops_out": round(ops.get("out", 0.0), 2),
                        "balance": round(booked + ops.get("net", 0.0), 2)})
    return out


async def _bank_balance(db: AsyncSession, bank_id) -> float:
    """Current balance = opening_balance + sum of approved revenues."""
    total = (
        await db.execute(
            select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)).where(
                SubscriptionRevenue.bank_account_id == bank_id
            )
        )
    ).scalar() or 0
    return float(total)


def _bank_dict(b: PlatformBankAccount, balance: float = 0.0, revenue_by_currency: Optional[dict] = None, ops_by_currency: Optional[dict] = None) -> dict:
    revenue_by_currency = revenue_by_currency or {}
    currencies = _bank_currencies_payload(b, revenue_by_currency, ops_by_currency)
    # Default currency balance = the configured currency's opening + booked,
    # matching the historic single-currency `balance` field for old consumers.
    default_cur = (b.currency or "SAR").upper()
    default_balance = next((c for c in currencies if c["currency"].upper() == default_cur), None)
    if default_balance is None and currencies:
        default_balance = currencies[0]
    return {
        "id": str(b.id),
        "bank_name": b.bank_name,
        "account_holder_name": b.account_holder_name or "",
        "account_number": b.account_number or "",
        "iban": b.iban or "",
        "country": b.country or "SA",
        "currency": b.currency or "SAR",
        "opening_balance": float(b.opening_balance or 0),
        "balance": round(default_balance["balance"], 2) if default_balance else round(float(b.opening_balance or 0) + balance, 2),
        "currencies": currencies,
        "notes": b.notes,
        "is_active": b.is_active,
        "is_system": bool(getattr(b, "is_system", False) or False),
        "sort_order": b.sort_order or 0,
        "created_at": b.created_at.isoformat() if b.created_at else None,
        "updated_at": b.updated_at.isoformat() if b.updated_at else None,
    }


async def _get_bank(db: AsyncSession, bank_id: str):
    try:
        result = await db.execute(
            select(PlatformBankAccount).where(PlatformBankAccount.id == uuid.UUID(bank_id))
        )
        return result.scalar_one_or_none()
    except (ValueError, TypeError):
        return None


# ════════════════ Stripe virtual settlement bank ════════════════
# A platform-owned bank named "Stripe" collects every successful card
# payment at its Stripe-confirmed amount/currency. No currency is created
# up front: the first successful payment in a currency creates that
# currency entry automatically. Same-currency payments accumulate into the
# same balance; different currencies are never merged.

STRIPE_BANK_NAME = "Stripe"


def _is_stripe_bank(b) -> bool:
    try:
        if getattr(b, "is_system", False):
            return True
    except Exception:
        pass
    try:
        return (getattr(b, "bank_name", "") or "").strip().lower() == STRIPE_BANK_NAME.lower()
    except Exception:
        return False


def _stripe_bank_guard(bank, action: str = "modify") -> None:
    """Reject renaming/deactivating/deleting the system Stripe bank."""
    if bank is not None and _is_stripe_bank(bank):
        raise HTTPException(
            status_code=400,
            detail="بنك Stripe نظامي ولا يمكن حذفه أو تعطيله أو تغيير هويته",
        )


async def ensure_stripe_bank(db: AsyncSession):
    """Get-or-create the virtual Stripe bank (flush-only; caller commits)."""
    res = await db.execute(
        select(PlatformBankAccount).where(
            func.lower(PlatformBankAccount.bank_name) == STRIPE_BANK_NAME.lower()
        )
    )
    bank = res.scalars().first()
    if bank is None:
        bank = PlatformBankAccount(
            bank_name=STRIPE_BANK_NAME,
            account_holder_name="FYONA Platform",
            country="SA",
            currency="SAR",
            opening_balance=0,
            currencies=None,
            notes="بنك نظامي افتراضي لتحصيل مدفوعات البطاقات الدولية عبر Stripe",
            is_active=True,
            is_system=True,
            sort_order=-100,
        )
        db.add(bank)
        await db.flush()
    else:
        changed = False
        if not getattr(bank, "is_system", False):
            bank.is_system = True
            changed = True
        if bank.is_active is False:
            bank.is_active = True
            changed = True
        if changed:
            await db.flush()
    # One-time backfill: historic Stripe revenues (bank NULL + provider id)
    # belong to this bank so history stays complete and per-currency.
    try:
        await db.execute(
            SubscriptionRevenue.__table__.update()
            .where(SubscriptionRevenue.bank_account_id.is_(None))
            .where(SubscriptionRevenue.provider_payment_id.isnot(None))
            .values(bank_account_id=bank.id)
        )
        await db.flush()
    except Exception:
        pass
    return bank


async def ensure_bank_currency(db: AsyncSession, bank, currency: str) -> str:
    """Create the currency entry inside a bank on first use (flush-only).

    Returns the normalized (upper-case) currency code. Same-currency reuse
    is automatic: an existing entry is never duplicated.
    """
    cur = (currency or "SAR").strip().upper()
    if not cur:
        cur = "SAR"
    current = _bank_currency_list(bank)
    if any((c.get("currency") or "").upper() == cur for c in current):
        return cur
    current.append({"currency": cur, "opening_balance": 0})
    bank.currencies = _encode_bank_currencies(current)
    await db.flush()
    return cur


async def _ops_by_currency(db: AsyncSession, bank_id) -> dict:
    """Net admin deposits/withdrawals per currency: {CUR: {in, out, net}}."""
    rows = (
        await db.execute(
            select(
                AdminOperation.currency,
                AdminOperation.type,
                func.coalesce(func.sum(AdminOperation.amount), 0),
            )
            .where(AdminOperation.bank_account_id == bank_id)
            .group_by(AdminOperation.currency, AdminOperation.type)
        )
    ).all()
    out: dict = {}
    for cur, typ, total in rows:
        key = (cur or "SAR").upper()
        slot = out.setdefault(key, {"in": 0.0, "out": 0.0, "net": 0.0})
        val = float(total or 0)
        if (typ or "deposit") == "withdraw":
            slot["out"] += val
        else:
            slot["in"] += val
        slot["net"] = slot["in"] - slot["out"]
    return out


async def _bank_available_in_currency(db: AsyncSession, bank, currency: str) -> Decimal:
    """Spendable balance of ONE currency: opening + booked revenue + ops net.

    Never mixes currencies: a USD balance can never cover a SAR withdrawal.
    """
    cur = (currency or "SAR").strip().upper()
    opening = 0.0
    for c in _bank_currency_list(bank):
        if (c.get("currency") or "").upper() == cur:
            opening = float(c.get("opening_balance") or 0)
            break
    booked = (await _bank_currency_balances(db, bank.id)).get(cur, 0.0)
    ops = (await _ops_by_currency(db, bank.id)).get(cur, {"net": 0.0})["net"]
    return Decimal(str(opening)) + Decimal(str(booked)) + Decimal(str(ops))


def _revenue_dict(r: SubscriptionRevenue, bank_name: Optional[str] = None) -> dict:
    return {
        "id": str(r.id),
        "request_id": str(r.request_id) if r.request_id else None,
        "organization_id": str(r.organization_id) if r.organization_id else None,
        "user_id": str(r.user_id) if r.user_id else None,
        "bank_account_id": str(r.bank_account_id) if r.bank_account_id else None,
        "bank_name": bank_name,
        "plan_name": r.plan_name,
        "period": r.period,
        "amount": float(r.amount or 0),
        "currency": r.currency or "SAR",
        "note": r.note,
        "created_at": r.created_at.isoformat() if r.created_at else None,
    }


@router.get("/admin/accounting/banks")
async def list_platform_banks(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("accounting", "read"))):
    # The virtual Stripe bank always exists for the admin panel.
    await ensure_stripe_bank(db)
    await db.commit()
    result = await db.execute(select(PlatformBankAccount).order_by(PlatformBankAccount.sort_order.asc(), PlatformBankAccount.created_at.asc()))
    banks = result.scalars().all()
    return ok({
        "banks": [_bank_dict(b, await _bank_balance(db, b.id), await _bank_currency_balances(db, b.id), await _ops_by_currency(db, b.id)) for b in banks],
        "total": len(banks),
    })


@router.post("/admin/accounting/banks", status_code=201)
async def create_platform_bank(body: PlatformBankCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("accounting", "create"))):
    if (body.bank_name or "").strip().lower() == STRIPE_BANK_NAME.lower():
        raise HTTPException(status_code=400, detail="بنك Stripe نظامي ويُنشأ تلقائيًا — لا يمكن إنشاء بنك آخر بهذا الاسم")
    bank = PlatformBankAccount(
        bank_name=body.bank_name.strip(),
        account_holder_name=body.account_holder_name,
        account_number=body.account_number,
        iban=body.iban,
        country=(body.country or "SA").upper(),
        currency=(body.currency or "SAR").upper(),
        opening_balance=body.opening_balance or 0,
        currencies=_encode_bank_currencies(body.currencies),
        notes=body.notes,
        is_active=body.is_active,
        sort_order=body.sort_order or 0,
    )
    db.add(bank)
    await db.commit()
    await db.refresh(bank)
    return created(_bank_dict(bank))


@router.put("/admin/accounting/banks/{bank_id}")
async def update_platform_bank(bank_id: str, body: PlatformBankUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("accounting", "update"))):
    bank = await _get_bank(db, bank_id)
    if not bank:
        raise HTTPException(status_code=404, detail="الحساب البنكي غير موجود")
    patch = body.model_dump(exclude_none=True)
    if _is_stripe_bank(bank):
        # System bank identity is frozen: no rename, no deactivation.
        if "bank_name" in patch and (patch["bank_name"] or "").strip().lower() != STRIPE_BANK_NAME.lower():
            _stripe_bank_guard(bank)
        if patch.get("is_active") is False:
            _stripe_bank_guard(bank)
    for k, v in patch.items():
        if k == "currency":
            v = v.upper()
        if k == "currencies" and isinstance(v, list):
            v = _encode_bank_currencies(v)
        if v is None:
            continue
        setattr(bank, k, v)
    bank.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(bank)
    return ok(_bank_dict(bank, await _bank_balance(db, bank.id), await _bank_currency_balances(db, bank.id), await _ops_by_currency(db, bank.id)))


@router.delete("/admin/accounting/banks/{bank_id}")
async def delete_platform_bank(bank_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("accounting", "delete"))):
    bank = await _get_bank(db, bank_id)
    if not bank:
        raise HTTPException(status_code=404, detail="الحساب البنكي غير موجود")
    _stripe_bank_guard(bank, "delete")
    has_revenue = (
        await db.execute(
            select(func.count(SubscriptionRevenue.id)).where(SubscriptionRevenue.bank_account_id == bank.id)
        )
    ).scalar() or 0
    if has_revenue:
        raise HTTPException(status_code=400, detail="لا يمكن حذف حساب عليه إيرادات مسجلة")
    await db.delete(bank)
    await db.commit()
    return no_content()


@router.get("/admin/accounting/entries")
async def list_accounting_entries(
    limit: int = Query(100, ge=1, le=500),
    bank_id: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("accounting", "read")),
):
    stmt = select(SubscriptionRevenue).order_by(SubscriptionRevenue.created_at.desc())
    if bank_id:
        try:
            stmt = stmt.where(SubscriptionRevenue.bank_account_id == UUID(str(bank_id)))
        except Exception:
            pass
    result = await db.execute(stmt.limit(limit))
    entries = result.scalars().all()
    bank_ids = {e.bank_account_id for e in entries if e.bank_account_id}
    bank_names: dict = {}
    if bank_ids:
        bank_rows = await db.execute(select(PlatformBankAccount).where(PlatformBankAccount.id.in_(bank_ids)))
        for b in bank_rows.scalars().all():
            bank_names[b.id] = b.bank_name
    # Resolve who paid: organization + user names in one batch each.
    org_ids = {e.organization_id for e in entries if e.organization_id}
    user_ids = {e.user_id for e in entries if e.user_id}
    org_names: dict = {}
    user_names: dict = {}
    if org_ids:
        for o in (await db.execute(select(Organization).where(Organization.id.in_(org_ids)))).scalars().all():
            org_names[o.id] = o.name
    if user_ids:
        for u in (await db.execute(select(User).where(User.id.in_(user_ids)))).scalars().all():
            user_names[u.id] = u.full_name or u.email
    return ok({
        "entries": [
            {**_revenue_dict(e, bank_names.get(e.bank_account_id)),
             "org_name": org_names.get(e.organization_id),
             "user_name": user_names.get(e.user_id)}
            for e in entries
        ],
        "total": len(entries),
    })


@router.get("/admin/accounting/stats")
async def accounting_stats(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("accounting", "read"))):
    banks_result = await db.execute(select(PlatformBankAccount).order_by(PlatformBankAccount.created_at.asc()))
    banks = banks_result.scalars().all()
    banks_out = []
    # Currency-separated grand totals: {CUR: amount} across all banks.
    # Different currencies are NEVER summed into one number.
    totals_by_currency: dict = {}
    for b in banks:
        bal = await _bank_balance(db, b.id)
        ops = await _ops_by_currency(db, b.id)
        banks_out.append(_bank_dict(b, bal, await _bank_currency_balances(db, b.id), ops))
        for c in banks_out[-1]["currencies"]:
            key = (c.get("currency") or "").upper()
            if key:
                totals_by_currency[key] = round(totals_by_currency.get(key, 0.0) + float(c.get("balance") or 0), 2)

    total_entries = (await db.execute(select(func.count(SubscriptionRevenue.id)))).scalar() or 0

    by_currency_rows = (
        await db.execute(
            select(SubscriptionRevenue.currency, func.coalesce(func.sum(SubscriptionRevenue.amount), 0))
            .group_by(SubscriptionRevenue.currency)
        )
    ).all()
    revenue_by_currency = [
        {"currency": r[0] or "SAR", "amount": float(r[1])} for r in by_currency_rows
    ]

    last_entries_result = await db.execute(
        select(SubscriptionRevenue).order_by(SubscriptionRevenue.created_at.desc()).limit(10)
    )
    last_entries = last_entries_result.scalars().all()
    bank_names = {}
    for e in last_entries:
        if e.bank_account_id and e.bank_account_id not in bank_names:
            bk = await _get_bank(db, str(e.bank_account_id))
            bank_names[e.bank_account_id] = bk.bank_name if bk else None

    return ok({
        "banks": banks_out,
        "total_banks": len(banks),
        "total_entries": total_entries,
        "totals_by_currency": [{"currency": k, "amount": v} for k, v in sorted(totals_by_currency.items())],
        "revenue_by_currency": revenue_by_currency,
        "recent_entries": [_revenue_dict(e, bank_names.get(e.bank_account_id)) for e in last_entries],
    })


class AdminOperationCreate(BaseModel):
    bank_id: Optional[str] = None
    bank_account_id: Optional[str] = None
    type: str = "deposit"  # deposit | withdraw
    amount: float = Field(..., gt=0)
    currency: str = "SAR"
    description: Optional[str] = None
    person_name: Optional[str] = None


@router.post("/admin/accounting/operations", status_code=201)
async def create_admin_operation(
    body: AdminOperationCreate,
    admin_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("accounting", "create")),
):
    """Deposit (إيداع) or withdrawal (صرفية) on an admin bank account."""
    bank_uuid = body.bank_account_id or body.bank_id
    if not bank_uuid:
        raise HTTPException(status_code=400, detail="حدد البنك")
    try:
        bank_uid = UUID(str(bank_uuid))
    except Exception:
        raise HTTPException(status_code=400, detail="معرف البنك غير صالح")
    bank = await _get_bank(db, str(bank_uid))
    if not bank:
        raise HTTPException(status_code=404, detail="البنك غير موجود")

    op_type = "withdraw" if body.type == "withdraw" else "deposit"
    amount = Decimal(str(body.amount))
    if amount <= 0:
        raise HTTPException(status_code=400, detail="المبلغ يجب أن يكون أكبر من صفر")

    # For withdrawals, ensure sufficient balance IN THE SAME currency:
    # opening + subscription revenue + net admin ops of that currency only.
    # A USD balance can never cover a SAR withdrawal (no cross-currency math).
    if op_type == "withdraw":
        op_currency = (body.currency or bank.currency or "SAR").upper()
        available = await _bank_available_in_currency(db, bank, op_currency)
        if available < amount:
            raise HTTPException(status_code=400, detail="الرصيد غير كافٍ لسحب هذا المبلغ")

    op = AdminOperation(
        bank_account_id=bank.id,
        bank_name=bank.bank_name,
        type=op_type,
        amount=amount,
        currency=(body.currency or bank.currency or "SAR").upper(),
        description=body.description,
        person_name=body.person_name,
        created_by=admin_id,
    )
    db.add(op)
    await db.commit()
    return created(
        data={"id": str(op.id), "type": op.type, "amount": float(op.amount), "currency": op.currency},
        message="تم تنفيذ العملية",
    )


@router.get("/admin/accounting/operations")
async def list_admin_operations(
    limit: int = Query(100, ge=1, le=500),
    bank_id: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("accounting", "read")),
):
    stmt = select(AdminOperation).order_by(AdminOperation.created_at.desc())
    if bank_id:
        try:
            stmt = stmt.where(AdminOperation.bank_account_id == UUID(str(bank_id)))
        except Exception:
            pass
    result = await db.execute(stmt.limit(limit))
    rows = result.scalars().all()
    creator_ids = {o.created_by for o in rows if o.created_by}
    creator_names: dict = {}
    if creator_ids:
        for u in (await db.execute(select(User).where(User.id.in_(creator_ids)))).scalars().all():
            creator_names[u.id] = u.full_name or u.email
    return ok({
        "operations": [
            {
                "id": str(o.id),
                "bank_id": str(o.bank_account_id) if o.bank_account_id else None,
                "bank_name": o.bank_name,
                "type": o.type,
                "amount": float(o.amount) if o.amount is not None else 0,
                "currency": o.currency,
                "description": o.description,
                "person_name": o.person_name,
                "created_by_name": creator_names.get(o.created_by),
                "created_at": o.created_at.isoformat() if o.created_at else None,
            }
            for o in rows
        ],
        "total": len(rows),
    })


# ════════════════════════════════════════════════════════════
#  PLATFORM CONTROLS — maintenance / disabled buttons / trial / force-paywall
# ════════════════════════════════════════════════════════════

class ControlsUpdate(BaseModel):
    maintenance: Optional[dict] = None
    disabled_buttons: Optional[dict] = None
    trial: Optional[dict] = None
    force_paid_subscription: Optional[bool] = None
    # Marketing extras (admin web → mobile plans page). Accepted here so the
    # admin panel can persist them through PUT /admin/controls; the mobile
    # app reads them from the public GET /controls snapshot.
    discounts: Optional[dict] = None
    urgency_countdown: Optional[dict] = None
    subscriber_counter: Optional[dict] = None


@router.get("/admin/controls")
async def get_admin_controls(
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_controls", "read")),
):
    return ok(await _settings_svc(db).get_controls())


@router.put("/admin/controls")
async def update_admin_controls(
    body: ControlsUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_controls", "update")),
):
    svc = _settings_svc(db)
    svc_name = "admin_controls"
    current = await svc.get_controls()
    previous = dict(current)
    for field in ("maintenance", "disabled_buttons", "trial",
                "discounts", "urgency_countdown", "subscriber_counter"):
        val = getattr(body, field)
        if val is not None:
            current[field] = val
    if body.force_paid_subscription is not None:
        current["force_paid_subscription"] = body.force_paid_subscription
    await svc.save_controls(current)
    # ── Maintenance notifications (rebuilt rule set) ──
    #  FEATURE (زر واحد):  OFF → In-App only (naming the feature)
    #                      ON  → In-App only (naming the feature)
    #  SECTION (شخصي/أعمال): OFF → In-App + Device Push (naming the section)
    #                        ON  → In-App + Device Push (naming the section)
    #  APPLICATION:         OFF → In-App + Device Push
    #                       ON  → In-App + Device Push
    #  Never email for any maintenance event.
    #  Messages are stored as a bilingual payload {"ar":…,"en":…} so the app
    #  renders them fully in the user's current language.
    try:
        _FEATURE_NAMES = {
            "debts": "الديون",
            "savings": "الأهداف",
            "banks": "البنوك",
            "budget": "الميزانية",
            "transactions": "المعاملات",
            "ai": "سارة",
            "suggestions": "الاقتراحات والتطوير",
            "recurring": "المعاملات المتكررة",
            "categories": "التصنيفات",
            "analytics": "التحليلات",
            "transfer": "التحويلات",
            "reports-center": "مركز التقارير",
            "reports": "التقارير",
            "executive": "النظرة التنفيذية",
            "bank-statement": "كشف الحساب",
            "account-detail": "تفاصيل الحساب",
            "savings-detail": "تفاصيل الهدف",
            "account-tree": "شجرة الحسابات",
            "financial-tree": "الشجرة المالية",
            "all-banks-report": "تقرير كل البنوك",
        }
        _FEATURE_NAMES_EN = {
            "debts": "Debts",
            "savings": "Goals",
            "banks": "Banks",
            "budget": "Budget",
            "transactions": "Transactions",
            "ai": "Sara",
            "suggestions": "Suggestions & Development",
            "recurring": "Recurring transactions",
            "categories": "Categories",
            "analytics": "Analytics",
            "transfer": "Transfers",
            "reports-center": "Reports center",
            "reports": "Reports",
            "executive": "Executive overview",
            "bank-statement": "Bank statement",
            "account-detail": "Account details",
            "savings-detail": "Goal details",
            "account-tree": "Accounts tree",
            "financial-tree": "Financial tree",
            "all-banks-report": "All banks report",
        }
        _SECTION_NAMES = {
            "all": "التطبيق بالكامل",
            "personal": "القسم الشخصي",
            "business": "قسم الأعمال",
        }
        _SECTION_NAMES_EN = {
            "all": "the whole application",
            "personal": "the Personal section",
            "business": "the Business section",
        }

        def _feat_label(key: str, lang: str) -> str:
            suffix = (key or "").strip("/").split("/")[-1].split("-")[0]
            table = _FEATURE_NAMES_EN if lang == "en" else _FEATURE_NAMES
            return table.get((key or "").strip("/"), table.get(suffix, (key or "")))

        def _sec_label(key: str, lang: str) -> str:
            return (_SECTION_NAMES_EN if lang == "en" else _SECTION_NAMES).get(key, key)

        def _bilingual(ar: str, en: str) -> str:
            return json.dumps({"ar": ar, "en": en}, ensure_ascii=False)

        def _feature_names(keys: list, lang: str) -> str:
            return "، ".join(_feat_label(f, lang) for f in sorted(keys)) or "—"

        prev_m = (previous or {}).get("maintenance") or {}
        curr_m = current.get("maintenance") or {}
        prev_b = (previous or {}).get("disabled_buttons") or {}
        curr_b = current.get("disabled_buttons") or {}

        def _features(d: dict) -> set:
            out = set()
            for mode, lst in d.items():
                if isinstance(lst, list):
                    out.update(str(x).strip("/") for x in lst)
            return out

        # ── Sections & application ──
        for key, name in _SECTION_NAMES.items():
            was_on = _as_bool(prev_m.get(key))
            now_on = _as_bool(curr_m.get(key))
            if now_on and not was_on:
                en_name = _sec_label(key, "en")
                await _platform_broadcast(
                    db,
                    _bilingual(
                        f"{name} تحت الصيانة حالياً — العمل عليه جارٍ وسيتم إشعارك عند عودته.",
                        f"{en_name} is currently under maintenance — we are working on it and you will be notified when it is back online.",
                    ),
                    type="warning", push=True, action_payload="maintenance-section",
                )
            elif was_on and not now_on:
                en_name = _sec_label(key, "en")
                await _platform_broadcast(
                    db,
                    _bilingual(
                        f"تم إعادة {name} للعمل بنجاح.",
                        f"Good news: {en_name} is back online.",
                    ),
                    type="success", push=True, action_payload="maintenance-section",
                )

        # ── Features (single buttons) — in-app rows ONLY (no device push) ──
        prev_feats = _features(prev_b)
        curr_feats = _features(curr_b)
        newly_off = sorted(curr_feats - prev_feats)
        newly_on = sorted(prev_feats - curr_feats)
        if newly_off:
            await _platform_broadcast(
                db,
                _bilingual(
                    f"تم إيقاف: {_feature_names(newly_off, 'ar')} — هذه الوظيفة تحت الصيانة حالياً.",
                    f"Disabled: {_feature_names(newly_off, 'en')} — this feature is currently under maintenance.",
                ),
                type="warning", push=False, action_payload="maintenance-feature",
            )
        if newly_on:
            await _platform_broadcast(
                db,
                _bilingual(
                    f"تم إعادة تفعيل: {_feature_names(newly_on, 'ar')} — عادت للعمل من جديد.",
                    f"Enabled again: {_feature_names(newly_on, 'en')} — this feature is back online.",
                ),
                type="success", push=False, action_payload="maintenance-feature",
            )
    except Exception:  # noqa: BLE001
        pass
    return ok(current)


@router.get("/controls")
async def get_public_controls(db: AsyncSession = Depends(get_db)):
    """Public endpoint — the mobile app reads current platform controls to
    enforce maintenance, disabled sections/buttons and trial enablement."""
    return ok(await _settings_svc(db).get_controls())


def _as_bool(v: object) -> bool:
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


def _controls_change_messages(prev: dict, curr: dict, only_restores: bool = False) -> tuple[Optional[str], Optional[str]]:
    """Split control changes into two audience-specific messages.

    Returns ``(section_msg, buttons_msg)``:
    - section_msg covers full-section maintenance (all/personal/business)
      plus force-paid toggles → device push.
    - buttons_msg covers single disabled-button toggles → in-app rows only.
    Either is ``None`` when nothing meaningful changed for that audience.
    With ``only_restores=True`` only re-enable events are reported (disables
    are silent: the app's maintenance overlay informs the user instead).
    """
    pm = prev.get("maintenance") or {}
    cm = curr.get("maintenance") or {}
    section_parts = []
    for key, arabic in (("all", "التطبيق كله"), ("personal", "القسم الشخصي"), ("business", "قسم الأعمال")):
        was_on = _as_bool(pm.get(key))
        now_on = _as_bool(cm.get(key))
        if now_on and not was_on:
            if not only_restores:
                section_parts.append(f"{arabic} متوقف مؤقتاً للصيانة")
        elif was_on and not now_on:
            section_parts.append(f"تم إعادة {arabic} للعمل")

    def _keys(d: dict) -> set:
        out = set()
        for mode, val in (d or {}).items():
            if isinstance(val, list):
                out.update(f"{mode}/{k}" for k in val)
        return out

    button_parts = []
    pb = _keys(prev.get("disabled_buttons"))
    cb = _keys(curr.get("disabled_buttons"))
    newly_disabled = cb - pb
    re_enabled = pb - cb
    if newly_disabled and not only_restores:
        button_parts.append("تم تعطيل بعض الوظائف مؤقتاً")
    if re_enabled:
        button_parts.append("تم إعادة تفعيل الوظائف المعطلة")

    if curr.get("force_paid_subscription") and not (prev or {}).get("force_paid_subscription"):
        section_parts.append("تم تفعيل الاشتراك المدفوع الإلزامي")
    elif not curr.get("force_paid_subscription") and (prev or {}).get("force_paid_subscription"):
        section_parts.append("تم إيقاف الاشتراك المدفوع الإلزامي")

    section_msg = "، ".join(section_parts) if section_parts else None
    buttons_msg = "، ".join(button_parts) if button_parts else None
    return section_msg, buttons_msg


def _controls_change_message(prev: dict, curr: dict) -> Optional[str]:
    """Backward-compatible single-message form (section + buttons combined)."""
    section_msg, buttons_msg = _controls_change_messages(prev, curr)
    parts = [p for p in (section_msg, buttons_msg) if p]
    return "، ".join(parts) if parts else None


async def _platform_broadcast(db: AsyncSession, message: str, type: str = "info", push: bool = True, action_payload: str = "notifications", push_body: Optional[str] = None) -> None:
    """Broadcast an in-app notification to every org (maintenance events).

    Maintenance broadcasts NEVER send email: the fanout runs with
    ``send_email=False`` so only in-app rows (and optionally a device push)
    are produced. ``action_payload`` tags the audience scope:
    'maintenance-feature' rows stay in-app ONLY (the app never surfaces them
    on the device); 'maintenance-section' rows may also carry a device push.

    ``message`` may be a bilingual payload {"ar":…,"en":…}; ``push_body`` is
    the plain device-push text (defaults to the Arabic variant) — the raw
    JSON envelope is NEVER pushed to devices.
    """
    notif = PlatformNotification(
        title="إشعار حالة النظام",
        message=message,
        target="all",
        type=type,
    )
    db.add(notif)
    await db.commit()
    await db.refresh(notif)
    try:
        # Inline fanout (no Celery worker tonight) so users get in-app rows now.
        # The audience marker travels WITH the fanout (the platform row has no
        # action_payload column).
        from ...workers.tasks import _fanout_platform_notification
        await _fanout_platform_notification(str(notif.id), send_email=False, action_payload=action_payload)
    except Exception:
        pass
    if not push:
        return
    if push_body is None:
        try:
            _parsed = json.loads(message)
            push_body = _parsed.get("ar") or message if isinstance(_parsed, dict) else message
            push_body_en = _parsed.get("en") if isinstance(_parsed, dict) else None
        except Exception:
            push_body = message
            push_body_en = None
    try:
        from ...domain.services.push_service import notify_all_users
        await notify_all_users(
            db,
            title="إشعار حالة النظام",
            body=push_body,
            action_payload=action_payload,
            body_en=push_body_en,
        )
    except Exception:
        pass


# ════════════════════════════════════════════════════════════
#  ADMIN NOTIFY EMAILS — who receives subscription-pending emails
# ════════════════════════════════════════════════════════════

@router.get("/admin/notify-emails")
async def get_notify_emails(
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_settings", "read")),
):
    return ok({"emails": await _settings_svc(db).get_notify_emails()})


@router.put("/admin/notify-emails")
async def update_notify_emails(
    body: dict,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_settings", "update")),
):
    emails = body.get("emails") or []
    return ok({"emails": await _settings_svc(db).save_notify_emails(emails)})


# ════════════════════════════════════════════════════════════
#  API KEYS — env-managed status (values live in .env only)
# ════════════════════════════════════════════════════════════

_ENV_KEYS_MSG = "مفاتيح API تُدار من ملف البيئة (.env) على الخادم ولا يمكن تعديلها من اللوحة"


@router.get("/admin/api-keys")
async def list_api_keys(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("api_keys", "read"))):
    statuses = await _settings_svc(db).env_key_statuses()
    return ok({"keys": statuses})


@router.post("/admin/api-keys", status_code=201)
async def create_api_key(_=Depends(require_admin_perm("api_keys", "create"))):
    raise HTTPException(status_code=403, detail=_ENV_KEYS_MSG)


@router.put("/admin/api-keys/{key_id}")
async def update_api_key(key_id: str, _=Depends(require_admin_perm("api_keys", "update"))):
    raise HTTPException(status_code=403, detail=_ENV_KEYS_MSG)


@router.delete("/admin/api-keys/{key_id}")
async def delete_api_key(key_id: str, _=Depends(require_admin_perm("api_keys", "delete"))):
    raise HTTPException(status_code=403, detail=_ENV_KEYS_MSG)


@router.post("/admin/api-keys/{key_id}/test")
async def test_api_key(key_id: str, _=Depends(require_admin_perm("api_keys", "update"))):
    raise HTTPException(status_code=403, detail=_ENV_KEYS_MSG)


# ════════════════════════════════════════════════════════════
#  NOTIFICATIONS (Platform-wide)
# ════════════════════════════════════════════════════════════

class NotificationCreate(BaseModel):
    title: str
    message: str
    target: str = "all"  # all, users, admins
    type: str = "info"  # info, warning, success, error


def _notification_dict(n: PlatformNotification) -> dict:
    return {
        "id": str(n.id),
        "title": n.title,
        "message": n.message,
        "target": n.target or "all",
        "type": n.type or "info",
        "sent_at": n.sent_at.isoformat() if n.sent_at else None,
        "created_at": n.created_at.isoformat() if n.created_at else None,
        "read_count": n.read_count or 0,
    }


@router.get("/admin/notifications")
async def list_notifications(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("notifications", "read"))):
    result = await db.execute(select(PlatformNotification).order_by(PlatformNotification.sent_at.desc()))
    notifications = result.scalars().all()
    return ok({
        "notifications": [_notification_dict(n) for n in notifications],
        "total": len(notifications),
    })


@router.post("/admin/notifications", status_code=201)
async def send_notification(body: NotificationCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("notifications", "create"))):
    notif = PlatformNotification(
        title=body.title,
        message=body.message,
        target=body.target,
        type=body.type,
    )
    db.add(notif)
    await db.commit()
    await db.refresh(notif)
    # Fan out to the TARGET audience (in-app notification + email) INLINE so
    # users see it immediately even without a Celery worker.
    # Manual admin broadcasts are admin-written (NOT system notifications).
    # The fanout itself enforces PlatformNotification.target (all/users/admins).
    try:
        from ...workers.tasks import _fanout_platform_notification
        await _fanout_platform_notification(str(notif.id), is_system=False)
    except Exception as exc:  # noqa: BLE001
        logger.warning("admin_notification_fanout_failed", error=str(exc),
                       notif_id=str(notif.id))
    # Real-device push (FCM) honoring the same target — a specific target
    # (users/admins) NEVER falls back to notifying everyone.
    try:
        from ...domain.services.push_service import notify_by_target
        await notify_by_target(
            db,
            body.target or "all",
            title=body.title,
            body=body.message,
            action="open_screen",
            action_payload="notifications",
        )
    except Exception as exc:  # noqa: BLE001 - push must never break the request
        logger.warning("admin_notification_push_failed", notif_id=str(notif.id),
                       error=str(exc))
    return created(_notification_dict(notif))


# ════════════════════════════════════════════════════════════
#  TRASH / SOFT DELETE
# ════════════════════════════════════════════════════════════

def _trash_dict(t: TrashItem) -> dict:
    return {
        "id": str(t.id),
        "item_type": t.item_type,
        "item_id": t.item_id,
        "item_name": t.item_name,
        "status": t.status or "trashed",
        "deleted_by": str(t.deleted_by) if t.deleted_by else None,
        "created_at": t.created_at.isoformat() if t.created_at else None,
        "restored_at": t.restored_at.isoformat() if t.restored_at else None,
    }


async def _get_trash_item(db: AsyncSession, item_id: str):
    try:
        result = await db.execute(
            select(TrashItem).where(TrashItem.id == uuid.UUID(item_id))
        )
        return result.scalar_one_or_none()
    except (ValueError, TypeError):
        return None


@router.get("/admin/trash")
async def list_trash(
    type_filter: Optional[str] = Query(None, alias="type"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("trash", "read")),
):
    query = select(TrashItem).order_by(TrashItem.created_at.desc())
    if type_filter:
        query = query.where(TrashItem.item_type == type_filter)
    result = await db.execute(query)
    items = result.scalars().all()
    return ok({"items": [_trash_dict(t) for t in items], "total": len(items)})


@router.post("/admin/trash/{item_id}/restore")
async def restore_trash_item(item_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("trash", "update"))):
    item = await _get_trash_item(db, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="العنصر غير موجود")
    item.status = "restored"
    item.restored_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(item)
    return ok(_trash_dict(item))


@router.delete("/admin/trash/{item_id}")
async def permanently_delete(item_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("trash", "delete"))):
    item = await _get_trash_item(db, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="العنصر غير موجود")
    await db.delete(item)
    await db.commit()
    return no_content()


# ════════════════════════════════════════════════════════════
#  DATA EXPORT
# ════════════════════════════════════════════════════════════

@router.get("/admin/export/users")
async def export_users_csv(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("export", "read"))):
    result = await db.execute(select(User))
    users = result.scalars().all()
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["ID", "Name", "Email", "Phone", "Role", "Active", "Created"])
    for u in users:
        writer.writerow([str(u.id), u.full_name, u.email, u.phone or "", u.role, u.is_active, u.created_at])
    output.seek(0)
    return StreamingResponse(
        io.BytesIO(output.getvalue().encode()),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=users_export.csv"},
    )


@router.get("/admin/export/organizations")
async def export_orgs_csv(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("export", "read"))):
    result = await db.execute(select(Organization))
    orgs = result.scalars().all()
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["ID", "Name", "Plan", "Status", "Created"])
    for o in orgs:
        writer.writerow([str(o.id), o.name, o.subscription_plan or "", o.subscription_status or "", o.created_at])
    output.seek(0)
    return StreamingResponse(
        io.BytesIO(output.getvalue().encode()),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=organizations_export.csv"},
    )


# ════════════════════════════════════════════════════════════
#  ORGANIZATIONS (separate from branches)
# ════════════════════════════════════════════════════════════

class OrgCreate(BaseModel):
    name: str
    plan: str = "trial"

class OrgUpdate(BaseModel):
    name: Optional[str] = None
    plan: Optional[str] = None
    is_active: Optional[bool] = None


def _org_dict(o: Organization, users_count: int = 0) -> dict:
    now = datetime.now(timezone.utc)
    plan = o.subscription_plan or "trial"
    sub_status = o.subscription_status or "pending"
    end_date = o.subscription_end_date
    start_date = o.subscription_start_date
    trial_end = o.trial_end_date

    # Calculate days remaining
    days_remaining = None
    if sub_status == "active" and end_date:
        e = end_date if end_date.tzinfo else end_date.replace(tzinfo=timezone.utc)
        if e > now:
            days_remaining = (e - now).days
        else:
            days_remaining = 0
    elif sub_status == "trial" and trial_end:
        t = trial_end if trial_end.tzinfo else trial_end.replace(tzinfo=timezone.utc)
        if t > now:
            days_remaining = (t - now).days
        else:
            days_remaining = 0

    return {
        "id": str(o.id),
        "name": o.name,
        "plan": plan,
        "status": sub_status,
        "is_active": o.is_active,
        "subscription_start_date": start_date.isoformat() if start_date else None,
        "subscription_end_date": end_date.isoformat() if end_date else None,
        "trial_end_date": trial_end.isoformat() if trial_end else None,
        "days_remaining": days_remaining,
        "users_count": users_count,
        "created_at": o.created_at.isoformat() if o.created_at else None,
        "updated_at": o.updated_at.isoformat() if o.updated_at else None,
    }


@router.get("/admin/orgs")
async def list_orgs(
    is_active: Optional[str] = Query(None),
    subscription_status: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("organizations", "read")),
):
    query = select(Organization).order_by(desc(Organization.created_at))
    if is_active == "true":
        query = query.where(Organization.is_active.is_(True))
    elif is_active == "false":
        query = query.where(Organization.is_active.is_(False))
    if subscription_status:
        query = query.where(Organization.subscription_status == subscription_status)
    result = await db.execute(query)
    orgs = result.scalars().all()

    # Batch-fetch users count per org
    org_ids = [o.id for o in orgs]
    users_count_map: dict = {}
    if org_ids:
        try:
            from sqlalchemy import text as sa_text
            rows = (await db.execute(sa_text("""
                SELECT organization_id, COUNT(*)::int AS cnt
                FROM users
                WHERE organization_id = ANY(:ids)
                GROUP BY organization_id
            """), {"ids": [str(i) for i in org_ids]})).fetchall()
            users_count_map = {r[0]: r[1] for r in rows}
        except Exception:
            pass

    return ok({
        "organizations": [_org_dict(o, users_count_map.get(str(o.id), 0)) for o in orgs],
        "total": len(orgs),
        "total_pages": 1,
    })


@router.post("/admin/orgs", status_code=201)
async def create_org(body: OrgCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("organizations", "create"))):
    org = Organization(
        id=uuid.uuid4(),
        name=body.name,
        subscription_plan=body.plan,
        subscription_status="active",
    )
    db.add(org)
    await db.commit()
    await db.refresh(org)
    return created(_org_dict(org))


@router.put("/admin/orgs/{org_id}")
async def update_org(org_id: str, body: OrgUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("organizations", "update"))):
    result = await db.execute(select(Organization).where(Organization.id == uuid.UUID(org_id)))
    org = result.scalar_one_or_none()
    if not org:
        raise HTTPException(status_code=404, detail="المؤسسة غير موجودة")
    if body.name is not None:
        org.name = body.name
    if body.plan is not None:
        org.subscription_plan = body.plan
    await db.commit()
    return ok(_org_dict(org))


class OrgSubscriptionBody(BaseModel):
    action: str  # extend, cancel, activate, change_plan
    days: Optional[int] = None
    plan_name: Optional[str] = None


@router.put("/admin/orgs/{org_id}/subscription")
async def manage_org_subscription(
    org_id: str,
    body: OrgSubscriptionBody,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("organizations", "update")),
):
    result = await db.execute(select(Organization).where(Organization.id == uuid.UUID(org_id)))
    org = result.scalar_one_or_none()
    if not org:
        raise HTTPException(status_code=404, detail="المؤسسة غير موجودة")
    now = datetime.now(timezone.utc)
    action = body.action
    from app.domain.services.section_entitlements import activate, cancel, subscriptions, package_key
    entries = subscriptions(org)
    target = package_key(body.plan_name or org.subscription_plan)
    org.section_subscriptions = entries
    if body.plan_name and target in entries:
        org.subscription_plan = target
        org.subscription_start_date = _aware_dt(datetime.fromisoformat(entries[target]["start_date"])) if entries[target].get("start_date") else now
        org.subscription_end_date = _aware_dt(datetime.fromisoformat(entries[target]["end_date"]))

    if action == "extend":
        if not body.days or body.days < 1:
            raise HTTPException(status_code=400, detail="حدد عدد الأيام")
        base = now
        if org.subscription_end_date:
            e = org.subscription_end_date if org.subscription_end_date.tzinfo else org.subscription_end_date.replace(tzinfo=timezone.utc)
            if e > now:
                base = e
        org.subscription_end_date = base + timedelta(days=body.days)
        if not org.subscription_start_date:
            org.subscription_start_date = now
        if org.subscription_status not in ("active", "trial"):
            org.subscription_status = "active"
        org.has_used_free_plan = True
    elif action == "cancel":
        org.subscription_status = "cancelled"
        if org.subscription_end_date:
            e = org.subscription_end_date if org.subscription_end_date.tzinfo else org.subscription_end_date.replace(tzinfo=timezone.utc)
            if e > now:
                org.subscription_end_date = now
    elif action == "activate":
        days = body.days or 30
        org.subscription_status = "active"
        org.subscription_start_date = now
        org.subscription_end_date = now + timedelta(days=days)
        org.trial_end_date = None
        org.has_used_free_plan = True
        if body.plan_name:
            org.subscription_plan = body.plan_name
    elif action == "change_plan":
        if not body.plan_name:
            raise HTTPException(status_code=400, detail="حدد اسم الباقة")
        org.subscription_plan = body.plan_name
        org.has_used_free_plan = True
        if org.subscription_status not in ("active",):
            org.subscription_status = "active"
        has_expired_end = False
        if org.subscription_end_date:
            e = org.subscription_end_date if org.subscription_end_date.tzinfo else org.subscription_end_date.replace(tzinfo=timezone.utc)
            has_expired_end = e < now
        else:
            has_expired_end = True
        if has_expired_end:
            org.subscription_start_date = now
            org.subscription_end_date = now + timedelta(days=30)
    else:
        raise HTTPException(status_code=400, detail="إجراء غير صالح. استخدم: extend, cancel, activate, change_plan")

    try:
        if action == "cancel":
            for key in ([target] if body.plan_name else list(entries)):
                cancel(org, key)
        elif target in ("personal", "business", "premium"):
            activate(org, target, start=org.subscription_start_date, end=org.subscription_end_date)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    await db.commit()
    await db.refresh(org)
    return ok(_org_dict(org))


@router.delete("/admin/orgs/{org_id}")
async def delete_org(org_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("organizations", "delete"))):
    result = await db.execute(select(Organization).where(Organization.id == uuid.UUID(org_id)))
    org = result.scalar_one_or_none()
    if not org:
        raise HTTPException(status_code=404, detail="المؤسسة غير موجودة")
    await db.delete(org)
    await db.commit()
    return no_content()


# ════════════════════════════════════════════════════════════
#  SYSTEM SETTINGS (extended)
# ════════════════════════════════════════════════════════════
#  SYSTEM SETTINGS (persisted in `app_config` via AdminSettingsService)
# ════════════════════════════════════════════════════════════

@router.get("/admin/settings")
async def get_settings(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("settings", "read"))):
    settings_dict = await _settings_svc(db).get_settings()
    return ok(settings_dict)


@router.put("/admin/settings")
async def update_settings(updates: dict, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("settings", "update"))):
    current = await _settings_svc(db).save_settings(updates)
    return ok(current)


# ════════════════════════════════════════════════════════════
#  CURRENCIES MANAGEMENT
# ════════════════════════════════════════════════════════════

class CurrencyCreate(BaseModel):
    code: str
    name: str
    symbol: str
    enabled: bool = True
    rate: float = 1.0
    auto_update: bool = False

class CurrencyUpdate(BaseModel):
    name: Optional[str] = None
    symbol: Optional[str] = None

class CurrencyRateUpdate(BaseModel):
    rate: float


@router.get("/admin/currencies")
async def list_currencies(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "read"))):
    return ok({"currencies": await _settings_svc(db).get_currencies()})


@router.put("/admin/currencies/{code}/toggle")
async def toggle_currency(code: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "update"))):
    result = await _settings_svc(db).toggle_currency(code)
    if result is None:
        raise HTTPException(status_code=404, detail="العملة غير موجودة")
    return ok(result)


@router.post("/admin/currencies", status_code=201)
async def create_currency(body: CurrencyCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "create"))):
    result = await _settings_svc(db).create_currency(body)
    if result is None:
        raise HTTPException(status_code=409, detail="العملة موجودة مسبقاً")
    return created(result)


@router.put("/admin/currencies/{code}")
async def update_currency(code: str, body: CurrencyUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "update"))):
    result = await _settings_svc(db).update_currency(code, body)
    if result is None:
        raise HTTPException(status_code=404, detail="العملة غير موجودة")
    return ok(result)


@router.put("/admin/currencies/{code}/rate")
async def update_currency_rate(code: str, body: CurrencyRateUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "update"))):
    result = await _settings_svc(db).update_currency_rate(code, body.rate)
    if result is None:
        raise HTTPException(status_code=404, detail="العملة غير موجودة")
    if result == "invalid-rate":
        raise HTTPException(status_code=400, detail="يجب أن يكون سعر الصرف أكبر من صفر")
    return ok(result)


@router.post("/admin/currencies/update-rates")
async def auto_update_rates(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("currencies", "update"))):
    """Auto-update exchange rates from API for currencies with auto_update=True."""
    svc = _settings_svc(db)
    has_api_key = bool((settings.EXCHANGE_RATE_HOST_KEY or settings.EGCURRENCY_API_KEY or "").strip())
    result = await svc.auto_update_rates(has_api_key)
    if result.get("error") == "no-key":
        raise HTTPException(status_code=400, detail="لا يوجد مفتاح API للعملات نشط")

    return ok({
        "updated_currencies": result["updated_currencies"],
        "total_updated": result["total_updated"],
        "message": f"تم تحديث {result['total_updated']} عملة",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })


# ════════════════════════════════════════════════════════════
#  BANNERS / PROMO CARDS
# ════════════════════════════════════════════════════════════

class BannerCreate(BaseModel):
    title_key: Optional[str] = None
    subtitle_key: Optional[str] = None
    icon_name: str = "star"
    color_start: str = "#A01530"
    color_end: str = "#FFD700"
    image_url: Optional[str] = None
    media_url: Optional[str] = None
    audio_url: Optional[str] = None
    video_url: Optional[str] = None
    click_url: Optional[str] = None
    text: Optional[str] = None
    duration_days: Optional[int] = 0
    carousel_seconds: Optional[int] = 4
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    is_active: bool = True
    sort_order: int = 0
    media_x: Optional[float] = None
    media_y: Optional[float] = None
    media_w: Optional[float] = None
    media_h: Optional[float] = None
    media_fit: Optional[str] = None

class BannerUpdate(BaseModel):
    title_key: Optional[str] = None
    subtitle_key: Optional[str] = None
    icon_name: Optional[str] = None
    color_start: Optional[str] = None
    color_end: Optional[str] = None
    image_url: Optional[str] = None
    media_url: Optional[str] = None
    audio_url: Optional[str] = None
    video_url: Optional[str] = None
    click_url: Optional[str] = None
    text: Optional[str] = None
    duration_days: Optional[int] = None
    carousel_seconds: Optional[int] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    is_active: Optional[bool] = None
    sort_order: Optional[int] = None
    media_x: Optional[float] = None
    media_y: Optional[float] = None
    media_w: Optional[float] = None
    media_h: Optional[float] = None
    media_fit: Optional[str] = None

class BannerLinkUpdate(BaseModel):
    click_url: str


@router.get("/admin/banners")
async def list_banners(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "read"))):
    try:
        return ok({"banners": [banner_with_image_status(b) for b in await _settings_svc(db).list_banners()]})
    except Exception as e:
        logger.exception("list_banners failed: %s", e)
        raise HTTPException(status_code=500, detail=f"تعذر جلب اللافتات: {e}")


@router.get("/banners")
async def list_active_banners(db: AsyncSession = Depends(get_db)):
    """Public endpoint — returns active banners for the home screen."""
    active = [b for b in await _settings_svc(db).list_banners() if b.get("is_active")]
    active.sort(key=lambda b: b.get("sort_order", 0))
    return ok({"banners": [banner_with_image_status(b) for b in active]})


@router.get("/support-contact")
async def get_support_contact(db: AsyncSession = Depends(get_db)):
    """Public endpoint — support WhatsApp number shown in the app drawer."""
    settings_dict = await _settings_svc(db).get_settings()
    number = str(settings_dict.get("support_whatsapp_number") or "").strip()
    return ok({"whatsapp_number": number})


@router.get("/admin/banners/{banner_id}")
async def get_banner_detail(banner_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "read"))):
    banner = await _settings_svc(db).get_banner(banner_id)
    if banner is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok(banner_with_image_status(banner))


@router.post("/admin/banners", status_code=201)
async def create_banner(body: BannerCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "create"))):
    try:
        return created(banner_with_image_status(await _settings_svc(db).create_banner(body)))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("create_banner failed: %s", e)
        raise HTTPException(status_code=500, detail=f"تعذر إنشاء اللافتة: {e}")


@router.put("/admin/banners/{banner_id}")
async def update_banner(banner_id: str, body: BannerUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "update"))):
    try:
        banner = await _settings_svc(db).update_banner(banner_id, body)
    except Exception as e:
        logger.exception("update_banner failed for %s: %s", banner_id, e)
        raise HTTPException(status_code=500, detail=f"تعذر تحديث اللافتة: {e}")
    if banner is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok(banner_with_image_status(banner))


@router.delete("/admin/banners/{banner_id}")
async def delete_banner(banner_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "delete"))):
    current = await _settings_svc(db).get_banner(banner_id)
    deleted = await _settings_svc(db).delete_banner(banner_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    if current is not None:
        old_path = banner_image_path(current.get("image_url"))
        if old_path and os.path.isfile(old_path):
            try:
                os.remove(old_path)
            except OSError:
                pass
    return no_content()


@router.post("/admin/banners/{banner_id}/upload-image")
async def upload_banner_image(banner_id: str, image: UploadFile = File(...), db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "update"))):
    ext = banner_image_extension(image.content_type or "", image.filename or "")
    if ext is None:
        raise HTTPException(status_code=400, detail="نوع الملف غير مدعوم — يُسمح بـ JPG, PNG, WebP, GIF فقط")

    content = await image.read()
    if not content:
        raise HTTPException(status_code=400, detail="الملف المرفوع فارغ")

    if len(content) > settings.MAX_FILE_SIZE_MB * 1024 * 1024:
        raise HTTPException(
            status_code=413,
            detail=f"حجم الصورة يتجاوز الحد المسموح ({settings.MAX_FILE_SIZE_MB}MB)",
        )

    upload_dir = os.path.join(UPLOAD_ROOT, "banners")
    os.makedirs(upload_dir, exist_ok=True)

    filename = f"banner_{banner_id}_{int(datetime.now().timestamp())}.{ext}"

    from app.core.storage import unified_upload
    content_type = f"image/{ext}" if ext != "jpg" else "image/jpeg"
    # Persist to LOCAL DISK first — that is what /uploads/ actually serves and
    # it is near-instant. The MinIO/S3 mirror is best-effort and off the request
    # path so an unreachable object store can never fail an upload.
    filepath = os.path.join(upload_dir, filename)
    try:
        with open(filepath, "wb") as f:
            f.write(content)
    except OSError as exc:
        logger.warning("banner_image_disk_failed", filename=filename, error=str(exc))
        raise HTTPException(status_code=500, detail="تعذر حفظ الصورة على الخادم")

    # Verify the file actually landed on disk BEFORE persisting the URL — never
    # store an image_url that points to a file that may not exist.
    if not os.path.isfile(filepath) or os.path.getsize(filepath) != len(content):
        try:
            os.remove(filepath)
        except OSError:
            pass
        raise HTTPException(status_code=500, detail="فشل حفظ الصورة — لم يتم تحديث الرابط")

    # Mirror to object storage in the background (best-effort).
    try:
        import asyncio as _asyncio

        async def _mirror_banner_image():
            try:
                await unified_upload("banners", filename, content, content_type)
            except Exception:  # noqa: BLE001 - best-effort mirror
                logger.warning("banner_s3_skipped", filename=filename)

        _asyncio.create_task(_mirror_banner_image())
    except Exception:  # noqa: BLE001
        pass

    current = await _settings_svc(db).get_banner(banner_id)
    old_url = current.get("image_url") if current is not None else None

    image_url = f"/uploads/banners/{filename}"
    banner = await _settings_svc(db).update_banner_image(banner_id, image_url)
    if banner is None:
        # Banner missing — remove the orphaned file we just wrote.
        try:
            os.remove(filepath)
        except OSError:
            pass
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")

    # Delete the previous image ONLY after the new URL was persisted.
    old_path = banner_image_path(old_url)
    if old_path and old_path != filepath and os.path.isfile(old_path):
        try:
            os.remove(old_path)
        except OSError:
            pass

    return ok(banner_with_image_status(banner))


@router.post("/admin/banners/{banner_id}/upload-media")
async def upload_banner_media(banner_id: str, media: UploadFile = File(...), db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "update"))):
    """Upload audio/video media for a banner (mp3/mp4/webm/m4a)."""
    allowed = {".mp3", ".m4a", ".mp4", ".webm", ".ogg", ".wav"}
    filename = media.filename or ""
    ext = os.path.splitext(filename)[1].lower()
    if ext not in allowed:
        raise HTTPException(status_code=400, detail="نوع الملف غير مدعوم — يُسمح بـ MP3, M4A, MP4, WEBM, OGG, WAV")
    content = await media.read()
    if not content:
        raise HTTPException(status_code=400, detail="الملف المرفوع فارغ")
    if len(content) > 100 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="حجم الملف يتجاوز الحد (100MB)")

    from app.core.storage import unified_upload
    upload_dir = os.path.join(UPLOAD_ROOT, "banners_media")
    os.makedirs(upload_dir, exist_ok=True)
    media_filename = f"{banner_id}_{uuid.uuid4().hex}{ext}"
    filepath = os.path.join(upload_dir, media_filename)
    # Persist to LOCAL DISK first — that is what /uploads/ actually serves and
    # it is near-instant. MinIO/S3 mirror is best-effort, off the request path.
    try:
        with open(filepath, "wb") as f:
            f.write(content)
    except OSError as exc:
        logger.warning("banner_media_disk_failed", filename=media_filename, error=str(exc))
        raise HTTPException(status_code=500, detail="تعذر حفظ الملف على الخادم")
    if not os.path.isfile(filepath) or os.path.getsize(filepath) != len(content):
        try: os.remove(filepath)
        except OSError: pass
        raise HTTPException(status_code=500, detail="فشل حفظ الملف")
    try:
        import asyncio as _asyncio

        async def _mirror_banner_media():
            try:
                await unified_upload("banners_media", media_filename, content, media.content_type or "application/octet-stream")
            except Exception:  # noqa: BLE001 - best-effort mirror
                logger.warning("banner_media_s3_skipped", filename=media_filename)

        _asyncio.create_task(_mirror_banner_media())
    except Exception:  # noqa: BLE001
        pass

    media_url = f"/uploads/banners_media/{media_filename}"
    current = await _settings_svc(db).get_banner(banner_id)
    old_url = current.get("media_url") if current else None
    banner = await _settings_svc(db).update_banner(banner_id, type("_B", (), {"model_dump": lambda self, **kw: {"media_url": media_url}})())
    if banner is None:
        try: os.remove(filepath)
        except OSError: pass
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    old_path = banner_image_path(old_url)
    if old_path and os.path.isfile(old_path) and old_path != filepath:
        try: os.remove(old_path)
        except OSError: pass
    return ok(banner_with_image_status(banner))


@router.put("/admin/banners/{banner_id}/link")
async def set_banner_link(banner_id: str, body: BannerLinkUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "update"))):
    banner = await _settings_svc(db).set_banner_link(banner_id, body.click_url)
    if banner is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok(banner)


@router.get("/admin/banners/{banner_id}/stats")
async def get_banner_stats(banner_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("banners", "read"))):
    banner = await _settings_svc(db).get_banner(banner_id)
    if banner is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok({
        "id": banner["id"],
        "title_key": banner["title_key"],
        "click_count": banner.get("click_count", 0),
        "view_count": banner.get("view_count", 0),
        "watch_seconds": banner.get("watch_seconds", 0),
        "watch_hours": round(int(banner.get("watch_seconds", 0)) / 3600.0, 1),
        "click_url": banner.get("click_url"),
        "is_active": banner.get("is_active"),
    })


@router.post("/banners/{banner_id}/click")
async def record_banner_click(banner_id: str, db: AsyncSession = Depends(get_db)):
    """Public endpoint — record a click on a banner."""
    count = await _settings_svc(db).record_banner_click(banner_id)
    if count is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok({"id": banner_id, "click_count": count})


@router.post("/banners/{banner_id}/view")
async def record_banner_view(banner_id: str, db: AsyncSession = Depends(get_db)):
    """Public endpoint — record a view of a banner."""
    count = await _settings_svc(db).record_banner_view(banner_id)
    if count is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok({"id": banner_id, "view_count": count})


@router.post("/banners/{banner_id}/watch")
async def record_banner_watch(banner_id: str, body: dict = {}, db: AsyncSession = Depends(get_db)):
    """Public endpoint — the app reports how long a banner stayed visible (seconds)."""
    seconds = int((body or {}).get("seconds") or 0)
    total = await _settings_svc(db).record_banner_watch(banner_id, seconds)
    if total is None:
        raise HTTPException(status_code=404, detail="اللافتة غير موجودة")
    return ok({"id": banner_id, "watch_seconds": total})


# ════════════════════════════════════════════════════════════
#  DASHBOARD STATS
# ════════════════════════════════════════════════════════════

@router.get("/admin/dashboard/stats")
async def dashboard_stats(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("dashboard", "read"))):
    users_result = await db.execute(select(func.count(User.id)))
    total_users = users_result.scalar() or 0

    orgs_result = await db.execute(select(func.count(Organization.id)))
    total_orgs = orgs_result.scalar() or 0

    active_orgs_result = await db.execute(
        select(func.count(Organization.id)).where(Organization.is_active == True)
    )
    active_orgs = active_orgs_result.scalar() or 0

    await _ensure_plans_seeded(db)

    plans_total = (await db.execute(select(func.count(Plan.id)))).scalar() or 0
    notifications_total = (
        await db.execute(select(func.count(PlatformNotification.id)))
    ).scalar() or 0
    sub_requests_pending = (
        await db.execute(
            select(func.count(SubscriptionRequest.id)).where(
                SubscriptionRequest.status == "pending"
            )
        )
    ).scalar() or 0
    # Keys the admin web dashboard reads (were missing → empty boxes).
    active_subscriptions = (
        await db.execute(
            select(func.count(Organization.id)).where(
                Organization.subscription_status == "active"
            )
        )
    ).scalar() or 0
    trial_subscriptions = (
        await db.execute(
            select(func.count(Organization.id)).where(
                Organization.subscription_status == "trial"
            )
        )
    ).scalar() or 0
    total_revenue = (
        await db.execute(select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)))
    ).scalar() or 0
    revenue_by_currency = [
        {"currency": r[0] or "SAR", "amount": float(r[1] or 0)}
        for r in (
            await db.execute(
                select(
                    SubscriptionRevenue.currency,
                    func.coalesce(func.sum(SubscriptionRevenue.amount), 0),
                ).group_by(SubscriptionRevenue.currency)
            )
        ).all()
    ]
    trash_total = (await db.execute(select(func.count(TrashItem.id)))).scalar() or 0

    # Org-based subscription truth (manual + Stripe alike, no duplicates).
    _now_ds = datetime.now(timezone.utc)
    _orgs_ds = (await db.execute(select(Organization))).scalars().all()
    _sub_total = 0
    _sub_active = 0
    _sub_expired = 0
    for _o in _orgs_ds:
        _has, _act, _exp = _org_state(_o, _now_ds)
        if not _has:
            continue
        _sub_total += 1
        if _act:
            _sub_active += 1
        if _exp:
            _sub_expired += 1
    _src_map = await _subscription_source_map(db, [_o.id for _o in _orgs_ds])
    _by_src: dict = {}
    for _o in _orgs_ds:
        if not _org_state(_o, _now_ds)[0]:
            continue
        _s = _src_map.get(_o.id, "none")
        _by_src[_s] = _by_src.get(_s, 0) + 1

    svc = _settings_svc(db)
    counts = await svc.counts()

    return ok({
        "total_users": total_users,
        "total_organizations": total_orgs,
        "active_organizations": active_orgs,
        "total_plans": plans_total,
        "total_banners": counts["banners"],
        "active_banners_count": counts["active_banners"],
        "total_notifications": notifications_total,
        "total_api_keys": counts["api_keys"],
        "total_currencies": counts["currencies"],
        "subscription_requests_pending": sub_requests_pending,
        # Dashboard KPI keys (exact names the web panel reads).
        "active_subscriptions": active_subscriptions,
        "pending_subscriptions": sub_requests_pending,
        "trial_subscriptions": trial_subscriptions,
        "total_revenue": float(total_revenue),
        "revenue_by_currency": revenue_by_currency,
        "trash_items": trash_total,
        # Org-based subscription stats (all channels, deduplicated).
        "subscriptions_total": _sub_total,
        "subscriptions_active_total": _sub_active,
        "subscriptions_expired_total": _sub_expired,
        "subscriptions_by_source": [
            {"source": _k, "count": _v} for _k, _v in sorted(_by_src.items())
        ],
    })


def _month_key(dt) -> str:
    if dt is None:
        return ""
    return dt.strftime("%Y-%m")


def _last_n_months(now, n: int) -> list[str]:
    months: list[str] = []
    y, m = now.year, now.month
    for _ in range(n):
        months.append(f"{y:04d}-{m:02d}")
        m -= 1
        if m == 0:
            y -= 1
            m = 12
    months.reverse()
    return months


def _trend_series(dates: list, months: list[str]) -> list[dict]:
    buckets = {mk: 0 for mk in months}
    for d in dates:
        mk = _month_key(d)
        if mk in buckets:
            buckets[mk] += 1
    return [{"month": mk, "count": buckets[mk]} for mk in months]


def _growth_pct(current: int, previous: int) -> float:
    if previous <= 0:
        return 100.0 if current > 0 else 0.0
    return round((current - previous) / previous * 100, 1)


@router.get("/admin/analytics/trends")
async def analytics_trends(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("dashboard", "read"))):
    now = datetime.now(timezone.utc)

    user_dates = list((await db.execute(select(User.created_at))).scalars())
    org_dates = list((await db.execute(select(Organization.created_at))).scalars())

    months = _last_n_months(now, 6)
    users_trend = _trend_series(user_dates, months)
    orgs_trend = _trend_series(org_dates, months)

    new_users_this_month = users_trend[-1]["count"]
    users_growth = _growth_pct(
        users_trend[-1]["count"],
        users_trend[-2]["count"] if len(users_trend) >= 2 else 0,
    )
    orgs_growth = _growth_pct(
        orgs_trend[-1]["count"],
        orgs_trend[-2]["count"] if len(orgs_trend) >= 2 else 0,
    )

    sub_rows = (
        await db.execute(
            select(Organization.subscription_status, func.count(Organization.id))
            .group_by(Organization.subscription_status)
        )
    ).all()
    subscription_breakdown = [
        {"status": r[0] or "unknown", "count": r[1]} for r in sub_rows
    ]

    user_rows = (
        await db.execute(
            select(User.status, func.count(User.id)).group_by(User.status)
        )
    ).all()
    user_status_breakdown = [
        {"status": r[0] or "unknown", "count": r[1]} for r in user_rows
    ]

    admin_users = (
        await db.execute(select(func.count(User.id)).where(User.is_platform_admin == True))
    ).scalar() or 0
    unverified_users = (
        await db.execute(select(func.count(User.id)).where(User.email_verified == False))
    ).scalar() or 0

    top_orgs = (
        await db.execute(
            select(Organization.name, func.count(User.id).label("cnt"))
            .join(User, User.organization_id == Organization.id)
            .group_by(Organization.id, Organization.name)
            .order_by(desc("cnt"))
            .limit(5)
        )
    ).all()
    top_organizations = [{"name": r[0], "count": r[1]} for r in top_orgs]

    return ok({
        "users_trend": users_trend,
        "organizations_trend": orgs_trend,
        "new_users_this_month": new_users_this_month,
        "users_growth_pct": users_growth,
        "organizations_growth_pct": orgs_growth,
        "subscription_breakdown": subscription_breakdown,
        "user_status_breakdown": user_status_breakdown,
        "admin_users_count": admin_users,
        "unverified_users_count": unverified_users,
        "top_organizations": top_organizations,
        "generated_at": now.isoformat(),
    })


def _overview_span(period: str) -> tuple:
    """Normalize the dashboard period filter to (days, bucket_count).

    7d → daily buckets, 30d → daily, 90d → weekly, 12m → monthly.
    """
    p = (period or "30d").strip().lower()
    if p == "7d":
        return 7, "day"
    if p == "90d":
        return 90, "week"
    if p in ("12m", "1y", "12mo"):
        return 365, "month"
    return 30, "day"


def _bucket_labels(now, days: int, grain: str) -> list:
    from datetime import timedelta as _td
    labels: list = []
    if grain == "month":
        y, m = now.year, now.month
        for _ in range(12):
            labels.append(f"{y:04d}-{m:02d}")
            m -= 1
            if m == 0:
                y -= 1
                m = 12
        labels.reverse()
        return labels
    if grain == "week":
        start = (now - _td(days=days)).date()
        cur = start
        while cur <= now.date():
            labels.append(cur.isoformat())
            cur += _td(days=7)
        return labels
    start = (now - _td(days=days - 1)).date()
    for i in range(days):
        labels.append((start + _td(days=i)).isoformat())
    return labels


def _bucketize(dates, labels: list, grain: str, tz=None) -> list:
    """Bucket datetimes into labels. With tz set, day/week attribution uses
    that timezone's calendar days (system timezone for custom ranges)."""
    buckets = {lb: 0 for lb in labels}
    label_set = set(labels)
    for d in dates:
        if d is None:
            continue
        try:
            if hasattr(d, "date"):
                dd = d
                if tz is not None:
                    if dd.tzinfo is None:
                        dd = dd.replace(tzinfo=timezone.utc)
                    dd = dd.astimezone(tz).date()
                else:
                    dd = dd.date()
            else:
                dd = d
            key = None
            if grain == "month":
                key = f"{dd.year:04d}-{dd.month:02d}"
            elif grain == "week":
                for lb in labels:
                    start = datetime.fromisoformat(lb).date()
                    if start <= dd < start + timedelta(days=7):
                        key = lb
                        break
            else:
                key = dd.isoformat()
            if key in label_set:
                buckets[key] += 1
        except Exception:
            continue
    return [{"label": lb, "count": buckets[lb]} for lb in labels]


def _bucket_labels_range(start_date, end_date, grain: str) -> list:
    """Bucket labels spanning an explicit [start, end] date range.

    Same label formats as _bucket_labels so _bucketize stays compatible:
    days → ISO dates, weeks → week-start ISO dates, months → YYYY-MM.
    """
    from datetime import timedelta as _td
    labels: list = []
    if grain == "month":
        y, m = start_date.year, start_date.month
        while (y, m) <= (end_date.year, end_date.month):
            labels.append(f"{y:04d}-{m:02d}")
            m += 1
            if m == 13:
                y += 1
                m = 1
        return labels
    if grain == "week":
        cur = start_date
        while cur <= end_date:
            labels.append(cur.isoformat())
            cur += _td(days=7)
        return labels
    cur = start_date
    while cur <= end_date:
        labels.append(cur.isoformat())
        cur += _td(days=1)
    return labels


def _auto_grain(span_days: int) -> str:
    """Smart bucketing by range length: short → daily, medium → weekly,
    long → monthly."""
    if span_days <= 45:
        return "day"
    if span_days <= 400:
        return "week"
    return "month"


def _parse_custom_range(date_from: Optional[str], date_to: Optional[str]):
    """Parse YYYY-MM-DD bounds into tz-aware UTC datetimes covering the FULL
    days in the system timezone (Asia/Riyadh), so the last day's data is
    never lost. Returns (start_utc, end_utc) or (None, None)."""
    if not date_from or not date_to:
        return None, None
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Riyadh")
        d0 = datetime.fromisoformat(date_from).date()
        d1 = datetime.fromisoformat(date_to).date()
        if d1 < d0:
            return None, None
        start = datetime(d0.year, d0.month, d0.day, 0, 0, 0, tzinfo=tz).astimezone(timezone.utc)
        end = (datetime(d1.year, d1.month, d1.day, 0, 0, 0, tzinfo=tz)
               + timedelta(days=1) - timedelta(microseconds=1)).astimezone(timezone.utc)
        return start, end
    except (ValueError, TypeError):
        return None, None


async def _subscription_source_map(db: AsyncSession, org_ids: list) -> dict:
    """Per-org subscription source from the org's LATEST paid invoice.

    stripe → international (card), bank_transfer → local (manual receipt),
    no invoice → none (trial / admin-direct / pending). One row per org —
    multiple payments/webhooks for the same org never duplicate it.
    """
    if not org_ids:
        return {}
    from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
    rows = (
        await db.execute(
            select(
                SubscriptionInvoice.organization_id,
                SubscriptionInvoice.payment_method,
                func.max(SubscriptionInvoice.created_at),
            )
            .where(
                SubscriptionInvoice.organization_id.in_(org_ids),
                SubscriptionInvoice.status == "paid",
            )
            .group_by(
                SubscriptionInvoice.organization_id,
                SubscriptionInvoice.payment_method,
            )
        )
    ).all()
    latest: dict = {}
    for oid, method, ts in rows:
        prev = latest.get(oid)
        if prev is None or (ts and prev[1] and ts > prev[1]):
            latest[oid] = (method, ts)
    out = {}
    for oid in org_ids:
        method = latest.get(oid, (None, None))[0]
        if (method or "") == "stripe":
            out[oid] = "international"
        elif method:
            out[oid] = "local"
        else:
            out[oid] = "none"
    return out


def _org_state(org, now) -> tuple:
    """Classify an org's CURRENT subscription: (has_sub, is_active, is_expired)."""
    status = (org.subscription_status or "").strip().lower()
    if not status or status == "none":
        return False, False, False
    end = org.subscription_end_date
    try:
        end_past = end is not None and end < now
    except TypeError:
        end_past = False
    if status == "expired" or (status == "active" and end_past):
        return True, False, True
    if status == "active":
        return True, True, False
    return True, False, False


@router.get("/admin/analytics/overview")
async def analytics_overview(
    period: str = Query("30d"),
    date_from: Optional[str] = Query(None, alias="from"),
    date_to: Optional[str] = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("dashboard", "read")),
):
    """Dashboard analytics for a selectable period (7d / 30d / 90d / 12m).

    KPIs, user/revenue trends, subscription mix and request outcomes —
    everything the admin needs to read the platform's health at a glance.

    Custom range: pass from=YYYY-MM-DD & to=YYYY-MM-DD to override the
    preset; bounds cover full days in the system timezone and bucketing
    adapts automatically (daily / weekly / monthly).
    """
    from datetime import timedelta as _td
    now = datetime.now(timezone.utc)
    custom_start, custom_end = _parse_custom_range(date_from, date_to)
    if custom_start is not None and custom_end is not None:
        start, end = custom_start, custom_end
        span_days = max((end - start).days + 1, 1)
        days = span_days
        grain = _auto_grain(span_days)
        prev_start = start - (end - start)
        prev_end = start
        period_label = "custom"
        from zoneinfo import ZoneInfo as _ZI
        _sys_tz = _ZI("Asia/Riyadh")
        range_labels = _bucket_labels_range(
            start.astimezone(_sys_tz).date(), end.astimezone(_sys_tz).date(), grain)
    else:
        days, grain = _overview_span(period)
        start = now - _td(days=days)
        end = now
        prev_start = now - _td(days=days * 2)
        prev_end = start
        period_label = period
        range_labels = None
        _sys_tz = None

    total_users = (await db.execute(select(func.count(User.id)))).scalar() or 0
    users_before = (
        await db.execute(
            select(func.count(User.id)).where(User.created_at < start)
        )
    ).scalar() or 0
    new_users = (
        await db.execute(
            select(func.count(User.id)).where(
                User.created_at >= start, User.created_at <= end
            )
        )
    ).scalar() or 0
    prev_users = (
        await db.execute(
            select(func.count(User.id)).where(
                User.created_at >= prev_start, User.created_at < prev_end
            )
        )
    ).scalar() or 0

    total_revenue = (
        await db.execute(select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)))
    ).scalar() or 0
    period_revenue = (
        await db.execute(
            select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)).where(
                SubscriptionRevenue.created_at >= start,
                SubscriptionRevenue.created_at <= end,
            )
        )
    ).scalar() or 0
    prev_revenue = (
        await db.execute(
            select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)).where(
                SubscriptionRevenue.created_at >= prev_start,
                SubscriptionRevenue.created_at < prev_end,
            )
        )
    ).scalar() or 0
    rev_currency_rows = (
        await db.execute(
            select(
                SubscriptionRevenue.currency,
                func.coalesce(func.sum(SubscriptionRevenue.amount), 0),
            )
            .where(
                SubscriptionRevenue.created_at >= start,
                SubscriptionRevenue.created_at <= end,
            )
            .group_by(SubscriptionRevenue.currency)
        )
    ).all()

    # ── Org-based subscription truth (local + Stripe, never duplicated) ──
    # Statuses live on organizations (set by manual approval AND by Stripe
    # auto-activation alike); requests alone would hide every card payment.
    orgs = (await db.execute(select(Organization))).scalars().all()
    sub_total = 0
    sub_active = 0
    sub_expired = 0
    sub_new_in_period = 0
    for o in orgs:
        has_sub, is_active, is_expired = _org_state(o, now)
        if not has_sub:
            continue
        sub_total += 1
        if is_active:
            sub_active += 1
        if is_expired:
            sub_expired += 1
        try:
            if o.subscription_start_date is not None and start <= o.subscription_start_date <= end:
                sub_new_in_period += 1
        except TypeError:
            pass
    source_map = await _subscription_source_map(db, [o.id for o in orgs])
    by_source: dict = {}
    for o in orgs:
        if not _org_state(o, now)[0]:
            continue
        src = source_map.get(o.id, "none")
        by_source[src] = by_source.get(src, 0) + 1

    sub_rows = (
        await db.execute(
            select(Organization.subscription_status, func.count(Organization.id))
            .group_by(Organization.subscription_status)
        )
    ).all()
    new_active = (
        await db.execute(
            select(func.count(Organization.id)).where(
                Organization.subscription_status == "active",
                Organization.subscription_start_date >= start,
                Organization.subscription_start_date <= end,
            )
        )
    ).scalar() or 0

    req_rows = (
        await db.execute(
            select(SubscriptionRequest.status, func.count(SubscriptionRequest.id))
            .where(SubscriptionRequest.created_at >= start,
                   SubscriptionRequest.created_at <= end)
            .group_by(SubscriptionRequest.status)
        )
    ).all()

    labels = range_labels if range_labels is not None else _bucket_labels(now, days, grain)
    user_dates = list(
        (await db.execute(select(User.created_at).where(
            User.created_at >= start, User.created_at <= end))).scalars()
    )
    rev_dates = list(
        (await db.execute(
            select(SubscriptionRevenue.created_at).where(
                SubscriptionRevenue.created_at >= start,
                SubscriptionRevenue.created_at <= end)
        )).scalars()
    )
    users_trend = _bucketize(user_dates, labels, grain, tz=_sys_tz)
    # Cumulative totals per bucket so the chart can show running totals.
    running = users_before
    for b in users_trend:
        running += b["count"]
        b["cumulative"] = running

    return ok({
        "period": period_label,
        "days": days,
        "grain": grain,
        "from": start.isoformat(),
        "to": end.isoformat(),
        "users": {
            "total": total_users,
            "new_in_period": new_users,
            "growth_pct": _growth_pct(new_users, prev_users),
            "total_before_period": users_before,
        },
        "revenue": {
            "total": float(total_revenue),
            "in_period": float(period_revenue),
            "growth_pct": _growth_pct(float(period_revenue), float(prev_revenue)),
            "by_currency": [
                {"currency": r[0] or "SAR", "amount": float(r[1] or 0)}
                for r in rev_currency_rows
            ],
        },
        "subscriptions": {
            "breakdown": [
                {"status": r[0] or "unknown", "count": r[1]} for r in sub_rows
            ],
            "new_active_in_period": new_active,
            "total": sub_total,
            "active_total": sub_active,
            "expired_total": sub_expired,
            "new_in_period": sub_new_in_period,
            "by_source": [
                {"source": k, "count": v} for k, v in sorted(by_source.items())
            ],
        },
        "requests_in_period": [
            {"status": r[0] or "unknown", "count": r[1]} for r in req_rows
        ],
        "users_trend": users_trend,
        "revenue_trend": _bucketize(rev_dates, labels, grain, tz=_sys_tz),
        "generated_at": now.isoformat(),
    })


def _converted_range(period: Optional[str], date_from: Optional[str],
                     date_to: Optional[str]) -> tuple:
    """Resolve the analytics window the same way as the overview endpoint
    (presets or a custom from/to range), without touching it."""
    from datetime import timedelta as _td
    now = datetime.now(timezone.utc)
    custom_start, custom_end = _parse_custom_range(date_from, date_to)
    if custom_start is not None and custom_end is not None:
        return custom_start, custom_end, "custom"
    days, _ = _overview_span(period or "30d")
    return now - _td(days=days), now, (period or "30d")


@router.get("/admin/analytics/revenue-converted")
async def analytics_revenue_converted(
    currency: str = Query("USD"),
    period: str = Query("30d"),
    date_from: Optional[str] = Query(None, alias="from"),
    date_to: Optional[str] = Query(None, alias="to"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("dashboard", "read")),
):
    """Period revenue converted into one admin-chosen currency.

    Per-currency lines stay exact (never merged); the grand total converts
    every line via the platform FX engine (exchangerate-api.com globally,
    2dec.net for YER_OLD/YER_NEW — read-only use, engine untouched).
    Lines without an available rate are listed under `unconverted` and
    excluded from the total instead of being guessed.
    """
    from app.domain.services.currency_service import CurrencyService
    target = (currency or "USD").strip().upper()
    start, end, period_label = _converted_range(period, date_from, date_to)
    rows = (
        await db.execute(
            select(
                SubscriptionRevenue.currency,
                func.coalesce(func.sum(SubscriptionRevenue.amount), 0),
            )
            .where(
                SubscriptionRevenue.created_at >= start,
                SubscriptionRevenue.created_at <= end,
            )
            .group_by(SubscriptionRevenue.currency)
        )
    ).all()
    fx = CurrencyService.get_instance()
    lines: list = []
    unconverted: list = []
    total = 0.0
    for cur_raw, amount_raw in rows:
        cur = (cur_raw or "SAR").upper()
        amount = round(float(amount_raw or 0), 2)
        try:
            conv = await fx.convert(amount, cur, target)
        except Exception:
            conv = None
        if conv is None:
            unconverted.append({"currency": cur, "amount": amount})
            lines.append({"currency": cur, "amount": amount, "converted": None})
        else:
            conv = round(conv, 2)
            total += conv
            lines.append({"currency": cur, "amount": amount, "converted": conv})
    lines.sort(key=lambda x: x["currency"])
    meta: dict = {}
    try:
        all_rates = await fx.get_all_rates()
        all_meta = (all_rates.get("meta") or {}) if isinstance(all_rates, dict) else {}
        meta = {
            "global_source": all_meta.get("global_source"),
            "yemen_source": all_meta.get("yemen_source"),
            "fetched_at": all_meta.get("fetched_at"),
        }
    except Exception:
        pass
    return ok({
        "target_currency": target,
        "period": period_label,
        "from": start.isoformat(),
        "to": end.isoformat(),
        "lines": lines,
        "total": round(total, 2),
        "unconverted": unconverted,
        "rates_meta": meta,
    })


# ════════════════════════════════════════════════════════════
#  USERS MANAGEMENT (DB-backed)
# ════════════════════════════════════════════════════════════

class UserCreate(BaseModel):
    full_name: str
    email: str
    phone: Optional[str] = None
    role: str = "employee"
    organization_id: Optional[str] = None  # falls back to the acting admin's org
    preferred_language: str = "ar"
    preferred_currency: str = "SAR"
    timezone: str = "Asia/Riyadh"
    is_platform_admin: bool = False
    password: Optional[str] = None  # sets auth_provider="email" so they can log into the web console
    admin_section: Optional[str] = None  # personal | business | all — preset for permissions

class UserUpdate(BaseModel):
    full_name: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    role: Optional[str] = None
    status: Optional[str] = None
    preferred_language: Optional[str] = None
    preferred_currency: Optional[str] = None
    timezone: Optional[str] = None
    is_platform_admin: Optional[bool] = None
    email_verified: Optional[bool] = None


def _user_dict(u: User, admin_permissions: Optional[list] = None) -> dict:
    try:
        org = u.organization
    except Exception:
        org = None
    return {
        "id": str(u.id),
        "organization_id": str(u.organization_id),
        "full_name": u.full_name,
        "email": u.email,
        "phone": u.phone,
        "role": u.role,
        "status": u.status,
        "preferred_language": u.preferred_language,
        "preferred_currency": u.preferred_currency,
        "timezone": u.timezone,
        "is_platform_admin": u.is_platform_admin,
        "admin_permissions": admin_permissions or [],
        "email_verified": u.email_verified,
        "last_login_at": u.last_login_at.isoformat() if u.last_login_at else None,
        "created_at": u.created_at.isoformat() if u.created_at else None,
        "subscription": {
            "plan": org.subscription_plan if org else None,
            "status": org.subscription_status if org else None,
            "start_date": org.subscription_start_date.isoformat() if org and org.subscription_start_date else None,
            "end_date": org.subscription_end_date.isoformat() if org and org.subscription_end_date else None,
        },
    }


async def _user_permission_codes(db: AsyncSession, user: User) -> list:
    if not user.is_platform_admin:
        return []
    rows = await db.execute(
        select(AdminPermission).where(AdminPermission.user_id == user.id)
    )
    rows = list(rows.scalars().all())
    if not rows:
        return all_admin_permission_codes()
    return admin_permission_codes(rows)


@router.get("/admin/users")
async def list_users(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    search: Optional[str] = None,
    role: Optional[str] = None,
    status_filter: Optional[str] = Query(None, alias="status"),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_users", "read")),
):
    from sqlalchemy.orm import selectinload
    query = select(User).options(selectinload(User.organization))
    count_query = select(func.count(User.id))

    if search:
        pattern = f"%{search}%"
        query = query.where(or_(User.full_name.ilike(pattern), User.email.ilike(pattern)))
        count_query = count_query.where(or_(User.full_name.ilike(pattern), User.email.ilike(pattern)))
    if role:
        query = query.where(User.role == role)
        count_query = count_query.where(User.role == role)
    if status_filter:
        query = query.where(User.status == status_filter)
        count_query = count_query.where(User.status == status_filter)

    total_result = await db.execute(count_query)
    total = total_result.scalar() or 0

    query = query.order_by(desc(User.created_at)).offset((page - 1) * per_page).limit(per_page)
    result = await db.execute(query)
    users = result.scalars().all()

    perm_map: dict[str, list] = {}
    if users:
        rows = (
            await db.execute(
                select(AdminPermission).where(
                    AdminPermission.user_id.in_([u.id for u in users])
                )
            )
        ).scalars().all()
        for u in users:
            perm_map[str(u.id)] = admin_permission_codes(
                [r for r in rows if r.user_id == u.id]
            ) or (all_admin_permission_codes() if u.is_platform_admin else [])

    return ok({
        "users": [_user_dict(u, perm_map.get(str(u.id), [])) for u in users],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": max(1, (total + per_page - 1) // per_page),
    })


@router.post("/admin/users", status_code=201)
async def create_user(
    body: UserCreate,
    admin_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_users", "create")),
):
    from ...core.security import hash_password

    org_uuid = uuid.UUID(body.organization_id) if body.organization_id else None
    if org_uuid is None:
        # Fall back to the acting admin's organization (master key resolves to
        # the designated super-admin identity).
        admin = (await db.execute(select(User).where(User.id == admin_id))).scalar_one_or_none()
        org_uuid = admin.organization_id if admin else None
    if org_uuid is None:
        raise HTTPException(status_code=400, detail="organization_id مطلوب أو العب دور مشرف معرّف")

    # Check for duplicate email
    existing_user = (await db.execute(select(User).where(User.email == body.email))).scalar_one_or_none()
    if existing_user:
        raise HTTPException(status_code=409, detail="البريد الإلكتروني مستخدم بالفعل — لا يمكن إنشاء حساب آخر بنفس البريد")

    user = User(
        id=uuid.uuid4(),
        organization_id=org_uuid,
        full_name=body.full_name,
        email=body.email,
        phone=body.phone,
        role=body.role,
        auth_provider="email" if body.password else "firebase",
        password_hash=hash_password(body.password) if body.password else None,
        preferred_language=body.preferred_language,
        preferred_currency=body.preferred_currency,
        timezone=body.timezone,
        is_platform_admin=body.is_platform_admin,
        # Admin-created users are vouched for by the admin, so they may log in
        # immediately without a separate email-verification step.
        email_verified=True,
        status="active",
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    # Apply the requested section preset so the new admin starts with usable
    # permissions right away (personal | business | all).
    section = (body.admin_section or "").strip().lower()
    if section in _SECTION_PRESETS:
        codes = _SECTION_PRESETS[section]
        if codes and codes != all_admin_permission_codes():
            role_repo = SQLAlchemyRoleRepository(db)
            await role_repo.replace_admin_permissions(user.id, permission_codes_to_rows(codes))
    return created(_user_dict(user, await _user_permission_codes(db, user)))


@router.get("/admin/users/{user_id}")
async def get_user(user_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_users", "read"))):
    from sqlalchemy.orm import selectinload
    result = await db.execute(select(User).options(selectinload(User.organization)).where(User.id == uuid.UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")
    return ok(_user_dict(user, await _user_permission_codes(db, user)))


@router.put("/admin/users/{user_id}")
async def update_user(user_id: str, body: UserUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_users", "update"))):
    result = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(user, field, value)
    await db.commit()
    await db.refresh(user)
    return ok(_user_dict(user, await _user_permission_codes(db, user)))


@router.delete("/admin/users/{user_id}")
async def delete_user(user_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_users", "delete"))):
    result = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")
    await db.delete(user)
    await db.commit()
    return no_content()


# ════════════════════════════════════════════════════════════
#  ROLES MANAGEMENT (DB-backed)
# ════════════════════════════════════════════════════════════

class RoleCreate(BaseModel):
    name: str
    name_ar: Optional[str] = None
    organization_id: str
    is_system: bool = False

class RoleUpdate(BaseModel):
    name: Optional[str] = None
    name_ar: Optional[str] = None
    is_system: Optional[bool] = None


def _role_dict(r: Role) -> dict:
    return {
        "id": str(r.id),
        "organization_id": str(r.organization_id),
        "name": r.name,
        "name_ar": r.name_ar,
        "is_system": r.is_system,
        "created_at": r.created_at.isoformat() if r.created_at else None,
    }


@router.get("/admin/roles")
async def list_roles(
    organization_id: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_roles", "read")),
):
    query = select(Role)
    if organization_id:
        query = query.where(Role.organization_id == uuid.UUID(organization_id))
    query = query.order_by(desc(Role.created_at))
    result = await db.execute(query)
    roles = result.scalars().all()
    return ok({"roles": [_role_dict(r) for r in roles], "total": len(roles)})


@router.post("/admin/roles", status_code=201)
async def create_role(body: RoleCreate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_roles", "create"))):
    role = Role(
        id=uuid.uuid4(),
        organization_id=uuid.UUID(body.organization_id),
        name=body.name,
        name_ar=body.name_ar,
        is_system=body.is_system,
    )
    db.add(role)
    await db.commit()
    await db.refresh(role)
    return created(_role_dict(role))


@router.get("/admin/roles/{role_id}")
async def get_role(role_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_roles", "read"))):
    result = await db.execute(select(Role).where(Role.id == uuid.UUID(role_id)))
    role = result.scalar_one_or_none()
    if not role:
        raise HTTPException(status_code=404, detail="الدور غير موجود")
    return ok(_role_dict(role))


@router.put("/admin/roles/{role_id}")
async def update_role(role_id: str, body: RoleUpdate, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_roles", "update"))):
    result = await db.execute(select(Role).where(Role.id == uuid.UUID(role_id)))
    role = result.scalar_one_or_none()
    if not role:
        raise HTTPException(status_code=404, detail="الدور غير موجود")
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(role, field, value)
    await db.commit()
    await db.refresh(role)
    return ok(_role_dict(role))


@router.delete("/admin/roles/{role_id}")
async def delete_role(role_id: str, db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("admin_roles", "delete"))):
    result = await db.execute(select(Role).where(Role.id == uuid.UUID(role_id)))
    role = result.scalar_one_or_none()
    if not role:
        raise HTTPException(status_code=404, detail="الدور غير موجود")
    await db.delete(role)
    await db.commit()
    return no_content()


# ════════════════════════════════════════════════════════════
#  BRANCHES MANAGEMENT (in-memory)
# ════════════════════════════════════════════════════════════

_branches_store: list[dict] = []

class BranchCreate(BaseModel):
    name: str
    organization_id: str
    address: Optional[str] = None
    phone: Optional[str] = None
    is_active: bool = True

class BranchUpdate(BaseModel):
    name: Optional[str] = None
    address: Optional[str] = None
    phone: Optional[str] = None
    is_active: Optional[bool] = None


@router.get("/admin/branches")
async def list_branches(
    organization_id: Optional[str] = None,
    _=Depends(require_admin_perm("branches", "read")),
):
    results = _branches_store
    if organization_id:
        results = [b for b in results if b["organization_id"] == organization_id]
    return ok({"branches": results, "total": len(results)})


@router.post("/admin/branches", status_code=201)
async def create_branch(body: BranchCreate, _=Depends(require_admin_perm("branches", "create"))):
    branch = {
        "id": str(uuid.uuid4()),
        "name": body.name,
        "organization_id": body.organization_id,
        "address": body.address,
        "phone": body.phone,
        "is_active": body.is_active,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _branches_store.append(branch)
    return created(branch)


@router.put("/admin/branches/{branch_id}")
async def update_branch(branch_id: str, body: BranchUpdate, _=Depends(require_admin_perm("branches", "update"))):
    for b in _branches_store:
        if b["id"] == branch_id:
            for k, v in body.model_dump(exclude_none=True).items():
                b[k] = v
            b["updated_at"] = datetime.now(timezone.utc).isoformat()
            return ok(b)
    raise HTTPException(status_code=404, detail="الفرع غير موجود")


@router.delete("/admin/branches/{branch_id}")
async def delete_branch(branch_id: str, _=Depends(require_admin_perm("branches", "delete"))):
    global _branches_store
    before = len(_branches_store)
    _branches_store = [b for b in _branches_store if b["id"] != branch_id]
    if len(_branches_store) == before:
        raise HTTPException(status_code=404, detail="الفرع غير موجود")
    return no_content()


# ════════════════════════════════════════════════════════════
#  MODULES MANAGEMENT (in-memory)
# ════════════════════════════════════════════════════════════

_modules_store: list[dict] = [
    {"key": "invoicing", "name": "الفواتير", "name_en": "Invoicing", "enabled": True, "icon": "receipt"},
    {"key": "inventory", "name": "المخزون", "name_en": "Inventory", "enabled": True, "icon": "inventory"},
    {"key": "hr", "name": "الموارد البشرية", "name_en": "HR", "enabled": False, "icon": "people"},
    {"key": "payroll", "name": "الرواتب", "name_en": "Payroll", "enabled": False, "icon": "payments"},
    {"key": "crm", "name": "إدارة العملاء", "name_en": "CRM", "enabled": True, "icon": "contacts"},
    {"key": "accounting", "name": "المحاسبة", "name_en": "Accounting", "enabled": True, "icon": "account_balance"},
    {"key": "reports", "name": "التقارير", "name_en": "Reports", "enabled": True, "icon": "bar_chart"},
    {"key": "multi_branch", "name": "فروع متعددة", "name_en": "Multi-Branch", "enabled": False, "icon": "store"},
]

class ModuleUpdate(BaseModel):
    enabled: Optional[bool] = None
    name: Optional[str] = None
    name_en: Optional[str] = None


@router.get("/admin/modules")
async def list_modules(_=Depends(require_admin_perm("modules", "read"))):
    return ok({"modules": _modules_store})


@router.put("/admin/modules/{key}")
async def update_module(key: str, body: ModuleUpdate, _=Depends(require_admin_perm("modules", "update"))):
    for m in _modules_store:
        if m["key"] == key:
            for k, v in body.model_dump(exclude_none=True).items():
                m[k] = v
            m["updated_at"] = datetime.now(timezone.utc).isoformat()
            return ok(m)
    raise HTTPException(status_code=404, detail="الوحدة غير موجودة")


# ════════════════════════════════════════════════════════════
#  AUDIT / ACTIVITY LOGS (in-memory)
# ════════════════════════════════════════════════════════════

_audit_logs_store: list[dict] = []
_activity_logs_store: list[dict] = []


@router.get("/admin/audit-logs")
async def list_audit_logs(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    action: Optional[str] = None,
    user_id: Optional[str] = None,
    _=Depends(require_admin_perm("audit", "read")),
):
    results = _audit_logs_store
    if action:
        results = [r for r in results if r.get("action") == action]
    if user_id:
        results = [r for r in results if r.get("user_id") == user_id]
    total = len(results)
    start = (page - 1) * per_page
    end = start + per_page
    return ok({
        "logs": results[start:end],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": max(1, (total + per_page - 1) // per_page),
    })


@router.get("/admin/activity-logs")
async def list_activity_logs(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    type: Optional[str] = None,
    _=Depends(require_admin_perm("audit", "read")),
):
    results = _activity_logs_store
    if type:
        results = [r for r in results if r.get("type") == type]
    total = len(results)
    start = (page - 1) * per_page
    end = start + per_page
    return ok({
        "logs": results[start:end],
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": max(1, (total + per_page - 1) // per_page),
    })


# ════════════════════════════════════════════════════════════
#  EMAIL CONFIGURATION (shared with email_service)
# ════════════════════════════════════════════════════════════

from ...core.email_service import email_config as _email_config

class EmailConfigUpdate(BaseModel):
    smtp_host: Optional[str] = None
    smtp_port: Optional[int] = None
    smtp_user: Optional[str] = None
    smtp_password: Optional[str] = None
    smtp_from: Optional[str] = None
    smtp_tls: Optional[bool] = None

class EmailTestRequest(BaseModel):
    to: str
    subject: str = "Fyona Test Email"
    body: str = "This is a test email from Fyona admin panel."


@router.get("/admin/email/config")
async def get_email_config(_=Depends(require_admin_perm("email", "read"))):
    safe = {k: v for k, v in _email_config.items() if k != "smtp_password"}
    safe["smtp_password_configured"] = bool(_email_config.get("smtp_password"))
    return ok(safe)


@router.put("/admin/email/config")
async def update_email_config(body: EmailConfigUpdate, _=Depends(require_admin_perm("email", "update"))):
    for k, v in body.model_dump(exclude_none=True).items():
        if k == "smtp_password":
            # Password is managed via .env only — never editable from the panel.
            continue
        _email_config[k] = v
    _email_config["is_configured"] = bool(_email_config.get("smtp_host"))
    safe = {k: v for k, v in _email_config.items() if k != "smtp_password"}
    safe["smtp_password_configured"] = bool(_email_config.get("smtp_password"))
    return ok(safe)


@router.post("/admin/email/test")
async def test_email(body: EmailTestRequest, _=Depends(require_admin_perm("email", "update"))):
    if not _email_config.get("is_configured"):
        raise HTTPException(status_code=400, detail="البريد الإلكتروني غير مُعد")
    from ...core.email_service import send_email

    sent = await send_email(
        to=body.to,
        subject=body.subject,
        html=f"<p>{body.body}</p>",
        text=body.body,
    )
    if not sent:
        raise HTTPException(status_code=502, detail="فشل إرسال البريد، تحقق من إعدادات SMTP")
    return ok({
        "sent": True,
        "to": body.to,
        "subject": body.subject,
        "message": "تم إرسال بريد الاختبار بنجاح",
    })


# ════════════════════════════════════════════════════════════
#  BACKUPS MANAGEMENT (in-memory)
# ════════════════════════════════════════════════════════════

_backups_store: list[dict] = []

class BackupCreate(BaseModel):
    type: str = "full"
    description: Optional[str] = None


@router.get("/admin/backups")
async def list_backups(_=Depends(require_admin_perm("backups", "read"))):
    return ok({"backups": _backups_store, "total": len(_backups_store)})


@router.post("/admin/backups", status_code=201)
async def create_backup(body: BackupCreate, _=Depends(require_admin_perm("backups", "create"))):
    backup = {
        "id": str(uuid.uuid4()),
        "type": body.type,
        "description": body.description,
        "status": "completed",
        "size_mb": 0,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _backups_store.append(backup)
    return created(backup)


@router.post("/admin/backups/{backup_id}/restore")
async def restore_backup(backup_id: str, _=Depends(require_admin_perm("backups", "update"))):
    for b in _backups_store:
        if b["id"] == backup_id:
            b["restored_at"] = datetime.now(timezone.utc).isoformat()
            b["restore_status"] = "completed"
            return ok({"message": "تم استعادة النسخة الاحتياطية بنجاح", "backup": b})
    raise HTTPException(status_code=404, detail="النسخة الاحتياطية غير موجودة")


@router.delete("/admin/backups/{backup_id}")
async def delete_backup(backup_id: str, _=Depends(require_admin_perm("backups", "delete"))):
    global _backups_store
    before = len(_backups_store)
    _backups_store = [b for b in _backups_store if b["id"] != backup_id]
    if len(_backups_store) == before:
        raise HTTPException(status_code=404, detail="النسخة الاحتياطية غير موجودة")
    return no_content()


# ════════════════════════════════════════════════════════════
#  MAINTENANCE (in-memory)
# ════════════════════════════════════════════════════════════

_maintenance_tasks: list[dict] = [
    {"key": "clear_cache", "name": "مسح ذاكرة التخزين المؤقت", "name_en": "Clear Cache", "status": "idle"},
    {"key": "db_cleanup", "name": "تنظيف قاعدة البيانات", "name_en": "Database Cleanup", "status": "idle"},
    {"key": "reindex", "name": "إعادة فهرسة البيانات", "name_en": "Reindex Data", "status": "idle"},
    {"key": "optimize_storage", "name": "تحسين التخزين", "name_en": "Optimize Storage", "status": "idle"},
]

class MaintenanceTaskCreate(BaseModel):
    key: str
    name: str
    name_en: Optional[str] = None

class MaintenanceRunRequest(BaseModel):
    key: str


@router.get("/admin/maintenance")
async def list_maintenance_tasks(_=Depends(require_admin_perm("maintenance", "read"))):
    return ok({"tasks": _maintenance_tasks})


@router.post("/admin/maintenance", status_code=201)
async def create_maintenance_task(body: MaintenanceTaskCreate, _=Depends(require_admin_perm("maintenance", "create"))):
    task = {
        "key": body.key,
        "name": body.name,
        "name_en": body.name_en,
        "status": "idle",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _maintenance_tasks.append(task)
    return created(task)


@router.post("/admin/maintenance/run")
async def run_maintenance_task(body: MaintenanceRunRequest, _=Depends(require_admin_perm("maintenance", "update"))):
    for t in _maintenance_tasks:
        if t["key"] == body.key:
            t["status"] = "running"
            t["last_run"] = datetime.now(timezone.utc).isoformat()
            t["status"] = "completed"
            return ok({"message": f"تم تشغيل المهمة: {t['name']}", "task": t})
    raise HTTPException(status_code=404, detail="المهمة غير موجودة")


# ════════════════════════════════════════════════════════════
#  ADMIN HEALTH
# ════════════════════════════════════════════════════════════

@router.get("/admin/health")
async def admin_health(db: AsyncSession = Depends(get_db), _=Depends(require_admin_perm("health", "read"))):
    db_ok = True
    try:
        await db.execute(select(func.count(User.id)))
    except Exception:
        db_ok = False

    return ok({
        "status": "healthy" if db_ok else "degraded",
        "database": "connected" if db_ok else "error",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": "1.0.0",
    })


# ════════════════════════════════════════════════════════════
#  SYSTEM INFO
# ════════════════════════════════════════════════════════════

import platform
import os
import time

_start_time = time.time()


@router.get("/admin/system/info")
async def system_info(_=Depends(require_admin_perm("system", "read"))):
    """Return system info: version, uptime, disk usage, memory."""
    uptime_seconds = int(time.time() - _start_time)
    hours, remainder = divmod(uptime_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)

    disk_total = 0
    disk_used = 0
    disk_free = 0
    try:
        import shutil
        usage = shutil.disk_usage("/")
        disk_total = usage.total // (1024 ** 3)
        disk_used = usage.used // (1024 ** 3)
        disk_free = usage.free // (1024 ** 3)
    except Exception:
        pass

    memory_total = 0
    memory_available = 0
    try:
        import psutil
        mem = psutil.virtual_memory()
        memory_total = mem.total // (1024 ** 2)
        memory_available = mem.available // (1024 ** 2)
    except ImportError:
        pass

    return ok({
        "version": "1.0.0",
        "platform": platform.system(),
        "platform_version": platform.version(),
        "python_version": platform.python_version(),
        "hostname": platform.node(),
        "uptime_seconds": uptime_seconds,
        "uptime_human": f"{hours}h {minutes}m {seconds}s",
        "disk": {
            "total_gb": disk_total,
            "used_gb": disk_used,
            "free_gb": disk_free,
        },
        "memory": {
            "total_mb": memory_total,
            "available_mb": memory_available,
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


# ════════════════════════════════════════════════════════════
#  PLATFORM ADMIN PERMISSIONS MANAGEMENT
# ════════════════════════════════════════════════════════════

# Preset permission codes for new admins by working section.
_RESOURCE_ACTIONS = ADMIN_PERMISSIONS
_SECTION_PRESETS: dict[str, list[str]] = {
    "all": all_admin_permission_codes(),
    "personal": [
        *[f"{r}:{a}" for r in ("dashboard", "notifications") for a in _RESOURCE_ACTIONS[r]],
        *[f"{r}:{a}" for r in ("banners", "exchange_rates", "personal_finance", "suggestions") for a in _RESOURCE_ACTIONS[r]],
        "audit:read",
    ],
    "business": [
        *[f"{r}:{a}" for r in ("dashboard", "plans", "subscription_requests", "accounting") for a in _RESOURCE_ACTIONS[r]],
        *[f"{r}:{a}" for r in ("organizations", "admin_users", "admin_roles", "branches") for a in _RESOURCE_ACTIONS[r]],
        *[f"{r}:{a}" for r in ("admin_controls", "admin_settings", "currencies", "modules", "email", "backups", "maintenance", "export") for a in _RESOURCE_ACTIONS[r]],
        "audit:read", "health:read", "system:read",
    ],
}

class AdminPermissionEntry(BaseModel):
    resource: str
    actions: list[str]


class AdminPermissionsUpdate(BaseModel):
    is_platform_admin: bool
    permissions: list[AdminPermissionEntry] = []


@router.get("/admin/admin-permissions/catalog")
async def get_admin_permissions_catalog(
    _=Depends(require_admin_perm("admin_permissions", "read")),
):
    return ok({"catalog": ADMIN_PERMISSIONS, "actions": list(ADMIN_ACTIONS)})


@router.get("/admin/admin-permissions")
async def list_admin_permissions(
    search: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_permissions", "read")),
):
    query = select(User).where(User.is_platform_admin == True)
    if search:
        pattern = f"%{search}%"
        query = query.where(
            or_(User.full_name.ilike(pattern), User.email.ilike(pattern))
        )
    result = await db.execute(query.order_by(desc(User.created_at)))
    users = result.scalars().all()

    perm_map: dict[str, list] = {}
    if users:
        rows = (
            await db.execute(
                select(AdminPermission).where(
                    AdminPermission.user_id.in_([u.id for u in users])
                )
            )
        ).scalars().all()
        for u in users:
            perm_map[str(u.id)] = admin_permission_codes(
                [r for r in rows if r.user_id == u.id]
            ) or all_admin_permission_codes()

    return ok({
        "users": [
            {
                "id": str(u.id),
                "full_name": u.full_name,
                "email": u.email,
                "is_platform_admin": u.is_platform_admin,
                "admin_permissions": perm_map.get(str(u.id), []),
            }
            for u in users
        ],
        "total": len(users),
    })


@router.put("/admin/admin-permissions/{user_id}")
async def update_admin_permissions(
    user_id: str,
    body: AdminPermissionsUpdate,
    db: AsyncSession = Depends(get_db),
    _=Depends(require_admin_perm("admin_permissions", "update")),
):
    result = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")

    role_repo = SQLAlchemyRoleRepository(db)

    if not body.is_platform_admin:
        user.is_platform_admin = False
        await role_repo.replace_admin_permissions(user.id, [])
        await db.commit()
        return ok({
            "id": str(user.id),
            "is_platform_admin": False,
            "admin_permissions": [],
        })

    codes = [f"{p.resource}:{a}" for p in body.permissions for a in p.actions]
    if not codes:
        raise HTTPException(
            status_code=400, detail="حدد صلاحية واحدة على الأقل للمشرف"
        )
    for p in body.permissions:
        for action in p.actions:
            if not is_valid_admin_permission(p.resource, action):
                raise HTTPException(
                    status_code=400,
                    detail=f"صلاحية غير معروفة: {p.resource}:{action}",
                )

    user.is_platform_admin = True
    await role_repo.replace_admin_permissions(user.id, permission_codes_to_rows(codes))
    await db.commit()

    return ok({
        "id": str(user.id),
        "is_platform_admin": True,
        "admin_permissions": sorted(set(codes)),
    })
