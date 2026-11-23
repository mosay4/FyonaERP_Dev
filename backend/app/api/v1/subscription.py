import json
import os
import uuid as uuid_lib
from datetime import datetime, timedelta, timezone
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, Form, HTTPException, UploadFile, status, File
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.logging import get_logger
from app.core.paths import UPLOAD_ROOT
from app.core.phone_validation import is_valid_phone
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.admin_entities import Plan
from app.domain.entities.notification_entities import AppNotification
from app.api.deps import get_current_user_uuid, get_current_org_id
from app.api.responses import ok

router = APIRouter(prefix="/subscription", tags=["Subscription"])
logger = get_logger("subscription_api")

TRIAL_HOURS = 24

TRIAL_DURATION_DEFAULT = {"unit": "hours", "value": 24, "hours": 24, "days": 1}


def _normalize_trial_unit(raw) -> str:
    u = str(raw or "").strip().lower()
    if u in ("days", "day", "d"):
        return "days"
    if u in ("weeks", "week", "w"):
        return "weeks"
    if u in ("months", "month", "mo"):
        return "months"
    return "hours"


def _trial_value(cfg: dict) -> tuple:
    """Return a normalized ``(unit, value)`` from the admin trial config.

    Supports the new ``unit`` + ``value`` shape (hours | days | weeks |
    months) and keeps backward compatibility with the legacy ``hours`` /
    ``days`` keys previously used by the admin web.
    """
    unit = _normalize_trial_unit(cfg.get("unit"))
    raw = cfg.get("value")
    if raw is None:
        # Legacy fallback: an explicit hours/days key overrides the unit.
        if unit == "hours" and cfg.get("hours") is not None:
            raw = cfg.get("hours")
        elif unit == "days" and cfg.get("days") is not None:
            raw = cfg.get("days")
    try:
        value = max(int(float(raw)), 1)
    except (TypeError, ValueError):
        value = 24 if unit == "hours" else 1
    return unit, value


def _trial_delta(cfg: dict) -> timedelta:
    unit, value = _trial_value(cfg)
    if unit == "days":
        return timedelta(days=value)
    if unit == "weeks":
        return timedelta(weeks=value)
    if unit == "months":
        return timedelta(days=value * 30)
    return timedelta(hours=value)


_AR_TRIAL_WORD = {
    "hours": lambda v: "ساعة واحدة" if v == 1 else ("ساعتان" if v == 2 else ("ساعات" if v <= 10 else "ساعة")),
    "days": lambda v: "يوم واحد" if v == 1 else ("يومان" if v == 2 else ("أيام" if v <= 10 else "يوماً")),
    "weeks": lambda v: "أسبوع واحد" if v == 1 else ("أسبوعان" if v == 2 else ("أسابيع" if v <= 10 else "أسبوعاً")),
    "months": lambda v: "شهر واحد" if v == 1 else ("شهران" if v == 2 else ("أشهر" if v <= 10 else "شهراً")),
}


def _trial_duration_label(cfg: dict) -> str:
    """Human label for the configured trial duration: '7 أيام', '3 ساعات', ..."""
    unit, value = _trial_value(cfg)
    word = _AR_TRIAL_WORD[unit](value)
    if value == 1:
        return word
    return f"لمدة {value} {word}"


async def _get_org(org_id: str, db: AsyncSession) -> Organization:
    result = await db.execute(select(Organization).where(Organization.id == UUID(org_id)))
    org = result.scalar_one_or_none()
    if not org:
        raise HTTPException(status_code=404, detail="المؤسسة غير موجودة")
    return org


async def _controls_trial_allowed(db: AsyncSession) -> tuple:
    """(trial_enabled, force_paid, trial_cfg) from platform controls (admin web)."""
    try:
        from app.api.v1.admin import _settings_svc
        ctrl = await _settings_svc(db).get_controls()
        trial_cfg = ctrl.get("trial") or {}
        return (
            trial_cfg.get("enabled", True),
            bool(ctrl.get("force_paid_subscription")),
            trial_cfg,
        )
    except Exception:
        return True, False, dict(TRIAL_DURATION_DEFAULT)


