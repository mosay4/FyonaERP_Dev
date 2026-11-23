"""Stripe payment endpoints.

  * User flow:  GET  /payments/stripe/plans
                 POST /payments/stripe/create-checkout-session  (auth)
                 GET  /payments/stripe/return   (Stripe redirect target)
                 GET  /payments/stripe/cancel   (Stripe redirect target)
  * Webhook:    POST /payments/stripe/webhook   (raw body, signature verified)
  * Admin:      GET  /payments/stripe/payments              (list)
                 GET  /payments/stripe/subscriptions        (list)
                 GET  /payments/stripe/settings  (safe summary)
                 POST /payments/stripe/settings  (save)
                 POST /payments/stripe/test-connection
                 PATCH /payments/stripe/plans/{plan_id}     (set stripe price id)

All paths live under `/payments/stripe/` so they never collide with the
invoice domain's `/payments` & `/payments/{payment_id}` routes in finance.py.
"""
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, Query, status
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user_uuid, get_current_org_id, require_platform_admin
from app.api.responses import ok, ok_paginated
from app.core.database import get_db
from app.core.logging import get_logger
from app.domain.entities.payment_entities import Plan
from app.domain.entities.auth_entities import User, Organization
from app.domain.services.payment_service import (
    PaymentService,
    StripeNotConfiguredError,
    _plan_catalog_dict,
)

router = APIRouter(tags=["Payments"])
logger = get_logger("payments_api")


class StripeCheckoutRequest(BaseModel):
    plan_id: UUID = Field(...)
    period: str = "yearly"  # monthly | yearly
    target_currency: Optional[str] = None  # settlement currency (sar/usd/aed/...)
    idempotency_key: Optional[str] = None  # client retry guard (reuse pending intent)


class StripeSettingsUpdate(BaseModel):
    stripe_enabled: Optional[bool] = None
    stripe_mode: Optional[str] = None
    stripe_publishable_key: Optional[str] = None
    stripe_secret_key: Optional[str] = None
    stripe_webhook_secret: Optional[str] = None


class PlanStripePatch(BaseModel):
    stripe_product_id: Optional[str] = None
    stripe_price_id_monthly: Optional[str] = None
    stripe_price_id_yearly: Optional[str] = None
    currency: Optional[str] = None
    is_active: Optional[bool] = None


# ── User-facing ──────────────────────────────────────────────────────

@router.get("/payments/stripe/plans")
async def list_plans(
    user_id: UUID = Depends(get_current_user_uuid),
    currency: Optional[str] = Query(default=None, description="Request prices quoted in this currency"),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    plans = await service.list_plans(target_currency=currency)
    return ok({"plans": plans, "stripe_enabled": await service._enabled()}, "تم تحميل الباقات")


@router.post("/payments/stripe/create-checkout-session")
async def create_checkout_session(
    payload: StripeCheckoutRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.create_checkout_session(user, org, payload.plan_id, payload.period, payload.target_currency, payload.idempotency_key)
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم إنشاء جلسة الدفع")


@router.post("/payments/stripe/create-payment-intent")
async def create_payment_intent(
    payload: StripeCheckoutRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """In-app PaymentSheet checkout: returns a client secret + public key.

    The client secret is used by `flutter_stripe`'s PaymentSheet so the user
    never leaves the app. Amount/currency come from the linked Stripe Price.
    """
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.create_payment_intent(user, org, payload.plan_id, payload.period, payload.target_currency, payload.idempotency_key)
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم إنشاء عملية الدفع")


class StripeConfirmRequest(BaseModel):
    payment_intent_id: Optional[str] = None
    payment_id: Optional[str] = None


class AutoRenewEnableRequest(BaseModel):
    plan_id: UUID = Field(...)
    period: str = "yearly"  # monthly | yearly (must match the subscription length)
    payment_method_id: str = Field(...)
    consent: bool = Field(...)  # explicit user consent — required


class AutoRenewActivateRequest(BaseModel):
    invoice_no: Optional[str] = None
    payment_intent_id: Optional[str] = None


# ── Auto-renew (independent layer — one-time endpoints above untouched) ──

@router.post("/payments/stripe/setup-intent")
async def create_setup_intent(
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """SetupIntent for saving a card for future auto-renewal.

    Returns ONLY the client secret — card data never touches FYONA.
    """
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.create_setup_intent(user, org)
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم إنشاء إعداد الحفظ")


@router.post("/payments/stripe/auto-renew/enable")
async def enable_auto_renew(
    body: AutoRenewEnableRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """Enable auto-renewal: attach the saved method + create the Subscription.

    Requires explicit `consent: true`. Price always comes from the plan's
    configured Stripe Price ID — never from the client.
    """
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.enable_auto_renew(
            user, org, body.plan_id, period=body.period,
            payment_method_id=body.payment_method_id, consent=body.consent,
        )
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم تفعيل التجديد التلقائي")


@router.post("/payments/stripe/auto-renew/activate")
async def activate_auto_renew_after_payment(
    body: AutoRenewActivateRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """Bind the just-charged card to automatic renewal after checkout.

    Called from the invoice "start" tap. The backend resolves the paid
    charge, reuses the card Stripe just charged, and creates the recurring
    subscription with the first charge at the paid period's end. Idempotent.
    """
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.activate_auto_renew_after_payment(
            user, org, invoice_no=body.invoice_no,
            payment_intent_id=body.payment_intent_id,
        )
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم تفعيل التجديد التلقائي")


@router.post("/payments/stripe/auto-renew/disable")
async def disable_auto_renew(
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """Stop the NEXT renewal (cancel_at_period_end). The subscription stays
    usable until the current paid period ends — nothing is revoked now."""
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.disable_auto_renew(user, org)
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(result, "تم إيقاف التجديد القادم — اشتراكك فعال حتى نهاية المدة")


@router.get("/payments/stripe/auto-renew/status")
async def auto_renew_status(
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """Renewal state + safe card display (brand/last4 only, never PAN)."""
    service = PaymentService(db)
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    org = (await db.execute(select(Organization).where(Organization.id == UUID(org_id)))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="المستخدم غير موجود")
    if not org:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المؤسسة غير موجودة")
    try:
        result = await service.auto_renew_status(user, org)
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc))
    return ok(result)


@router.post("/payments/stripe/confirm")
async def confirm_stripe_payment(
    body: StripeConfirmRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    """Client-triggered Stripe confirmation — activates immediately after
    `presentPaymentSheet` succeeds, without waiting for the webhook.

    Verifies the PaymentIntent status and amount server-side via the Stripe
    API and, if `succeeded`, activates the subscription, creates the invoice,
    and sends notifications to the user and admins. Idempotent.
    """
    if not body.payment_intent_id and not body.payment_id:
        raise HTTPException(status_code=400, detail="payment_intent_id أو payment_id مطلوب")
    service = PaymentService(db)
    try:
        from uuid import UUID as _UUID
        org_uuid = _UUID(org_id)
    except Exception:
        raise HTTPException(status_code=400, detail="معرف المؤسسة غير صالح")
    try:
        result = await service.confirm_stripe_payment(
            user_id=user_id,
            org_id=org_uuid,
            payment_intent_id=body.payment_intent_id,
            payment_id=body.payment_id,
        )
    except StripeNotConfiguredError as exc:
        raise HTTPException(status_code=403, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return ok(result, "تم تفعيل اشتراكك بنجاح")


# ── Stripe redirect targets (no auth; no secrets) ─────────────────────

def _return_html(title: str, body: str) -> HTMLResponse:
    return HTMLResponse(
        content=(
            "<!doctype html><html lang='ar' dir='rtl'><head><meta charset='utf-8'>"
            f"<title>{title}</title><meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<style>body{font-family:system-ui,Arial;background:#0a0a0a;color:#e0e0e0;"
            "display:flex;align-items:center;justify-content:center;height:100vh;margin:0}"
            ".c{background:#151515;border:1px solid #252525;border-radius:14px;padding:24px;max-width:420px;"
            "text-align:center} .c h1{color:#A01530} .c p{margin-top:8}</style></head><body>"
            f"<div class='c'><h1>{title}</h1><p>{body}</p></div></body></html>"
        ),
        media_type="text/html",
    )


@router.get("/payments/stripe/return", response_class=HTMLResponse)
async def stripe_return(request: Request, session_id: Optional[str] = None):
    # Confirmation is driven by the webhook, NOT by this redirect. We only inform
    # the user; the app re-fetches account status from the backend on resume.
    return _return_html(
        "تم الدفع بنجاح",
        "تم استلام إشعار الدفع. سيتم تفعيل اشتراكك تلقائيًّا. يمكنك إغلاق هذه النافذة "
        "والعودة إلى التطبيق. إذا لم ينعكب بعد، قد يستغرق بضع دقائق.",
    )


@router.get("/payments/stripe/cancel", response_class=HTMLResponse)
async def stripe_cancel(request: Request):
    return _return_html("تم إلغاء العملية", "لم يتم إكمال الدفع. اخر باقة أخرى أو حاول مرة أخرى.")


# ── Webhook (no auth; signature verified) ─────────────────────────────

@router.post("/payments/stripe/webhook")
async def stripe_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    payload = await request.body()
    sig = request.headers.get("stripe-signature", "")
    service = PaymentService(db)
    try:
        secret = await service._webhook_secret()
        event = service.construct_event(payload, sig, secret=secret)
    except Exception as exc:
        logger.warning("webhook_signature_invalid", error=str(exc))
        return JSONResponse(content={"success": False, "message": "Invalid Stripe signature"}, status_code=400)
    await service.handle_event(event)
    return {"status": "received"}


# ── Admin ────────────────────────────────────────────────────────────

@router.get("/payments/stripe/payments")
async def admin_list_payments(
    status: Optional[str] = Query(default=None),
    search: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    per_page: int = Query(default=20, ge=1, le=100),
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    items, total = await service.list_payments(status=status, search=search, page=page, per_page=per_page)
    return ok_paginated(items, total, page, per_page)


@router.get("/payments/stripe/subscriptions")
async def admin_list_subscriptions(
    status: Optional[str] = Query(default=None),
    search: Optional[str] = Query(default=None),
    page: int = Query(default=1, ge=1),
    per_page: int = Query(default=20, ge=1, le=100),
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    items, total = await service.list_subscriptions(status=status, search=search, page=page, per_page=per_page)
    return ok_paginated(items, total, page, per_page)


@router.get("/payments/stripe/settings")
async def admin_stripe_settings(
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    return ok(await service.get_stripe_settings(), "إعدادات Stripe")


@router.post("/payments/stripe/settings")
async def admin_save_stripe_settings(
    body: StripeSettingsUpdate,
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    try:
        settings_out = await service.save_stripe_settings(body.model_dump(exclude_none=True))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ok(settings_out, "تم حفظ إعدادات Stripe")


@router.post("/payments/stripe/test-connection")
async def admin_test_stripe(
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    service = PaymentService(db)
    try:
        result = await service.test_connection()
    except StripeNotConfiguredError as exc:
        return ok({"connected": False, "error": str(exc)}, "Stripe connection test")
    return ok(result, "Stripe connection test")


@router.patch("/payments/stripe/plans/{plan_id}")
async def admin_patch_plan_stripe(
    plan_id: UUID,
    body: PlanStripePatch,
    _=Depends(require_platform_admin),
    db: AsyncSession = Depends(get_db),
):
    plan = (await db.execute(select(Plan).where(Plan.id == plan_id))).scalar_one_or_none()
    if not plan:
        raise HTTPException(status_code=404, detail="الباقة غير موجودة")
    for k, v in body.model_dump(exclude_none=True).items():
        setattr(plan, k, v)
    await db.commit()
    return ok(_plan_catalog_dict(plan), "تم تحديث إعدادات الباقة")