async def _calc_status(org: Organization, db: AsyncSession) -> dict:
    from app.domain.services.section_entitlements import access_snapshot, active_subscriptions
    # Controls are fetched ONCE and shared: the legacy body and the access
    # overlay must not double the DB round-trips (mocked callers stub exact
    # counts, and hot paths stay cheap).
    trial_enabled, force_paid, trial_cfg_full = await _controls_trial_allowed(db)
    result = await _calc_legacy_status(
        org, db, (trial_enabled, force_paid, trial_cfg_full)
    )
    result["request_status"] = result.get("status")
    access = access_snapshot(org, trial_allowed=trial_enabled and not force_paid)
    active = active_subscriptions(org)
    if active:
        key = org.subscription_plan if org.subscription_plan in active else next(iter(active))
        entry = active[key]
        result.update(status="active", plan_name=key, plan_id=_plan_name_to_id(key),
                      is_trial=False, start_date=entry.get("start_date"), end_date=entry["end_date"])
    result.update(access)
    return result


async def _calc_legacy_status(
    org: Organization, db: AsyncSession, controls: tuple | None = None
) -> dict:
    now = datetime.now(timezone.utc)
    if controls is None:
        trial_enabled, force_paid, trial_cfg = await _controls_trial_allowed(db)
    else:
        trial_enabled, force_paid, trial_cfg = controls
    # Latest paid invoice (used to render the subscription invoice fully:
    # amount, currency, payment method, period, invoice number).
    invoice: Optional[dict] = None
    try:
        from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
        inv_row = (
            await db.execute(
                select(SubscriptionInvoice)
                .where(SubscriptionInvoice.organization_id == org.id)
                .order_by(SubscriptionInvoice.created_at.desc())
                .limit(1)
            )
        ).scalar_one_or_none()
        if inv_row is not None:
            bank_name = None
            try:
                from app.domain.entities.admin_entities import (
                    PlatformBankAccount,
                    SubscriptionRequest,
                    SubscriptionRevenue,
                )
                from sqlalchemy import select as _sel
                rev = (
                    await db.execute(
                        _sel(SubscriptionRevenue)
                        .where(SubscriptionRevenue.request_id == inv_row.request_id)
                        .order_by(SubscriptionRevenue.created_at.desc())
                        .limit(1)
                    )
                ).scalar_one_or_none()
                if rev is not None and rev.bank_account_id:
                    bank = (
                        await db.execute(
                            _sel(PlatformBankAccount).where(
                                PlatformBankAccount.id == rev.bank_account_id
                            )
                        )
                    ).scalar_one_or_none()
                    if bank is not None:
                        bank_name = bank.bank_name or None
            except Exception:  # noqa: BLE001
                bank_name = None
            invoice = {
                "invoice_number": inv_row.invoice_number,
                "amount": float(inv_row.amount or 0),
                "currency": inv_row.currency or "SAR",
                "payment_method": inv_row.payment_method or "bank_transfer",
                "period": inv_row.period or "yearly",
            }
            if bank_name:
                invoice["bank_name"] = bank_name
            if inv_row.bank_name:
                invoice["bank_name"] = inv_row.bank_name
            if getattr(inv_row, "card_brand", None):
                invoice["card_brand"] = inv_row.card_brand
    except Exception:
        invoice = None

    if org.subscription_status == "active" and org.subscription_end_date:
        end = org.subscription_end_date if org.subscription_end_date.tzinfo else org.subscription_end_date.replace(tzinfo=timezone.utc)
        if end > now:
            remaining = (end - now).days
            result = {
                "status": "active",
                "plan_id": _plan_name_to_id(org.subscription_plan),
                "plan_name": org.subscription_plan,
                "is_trial": org.subscription_plan == "trial",
                "start_date": org.subscription_start_date.isoformat() if org.subscription_start_date else None,
                "end_date": org.subscription_end_date.isoformat() if org.subscription_end_date else None,
                "days_remaining": remaining,
            }
            if invoice:
                result["invoice_number"] = invoice["invoice_number"]
                result["plan_price"] = invoice["amount"]
                result["currency"] = invoice["currency"]
                result["payment_method"] = invoice["payment_method"]
                result["period"] = invoice["period"]
                if invoice.get("bank_name"):
                    result["bank_name"] = invoice["bank_name"]
                if invoice.get("card_brand"):
                    result["card_brand"] = invoice["card_brand"]
            return result

    # A cancelled subscription is frozen immediately: the app must force
    # re-subscription regardless of any leftover end date.
    if org.subscription_status == "cancelled":
        return {
            "status": "expired",
            "plan_id": _plan_name_to_id(org.subscription_plan),
            "plan_name": org.subscription_plan,
            "is_trial": False,
            "days_remaining": 0,
            "end_date": org.subscription_end_date.isoformat() if org.subscription_end_date else None,
        }

    # A paid subscription that has passed its end date → the account is frozen
    # and the user must renew (never silently downgraded to "pending").
    if org.subscription_end_date and org.subscription_plan and org.subscription_plan != "trial":
        end = org.subscription_end_date if org.subscription_end_date.tzinfo else org.subscription_end_date.replace(tzinfo=timezone.utc)
        if end <= now:
            return {
                "status": "expired",
                "plan_id": _plan_name_to_id(org.subscription_plan),
                "plan_name": org.subscription_plan,
                "is_trial": False,
                "days_remaining": 0,
                "end_date": org.subscription_end_date.isoformat() if org.subscription_end_date else None,
            }

    # Trial only counts while the admin left the trial ON and paid is not forced.
    # A user with a pending/rejected paid request must NEVER be reported as
    # `active` from a leftover trial — the admin review owns that decision.
    if org.trial_end_date and org.subscription_status not in ("pending", "rejected") \
            and trial_enabled and not force_paid:
        tend = org.trial_end_date if org.trial_end_date.tzinfo else org.trial_end_date.replace(tzinfo=timezone.utc)
        if tend > now:
            remaining_hours = int((tend - now).total_seconds() // 3600)
            remaining_mins = int((tend - now).total_seconds() // 60)
            dur_unit, dur_value = _trial_value(dict(trial_cfg))
            return {
                "status": "active",
                "plan_id": None,
                "plan_name": "trial",
                "is_trial": True,
                "start_date": org.subscription_start_date.isoformat() if org.subscription_start_date else None,
                "end_date": org.trial_end_date.isoformat() if org.trial_end_date else None,
                "days_remaining": max(remaining_hours // 24, 1) if remaining_hours > 0 else 0,
                "hours_remaining": remaining_hours,
                "minutes_remaining": remaining_mins,
                "duration_value": dur_value,
                "duration_unit": dur_unit,
                "duration_label": _trial_duration_label(dict(trial_cfg)),
            }

    # Not on trial and not active — resolve the review state from the latest
    # subscription request so the app can surface an approval / rejection result
    # instead of staying on the "waiting" screen forever.
    last_req = None
    try:
        from app.domain.entities.admin_entities import SubscriptionRequest as _SubReq
        last_req = (
            await db.execute(
                select(_SubReq)
                .where(_SubReq.organization_id == org.id)
                .order_by(_SubReq.created_at.desc())
                .limit(1)
            )
        ).scalar_one_or_none()
    except Exception:  # noqa: BLE001
        last_req = None

    if last_req is not None and last_req.status == "rejected":
        return {
            "status": "rejected",
            "plan_id": None,
            "plan_name": last_req.plan_name,
            "is_trial": False,
            "days_remaining": 0,
            "request_id": str(last_req.id),
            "rejection_reason": last_req.rejection_reason or "",
        }

    if last_req is not None and last_req.status == "pending":
        return {
            "status": "pending",
            "plan_id": None,
            "plan_name": last_req.plan_name,
            "is_trial": False,
            "days_remaining": 0,
            "request_id": str(last_req.id),
        }

    # No pending/rejected request, no active trial, no paid subscription:
    # this is a brand-new account that has NEVER subscribed. Report `none`
    # (not `pending`) so the app offers the plans/trial CTA instead of
    # showing a phantom "your request is under review" waiting screen.
    return {
        "status": "none",
        "plan_id": None,
        "plan_name": None,
        "is_trial": False,
        "days_remaining": 0,
    }


def _package_type_from_name(name_en: str | None, name_ar: str | None = None) -> str | None:
    """Canonical package type from plan names: free|personal|business|premium."""
    for cand in (name_en or "", name_ar or ""):
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


def _plan_name_to_id(name: str | None) -> int | None:
    mapping = {"personal": 1, "business": 2, "premium": 3, "trial": None, "free": 0}
    return mapping.get(name) if name else None


def _plan_id_to_name(plan_id: int) -> str:
    mapping = {0: "free", 1: "personal", 2: "business", 3: "premium"}
    return mapping.get(plan_id, "personal")


@router.get("/status")
async def get_status(
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    org = await _get_org(org_id, db)
    return ok(await _calc_status(org, db))


@router.get("/plans")
async def get_plans(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Plan).where(Plan.is_active == True).order_by(Plan.created_at.asc())
    )
    plans = result.scalars().all()
    items = []
    for p in plans:
        if p.name_en and p.name_en.lower() == "free plan":
            continue
        feats = []
        if p.features:
            try:
                import json
                feats = json.loads(p.features) if isinstance(p.features, str) else p.features
            except Exception:
                feats = []
        items.append({
            "id": str(p.id),
            "name": p.name,
            "description": p.description or "",
            "package_type": (p.package_type or _package_type_from_name(p.name_en, p.name) or "personal"),
            "duration_days": p.duration_days or 365,
            "price_monthly": p.price_monthly or 0,
            "price_yearly": p.price_yearly or 0,
            "currency": p.currency or "SAR",
            "features": feats,
            "color": p.color or "#A01530",
            "icon": p.icon or "star",
            "is_active": p.is_active,
            "updated_at": p.updated_at.isoformat() if p.updated_at else None,
        })
    if not items:
        items = _fallback_plans()
    return ok(items)


@router.post("/business-setup/complete")
async def complete_business_setup(
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    org = await _get_org(org_id, db)
    snapshot = await _calc_status(org, db)
    if not snapshot["sections"]["business"]["active"]:
        raise HTTPException(status_code=403, detail="Business subscription required")
    # Questions are intentionally deferred. Store completion per account,
    # not per device, so login/reinstall does not repeat the empty wizard.
    org.business_setup_completed = True
    await db.commit()
    return ok({"business_setup_completed": True})


def _fallback_plans():
    # Fallback reflects the current admin pricing (USD base).
    # Real prices ALWAYS come from the DB via the query above; this fallback
    # is only used if the DB is truly empty and never masks admin updates.
    return [
        {"id": "1", "name": "باقة شخصية", "description": "لإدارة أموالك الشخصية", "package_type": "personal", "duration_days": 365, "price_monthly": 0, "price_yearly": 13, "currency": "USD", "features": ["المحفظة الشخصية", "تسجيل المصاريف", "الأهداف الادخارية", "التقارير المالية"], "color": "#1565C0", "icon": "person", "is_active": True},
        {"id": "2", "name": "باقة أعمال", "description": "لإدارة أعمالك", "package_type": "business", "duration_days": 365, "price_monthly": 0, "price_yearly": 15, "currency": "USD", "features": ["إدارة العملاء والموردين", "الفواتير", "حسابات البنوك", "المصروفات"], "color": "#A01530", "icon": "business", "is_active": True},
        {"id": "3", "name": "باقة أعمال + شخصي", "description": "تجمع الباقة الشخصية وباقة الأعمال", "package_type": "premium", "duration_days": 365, "price_monthly": 0, "price_yearly": 18.3, "currency": "USD", "features": ["جميع مزايا شخصي وأعمال", "التحليلات المتقدمة", "لوحة موحدة", "أولوية الدعم الفني"], "color": "#FFD700", "icon": "crown", "is_active": True},
    ]


@router.get("/plans/{plan_id}")
async def get_plan(plan_id: str, db: AsyncSession = Depends(get_db)):
    try:
        result = await db.execute(select(Plan).where(Plan.id == uuid_lib.UUID(plan_id)))
        plan = result.scalar_one_or_none()
    except Exception:
        plan = None
    if not plan:
        raise HTTPException(status_code=404, detail="الباقة غير موجودة")
    feats = []
    if plan.features:
        try:
            import json
            feats = json.loads(plan.features) if isinstance(plan.features, str) else plan.features
        except Exception:
            feats = []
    return ok({
        "id": str(plan.id),
        "name": plan.name,
        "description": plan.description or "",
        "package_type": (plan.package_type or _package_type_from_name(plan.name_en, plan.name) or "personal"),
        "duration_days": plan.duration_days or 365,
        "price_monthly": plan.price_monthly or 0,
        "price_yearly": plan.price_yearly or 0,
        "currency": plan.currency or "SAR",
        "features": feats,
        "color": plan.color or "#A01530",
        "icon": plan.icon or "star",
        "is_active": plan.is_active,
        "updated_at": plan.updated_at.isoformat() if plan.updated_at else None,
    })


@router.post("/trial")
async def activate_trial(
    body: dict | None = None,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    org = await _get_org(org_id, db)
    now = datetime.now(timezone.utc)

    # Respect platform controls (admin): trial enabled + duration.
    trial_cfg = dict(TRIAL_DURATION_DEFAULT)
    try:
        from app.domain.services.admin_settings_service import AdminSettingsService
        from app.api.v1.admin import _settings_svc as _svc
        ctrl = await _svc(db).get_controls()
        trial_cfg = (ctrl.get("trial") or {})
        if not trial_cfg.get("enabled", True):
            raise HTTPException(status_code=403, detail="الفترة التجريبية معطلة حالياً من الإدارة")
        force_paid = ctrl.get("force_paid_subscription", False)
        if force_paid:
            raise HTTPException(status_code=403, detail="الاشتراك التجريبي غير متاح — يلزم اشتراك مدفوع")
        trial_delta = _trial_delta(trial_cfg)
        duration_label = _trial_duration_label(trial_cfg)
    except HTTPException:
        raise
    except Exception:
        trial_delta = timedelta(hours=TRIAL_HOURS)
        duration_label = _trial_duration_label(TRIAL_DURATION_DEFAULT)

    if org.trial_end_date:
        tend = org.trial_end_date if org.trial_end_date.tzinfo else org.trial_end_date.replace(tzinfo=timezone.utc)
        if tend > now:
            remaining_hours = int((tend - now).total_seconds() // 3600)
            return ok({
                "success": True,
                "message": "الفترة التجريبية نشطة بالفعل",
                "hours_remaining": remaining_hours,
            })
    # Free plan is offered ONCE per account, forever: the durable marker is
    # raised on trial activation and on every paid activation path and is
    # never cleared — cancellations/reinstalls/admin toggles can't reopen it.
    if getattr(org, "has_used_free_plan", False) or org.trial_end_date:
        raise HTTPException(
            status_code=400,
            detail="انتهت الفترة التجريبية، يمكن تفعيل الباقة المجانية مرة واحدة فقط",
        )

    # Phone is now collected mandatorily right after choosing usage mode
    # (choose_usage → phone_entry), so the trial activation itself no longer
    # blocks on phone. Keep a soft log for observability but never reject.
    try:
        _u = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
        if _u is not None and not is_valid_phone(_u.phone, region=_u.phone_country or "SA"):
            logger.info("trial_without_phone", user_id=str(user_id), org_id=org_id)
    except Exception:
        pass

    org.subscription_status = "trial"
    org.subscription_plan = "trial"
    org.subscription_start_date = now
    org.trial_end_date = now + trial_delta
    org.subscription_end_date = org.trial_end_date
    org.has_used_free_plan = True
    await db.commit()
    await db.refresh(org)

    # Unified welcome: exactly one in-app row + one FCM push per real
    # trial activation (exact frozen copy, idempotent via source_notif_id).
    # DB row stays first inside the helper, then the push; each guarded
    # separately there.  Best-effort: must never break the activation itself.
    try:
        from app.domain.services.subscription_welcome import (
            send_subscription_welcome as _send_welcome,
        )

        await _send_welcome(db, user_id=user_id, org_id=org.id, event="trial")
    except Exception as exc:  # noqa: BLE001
        logger.warning("trial_welcome_notify_failed", user_id=str(user_id),
                       org_id=str(org_id), error=str(exc))

    dur_unit, dur_value = _trial_value(trial_cfg)
    logger.info("trial_activated", user_id=str(user_id), org_id=org_id)
    return ok({
        "message": f"تم تفعيل الفترة التجريبية {duration_label}",
        "hours_remaining": int(trial_delta.total_seconds() // 3600),
        "duration_value": dur_value,
        "duration_unit": dur_unit,
        "duration_label": duration_label,
    })


@router.post("/subscribe")
async def subscribe(
    plan_id: int = Form(...),
    period: str = Form("yearly"),
    currency: str = Form(""),       # currency the user selected at checkout
    amount: float = Form(0.0),      # optional: exact paid amount in that currency
    proof_image: UploadFile | None = File(None),
    proof_images: List[UploadFile] | None = File(None),
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    if plan_id not in [1, 2, 3]:
        raise HTTPException(status_code=400, detail="باقة غير صالحة")
    if period not in ("yearly", "monthly"):
        raise HTTPException(status_code=400, detail="فترة اشتراك غير صالحة")
    currency = (currency or "").strip().upper()
    if currency not in {"SAR", "USD", "EUR", "YER_OLD", "YER_NEW", "AED", "EGP", "KWD", "QAR", "BHD", "OMR", "TRY"}:
        currency = "SAR"

    # Guards BEFORE any file upload: single active subscription + one
    # PENDING request per org (no duplicate receipts on disk either).
    _guard_org = await _get_org(org_id, db)
    _now_guard = datetime.now(timezone.utc)
    from app.domain.services.section_entitlements import validate_purchase, subscriptions
    try:
        validate_purchase(_guard_org, _plan_id_to_name(plan_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    # Preserve existing paid periods before the legacy pending projection changes.
    _guard_org.section_subscriptions = subscriptions(_guard_org)
    from app.domain.entities.admin_entities import SubscriptionRequest as _SubReqGuard
    _has_pending = (
        await db.execute(
            select(_SubReqGuard.id)
            .where(
                _SubReqGuard.organization_id == _guard_org.id,
                _SubReqGuard.status == "pending",
            )
            .limit(1)
        )
    ).scalar_one_or_none()
    if _has_pending is not None:
        raise HTTPException(
            status_code=400,
            detail="لديك طلب اشتراك قيد المراجعة حالياً",
        )

    # ── Save ALL proof files (single legacy `proof_image` + list `proof_images`) ──
    allowed_ext = {".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif", ".avif"}
    files: list = []
    if proof_image and proof_image.filename:
        files.append(proof_image)
    if proof_images:
        files.extend(proof_images)

    proof_paths: list = []
    mirror_tasks: list = []

    def _write_file_sync(path: str, data: bytes) -> None:
        with open(path, "wb") as fh:
            fh.write(data)

    async def _save_one(upload: UploadFile) -> None:
        ext = os.path.splitext(upload.filename or "")[1].lower()
        if ext not in allowed_ext:
            raise HTTPException(status_code=400, detail=f"صيغة الملف غير مدعومة: {upload.filename or ''}")
        try:
            content = await upload.read()
        except Exception:
            logger.warning("proof_read_failed", filename=upload.filename)
            raise HTTPException(status_code=400, detail="تعذر قراءة ملف الإثبات")
        if not content:
            raise HTTPException(status_code=400, detail="الملف المرفق فارغ")
        if len(content) > 5 * 1024 * 1024:
            raise HTTPException(status_code=400, detail="حجم الصورة يتجاوز الحد المسموح (5 ميجابايت)")
        upload_dir = os.path.join(UPLOAD_ROOT, "subscription_proofs")
        os.makedirs(upload_dir, exist_ok=True)
        proof_filename = f"{org_id}_{uuid_lib.uuid4().hex}{ext}"
        # Persist to LOCAL DISK without blocking the event loop — use a
        # thread-pool write so concurrent uploads stay fast even under load.
        filepath = os.path.join(upload_dir, proof_filename)
        try:
            import asyncio as _aio
            await _aio.to_thread(_write_file_sync, filepath, content)
        except OSError as exc:
            logger.warning("proof_disk_failed", filename=proof_filename, error=str(exc))
            raise HTTPException(status_code=500, detail="تعذر حفظ صورة الإثبات على الخادم")
        proof_paths.append(f"subscription_proofs/{proof_filename}")
        # S3/MinIO mirror is best-effort and OFF the request path: it runs in a
        # background task so a slow/unreachable object store can never delay the
        # response to the user.
        try:
            import asyncio as _asyncio
            from app.core.storage import unified_upload as _uu
            mirror_tasks.append(
                _asyncio.create_task(
                    _mirror_proof(_uu, "subscription_proofs", proof_filename, content, f"image/{ext.lstrip('.')}")
                )
            )
        except Exception:
            pass
        logger.info("proof_saved", path=proof_filename, filename=upload.filename, size=len(content))

    async def _mirror_proof(upload_fn, category: str, filename: str, content: bytes, content_type: str) -> None:
        try:
            await upload_fn(category, filename, content, content_type)
        except Exception:  # noqa: BLE001 - best-effort mirror
            logger.warning("proof_s3_skipped", filename=filename)

    # Save all proofs concurrently — was sequential and blocked the event loop.
    if files:
        import asyncio as _asyncio2
        await _asyncio2.gather(*[_save_one(u) for u in files])

    proof_path = proof_paths[0] if proof_paths else None

    org = _guard_org
    now = datetime.now(timezone.utc)
    plan_name = _plan_id_to_name(plan_id)

    if period == "yearly":
        end_date = now + timedelta(days=365)
    else:
        end_date = now + timedelta(days=30)

    # ── Server-side price validation: always use DB plan price, never trust client amount ──
    from app.domain.entities.admin_entities import Plan as _Plan
    _db_plan = None
    result_legacy = await db.execute(select(_Plan).order_by(_Plan.created_at.asc()))
    _plans_list = list(result_legacy.scalars().all())
    idx = plan_id - 1
    if 0 <= idx < len(_plans_list):
        _db_plan = _plans_list[idx]
    if _db_plan is not None:
        server_amount = float(_db_plan.price_yearly or 0) if period == "yearly" else float(_db_plan.price_monthly or 0)
        if server_amount <= 0:
            server_amount = float(_db_plan.price_yearly or 0)
        server_currency = _db_plan.currency or currency or "SAR"
    else:
        server_amount = 0.0
        server_currency = currency

    # Set status to pending until admin reviews.
    # IMPORTANT: clear any running free trial NOW. Otherwise `_calc_status`
    # keeps reporting `active` (from the still-valid trial) and the waiting
    # screen instantly bounces the user to the invoice — a phantom activation
    # without admin approval. A paid request supersedes the trial: the admin
    # review exclusively decides the final state.
    org.subscription_status = "pending"
    org.subscription_plan = plan_name
    org.has_used_free_plan = True
    if org.trial_end_date:
        org.trial_end_date = None
    # A leftover trial had set subscription_end_date too (activation writes it).
    # While the paid request is PENDING the admin owns the timeline — clear it
    # so `_calc_status` can NEVER confuse a pending request with an active plan.
    if org.subscription_plan != "trial":
        org.subscription_end_date = None
        org.subscription_start_date = None
    # Override currency with server-validated value
    currency = server_currency if server_currency else currency
    await db.commit()

    # Create subscription request in database (server-validated currency, never trust client)
    from sqlalchemy import text
    proof_images_json = json.dumps(proof_paths, ensure_ascii=False)
    try:
        await db.execute(text("""
            INSERT INTO subscription_requests (id, user_id, organization_id, plan_id, plan_name, status, message, proof_image, proof_images, period, currency, created_at)
            VALUES (gen_random_uuid(), :user_id, :org_id, :plan_id, :plan_name, 'pending', :message, :proof_image, :proof_images, :period, :currency, NOW())
        """), {
            "user_id": str(user_id),
            "org_id": org_id,
            "plan_id": str(plan_id),
            "plan_name": plan_name,
            "message": None,
            "proof_image": proof_path,
            "proof_images": proof_images_json,
            "period": period,
            "currency": currency,
        })
        await db.commit()
    except IntegrityError:
        # Race with another pending request (partial unique index).
        await db.rollback()
        raise HTTPException(
            status_code=400,
            detail="لديك طلب اشتراك قيد المراجعة حالياً",
        )
    except Exception:
        logger.exception("subscription_request_insert_failed", user_id=str(user_id), org_id=org_id)
        raise HTTPException(status_code=500, detail="تعذر حفظ طلب الاشتراك، حاول مرة أخرى")

    # Notify every active platform admin about the new request (in-app row
    # FIRST, then the FCM push — each guarded separately with clear logs).
    # NO email: the platform never emails about subscription events.
    # Never allowed to break the request creation flow.
    notif_ids: list = []
    admins: list = []
    _admin_push_title = "طلب اشتراك جديد"
    _admin_push_body = ""
    _admin_push_payload = "/admin/subscription-requests"
    try:
        admins = (
            await db.execute(
                select(User).where(User.is_platform_admin.is_(True), User.status == "active")
            )
        ).scalars().all()
        plan_ar = {1: "شخصية", 2: "أعمال", 3: "أعمال + شخصي"}.get(plan_id, plan_name)
        period_ar = "سنوي" if period == "yearly" else "شهري"
        org_name = org.name or org_id
        _admin_push_body = f"وصل طلب اشتراك جديد من {org_name} — باقة {plan_ar} ({period_ar})"
        for admin in admins:
            notif = AppNotification(
                organization_id=admin.organization_id,
                user_id=admin.id,
                type="warning",
                title="طلب اشتراك جديد",
                message=_admin_push_body,
                action="open_screen",
                action_payload="/admin/subscription-requests",
            )
            db.add(notif)
            await db.flush()
            notif_ids.append(notif.id)
        await db.commit()
    except Exception as exc:  # noqa: BLE001
        logger.warning("admin_subscription_notify_failed", user_id=str(user_id),
                       org_id=str(org_id), error=str(exc))
        try:
            await db.rollback()
        except Exception:
            pass
    # FCM push AFTER the DB rows committed — never breaks the request.
    if notif_ids:
        try:
            from app.domain.services import push_service as _push

            await _push.notify_platform_admins(
                db,
                title=_admin_push_title,
                body=_admin_push_body,
                action="open_screen",
                action_payload=_admin_push_payload,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("admin_subscription_push_failed", user_id=str(user_id),
                           org_id=str(org_id), error=str(exc))

    return ok({
        "success": True,
        "message": "تم تقديم طلب الاشتراك. سيتم مراجعته من قبل الإدارة.",
        "status": "pending",
    })
