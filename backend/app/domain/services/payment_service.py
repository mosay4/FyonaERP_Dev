"""Stripe payment + subscription service.

Security model:
  * The Stripe keys are NEVER inside the Flutter app. They are read
    exclusively from the server `.env` file (STRIPE_* env vars) — the admin
    panel only shows whether they are configured.
  * Checkout Sessions are created server-side; Flutter opens the returned URL
    with the platform browser (url_launcher). StripePayment status is confirmed
    exclusively via Stripe webhooks — the app never trusts a client redirect.
  * Webhooks are verified with STRIPE_WEBHOOK_SECRET and de-duplicated by event id.

Pricing catalog: the single source of truth is the `plans` table
(app.domain.entities.admin_entities.Plan), extended there with nullable
Stripe columns.

Charging currency: plan base prices are stored in Yemeni Rial (YER).
Stripe does not support YER, so at checkout time the amount is converted
to SAR using the CentralFX live rates (Sanaa USD average + global
USD->SAR). The linked Stripe Price (if any) is only used as a fallback
when FX data is unavailable.
"""
import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import get_logger
from app.core.security import decrypt_secret, encrypt_secret
from app.domain.entities.admin_entities import Plan, dumps_features, loads_features
from app.domain.entities.payment_entities import AppSetting, StripePayment, StripeWebhookEvent, StripeSubscription
from app.domain.entities.auth_entities import Organization, User

logger = get_logger("payment_service")

try:  # pragma: no cover - import guard
    import stripe as stripe_sdk
except Exception:  # pragma: no cover
    stripe_sdk = None
    if logging.getLogger(__name__).isEnabledFor(logging.DEBUG):
        logger.warning("stripe_sdk_not_installed", extra={"component": "payment_service"})


class StripeNotConfiguredError(Exception):
    pass


# Legacy int-code accessor -> plan name (mirrors subscription.py plan ids).
_CODE_TO_NAME = {1: "باقة شخصية", 2: "باقة أعمال", 3: "باقة أعمال + شخصي"}


def _stripe_field(obj, key):
    """Read a field from a Stripe SDK object OR a plain dict."""
    if obj is None:
        return None
    if isinstance(obj, dict):
        return obj.get(key)
    return getattr(obj, key, None)


def _extract_provider_payment_id(session) -> Optional[str]:
    """Stable idempotency key: payment_intent id, else the session id."""
    pid = _stripe_field(session, "payment_intent")
    if isinstance(pid, dict):
        pid = pid.get("id")
    if not pid:
        pid = _stripe_field(session, "id")
    return str(pid) if pid else None


def _extract_card_brand(session) -> Optional[str]:
    """Card brand (visa/mastercard/...) from intent charges, if present."""
    try:
        charges = _stripe_field(session, "charges")
        data = _stripe_field(charges, "data") or []
        first = data[0] if data else None
        pmd = _stripe_field(first, "payment_method_details") or {}
        card = _stripe_field(pmd, "card") or {}
        brand = _stripe_field(card, "brand")
        if brand:
            return str(brand)
        pm_types = _stripe_field(session, "payment_method_types") or []
        if pm_types:
            return str(pm_types[0])
    except Exception:  # noqa: BLE001 - best effort only
        pass
    return None


class PaymentService:
    # Stripe settlement currencies we accept (lowercase ISO codes).
    STRIPE_ALLOWED_CURRENCIES = {
        "sar", "usd", "eur", "gbp", "aed", "egp",
        "kwd", "qar", "bhd", "omr", "jod", "try",
    }
    # Currencies whose smallest unit is 1/1000 (Stripe minor-unit rules).
    STRIPE_CURRENCY_MINOR_UNITS = {
        "kwd": 1000, "bhd": 1000, "omr": 1000, "jod": 1000,
    }

    def __init__(self, db: AsyncSession):
        self.db = db

    async def ensure_plans_seeded(self) -> None:
        existing = (await self.db.execute(select(func.count(Plan.id)))).scalar() or 0
        if existing:
            return
        from app.api.v1.admin import _DEFAULT_PLANS  # lazy: avoids API-layer coupling at import
        from app.domain.entities.admin_entities import Plan as _Plan
        for data in _DEFAULT_PLANS:
            row = dict(data)
            row["features"] = dumps_features(row.get("features"))
            self.db.add(_Plan(**row))
        await self.db.commit()

    async def list_plans(self, target_currency: Optional[str] = None) -> list:
        await self.ensure_plans_seeded()
        rows = (
            await self.db.execute(
                select(Plan).where(Plan.is_active.is_(True)).order_by(Plan.name.asc())
            )
        ).scalars().all()
        resolved = {}
        if await self._enabled():
            try:
                await self._stripe()
                for p in rows:
                    resolved[p.id] = {
                        "monthly": self._resolve_stripe_price(p.stripe_price_id_monthly),
                        "yearly": self._resolve_stripe_price(p.stripe_price_id_yearly),
                    }
            except StripeNotConfiguredError:
                resolved = {}
        result = []
        for p in rows:
            quoted_monthly = None
            quoted_yearly = None
            quote_currency = None
            quote_charge_currency = None
            fx_rate = None
            fx_source = None
            quote_fallback_usd = False
            if target_currency:
                qm = qy = None
                try:
                    qm = await self._quote_plan(p, "monthly", target_currency)
                except (ValueError, StripeNotConfiguredError):
                    qm = None
                try:
                    qy = await self._quote_plan(p, "yearly", target_currency)
                except (ValueError, StripeNotConfiguredError):
                    qy = None
                if qm is not None or qy is not None:
                    qy = qy or qm or {"currency": None, "charge_currency": None, "exchange_rate": None, "fx_source": None, "fallback_to_usd": False}
                    qm = qm or {"currency": qy["currency"], "charge_currency": qy["charge_currency"], "exchange_rate": qy["exchange_rate"], "fx_source": qy["fx_source"], "fallback_to_usd": qy["fallback_to_usd"]}
                    quoted_monthly = qm.get("amount")
                    quoted_yearly = qy.get("amount")
                    quote_currency = (qm.get("currency") or qy.get("currency") or target_currency).upper()
                    quote_charge_currency = (qm.get("charge_currency") or qy.get("charge_currency") or quote_currency).upper()
                    fx_rate = qy.get("exchange_rate") if qy else None
                    fx_source = qy.get("fx_source") if qy else None
                    quote_fallback_usd = bool((qm.get("fallback_to_usd") or qy.get("fallback_to_usd")))
            result.append(
                _plan_catalog_dict(
                    p,
                    stripe_amount_monthly=resolved.get(p.id, {}).get("monthly"),
                    stripe_amount_yearly=resolved.get(p.id, {}).get("yearly"),
                    stripe_currency=resolved.get(p.id, {}).get("yearly")[1]
                    if resolved.get(p.id, {}).get("yearly") else None,
                    quote_amount_monthly=quoted_monthly,
                    quote_amount_yearly=quoted_yearly,
                    quote_currency=quote_currency,
                    quote_charge_currency=quote_charge_currency,
                    quote_fx_rate=fx_rate,
                    quote_fx_source=fx_source,
                    quote_fallback_usd=quote_fallback_usd,
                )
            )
        return result

    async def _quote_plan(self, plan: Plan, period: str, target_currency: str) -> dict:
        """Server-side price quote for a plan/period in the requested currency.

        Uses the exact same FX path as eventual charge (`_resolve_charge`) so the
        price the user SEES is exactly the amount that will be charged.
        """
        charge = await self._resolve_charge(plan, period, target_currency)
        currency = charge["currency"]
        minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(currency, 100)
        return {
            "amount": charge.get("display_amount") or (float(charge["amount_minor"]) / minor_units),
            "currency": charge.get("display_currency") or currency.upper(),
            "charge_currency": currency.upper(),
            "exchange_rate": charge["exchange_rate"],
            "fx_source": charge.get("fx_source") or charge["source"],
            "base_amount": charge["base_amount"],
            "base_currency": (charge.get("base_currency") or "YER").upper(),
            "fallback_to_usd": charge.get("fallback_to_usd", False),
        }

    def _resolve_stripe_price(self, price_id: Optional[str]):
        """Returns (unit_amount_minor, currency_lower) for a Stripe Price or None."""
        if not price_id or not stripe_sdk:
            return None
        try:
            price = stripe_sdk.Price.retrieve(price_id)
            return price.unit_amount, (price.currency or "").lower()
        except Exception as exc:
            logger.warning("stripe_price_resolve_failed", price_id=price_id, error=str(exc))
            return None

    async def get_plan(self, plan_id) -> Optional[Plan]:
        await self.ensure_plans_seeded()
        try:
            plan_uuid = UUID(str(plan_id))
        except (TypeError, ValueError):
            return None
        res = await self.db.execute(select(Plan).where(Plan.id == plan_uuid))
        return res.scalar_one_or_none()

    async def get_plan_by_code(self, code) -> Optional[Plan]:
        await self.ensure_plans_seeded()
        name = _CODE_TO_NAME.get(code)
        if name is None:
            return None
        res = await self.db.execute(
            select(Plan).where(Plan.is_active.is_(True), Plan.name == name)
        )
        return res.scalar_one_or_none()

    async def _cfg_get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        row = (await self.db.execute(select(AppSetting).where(AppSetting.key == key))).scalar_one_or_none()
        if row and row.value_encrypted:
            try:
                return decrypt_secret(row.value_encrypted)
            except Exception:
                logger.warning("config_decrypt_failed", key=key)
                return None
        return default

    async def _cfg_set(self, key: str, value: Optional[str]) -> None:
        existing = (await self.db.execute(select(AppSetting).where(AppSetting.key == key))).scalar_one_or_none()
        if value is None:
            if existing:
                await self.db.delete(existing)
            return
        encrypted = encrypt_secret(value)
        if existing:
            existing.value_encrypted = encrypted
        else:
            self.db.add(AppSetting(key=key, value_encrypted=encrypted))
        await self.db.commit()

    async def get_stripe_settings(self) -> dict:
        enabled = await self._cfg_get("stripe_enabled", str(settings.STRIPE_ENABLED))
        mode = await self._cfg_get("stripe_mode", settings.STRIPE_MODE) or "test"
        return {
            "stripe_enabled": _as_bool(enabled),
            "stripe_mode": mode,
            "publishable_key": settings.STRIPE_PUBLISHABLE_KEY,
            "secret_key_configured": bool((settings.STRIPE_SECRET_KEY or "").strip()),
            "webhook_secret_configured": bool((settings.STRIPE_WEBHOOK_SECRET or "").strip()),
            "webhook_url": settings.stripe_webhook_url,
        }

    async def save_stripe_settings(self, payload: dict) -> dict:
        """Persist only the non-secret toggles.

        Stripe keys themselves are managed exclusively through the server `.env`
        file; legacy DB-stored key overrides are cleared.
        """
        enabled = payload.get("stripe_enabled")
        mode = payload.get("stripe_mode")

        if mode is not None and mode not in ("test", "live"):
            raise ValueError("stripe_mode must be 'test' or 'live'")

        await self._cfg_set("stripe_enabled", _as_str(enabled) if enabled is not None else None)
        await self._cfg_set("stripe_mode", _as_str(mode) if mode is not None else None)
        for legacy_key in ("stripe_publishable_key", "stripe_secret_key", "stripe_webhook_secret"):
            await self._cfg_set(legacy_key, None)
        return await self.get_stripe_settings()

    async def test_connection(self) -> dict:
        secret = settings.STRIPE_SECRET_KEY
        if not secret:
            raise StripeNotConfiguredError("لم يتم تكوين Stripe secret key في ملف .env")
        if not stripe_sdk:
            raise StripeNotConfiguredError("مكتبة Stripe غير مثبتة في الخادم")
        try:
            stripe_sdk.api_key = secret
            stripe_sdk.Balance.retrieve()
            return {"connected": True}
        except Exception as exc:
            logger.error("stripe_test_connection_failed", error=str(exc))
            return {"connected": False, "error": "فشل الاتصال بـ Stripe. تحقق من Secret Key."}

    async def _enabled(self) -> bool:
        val = await self._cfg_get("stripe_enabled", str(settings.STRIPE_ENABLED))
        return _as_bool(val)

    async def _stripe(self):
        if not stripe_sdk:
            raise StripeNotConfiguredError("مكتبة Stripe غير مثبتة في الخادم")
        secret = settings.STRIPE_SECRET_KEY
        if not secret:
            raise StripeNotConfiguredError("لم يتم تكوين Stripe secret key في ملف .env")
        stripe_sdk.api_key = secret
        return stripe_sdk

    async def _webhook_secret(self) -> str:
        secret = settings.STRIPE_WEBHOOK_SECRET
        if not secret:
            raise StripeNotConfiguredError("لم يتم تكوين Stripe webhook secret في ملف .env")
        return secret

    @staticmethod
    def _plan_package_key(plan) -> str:
        """Canonical package key (personal|business|premium) for a Plan row."""
        pt = (getattr(plan, "package_type", None) or "").strip().lower()
        if pt in ("personal", "business", "premium", "free"):
            return pt
        for cand in (getattr(plan, "name_en", None) or "", getattr(plan, "name", None) or ""):
            low = cand.lower()
            if "personal" in low and "business" in low:
                return "premium"
            if "business" in low or "أعمال" in cand:
                return "business"
            if "personal" in low or "شخص" in cand:
                return "personal"
        return ""

    async def _apply_plan_discount(self, plan, base_amount: float) -> float:
        """Return the chargeable base after the admin's active discount.

        Reads `discounts.{package_key} = {percent, starts_on, ends_on}` from
        platform controls. The discount applies ONLY while now is inside
        [starts_on, ends_on]; otherwise the original price is returned, so
        expiry automatically restores the admin's base price.
        """
        try:
            if not base_amount or base_amount <= 0:
                return base_amount
            from app.api.v1.admin import _settings_svc
            ctrl = await _settings_svc(self.db).get_controls()
            discounts = ctrl.get("discounts") or {}
            if not isinstance(discounts, dict):
                return base_amount
            key = self._plan_package_key(plan)
            cfg = discounts.get(key)
            if not isinstance(cfg, dict):
                return base_amount
            try:
                percent = int(float(cfg.get("percent") or 0))
            except (TypeError, ValueError):
                return base_amount
            if percent <= 0 or percent >= 100:
                return base_amount
            now = datetime.now(timezone.utc)
            starts_on = (cfg.get("starts_on") or "").strip() if isinstance(cfg.get("starts_on"), str) else ""
            ends_on = (cfg.get("ends_on") or "").strip() if isinstance(cfg.get("ends_on"), str) else ""
            if starts_on:
                try:
                    start_dt = datetime.fromisoformat(starts_on)
                    if start_dt.tzinfo is None:
                        start_dt = start_dt.replace(tzinfo=timezone.utc)
                    if now < start_dt:
                        return base_amount
                except (ValueError, TypeError):
                    pass
            if ends_on:
                try:
                    end_dt = datetime.fromisoformat(ends_on)
                    if end_dt.tzinfo is None:
                        end_dt = end_dt.replace(tzinfo=timezone.utc)
                    if now > end_dt:
                        return base_amount
                except (ValueError, TypeError):
                    pass
            return round(base_amount * (1 - percent / 100.0), 2)
        except Exception:
            return base_amount

    async def _resolve_charge(self, plan: Plan, period: str, target_currency: Optional[str] = None) -> dict:
        """Resolve the chargeable amount for a plan in a target currency.

        The plan base price is stored in the plan's own currency
        (plan.currency — USD for current plans, YER/SAR for legacy ones).
        Most Stripe accounts can only settle in a handful of currencies, so any
        unsupported target is AUTO-CONVERTED: the user still sees the price in
        their chosen currency, but Stripe is charged in USD (universal fallback).

        Returns a dict:
          amount_minor       -> minor units in [charge_currency]
          currency           -> ACTUAL Stripe charge currency (lowercase)
          display_amount     -> price as shown to the user, in [display_currency]
          display_currency   -> the currency the user picked (uppercase)
          charge_source      -> live_fx | stripe_price
          source             -> alias for [charge_source]
          base_amount, base_currency, exchange_rate, fx_source
          fallback_to_usd    -> True when the target was not Stripe-supported
        """
        target = (target_currency or settings.STRIPE_CURRENCY or "sar").strip().lower()
        if not target:
            target = "sar"
        charge_allowed = target in self.STRIPE_ALLOWED_CURRENCIES
        base = plan.price_yearly if period == "yearly" else plan.price_monthly
        base_cur = (getattr(plan, "currency", None) or "YER").strip().upper()
        price_id = plan.stripe_price_id_yearly if period == "yearly" else plan.stripe_price_id_monthly

        # ── Admin marketing discount: when a percentage discount is active
        # for this plan (now inside [starts_on, ends_on]), the CHARGED base
        # is the discounted price — so Stripe auto-payment honors the offer.
        # Once the window lapses, the original admin price returns by itself.
        try:
            base = await self._apply_plan_discount(plan, float(base or 0))
        except Exception:
            pass

        _min_msg = (
            "المبلغ المستحق بعد الخصم أقل من الحد الأدنى "
            "للدفع الإلكتروني (0.50 دولار أمريكي أو ما يعادله). "
            "ارفع سعر الباقة أو خفّض نسبة الخصم ثم أعد المحاولة."
        )

        # Same currency as the plan (and Stripe can settle it): no exchange
        # rate is involved, so the charge never depends on the FX service.
        if base and float(base) > 0 and charge_allowed and target.upper() == base_cur:
            minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(target, 100)
            amount_minor = int(round(float(base) * minor_units))
            if amount_minor < 50:
                raise ValueError(_min_msg)
            return {
                "amount_minor": amount_minor,
                "currency": target,
                "display_amount": float(base),
                "display_currency": target.upper(),
                "source": "live_fx",
                "charge_source": "live_fx",
                "base_amount": float(base),
                "base_currency": base_cur,
                "exchange_rate": 1.0,
                "fx_source": "same_currency",
                "fallback_to_usd": False,
            }

        if base and float(base) > 0:
            try:
                from app.domain.services.currency_service import CurrencyService
                rates = await CurrencyService.get_instance().get_all_rates()
                yemen = (rates.get("yemen") or {}) if isinstance(rates, dict) else {}
                sanaa_usd = (yemen.get("sanaa") or {}).get("USD") or {}
                aden_usd = (yemen.get("aden") or {}).get("USD") or {}
                sanaa_avg = float(sanaa_usd.get("average") or 0)
                aden_avg = float(aden_usd.get("average") or 0)
                global_rates = rates.get("global") or {}

                def _per_usd(cur: str) -> float:
                    """Units of `cur` per 1 USD (2dec.net for YER, globals else)."""
                    c = (cur or "").upper()
                    if c == "USD":
                        return 1.0
                    if c in ("YER", "YER_OLD"):
                        return sanaa_avg
                    if c == "YER_NEW":
                        return aden_avg
                    try:
                        return float(global_rates.get(c) or 0)
                    except (TypeError, ValueError):
                        return 0.0

                def _to_usd(amount: float, cur: str) -> float:
                    """Convert `amount` in `cur` to USD."""
                    c = (cur or "").upper()
                    if c == "USD":
                        return amount
                    rate = _per_usd(c)
                    return amount / rate if rate > 0 else 0.0

                plan_usd = _to_usd(float(base), base_cur)
                target_rate = _per_usd(target)
                if plan_usd > 0:
                    if charge_allowed and target_rate > 0:
                        # Settle in the chosen currency directly.
                        target_amount = plan_usd * target_rate
                        minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(target, 100)
                        amount_minor = int(round(target_amount * minor_units))
                        display_amount = target_amount
                        charge_currency = target
                    else:
                        # Chosen currency not supported by Stripe (e.g.
                        # YER_OLD, YER_NEW, ...) OR FX for it unknown:
                        # show the user's price in their currency, but charge
                        # in USD converted from the plan base currency.
                        if target_rate > 0:
                            display_amount = plan_usd * target_rate
                        elif target.upper() == base_cur:
                            display_amount = float(base)
                        else:
                            display_amount = 0.0
                        charge_currency = "usd"
                        amount_minor = int(round(plan_usd * 100))

                    if display_amount > 0 and amount_minor > 0:
                        if amount_minor < 50:
                            # Below the card processor minimum. Never fall
                            # back to the plan's stored Stripe Price here:
                            # doing so silently charged the OLD list price
                            # (e.g. 9900 SAR) instead of the admin's current
                            # discounted price. Fail with a clear reason.
                            raise ValueError(_min_msg)
                        return {
                            "amount_minor": amount_minor,
                            "currency": charge_currency,
                            "display_amount": display_amount,
                            "display_currency": target.upper(),
                            "source": "live_fx",
                            "charge_source": "live_fx",
                            "base_amount": float(base),
                            "base_currency": base_cur,
                            "exchange_rate": (plan_usd / float(base)) if float(base) else None,
                            "fx_source": "live_fx",
                            "fallback_to_usd": not charge_allowed,
                        }
            except ValueError:
                raise
            except Exception as exc:
                logger.warning("fx_charge_resolution_failed", error=str(exc), plan_id=str(plan.id))
            # The admin price exists: never charge the plan's stored Stripe
            # Price instead (it can be an old list price without the current
            # price / discount). Without a rate, fail with a clear reason.
            raise ValueError("تعذر تحديد مبلغ الدفع: أسعار الصرف غير متوفرة حاليًا، حاول لاحقًا")

        # Legacy plans with no admin price: their Stripe Price is the price.
        stripe = await self._stripe()
        if price_id:
            try:
                price = stripe.Price.retrieve(price_id)
                if price.unit_amount and int(price.unit_amount) > 0:
                    price_currency = (price.currency or settings.STRIPE_CURRENCY or "sar").lower()
                    if price_currency not in self.STRIPE_ALLOWED_CURRENCIES:
                        price_currency = "usd"
                    return {
                        "amount_minor": int(price.unit_amount),
                        "currency": price_currency,
                        "display_amount": int(price.unit_amount) / self.STRIPE_CURRENCY_MINOR_UNITS.get(price_currency, 100),
                        "display_currency": target.upper(),
                        "source": "stripe_price",
                        "charge_source": "stripe_price",
                        "base_amount": float(base) if base else None,
                        "base_currency": (price.currency or settings.STRIPE_CURRENCY or "sar").upper(),
                        "exchange_rate": None,
                        "fx_source": "stripe_price",
                        "fallback_to_usd": price_currency == "usd",
                    }
            except Exception as exc:
                logger.warning("stripe_price_fallback_failed", error=str(exc), price_id=price_id)
        raise ValueError("تعذر تحديد مبلغ الدفع: أسعار الصرف غير متوفرة حاليًا، حاول لاحقًا")

    async def create_checkout_session(self, user: User, org: Organization, plan_id, period: str = "yearly", target_currency: Optional[str] = None, idempotency_key: Optional[str] = None) -> dict:
        if not await self._enabled():
            raise StripeNotConfiguredError("Stripe غير مفعّل")
        plan = await self.get_plan(plan_id)
        if not plan:
            raise ValueError("الباقة غير موجودة")
        from app.domain.services.section_entitlements import validate_purchase
        validate_purchase(org, self._plan_package_key(plan))
        stripe = await self._stripe()
        charge = await self._resolve_charge(plan, period, target_currency)
        amount_minor = charge["amount_minor"]
        currency = charge["currency"]
        minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(currency, 100)
        payment = StripePayment(
            user_id=user.id, organization_id=org.id, provider="stripe",
            plan_id=plan.id, plan_name=plan.name, period=period,
            amount=float(amount_minor) / minor_units,
            amount_minor=amount_minor,
            currency=currency.upper(),
            status="pending",
            mode=settings.STRIPE_MODE or "test",
            base_amount=charge["base_amount"],
            base_currency=(charge.get("base_currency") or "YER").upper(),
            exchange_rate=charge["exchange_rate"],
            fx_source=charge.get("fx_source") or charge["source"],
            idempotency_key=idempotency_key,
            metadata_=json.dumps({"period": period}),
        )
        self.db.add(payment)
        await self.db.flush()
        success_url = f"{settings.API_BASE_URL}{settings.API_PREFIX}/payments/stripe/return?session_id={{CHECKOUT_SESSION_ID}}"
        cancel_url = f"{settings.API_BASE_URL}{settings.API_PREFIX}/payments/stripe/cancel"
        session = stripe.checkout.Session.create(
            payment_method_types=["card"], mode="payment",
            locale="en",
            line_items=[{
                "quantity": 1,
                "price_data": {
                    "currency": currency,
                    "unit_amount": amount_minor,
                    "product_data": {
                        "name": f"FYONA — {plan.name or 'Subscription'} ({'Yearly' if period == 'yearly' else 'Monthly'})",
                        "description": "FYONA ERP subscription plan",
                    },
                },
            }],
            client_reference_id=str(user.id), customer_email=user.email,
            success_url=success_url, cancel_url=cancel_url,
            metadata={
                "fyona_user_id": str(user.id),
                "fyona_org_id": str(org.id),
                "fyona_plan_id": str(plan.id),
                "fyona_plan_name": plan.name or "",
                "fyona_payment_id": str(payment.id),
                "fyona_period": period,
                "fyona_amount_minor": amount_minor,
                "fyona_currency": currency,
                "fyona_display_currency": charge.get("display_currency") or "",
                "fyona_display_amount": charge.get("display_amount") or "",
                "fyona_idempotency_key": idempotency_key or "",
            },
        )
        payment.stripe_checkout_session_id = session.id
        await self.db.commit()
        await self.db.refresh(payment)
        logger.info("checkout_session_created", user_id=str(user.id), org_id=str(org.id),
                    plan_id=str(plan.id), session_id=session.id, payment_id=str(payment.id),
                    amount_minor=amount_minor, currency=currency, source=charge["source"],
                    fallback_to_usd=charge.get("fallback_to_usd", False))
        return {
            "checkout_url": session.url,
            "session_id": session.id,
            "payment_id": str(payment.id),
            "plan_id": str(plan.id),
            "plan_name": plan.name,
            "currency": payment.currency,
            "amount": payment.amount,
            "display_currency": charge.get("display_currency") or payment.currency,
            "display_amount": charge.get("display_amount") or payment.amount,
            "period": period,
        }

    async def create_payment_intent(self, user: User, org: Organization, plan_id, period: str = "yearly", target_currency: Optional[str] = None, idempotency_key: Optional[str] = None) -> dict:
        """Create a PaymentIntent for in-app card checkout.

        The plan's YER base price is converted to the requested settlement
        currency using the live FX rate at checkout time so the charged amount
        always reflects the current exchange rate. The applied exchange rate
        (plus base amount/currency) is recorded on the payment row.

        Idempotency: when `idempotency_key` is supplied we reuse an existing
        PENDING payment with the same key (single charge even if the app
        retries after a network failure or double-tap). The key is also handed
        to Stripe so duplicate PaymentIntent creation is rejected.
        """
        if not await self._enabled():
            raise StripeNotConfiguredError("Stripe غير مفعّل")
        plan = await self.get_plan(plan_id)
        if not plan:
            raise ValueError("الباقة غير موجودة")
        from app.domain.services.section_entitlements import validate_purchase
        validate_purchase(org, self._plan_package_key(plan))

        # Reuse an existing pending intent with the same idempotency key.
        if idempotency_key:
            existing = (
                await self.db.execute(
                    select(StripePayment).where(
                        StripePayment.user_id == user.id,
                        StripePayment.plan_id == plan.id,
                        StripePayment.period == period,
                        StripePayment.idempotency_key == idempotency_key,
                        StripePayment.status == "pending",
                    ).order_by(StripePayment.created_at.desc())
                )
            ).scalars().first()
            if existing and existing.stripe_payment_intent_id:
                publishable = settings.STRIPE_PUBLISHABLE_KEY
                client_secret = await self._retrieve_client_secret(existing.stripe_payment_intent_id)
                if not client_secret:
                    raise ValueError("تعذر استرجاع عملية الدفع السابقة، حاول مرة أخرى")
                return {
                    "client_secret": client_secret,
                    "publishable_key": publishable,
                    "payment_id": str(existing.id),
                    "stripe_payment_intent_id": existing.stripe_payment_intent_id,
                    "plan_id": str(plan.id),
                    "plan_name": plan.name,
                    "amount": existing.amount,
                    "currency": (existing.currency or "SAR").upper(),
                    "display_currency": target_currency.upper() if target_currency else (existing.currency or "SAR").upper(),
                    "display_amount": existing.amount,
                    "period": period,
                    "reused": True,
                }

        stripe = await self._stripe()
        charge = await self._resolve_charge(plan, period, target_currency)
        amount_minor = charge["amount_minor"]
        currency = charge["currency"]
        minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(currency, 100)

        payment = StripePayment(
            user_id=user.id, organization_id=org.id, provider="stripe",
            plan_id=plan.id, plan_name=plan.name, period=period,
            amount=float(amount_minor) / minor_units,
            amount_minor=amount_minor,
            currency=currency.upper(),
            status="pending",
            mode=settings.STRIPE_MODE or "test",
            base_amount=charge["base_amount"],
            base_currency=(charge.get("base_currency") or "YER").upper(),
            exchange_rate=charge["exchange_rate"],
            fx_source=charge.get("fx_source") or charge["source"],
            idempotency_key=idempotency_key,
            metadata_=json.dumps({"period": period}),
        )
        self.db.add(payment)
        await self.db.flush()
        customer_id = None
        try:
            customer_id = await self.get_or_create_customer(user, org)
        except Exception as exc:  # noqa: BLE001
            logger.warning("payment_intent_customer_failed", error=str(exc))
        create_kwargs = dict(
            amount=int(amount_minor),
            currency=currency,
            automatic_payment_methods={"enabled": True},
            receipt_email=user.email,
            metadata={
                "fyona_user_id": str(user.id),
                "fyona_org_id": str(org.id),
                "fyona_plan_id": str(plan.id),
                "fyona_plan_name": plan.name or "",
                "fyona_payment_id": str(payment.id),
                "fyona_period": period,
                "fyona_amount_minor": int(amount_minor),
                "fyona_currency": currency,
                "fyona_display_currency": charge.get("display_currency") or "",
                "fyona_display_amount": charge.get("display_amount") or "",
                "fyona_idempotency_key": idempotency_key or "",
            },
        )
        if customer_id:
            create_kwargs["customer"] = customer_id
            create_kwargs["setup_future_usage"] = "off_session"
        if idempotency_key:
            create_kwargs["idempotency_key"] = idempotency_key
        try:
            intent = stripe.PaymentIntent.create(**create_kwargs)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            low = msg.lower()
            if "minimum" in low or "at least" in low or "amount_too_small" in low:
                raise ValueError(
                    "المبلغ المستحق أقل من الحد الأدنى الذي يقبله مزوّد الدفع "
                    "لهذه العملة. ارفع سعر الباقة أو خفّض نسبة الخصم ثم أعد المحاولة."
                )
            raise
        payment.stripe_payment_intent_id = intent.id
        await self.db.commit()
        await self.db.refresh(payment)
        logger.info("payment_intent_created", user_id=str(user.id), org_id=str(org.id),
                    plan_id=str(plan.id), intent_id=intent.id, payment_id=str(payment.id),
                    amount_minor=amount_minor, currency=currency, source=charge["source"],
                    exchange_rate=charge["exchange_rate"],
                    fallback_to_usd=charge.get("fallback_to_usd", False))
        publishable = settings.STRIPE_PUBLISHABLE_KEY
        return {
            "client_secret": intent.client_secret,
            "publishable_key": publishable,
            "payment_id": str(payment.id),
            "stripe_payment_intent_id": intent.id,
            "plan_id": str(plan.id),
            "plan_name": plan.name,
            "amount": float(amount_minor) / minor_units,
            "currency": currency.upper(),
            "display_currency": charge.get("display_currency") or currency.upper(),
            "display_amount": charge.get("display_amount") or (float(amount_minor) / minor_units),
            "period": period,
            "exchange_rate": charge["exchange_rate"],
            "base_currency": (charge.get("base_currency") or "YER").upper(),
            "fx_source": charge.get("fx_source") or charge["source"],
            "fallback_to_usd": charge.get("fallback_to_usd", False),
            "reused": False,
        }

    async def _retrieve_client_secret(self, intent_id: str) -> str:
        """Fetch the current client_secret for an existing PaymentIntent."""
        stripe = await self._stripe()
        if not intent_id:
            return ""
        try:
            intent = stripe.PaymentIntent.retrieve(intent_id)
            return getattr(intent, "client_secret", "") or ""
        except Exception as exc:
            logger.warning("payment_intent_retrieve_failed", intent_id=intent_id, error=str(exc))
            return ""

    async def confirm_stripe_payment(self, user_id: UUID, org_id: UUID, payment_intent_id: Optional[str] = None, payment_id: Optional[str] = None) -> dict:
        """Verify a Stripe PaymentIntent succeeded and activate the subscription instantly.

        Called by the mobile app right after `presentPaymentSheet` succeeds.
        This is the fast-path activation that does NOT wait for the webhook
        (which may be delayed). Idempotent — if already paid/activated it
        simply returns the current status.
        """
        from sqlalchemy import select

        payment = None
        if payment_intent_id:
            payment = await self._payment_by_intent(payment_intent_id)
        if not payment and payment_id:
            try:
                pid = UUID(str(payment_id))
                res = await self.db.execute(select(StripePayment).where(StripePayment.id == pid, StripePayment.organization_id == org_id))
                payment = res.scalar_one_or_none()
            except Exception:
                payment = None
        if not payment:
            raise ValueError("عملية الدفع غير موجودة")
        # Ensure ownership
        if str(payment.user_id) != str(user_id) or str(payment.organization_id) != str(org_id):
            raise ValueError("عملية الدفع لا تخص هذا المستخدم")

        # If already active ON THE SAME plan, still verify the intent with
        # Stripe before reporting success: a failed/canceled intent must
        # never get a success answer, even when the org is already active.
        # (A paid intent for a DIFFERENT plan falls through to activation.)
        org = await self._get_organization(org_id)
        _paid_plan = (payment.plan_name or "").strip().lower()
        _current_plan = (org.subscription_plan if org and org.subscription_plan else "").strip().lower() if org else ""
        _same_plan_active = bool(
            org and org.subscription_status == "active" and org.subscription_end_date
            and _paid_plan and _paid_plan == _current_plan
        )
        stripe = await self._stripe()
        intent_id = payment_intent_id or payment.stripe_payment_intent_id
        if not intent_id:
            raise ValueError("لا يوجد PaymentIntent مرتبط")
        try:
            intent = stripe.PaymentIntent.retrieve(intent_id)
        except Exception as exc:
            logger.warning("confirm_retrieve_failed", intent_id=intent_id, error=str(exc))
            raise ValueError("تعذر التحقق من حالة الدفع في Stripe")

        stripe_status = getattr(intent, "status", "")
        # Stripe marks successful card payments as 'succeeded'. Anything else
        # (requires_payment_method, requires_action, processing, canceled,
        # failed — e.g. insufficient funds or declined) is a hard failure:
        # no activation, no invoice, no success answer.
        if stripe_status != "succeeded":
            raise ValueError(f"حالة الدفع في Stripe هي '{stripe_status}' وليست ناجحة بعد")

        if not self._verify_intent_amount(intent, payment.amount_minor, payment.currency):
            logger.warning("confirm_amount_mismatch", intent_id=intent_id, expected_minor=payment.amount_minor, expected_currency=payment.currency)
            raise ValueError("مبلغ الدفع غير متطابق — تم رفض التأكيد")

        if _same_plan_active:
            return {"status": "active", "already_active": True, "plan_name": payment.plan_name, "period": payment.period}

        # Mark paid and activate (idempotent)
        if payment.status != "paid":
            payment.status = "paid"
            await self.db.commit()

        await self._activate_subscription(intent)
        return {"status": "active", "plan_name": payment.plan_name, "period": payment.period, "amount": payment.amount, "currency": payment.currency}

    def construct_event(self, payload: bytes, sig_header: str, secret: Optional[str] = None):
        """Verify + parse a Stripe webhook payload.

        `secret` should be the webhook signing secret resolved by the caller
        (DB-stored value with env fallback, see `_webhook_secret`). When not
        provided it falls back to the env var for backwards compatibility.
        """
        if not stripe_sdk:
            raise StripeNotConfiguredError("مكتبة Stripe غير مثبتة في الخادم")
        secret = secret or settings.STRIPE_WEBHOOK_SECRET
        if not secret:
            raise StripeNotConfiguredError("لم يتم تكوين Stripe webhook secret")
        return stripe_sdk.Webhook.construct_event(
            payload=payload, sig_header=sig_header, secret=secret,
            tolerance=settings.STRIPE_WEBHOOK_TOLERANCE,
        )

    async def _event_processed(self, event_id: str) -> bool:
        row = (
            await self.db.execute(
                select(StripeWebhookEvent).where(StripeWebhookEvent.event_id == event_id)
            )
        ).scalar_one_or_none()
        return bool(row is not None and (row.status or "") == "processed")

    async def _mark_event(self, event_id: str, event_type: str, status: str) -> None:
        from sqlalchemy.exc import IntegrityError
        existing = (
            await self.db.execute(
                select(StripeWebhookEvent).where(StripeWebhookEvent.event_id == event_id)
            )
        ).scalar_one_or_none()
        if existing is not None:
            existing.event_type = event_type
            existing.status = status
            existing.processed_at = datetime.now(timezone.utc)
            await self.db.commit()
            return
        try:
            self.db.add(StripeWebhookEvent(event_id=event_id, event_type=event_type, status=status))
            await self.db.commit()
        except IntegrityError:
            await self.db.rollback()
            try:
                race = (
                    await self.db.execute(
                        select(StripeWebhookEvent).where(StripeWebhookEvent.event_id == event_id)
                    )
                ).scalar_one_or_none()
                if race is not None:
                    race.status = status
                    race.event_type = event_type
                    race.processed_at = datetime.now(timezone.utc)
                    await self.db.commit()
            except Exception:
                logger.info("webhook_duplicate_marked", event_id=event_id)

    async def handle_event(self, event) -> None:
        event_id, event_type = event.id, event.type
        if await self._event_processed(event_id):
            logger.info("webhook_duplicate_ignored", event_id=event_id)
            return
        try:
            if event_type == "checkout.session.completed":
                await self._on_checkout_completed(event.data.object, event_id)
            elif event_type == "payment_intent.succeeded":
                await self._on_payment_intent_succeeded(event.data.object, event_id)
            elif event_type == "invoice.paid":
                # Auto-renewal lifecycle (independent layer — one-time flow untouched).
                await self._on_renewal_paid(event.data.object)
            elif event_type in ("invoice.payment_failed", "invoice.payment_failed:async", "payment_intent.payment_failed"):
                await self._on_payment_failed(event.data.object)
            elif event_type == "charge.refunded":
                await self._on_refunded(event.data.object)
            elif event_type == "customer.subscription.updated":
                await self._on_subscription_updated(event.data.object)
            elif event_type == "customer.subscription.deleted":
                await self._on_subscription_deleted(event.data.object)
            else:
                logger.info("webhook_event_unhandled", event_type=event_type, event_id=event_id)
            await self._mark_event(event_id, event_type, "processed")
        except Exception as exc:
            logger.error("webhook_event_error", event_type=event_type, event_id=event_id, error=str(exc))
            await self._mark_event(event_id, event_type, "error")

    def _verify_intent_amount(self, intent_or_session, expected_minor: Optional[int], expected_currency: Optional[str]) -> bool:
        """Server-side truth check before marking a payment paid.

        The charged `amount`/`currency` observed on Stripe must match what the
        backend computed at intent creation. A mismatch (e.g. a tampered intent)
        is rejected — we never trust client-side amounts. Missing expectations
        fail closed (no legacy bypass): an unverifiable charge is rejected.
        """
        if expected_minor is None or expected_currency is None:
            return False
        actual_amount = getattr(intent_or_session, "amount", None)
        if actual_amount is None:
            actual_amount = getattr(intent_or_session, "amount_total", None)
        actual_currency = getattr(intent_or_session, "currency", None)
        if actual_amount is None or actual_currency is None:
            return False
        return int(actual_amount) == int(expected_minor) and str(actual_currency).lower() == str(expected_currency).lower()

    async def _on_checkout_completed(self, session, event_id: Optional[str] = None) -> None:
        payment = await self._find_payment_by_session(getattr(session, "id", None))
        if payment and payment.status != "paid":
            # The session itself must report paid — never activate on an
            # unpaid/abandoned checkout, even if the event arrived.
            if getattr(session, "payment_status", "paid") != "paid":
                logger.warning("checkout_unpaid_session", session_id=getattr(session, "id", None),
                               payment_status=getattr(session, "payment_status", None))
                payment.status = "failed"
                await self.db.commit()
                return
            if not self._verify_intent_amount(session, payment.amount_minor, payment.currency):
                logger.warning("checkout_amount_mismatch", session_id=getattr(session, "id", None),
                               expected_minor=payment.amount_minor, expected_currency=payment.currency)
                payment.status = "failed"
                await self.db.commit()
                return
            payment.status = "paid"
            payment.stripe_payment_intent_id = getattr(session, "payment_intent", None) or payment.stripe_payment_intent_id
            payment.stripe_event_id = event_id or payment.stripe_event_id
            await self.db.commit()
        await self._activate_subscription(session)

    async def _on_payment_intent_succeeded(self, intent, event_id: Optional[str] = None) -> None:
        intent_id = getattr(intent, "id", None)
        payment = await self._payment_by_intent(intent_id) if intent_id else None
        if payment and payment.status != "paid":
            if not self._verify_intent_amount(intent, payment.amount_minor, payment.currency):
                logger.warning("payment_intent_amount_mismatch", intent_id=intent_id,
                               expected_minor=payment.amount_minor, expected_currency=payment.currency)
                payment.status = "failed"
                await self.db.commit()
                return
            payment.status = "paid"
            payment.stripe_event_id = event_id or payment.stripe_event_id
            await self.db.commit()
        await self._activate_subscription(intent)

    async def _find_payment_by_session(self, session_id) -> Optional[StripePayment]:
        if not session_id:
            return None
        res = await self.db.execute(select(StripePayment).where(StripePayment.stripe_checkout_session_id == session_id))
        return res.scalar_one_or_none()

    async def _activate_subscription(self, session) -> None:
        meta = getattr(session, "metadata", {}) or {}
        org_id = meta.get("fyona_org_id")
        plan_id = meta.get("fyona_plan_id")
        plan_name = meta.get("fyona_plan_name") or ""
        if not org_id:
            return
        org_uuid = _to_uuid(org_id)
        if org_uuid is None:
            return
        org = await self._get_organization(org_uuid)
        if not org:
            return
        now = datetime.now(timezone.utc)
        period = meta.get("fyona_period") or "yearly"
        days = 30 if period == "monthly" else 365
        user_uuid = _to_uuid(meta.get("fyona_user_id"))

        # ── Resolve the TRUE paid amount/currency (fail-closed, §8) ──
        # The invoice must reflect what Stripe actually charged — never a
        # 0.0/USD fallback. Resolution order:
        #   1. StripePayment row (backend-computed at intent creation), found
        #      via the session's payment_intent id (sessions) or via the
        #      object's own id when it IS a PaymentIntent (pi_xxx ids never
        #      match stripe_checkout_session_id, so a checkout-only lookup
        #      can never find them — that was the $0 root cause).
        #   2. The Stripe object itself (amount_received/amount/amount_total
        #      + currency) as the trusted source when no local row exists.
        #   3. FAIL CLOSED: raise instead of writing a $0 invoice. A genuine
        #      Stripe zero (amount explicitly 0) is the only allowed zero.
        payment = None
        intent_id = getattr(session, "payment_intent", None)
        if isinstance(intent_id, dict):
            intent_id = intent_id.get("id")
        if intent_id:
            payment = await self._payment_by_intent(intent_id)
        if not payment:
            checkout_id = getattr(session, "id", None)
            # Only match checkout rows for real session ids — a pi_xxx id
            # must never be compared against stripe_checkout_session_id.
            if checkout_id and str(checkout_id).startswith("cs_"):
                res = await self.db.execute(
                    select(StripePayment).where(StripePayment.stripe_checkout_session_id == checkout_id)
                )
                payment = res.scalar_one_or_none()
        if not payment:
            # The object itself may BE the PaymentIntent — look the local
            # row up by its own intent id directly.
            own_id = getattr(session, "id", None)
            if own_id and str(own_id).startswith("pi_"):
                payment = await self._payment_by_intent(str(own_id))

        paid_amount: Optional[float] = None
        paid_currency: Optional[str] = None
        if payment is not None and payment.amount_minor is not None and payment.currency:
            minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(
                (payment.currency or "usd").lower(), 100
            )
            paid_amount = (payment.amount_minor or 0) / minor_units
            paid_currency = (payment.currency or "USD").upper()
        if paid_amount is None:
            # Trusted fallback: what Stripe itself reports on this object.
            # amount_received is the actually-settled sum; fall back to the
            # authorized amount / session total when not present.
            stripe_amount = getattr(session, "amount_received", None)
            if stripe_amount is None:
                stripe_amount = getattr(session, "amount", None)
            if stripe_amount is None:
                stripe_amount = getattr(session, "amount_total", None)
            stripe_currency = getattr(session, "currency", None)
            if stripe_amount is not None and stripe_currency:
                try:
                    minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(
                        str(stripe_currency).lower(), 100
                    )
                    paid_amount = int(stripe_amount) / minor_units
                    paid_currency = str(stripe_currency).upper()
                except (TypeError, ValueError):
                    paid_amount = None
        if paid_amount is None or not paid_currency:
            logger.error(
                "activate_no_truthful_amount",
                provider_payment_id=_extract_provider_payment_id(session),
                object_id=getattr(session, "id", None),
            )
            raise ValueError("تعذر تحديد مبلغ الدفع الحقيقي — تم رفض التفعيل")

        # ── Stable provider key + card brand from the Stripe object ──
        provider_payment_id = _extract_provider_payment_id(session)
        card_brand = _extract_card_brand(session)

        # ── Idempotency: the same provider payment is never processed twice ──
        if provider_payment_id:
            from app.domain.entities.subscription_invoice_entities import (
                SubscriptionInvoice as _SI,
            )
            from sqlalchemy import select as _sel0
            dup = (
                await self.db.execute(
                    _sel0(_SI).where(
                        _SI.provider_payment_id == provider_payment_id
                    )
                )
            ).scalar_one_or_none()
            if dup is not None:
                logger.info(
                    "stripe_payment_already_processed",
                    provider_payment_id=provider_payment_id,
                )
                return

        # ── Activate the org subscription ──
        from app.domain.services.section_entitlements import activate
        activate(org, plan_name or "personal", days=days, now=now)
        await self.db.commit()
        await self.db.refresh(org)
        # Mirror onto the user row: readers of users.subscription_plan
        # (profile fallbacks, AI context) must agree with the org — no new
        # source of truth, just write-through (best-effort, never fatal).
        await self._sync_user_subscription(
            user_uuid, org.subscription_plan, "active",
            org.subscription_start_date, org.subscription_end_date,
        )

        existing_sub = (
            await self.db.execute(
                select(StripeSubscription).where(
                    StripeSubscription.organization_id == org.id,
                    StripeSubscription.status == "active",
                    StripeSubscription.plan_name == plan_name,
                )
            )
        ).scalars().first()
        if existing_sub:
            existing_sub.plan_name = plan_name or existing_sub.plan_name
            existing_sub.plan_id = _to_uuid(plan_id) if plan_id else existing_sub.plan_id
            existing_sub.current_period_start = now
            existing_sub.current_period_end = now + timedelta(days=days)
            await self.db.commit()
        else:
            sub = StripeSubscription(
                user_id=user_uuid,
                organization_id=org.id,
                plan_id=_to_uuid(plan_id) if plan_id else None,
                stripe_subscription_id=getattr(session, "subscription", None),
                plan_name=plan_name, status="active",
                current_period_start=now, current_period_end=now + timedelta(days=days),
            )
            self.db.add(sub)
            await self.db.commit()

        # ── Bind the Stripe customer to the billing profile ──
        # The PaymentIntent/CheckoutSession carries the customer Stripe used
        # for this charge. Recording it now keeps exactly one customer per
        # org, so a later renewal binds the same customer instead of minting
        # another one (whose Subscriptions tab would stay empty). Never
        # overwrites an id that is already stored; never breaks activation.
        try:
            _sess_customer = getattr(session, "customer", None)
            if isinstance(_sess_customer, dict):
                _sess_customer = _sess_customer.get("id")
            if isinstance(_sess_customer, str) and _sess_customer.startswith("cus_"):
                _prof_row = existing_sub if existing_sub else sub
                if _prof_row is not None and not _prof_row.stripe_customer_id:
                    _prof_row.stripe_customer_id = _sess_customer
                    await self.db.commit()
        except Exception as exc:  # noqa: BLE001
            logger.warning("activate_customer_bind_failed", error=str(exc))

        # ── Auto-renew follows the newly-paid plan ──
        # A one-time purchase of a different plan must not leave renewal
        # bound to the old plan/price. Best-effort: never breaks activation.
        try:
            await self._sync_renewal_to_plan(org, plan_id, plan_name, period)
        except Exception as exc:
            logger.warning("renewal_plan_sync_failed", error=str(exc))

        # ── Book the e-payment in the platform revenue ledger (no bank:
        # the money sits with the card processor, not a platform bank) ──
        await self._book_stripe_revenue(
            org, user_uuid, plan_name, period,
            paid_amount, paid_currency, provider_payment_id,
        )

        # ── Create SubscriptionInvoice (idempotent) ──
        invoice_number = await self._create_stripe_invoice(
            org, user_uuid, plan_name, period, paid_amount, paid_currency,
            now, days, provider_payment_id, card_brand,
        )

        # ── Unified subscription welcome (one row + one push per real
        # activation; idempotent via source_notif_id).  Activation rows above
        # are byte-identical; only this notification hook changed.  Runs AFTER
        # ACTIVE status is committed; never before.  Best-effort with a clear
        # log — never breaks the activation.
        try:
            from app.domain.services.subscription_welcome import (
                send_subscription_welcome as _send_welcome,
            )

            _welcome_event = f"stripe:{provider_payment_id or invoice_number or 'unknown'}"
            await _send_welcome(
                self.db,
                user_id=user_uuid,
                org_id=org.id,
                event=_welcome_event,
                invoice_no=invoice_number,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("stripe_welcome_notify_failed", error=str(exc),
                           user_id=str(user_uuid), org_id=str(org.id))

        # ── Notify platform admins about the new Stripe payment ──
        await self._notify_admins_stripe_payment(org.id, user_uuid, plan_name, paid_amount, paid_currency)

        logger.info("subscription_activated", org_id=str(org.id), plan=plan_name, amount=paid_amount, currency=paid_currency)

    async def _sync_renewal_to_plan(self, org, plan_id, plan_name, period) -> None:
        """Re-point an active auto-renewal at the newly-purchased plan.

        Called after every one-time activation. No-ops when there is no
        Stripe subscription, when renewal was disabled (cancel_at_period_end
        stays off-market), or when the price is not configured. Raises on
        Stripe errors so the caller can log (never fatal to activation —
        callers wrap in try/except).
        """
        res = await self.db.execute(
            select(StripeSubscription).where(
                StripeSubscription.organization_id == org.id,
                StripeSubscription.stripe_subscription_id.isnot(None),
            ).order_by(StripeSubscription.created_at.desc())
        )
        profile = res.scalars().first()
        if profile is None:
            return
        new_plan_uuid = _to_uuid(plan_id) if plan_id else None
        same_plan = (
            new_plan_uuid is not None
            and profile.plan_id is not None
            and str(profile.plan_id) == str(new_plan_uuid)
        )
        # Local row always tracks the current plan (display consistency),
        # even when renewal itself is disabled.
        if new_plan_uuid is not None:
            profile.plan_id = new_plan_uuid
        if plan_name:
            profile.plan_name = plan_name
        if same_plan or profile.cancel_at_period_end:
            await self.db.commit()
            return
        plan = await self.get_plan(new_plan_uuid) if new_plan_uuid else None
        if plan is None:
            await self.db.commit()
            return
        stripe = await self._stripe()
        # Renewal follows what was PAID (locked price), not the editable
        # list price — a switch re-locks to the just-paid charge.
        try:
            price_id = await self._renewal_price_for_org(
                stripe, org, plan, period or "yearly")
        except ValueError as exc:
            logger.warning("renewal_plan_sync_bad_price", error=str(exc))
            await self.db.commit()
            return
        live = stripe.Subscription.modify(
            profile.stripe_subscription_id,
            items=[{"price": price_id}],
            proration_behavior="none",
            metadata={
                "fyona_plan_id": str(new_plan_uuid),
                "fyona_plan_name": plan_name or "",
                "fyona_period": period or "yearly",
            },
        )
        try:
            profile.status = getattr(live, "status", None) or profile.status
            cps = getattr(live, "current_period_start", None)
            cpe = getattr(live, "current_period_end", None)
            if cps:
                profile.current_period_start = _from_ts(cps)
            if cpe:
                profile.current_period_end = _from_ts(cpe)
        except Exception:
            pass
        await self.db.commit()
        logger.info("renewal_plan_synced", org_id=str(org.id),
                    plan=plan_name, subscription_id=profile.stripe_subscription_id)

    async def _sync_user_subscription(self, user_uuid, plan_name, status, start, end) -> None:
        """Write-through org subscription state onto the users row.

        Several readers (profile offline fallback, AI context) use
        users.subscription_plan; without this they lag one purchase behind.
        Best-effort: failures are logged, never raised.
        """
        try:
            if user_uuid is None:
                return
            res = await self.db.execute(select(User).where(User.id == user_uuid))
            user = res.scalar_one_or_none()
            if user is None:
                return
            user.subscription_plan = plan_name
            user.subscription_status = status
            user.subscription_start_date = start
            user.subscription_end_date = end
            await self.db.commit()
        except Exception as exc:
            logger.warning("sync_user_subscription_failed", error=str(exc))

    async def _book_stripe_revenue(
        self, org, user_uuid, plan_name, period,
        paid_amount, paid_currency, provider_payment_id,
    ) -> None:
        """Record e-payment income in the virtual Stripe bank (visible in admin
        banks/stats/entries), at the Stripe-confirmed amount/currency.
        Idempotent per provider payment: repeats and webhook redeliveries
        never book twice."""
        from app.domain.entities.admin_entities import SubscriptionRevenue
        from sqlalchemy import select as _selr

        if provider_payment_id:
            dup = (
                await self.db.execute(
                    _selr(SubscriptionRevenue).where(
                        SubscriptionRevenue.provider_payment_id == provider_payment_id
                    )
                )
            ).scalar_one_or_none()
            if dup is not None:
                return
        # Lazy import: avoids API-layer coupling at module import time.
        from app.api.v1.admin import ensure_stripe_bank, ensure_bank_currency
        stripe_bank = await ensure_stripe_bank(self.db)
        currency = await ensure_bank_currency(self.db, stripe_bank, paid_currency)
        plan_ar = {"personal": "شخصي", "business": "أعمال", "premium": "أعمال + شخصي"}.get(
            (plan_name or "").lower(), plan_name
        )
        self.db.add(SubscriptionRevenue(
            request_id=None,
            organization_id=org.id,
            user_id=user_uuid,
            bank_account_id=stripe_bank.id,
            plan_name=plan_name or "personal",
            period=period,
            amount=paid_amount,
            currency=currency,
            provider_payment_id=provider_payment_id,
            note=f"إيراد اشتراك دفع إلكتروني — {plan_ar}",
        ))
        await self.db.flush()

    async def _create_stripe_invoice(self, org, user_uuid, plan_name, period, paid_amount, paid_currency, now, days, provider_payment_id=None, card_brand=None) -> Optional[str]:
        """Create a SubscriptionInvoice record for a Stripe payment (idempotent).

        Returns the invoice number (new or already-existing) so notifiers can
        deep-link the exact invoice (§13) — never a stale/plan-name lookup.
        """
        from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
        from sqlalchemy import select as _sel

        # Strong idempotency: same provider payment → same invoice.
        if provider_payment_id:
            dup = (
                await self.db.execute(
                    _sel(SubscriptionInvoice).where(
                        SubscriptionInvoice.provider_payment_id == provider_payment_id
                    )
                )
            ).scalar_one_or_none()
            if dup is not None:
                return dup.invoice_number
        # Fallback: same org+timeframe (covers old rows without a pid).
        existing = (
            await self.db.execute(
                _sel(SubscriptionInvoice).where(
                    SubscriptionInvoice.organization_id == org.id,
                    SubscriptionInvoice.payment_method == "stripe",
                    SubscriptionInvoice.subscription_start_date >= now - timedelta(minutes=5),
                )
            )
        ).scalars().first()
        if existing:
            return existing.invoice_number

        # Generate unique invoice number
        from datetime import date as _date
        from sqlalchemy import func as _func
        today = _date.today()
        prefix = f"INV-{today.strftime('%Y%m%d')}"
        inv_number = f"{prefix}-0001"
        for attempt in range(5):
            candidate = f"{prefix}-{(attempt + 1):04d}"
            check = await self.db.execute(
                _sel(_func.count()).select_from(SubscriptionInvoice).where(SubscriptionInvoice.invoice_number == candidate)
            )
            if (check.scalar() or 0) == 0:
                inv_number = candidate
                break

        plan_ar = {"personal": "شخصي", "business": "أعمال", "premium": "أعمال + شخصي"}.get((plan_name or "").lower(), plan_name)
        invoice = SubscriptionInvoice(
            invoice_number=inv_number,
            organization_id=org.id,
            user_id=user_uuid,
            plan_name=plan_name or "personal",
            period=period,
            amount=paid_amount,
            currency=paid_currency,
            status="paid",
            payment_method="stripe",
            card_brand=card_brand,
            provider_payment_id=provider_payment_id,
            subscription_start_date=now,
            subscription_end_date=now + timedelta(days=days),
            notes=f"إيراد اشتراك دفع إلكتروني — {plan_ar}",
        )
        self.db.add(invoice)
        await self.db.commit()
        return inv_number

    async def _notify_user_stripe_activation(self, org_id, user_uuid, plan_name, paid_amount, paid_currency, period, now, days, provider_payment_id=None, invoice_number=None):
        """Send in-app notification + push to user after Stripe payment.

        Single authoritative user notification (§10): idempotent on
        (user_id + exact action payload). The payload deep-links the exact
        invoice (§13). Concurrent confirm+webhook races can never produce a
        second user notification for the same payment.
        """
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.services import push_service
        from sqlalchemy import select as _seln

        plan_ar = {"personal": "الباقة الشخصية", "business": "باقة الأعمال", "premium": "باقة الأعمال + الشخصية"}.get(
            (plan_name or "").lower(), plan_name or "الباقة"
        )
        payload = "/subscription/invoice"
        if invoice_number:
            payload = f"/subscription/invoice?invoice_no={invoice_number}"
        # ── User-notification idempotency (§10): same user + same exact
        # payload (i.e. same payment/invoice) → already notified, skip. ──
        try:
            dupn = (
                await self.db.execute(
                    _seln(AppNotification).where(
                        AppNotification.user_id == user_uuid,
                        AppNotification.action_payload == payload,
                        AppNotification.type == "success",
                    )
                )
            ).scalar_one_or_none()
            if dupn is not None:
                logger.info("stripe_user_notif_duplicate_skipped", payload=payload)
                return
        except Exception as exc:
            logger.warning("stripe_user_notif_dedup_check_failed", error=str(exc))
        notif = AppNotification(
            organization_id=org_id,
            user_id=user_uuid,
            type="success",
            title=f"تم تفعيل اشتراكك في {plan_ar} 🎉",
            message=f"تم تفعيل اشتراكك في {plan_ar} — انقر هنا لعرض الفاتورة وتفاصيل الاشتراك.",
            action="open_screen",
            action_payload=payload,
        )
        self.db.add(notif)
        await self.db.flush()
        notif_id = notif.id
        await self.db.commit()

        # NO user-facing email — the user is notified ONLY via the in-app
        # notification + an instant FCM push below.

        # Push to user device (DB row stays first; guarded separately).
        try:
            await push_service.notify_user(
                self.db,
                user_id=user_uuid,
                title="تم تفعيل اشتراكك 🎉",
                body=f"تم تفعيل باقتك ({plan_ar}) بنجاح — اضغط هنا لعرض الفاتورة والتفاصيل.",
                action="open_screen",
                action_payload=payload,
            )
        except Exception as exc:  # noqa: BLE001 - push never breaks activation
            logger.warning("stripe_user_push_failed", error=str(exc),
                           user_id=str(user_uuid))

    async def _notify_admins_stripe_payment(self, org_id, user_uuid, plan_name, paid_amount, paid_currency, kind: str = "new"):
        """Notify all platform admins when a Stripe payment is received.

        kind="new" for first-time card subscriptions, "renewal" for automatic
        renewal charges. Both carry user/org, plan, amount and currency.
        """
        from app.domain.services import push_service

        plan_ar = {"personal": "شخصي", "business": "أعمال", "premium": "أعمال + شخصي"}.get(plan_name.lower(), plan_name)
        amt_str = f"{paid_amount:,.2f}".rstrip("0").rstrip(".")
        is_renewal = kind == "renewal"
        title = "تجديد اشتراك — دفع إلكتروني" if is_renewal else "اشتراك جديد — دفع إلكتروني"
        verb = "جدّد" if is_renewal else "اشترك"

        # Get org name
        org_name = "مستخدم"
        try:
            from app.domain.entities.auth_entities import Organization as _Org
            from sqlalchemy import select as _sel
            res = await self.db.execute(_sel(_Org).where(_Org.id == org_id))
            org = res.scalar_one_or_none()
            if org:
                org_name = getattr(org, "company_name", None) or getattr(org, "name", None) or "مستخدم"
        except Exception:
            pass

        # In-app notification for each platform admin (DB rows first).
        try:
            admin_ids = await push_service.platform_admin_ids(self.db)
            from app.domain.entities.notification_entities import AppNotification
            for aid in admin_ids:
                notif = AppNotification(
                    organization_id=org_id,
                    user_id=aid,
                    type="success",
                    title=title,
                    message=f"{verb} {org_name} في الباقة ({plan_ar}) بمبلغ {amt_str} {paid_currency} عبر الدفع الإلكتروني.",
                    action="open_screen",
                    action_payload="/subscription",
                )
                self.db.add(notif)
            await self.db.commit()
        except Exception as exc:  # noqa: BLE001
            logger.warning("stripe_admin_notify_failed", error=str(exc))
            try:
                await self.db.rollback()
            except Exception:
                pass

        # Push to all platform admins (guarded separately).
        try:
            await push_service.notify_platform_admins(
                self.db,
                title=f"{title} 💳",
                body=f"{verb} {org_name} في الباقة ({plan_ar}) بمبلغ {amt_str} {paid_currency}.",
                action="open_screen",
                action_payload="/subscription",
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("stripe_admin_push_failed", error=str(exc))

    async def _get_organization(self, org_id) -> Optional[Organization]:
        res = await self.db.execute(select(Organization).where(Organization.id == org_id))
        return res.scalar_one_or_none()

    async def _on_payment_failed(self, invoice) -> None:
        # Recurring-billing failures route to the renewal path (records +
        # notifies, never extends). One-time PaymentIntent failures keep the
        # exact legacy behavior below.
        try:
            if getattr(invoice, "subscription", None):
                await self._on_renewal_failed(invoice)
                return
        except Exception:
            pass
        intent = getattr(invoice, "payment_intent", None)
        if isinstance(intent, str) and _looks_uuid(intent):
            payment = await self._payment_by_intent(intent)
            if payment and payment.status in ("pending", "paid"):
                payment.status = "failed"
                await self.db.commit()
        logger.warning("payment_failed", invoice_id=getattr(invoice, "id", None))

    async def _on_refunded(self, charge) -> None:
        intent = getattr(charge, "payment_intent", None)
        payment = None
        if intent:
            payment = await self._payment_by_intent(intent)
        if payment and payment.status == "paid":
            payment.status = "refunded"
            await self.db.commit()
        logger.info("payment_refunded", charge_id=getattr(charge, "id", None))

    async def _on_subscription_updated(self, subscription) -> None:
        await self._upsert_subscription(subscription, status=getattr(subscription, "status", None))

    async def _on_subscription_deleted(self, subscription) -> None:
        await self._upsert_subscription(subscription, status="canceled")

    async def _upsert_subscription(self, stripe_sub, status: str) -> None:
        sid = getattr(stripe_sub, "id", None)
        if not sid:
            return
        existing = await self.db.execute(select(StripeSubscription).where(StripeSubscription.stripe_subscription_id == sid))
        row = existing.scalar_one_or_none()
        if row:
            row.status = status or row.status
            row.current_period_start = _from_ts(getattr(stripe_sub, "current_period_start", None))
            row.current_period_end = _from_ts(getattr(stripe_sub, "current_period_end", None))
        else:
            self.db.add(StripeSubscription(
                stripe_subscription_id=sid,
                plan_name=getattr(stripe_sub, "plan", {}).get("id") if isinstance(getattr(stripe_sub, "plan", None), dict) else None,
                status=status or "incomplete",
                current_period_start=_from_ts(getattr(stripe_sub, "current_period_start", None)),
                current_period_end=_from_ts(getattr(stripe_sub, "current_period_end", None)),
            ))
        await self.db.commit()

    async def _payment_by_intent(self, intent) -> Optional[StripePayment]:
        res = await self.db.execute(select(StripePayment).where(StripePayment.stripe_payment_intent_id == intent))
        return res.scalar_one_or_none()

    async def list_payments(self, org_id=None, status=None, search=None, page=1, per_page=20):
        stmt = select(StripePayment).order_by(StripePayment.created_at.desc())
        if org_id:
            stmt = stmt.where(StripePayment.organization_id == org_id)
        if status:
            stmt = stmt.where(StripePayment.status == status)
        if search:
            like = f"%{search}%"
            stmt = stmt.where(
                (StripePayment.stripe_checkout_session_id.like(like)) |
                (StripePayment.stripe_payment_intent_id.like(like)) |
                (StripePayment.plan_name.like(like))
            )
        total = (await self.db.execute(select(func.count()).select_from(stmt.subquery()))).scalar() or 0
        rows = (await self.db.execute(stmt.offset((page - 1) * per_page).limit(per_page))).scalars().all()
        return [_payment_to_dict(p) for p in rows], total

    async def list_subscriptions(self, org_id=None, status=None, search=None, page=1, per_page=20):
        stmt = select(StripeSubscription).order_by(StripeSubscription.created_at.desc())
        if org_id:
            stmt = stmt.where(StripeSubscription.organization_id == org_id)
        if status:
            stmt = stmt.where(StripeSubscription.status == status)
        if search:
            like = f"%{search}%"
            stmt = stmt.where(
                (StripeSubscription.stripe_subscription_id.like(like)) |
                (StripeSubscription.plan_name.like(like))
            )
        total = (await self.db.execute(select(func.count()).select_from(stmt.subquery()))).scalar() or 0
        rows = (await self.db.execute(stmt.offset((page - 1) * per_page).limit(per_page))).scalars().all()
        return [_subscription_to_dict(s) for s in rows], total

    # ══════════════════════════════════════════════════════════════
    #  AUTO-RENEW (independent layer — one-time payment flow untouched)
    #
    #  Official Stripe recurring billing only: Customer → SetupIntent →
    #  Subscription (charge_automatically, off_session). No local cron, no
    #  charging from Flutter. Renewals arrive via invoice.paid webhooks.
    # ══════════════════════════════════════════════════════════════

    async def _auto_profile(self, user_id, org_id):
        """The org's billing-profile row (holds stripe_customer_id)."""
        res = await self.db.execute(
            select(StripeSubscription).where(
                StripeSubscription.organization_id == org_id
            ).order_by(StripeSubscription.created_at.desc())
        )
        return res.scalars().first()

    async def _org_owns_customer(self, org_id, customer_id: str) -> bool:
        """True when this customer id is stored on any of the org's rows."""
        if not customer_id:
            return False
        try:
            res = await self.db.execute(
                select(StripeSubscription.id).where(
                    StripeSubscription.organization_id == org_id,
                    StripeSubscription.stripe_customer_id == str(customer_id),
                ).limit(1)
            )
            return res.scalar_one_or_none() is not None
        except Exception as exc:
            logger.warning("org_customer_check_failed", error=str(exc))
            return False

    async def _adopt_any_stored_customer(self, profile):
        """Adopt a customer id stored on an older row of the same org.

        A one-time activation row written after the customer row can leave
        the newest profile blank; adopting keeps a single customer per org.
        """
        try:
            res = await self.db.execute(
                select(StripeSubscription.stripe_customer_id).where(
                    StripeSubscription.organization_id == profile.organization_id,
                    StripeSubscription.stripe_customer_id.isnot(None),
                ).order_by(StripeSubscription.created_at.desc())
            )
            for cid in res.scalars().all() or []:
                if cid:
                    profile.stripe_customer_id = str(cid)
                    await self.db.commit()
                    return str(cid)
        except Exception as exc:
            logger.warning("adopt_stored_customer_failed", error=str(exc))
        return None

    async def _stripe_customer_belongs_to_org(self, stripe, customer_id: str, org) -> bool:
        """Ground-truth check on Stripe: the customer metadata names this org."""
        try:
            cust = stripe.Customer.retrieve(customer_id)
            meta = getattr(cust, "metadata", None) or {}
            get = (lambda k: meta.get(k) if isinstance(meta, dict) else getattr(meta, k, None))
            return str(get("fyona_org_id") or "") == str(getattr(org, "id", ""))
        except Exception as exc:
            logger.warning("stripe_customer_verify_failed", error=str(exc))
            return False

    async def get_or_create_customer(self, user, org, preferred_customer_id: Optional[str] = None) -> str:
        """One Stripe Customer per org. Reuses the stored id, never duplicates.

        Resolution order: an explicitly preferred id that already belongs to
        this org (e.g. the customer Stripe put on the just-paid
        PaymentIntent — it owns the card about to be bound) → the latest
        profile row → any older org row → create a brand-new customer.
        Adopted ids are written back onto the latest profile row so the next
        lookup is a single query again.
        """
        preferred = (preferred_customer_id or "").strip()
        if preferred.startswith("cus_") and await self._org_owns_customer(org.id, preferred):
            profile = await self._auto_profile(user.id, org.id)
            if profile is not None and not profile.stripe_customer_id:
                profile.stripe_customer_id = preferred
                await self.db.commit()
            logger.info("auto_renew_customer_adopted", user_id=str(user.id), org_id=str(org.id),
                        customer_id=preferred)
            return preferred
        profile = await self._auto_profile(user.id, org.id)
        if profile and profile.stripe_customer_id:
            return profile.stripe_customer_id
        if profile is not None:
            adopted = await self._adopt_any_stored_customer(profile)
            if adopted:
                return adopted
        if preferred.startswith("cus_"):
            stripe = await self._stripe()
            if await self._stripe_customer_belongs_to_org(stripe, preferred, org):
                if profile:
                    profile.stripe_customer_id = preferred
                else:
                    self.db.add(StripeSubscription(
                        user_id=user.id,
                        organization_id=org.id,
                        stripe_customer_id=preferred,
                        status="none",
                    ))
                await self.db.commit()
                logger.info("auto_renew_customer_adopted", user_id=str(user.id), org_id=str(org.id),
                            customer_id=preferred)
                return preferred
        if not await self._enabled():
            raise StripeNotConfiguredError("Stripe غير مفعّل")
        stripe = await self._stripe()
        customer = stripe.Customer.create(
            email=getattr(user, "email", None),
            name=getattr(user, "full_name", None) or getattr(user, "name", None),
            metadata={
                "fyona_user_id": str(user.id),
                "fyona_org_id": str(org.id),
            },
        )
        if profile:
            profile.stripe_customer_id = customer.id
            await self.db.commit()
        else:
            self.db.add(StripeSubscription(
                user_id=user.id,
                organization_id=org.id,
                stripe_customer_id=customer.id,
                status="none",
            ))
            await self.db.commit()
        logger.info("auto_renew_customer", user_id=str(user.id), org_id=str(org.id),
                    customer_id=customer.id)
        return customer.id

    async def create_setup_intent(self, user, org) -> dict:
        """SetupIntent for saving a card (explicit consent collected in-app).

        Returns ONLY the client secret — card data never touches FYONA.
        """
        customer_id = await self.get_or_create_customer(user, org)
        stripe = await self._stripe()
        intent = stripe.SetupIntent.create(
            customer=customer_id,
            payment_method_types=["card"],
            # Off-session renewals charge without the user present — declare
            # it now so the saved method is usable for future renewals.
            usage="off_session",
            metadata={
                "fyona_user_id": str(user.id),
                "fyona_org_id": str(org.id),
                "fyona_purpose": "auto_renew",
            },
        )
        return {
            "client_secret": intent.client_secret,
            "setup_intent_id": intent.id,
            "customer_id": customer_id,
            "publishable_key": settings.STRIPE_PUBLISHABLE_KEY,
        }

    def _auto_price_id(self, plan, period: str) -> str:
        price_id = (getattr(plan, "stripe_price_id_yearly", None)
                    if period == "yearly"
                    else getattr(plan, "stripe_price_id_monthly", None))
        if not price_id:
            raise ValueError("سعر Stripe لهذه المدة غير مهيأ — حدده من لوحة الإدارة أولاً")
        return price_id

    def _verified_price_id(self, stripe, price_id: str) -> str:
        """Ensure a linked Price ID really exists and is active on Stripe.

        A stale/deleted link otherwise explodes deep inside Subscription
        creation as an opaque 500. Fail here with a clear, actionable error.
        A zero-amount recurring price is also rejected: auto-renewal must
        never be bound to a $0 price (§16).
        """
        try:
            live_price = stripe.Price.retrieve(price_id)
        except Exception as exc:
            logger.warning("auto_renew_price_missing", price_id=price_id, error=str(exc))
            raise ValueError("سعر التجديد المرتبط بالباقة غير صالح — حدّثه من لوحة الإدارة")
        if not getattr(live_price, "active", False):
            raise ValueError("سعر التجديد معطّل حالياً — فعّله من لوحة Stripe")
        try:
            unit_amount = getattr(live_price, "unit_amount", None)
        except Exception:
            unit_amount = None
        if unit_amount is not None and int(unit_amount) <= 0:
            logger.warning("auto_renew_price_zero", price_id=price_id)
            raise ValueError("سعر التجديد صفر — حدّثه من لوحة الإدارة أولاً")
        return price_id

    async def _renewal_trial_end_ts(self, org) -> Optional[int]:
        """Unix timestamp of the org's current paid period end (server truth).

        Returns None when there is no usable future period end — the caller
        then falls back to immediate billing. A small 1h floor avoids a
        trial_end in the past (Stripe rejects those) on commit races.
        """
        try:
            fresh = await self._get_organization(getattr(org, "id", org))
            end = getattr(fresh, "subscription_end_date", None) if fresh else None
            if end is None:
                return None
            if getattr(end, "tzinfo", None) is None:
                end = end.replace(tzinfo=timezone.utc)
            now = datetime.now(timezone.utc)
            if end <= now + timedelta(hours=1):
                return None
            return int(end.timestamp())
        except Exception as exc:
            logger.warning("renewal_trial_end_unresolved", error=str(exc))
            return None

    async def _renewal_paid_charge(self, org) -> tuple:
        """The org's latest PAID one-time charge (minor units, currency).

        This is the backend-verified receipt — including any discount — and
        becomes the locked renewal price. Returns (None, None) when no paid
        charge exists (caller falls back to the plan's recurring price).
        Defensive: any malformed row degrades to (None, None), never raises.
        """
        try:
            res = await self.db.execute(
                select(StripePayment)
                .where(
                    StripePayment.organization_id == getattr(org, "id", org),
                    StripePayment.status == "paid",
                )
                .order_by(StripePayment.created_at.desc())
                .limit(1)
            )
            row = res.scalar_one_or_none()
            if row is None:
                return None, None
            minor = int(row.amount_minor or 0)
            cur = str(row.currency or "").strip().upper()
            if minor <= 0 or not cur:
                return None, None
            return minor, cur
        except Exception as exc:
            logger.warning("renewal_paid_charge_unresolved", error=str(exc))
            return None, None

    async def _locked_renewal_price_id(self, stripe, org, plan, period: str,
                                       amount_minor: int, currency: str) -> str:
        """Get-or-create a per-subscriber recurring Price locked to the paid
        amount (e.g. $8 after a 20% discount on $10 — never the list price).

        The lookup key embeds org + period + exact amount/currency, so an
        identical renewal reuses the same Price while a different paid amount
        mints a new one. Prices are immutable: future list-price edits can
        never move existing subscribers. Created under the plan's product so
        reporting stays grouped.
        """
        interval = "month" if period == "monthly" else "year"
        cur = currency.strip().lower()
        lookup = f"fyona_renew_{org.id}_{plan.id}_{period}_{amount_minor}{cur}"
        try:
            found = stripe.Price.list(lookup_keys=[lookup], limit=1)
            for p in getattr(found, "data", []) or []:
                try:
                    if (getattr(p, "active", False)
                            and int(getattr(p, "unit_amount", -1)) == int(amount_minor)
                            and str(getattr(p, "currency", "")).lower() == cur
                            and ((getattr(p, "recurring", None) or {}).get("interval")
                                 if isinstance(getattr(p, "recurring", None), dict)
                                 else getattr(getattr(p, "recurring", None), "interval", None)) == interval):
                        return p.id
                except (TypeError, ValueError):
                    continue
        except Exception as exc:
            logger.warning("locked_price_lookup_failed", error=str(exc))
        product_id = getattr(plan, "stripe_product_id", None)
        create_kwargs = dict(
            unit_amount=int(amount_minor),
            currency=cur,
            recurring={"interval": interval},
            lookup_key=lookup,
            metadata={
                "fyona_locked": "true",
                "fyona_source": "paid_amount",
                "fyona_org_id": str(org.id),
                "fyona_plan_id": str(plan.id),
                "fyona_period": period,
            },
        )
        if product_id:
            create_kwargs["product"] = product_id
        else:
            create_kwargs["product_data"] = {
                "name": getattr(plan, "name", "") or "FYONA plan"}
        try:
            created = stripe.Price.create(**create_kwargs)
        except Exception as exc:
            logger.warning("locked_price_create_failed", error=str(exc))
            raise ValueError("تعذر اعتماد سعر التجديد — أعد المحاولة")
        logger.info("locked_renewal_price", org_id=str(org.id),
                    price_id=created.id, amount=amount_minor, currency=cur)
        return created.id

    async def _renewal_price_for_org(self, stripe, org, plan, period: str) -> str:
        """Renewal Price ID for an org: locked-to-paid when a paid charge
        exists, otherwise the verified plan recurring price (legacy path)."""
        paid_minor, paid_cur = await self._renewal_paid_charge(org)
        if paid_minor is not None and paid_cur:
            return await self._locked_renewal_price_id(
                stripe, org, plan, period, paid_minor, paid_cur)
        return self._verified_price_id(stripe, self._auto_price_id(plan, period))

    async def enable_auto_renew(self, user, org, plan_id, period: str = "yearly",
                                payment_method_id: Optional[str] = None,
                                consent: bool = False,
                                preferred_customer_id: Optional[str] = None) -> dict:
        """Create the Stripe Subscription after explicit user consent.

        Price always comes from the plan's configured Stripe Price ID —
        never from the client.

        Renewal-at-expiry model: the subscription is created with
        trial_end = the org's current paid period end, so the FIRST real
        charge happens automatically AT expiry (off-session, no user
        action) — never at save time. If the org has no future period end
        (e.g. lapsed), no trial is set and the first period bills
        immediately (legacy immediate-charge path, may require 3DS).

        Renewal price is LOCKED to what the org actually paid (backend
        receipt, discount included — e.g. $8 after 20% off $10), via a
        per-subscriber immutable Stripe Price. Later list-price edits never
        move existing subscribers.
        """
        if consent is not True:
            raise ValueError("موافقة المستخدم على التجديد التلقائي مطلوبة")
        if not payment_method_id:
            raise ValueError("وسيلة الدفع المحفوظة مطلوبة")
        if period not in ("monthly", "yearly"):
            raise ValueError("مدة غير صالحة")
        if not await self._enabled():
            raise StripeNotConfiguredError("Stripe غير مفعّل")
        from app.domain.entities.admin_entities import Plan as _Plan
        plan = await self.get_plan(plan_id)
        if not plan:
            raise ValueError("الباقة غير موجودة")
        _ = _Plan
        stripe = await self._stripe()
        # Locked renewal price (paid receipt) with legacy plan-price fallback.
        price_id = await self._renewal_price_for_org(stripe, org, plan, period)
        customer_id = await self.get_or_create_customer(
            user, org, preferred_customer_id=preferred_customer_id)

        # The payment method must belong to THIS customer — never accept a
        # foreign id blindly. A method just saved via SetupIntent already
        # arrives attached: skip re-attaching instead of relying on fragile
        # error-message matching.
        pm = stripe.PaymentMethod.retrieve(payment_method_id)
        pm_customer = getattr(pm, "customer", None)
        if pm_customer not in (None, customer_id):
            raise ValueError("وسيلة الدفع لا تخص هذا الحساب")
        if pm_customer is None:
            try:
                stripe.PaymentMethod.attach(payment_method_id, customer=customer_id)
            except Exception as exc:
                code = getattr(exc, "code", "") or ""
                msg = str(exc)
                if code != "resource_already_exists" and "attach" not in msg:
                    raise
        try:
            stripe.Customer.modify(
                customer_id,
                invoice_settings={"default_payment_method": payment_method_id},
            )
        except Exception as exc:
            logger.warning("auto_renew_default_pm_failed", error=str(exc))
            raise ValueError("تعذر اعتماد وسيلة الدفع للتجديد — أعد المحاولة")
        # Verify the default actually stuck: without it, off-session renewal
        # charges would fail later while the UI claimed success.
        try:
            live_customer = stripe.Customer.retrieve(customer_id)
            inv_settings = getattr(live_customer, "invoice_settings", None) or {}
            default_pm = inv_settings.get("default_payment_method") if isinstance(inv_settings, dict) else getattr(inv_settings, "default_payment_method", None)
            if default_pm != payment_method_id:
                raise ValueError("تعذر اعتماد وسيلة الدفع للتجديد — أعد المحاولة")
        except ValueError:
            raise
        except Exception as exc:
            logger.warning("auto_renew_default_pm_verify_failed", error=str(exc))
            raise ValueError("تعذر التحقق من وسيلة الدفع — أعد المحاولة")

        # One active auto-renewal per org — reuse instead of duplicating.
        # Trial end is read server-side from the org's paid period end so the
        # first charge lands exactly at expiry (never a client-supplied date).
        trial_end_ts = await self._renewal_trial_end_ts(org)
        profile = await self._auto_profile(user.id, org.id)
        if profile and profile.stripe_subscription_id:
            try:
                live = stripe.Subscription.retrieve(profile.stripe_subscription_id)
                if getattr(live, "status", "") in ("active", "trialing", "past_due", "incomplete"):
                    # Keep a still-trialing renewal aligned with the newest
                    # paid period (e.g. after a plan switch mid-period).
                    if getattr(live, "status", "") == "trialing" and trial_end_ts:
                        try:
                            stripe.Subscription.modify(
                                profile.stripe_subscription_id, trial_end=trial_end_ts)
                        except Exception as exc:
                            logger.warning("auto_renew_trial_realign_failed", error=str(exc))
                    out_reused = {
                        "reused": True,
                        "stripe_subscription_id": live.id,
                        "status": live.status,
                    }
                    # Card just replaced on a past-due renewal: attempt the
                    # open invoice NOW (best-effort) so the user completes
                    # payment immediately instead of waiting for the schedule.
                    # invoice.paid webhook finalizes on success.
                    if (getattr(profile, "status", "") == "past_due"
                            or getattr(live, "status", "") == "past_due"):
                        try:
                            inv = getattr(live, "latest_invoice", None)
                            if isinstance(inv, str):
                                inv = stripe.Invoice.retrieve(inv)
                            if inv is not None and getattr(inv, "status", "") == "open":
                                paid_now = stripe.Invoice.pay(getattr(inv, "id", ""))
                                out_reused["renewal_charged"] = (
                                    getattr(paid_now, "status", "") == "paid")
                            else:
                                out_reused["renewal_charged"] = False
                        except Exception as exc:
                            logger.info("renewal_immediate_charge_failed",
                                        subscription=str(profile.stripe_subscription_id),
                                        error=str(exc))
                            out_reused["renewal_charged"] = False
                    return out_reused
            except Exception:
                pass

        create_kwargs = dict(
            customer=customer_id,
            items=[{"price": price_id}],
            default_payment_method=payment_method_id,
            collection_method="charge_automatically",
            payment_behavior="default_incomplete",
            # NOTE: valid values are off|on_subscription|none ("off_session"
            # is a SetupIntent usage, not a subscription setting — sending it
            # makes Stripe reject the whole creation with a 500 downstream).
            payment_settings={"save_default_payment_method": "off"},
            expand=["latest_invoice.payment_intent"],
            metadata={
                "fyona_user_id": str(user.id),
                "fyona_org_id": str(org.id),
                "fyona_plan_id": str(plan.id),
                "fyona_plan_name": getattr(plan, "name", "") or "",
                "fyona_period": period,
            },
        )
        if trial_end_ts:
            # Renewal starts billing at expiry: no charge today, status
            # becomes `trialing` (billed automatically when trial ends).
            create_kwargs["trial_end"] = trial_end_ts
        sub = stripe.Subscription.create(**create_kwargs)
        status = getattr(sub, "status", "incomplete") or "incomplete"
        if profile:
            profile.stripe_subscription_id = sub.id
            profile.plan_id = plan.id
            profile.plan_name = getattr(plan, "name", "") or profile.plan_name
            profile.status = status
            profile.cancel_at_period_end = False
            await self.db.commit()
        else:
            self.db.add(StripeSubscription(
                user_id=user.id,
                organization_id=org.id,
                plan_id=plan.id,
                stripe_customer_id=customer_id,
                stripe_subscription_id=sub.id,
                plan_name=getattr(plan, "name", "") or "",
                status=status,
                cancel_at_period_end=False,
            ))
            await self.db.commit()
        out = {
            "reused": False,
            "stripe_subscription_id": sub.id,
            "status": status,
            "customer_id": customer_id,
        }
        # First charge may require 3DS — hand the client secret back so the
        # app completes it with the Stripe SDK (webhook finalizes after).
        try:
            invoice = getattr(sub, "latest_invoice", None)
            pi = getattr(invoice, "payment_intent", None) if invoice else None
            if isinstance(pi, str):
                pi = stripe.PaymentIntent.retrieve(pi)
            if pi is not None and getattr(pi, "status", "") == "requires_action":
                out["requires_action"] = True
                out["client_secret"] = getattr(pi, "client_secret", "")
        except Exception:
            pass
        logger.info("auto_renew_enabled", user_id=str(user.id), org_id=str(org.id),
                    subscription_id=sub.id, status=status)
        return out

    async def activate_auto_renew_after_payment(self, user, org, invoice_no: Optional[str] = None, payment_intent_id: Optional[str] = None) -> dict:
        """Bind the card that just paid to an off-session renewal.

        Called from the invoice "start" tap right after a successful card
        payment. Resolves the paid charge server-side (never trusting the
        client for amount/plan), reuses the just-charged payment method and
        creates the Stripe Subscription with trial_end at the paid period
        end. Idempotent: a live renewal is reused, never doubled.
        """
        from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
        payment = None
        if payment_intent_id:
            payment = await self._payment_by_intent(str(payment_intent_id))
        if payment is None and invoice_no:
            inv = (
                await self.db.execute(
                    select(SubscriptionInvoice).where(
                        SubscriptionInvoice.invoice_number == str(invoice_no).strip(),
                        SubscriptionInvoice.organization_id == org.id,
                    ).limit(1)
                )
            ).scalar_one_or_none()
            if inv is not None and inv.provider_payment_id:
                payment = await self._payment_by_intent(inv.provider_payment_id)
        if payment is None:
            payment = (
                await self.db.execute(
                    select(StripePayment).where(
                        StripePayment.organization_id == org.id,
                        StripePayment.status == "paid",
                    ).order_by(StripePayment.created_at.desc()).limit(1)
                )
            ).scalars().first()
        if payment is None:
            raise ValueError("لم يتم العثور على عملية الدفع الخاصة بهذا الاشتراك")
        if str(payment.organization_id) != str(org.id):
            raise ValueError("عملية الدفع لا تخص هذا الحساب")
        if (payment.status or "") != "paid":
            raise ValueError("لم تكتمل عملية الدفع بعد")
        plan = await self.get_plan(payment.plan_id) if payment.plan_id else None
        if plan is None:
            raise ValueError("الباقة غير موجودة")
        if (getattr(plan, "package_type", "") or "").strip().lower() == "free":
            return {"activated": False, "reason": "free_plan"}
        intent_id = payment.stripe_payment_intent_id
        if not intent_id:
            raise ValueError("لا يوجد PaymentIntent مرتبط بعملية الدفع")
        stripe = await self._stripe()
        try:
            intent = stripe.PaymentIntent.retrieve(intent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("auto_activate_retrieve_failed", intent_id=intent_id, error=str(exc))
            raise ValueError("تعذر التحقق من عملية الدفع في Stripe")
        if getattr(intent, "status", "") != "succeeded":
            raise ValueError("لم تكتمل عملية الدفع بعد")
        pm = getattr(intent, "payment_method", None)
        if isinstance(pm, dict):
            pm = pm.get("id")
        if not pm:
            raise ValueError("لا توجد بطاقة محفوظة لهذه العملية")
        pi_customer = getattr(intent, "customer", None)
        if isinstance(pi_customer, dict):
            pi_customer = pi_customer.get("id")
        result = await self.enable_auto_renew(
            user, org, plan.id, period=(payment.period or "yearly"),
            payment_method_id=str(pm), consent=True,
            preferred_customer_id=(pi_customer if isinstance(pi_customer, str) else None),
        )
        logger.info("auto_renew_activated_after_payment", org_id=str(org.id),
                    plan_id=str(plan.id), payment_id=str(payment.id))
        return {"activated": True, **result}

    async def disable_auto_renew(self, user, org) -> dict:
        """Cancel the NEXT renewal only (cancel_at_period_end).

        The subscription stays usable until the current paid period ends —
        nothing is revoked immediately.
        """
        profile = await self._auto_profile(user.id, org.id)
        if not profile or not profile.stripe_subscription_id:
            raise ValueError("لا يوجد تجديد تلقائي مفعّل")
        stripe = await self._stripe()
        try:
            live = stripe.Subscription.modify(
                profile.stripe_subscription_id, cancel_at_period_end=True
            )
        except Exception as exc:
            logger.warning("auto_renew_disable_failed", error=str(exc))
            raise ValueError("تعذر إيقاف التجديد التلقائي حالياً")
        profile.cancel_at_period_end = True
        try:
            profile.status = getattr(live, "status", None) or profile.status
        except Exception:
            pass
        # Opted out: stop any scheduled collection retries.
        try:
            profile.renewal_retry_count = 0
            profile.renewal_next_retry_at = None
        except Exception:
            pass
        await self.db.commit()
        period_end = getattr(live, "current_period_end", None)
        return {
            "cancel_at_period_end": True,
            "status": profile.status,
            "current_period_end": period_end,
        }

    async def auto_renew_status(self, user, org) -> dict:
        """Renewal state + safe card display (brand/last4 only, never PAN)."""
        profile = await self._auto_profile(user.id, org.id)
        if not profile or not profile.stripe_subscription_id:
            return {"enabled": False, "status": getattr(profile, "status", None)}
        out: dict = {
            "enabled": not bool(getattr(profile, "cancel_at_period_end", False)),
            "status": profile.status,
            "cancel_at_period_end": bool(getattr(profile, "cancel_at_period_end", False)),
            "stripe_subscription_id": profile.stripe_subscription_id,
            "current_period_start": profile.current_period_start.isoformat() if profile.current_period_start else None,
            "current_period_end": profile.current_period_end.isoformat() if profile.current_period_end else None,
        }
        try:
            stripe = await self._stripe()
            live = stripe.Subscription.retrieve(profile.stripe_subscription_id)
            out["status"] = getattr(live, "status", None) or out["status"]
            out["cancel_at_period_end"] = bool(getattr(live, "cancel_at_period_end", False))
            out["enabled"] = not out["cancel_at_period_end"] and out["status"] in ("active", "trialing", "past_due")
            cpe = getattr(live, "current_period_end", None)
            out["current_period_end_live"] = cpe
            pm_id = getattr(live, "default_payment_method", None)
            if pm_id:
                pm = stripe.PaymentMethod.retrieve(pm_id if isinstance(pm_id, str) else pm_id.id)
                card = getattr(pm, "card", None) or {}
                get = (lambda k: card.get(k) if isinstance(card, dict) else getattr(card, k, None))
                out["card"] = {
                    "brand": get("brand"),
                    "last4": get("last4"),
                    "exp_month": get("exp_month"),
                    "exp_year": get("exp_year"),
                }
            # Pending first charge (e.g. 3DS never completed): expose its
            # client secret so the app can finish it. Publishable-safe.
            try:
                invoice = getattr(live, "latest_invoice", None)
                if isinstance(invoice, str):
                    invoice = stripe.Invoice.retrieve(invoice)
                pi = getattr(invoice, "payment_intent", None) if invoice else None
                if isinstance(pi, str):
                    pi = stripe.PaymentIntent.retrieve(pi)
                if pi is not None and getattr(pi, "status", "") == "requires_action":
                    out["pending_action"] = True
                    out["pending_client_secret"] = getattr(pi, "client_secret", "")
            except Exception as exc:
                logger.warning("auto_renew_pending_lookup_failed", error=str(exc))
            # Saved-method truth (never inferred from UI): a method exists
            # iff the live subscription carries one.
            out["has_saved_method"] = bool(pm_id)
            # Off-session readiness: active billing + a default method Stripe
            # can actually charge without the user present.
            out["off_session_ready"] = bool(
                out.get("status") in ("active", "trialing")
                and not out.get("cancel_at_period_end", False)
                and pm_id
            )
        except Exception as exc:
            logger.warning("auto_renew_status_live_failed", error=str(exc))
        return out

    async def _on_renewal_paid(self, invoice) -> None:
        """invoice.paid → extend the org subscription for the paid period.

        Verifies customer + subscription + metadata + user; duplicates are
        impossible (webhook event id + provider-payment idempotency).
        Reuses the invoice/revenue/notify pipeline — no new invoice design.
        """
        from datetime import datetime as _dt
        customer_id = getattr(invoice, "customer", None)
        if isinstance(customer_id, dict):
            customer_id = customer_id.get("id")
        sub_id = getattr(invoice, "subscription", None)
        if isinstance(sub_id, dict):
            sub_id = sub_id.get("id")
        profile = None
        if customer_id:
            res = await self.db.execute(
                select(StripeSubscription).where(
                    StripeSubscription.stripe_customer_id == str(customer_id)
                ).order_by(StripeSubscription.created_at.desc())
            )
            profile = res.scalars().first()
        meta = {}
        try:
            if sub_id:
                stripe = await self._stripe()
                live = stripe.Subscription.retrieve(sub_id)
                meta = getattr(live, "metadata", {}) or {}
        except Exception:
            pass
        org_id = meta.get("fyona_org_id")
        user_id = meta.get("fyona_user_id")
        plan_name = meta.get("fyona_plan_name") or (profile.plan_name if profile else "")
        period = meta.get("fyona_period") or "yearly"
        if not org_id or not user_id:
            logger.warning("renewal_paid_unlinked", customer=str(customer_id), subscription=str(sub_id))
            return
        org_uuid = _to_uuid(org_id)
        user_uuid = _to_uuid(user_id)
        if org_uuid is None or user_uuid is None:
            return
        org = await self._get_organization(org_uuid)
        if not org:
            return
        # Period from the paid Stripe invoice lines (fallback: subscription).
        start = end = None
        try:
            lines = getattr(getattr(invoice, "lines", None), "data", None) or []
            if lines:
                per = getattr(lines[0], "period", None)
                if per:
                    start = _from_ts(getattr(per, "start", None))
                    end = _from_ts(getattr(per, "end", None))
        except Exception:
            pass
        now = datetime.now(timezone.utc)
        start = start or now
        days = 30 if period == "monthly" else 365
        if end is None:
            try:
                stripe = await self._stripe()
                live = stripe.Subscription.retrieve(sub_id) if sub_id else None
                cpe = getattr(live, "current_period_end", None)
                end = _dt.fromtimestamp(int(cpe), tz=timezone.utc) if cpe else None
            except Exception:
                end = None
        end = end or (start + timedelta(days=days))

        # Amount comes ONLY from what Stripe actually collected on this
        # invoice (§6/§8). A missing amount/currency fails closed: no
        # extension, no paid invoice — never a $0 fallback.
        raw_paid = getattr(invoice, "amount_paid", None)
        raw_currency = getattr(invoice, "currency", None)
        if raw_paid is None or not raw_currency:
            logger.error(
                "renewal_paid_no_amount",
                invoice_id=getattr(invoice, "id", None),
                subscription=str(sub_id),
            )
            return
        try:
            minor_units = self.STRIPE_CURRENCY_MINOR_UNITS.get(
                str(raw_currency).lower(), 100
            )
            amount = int(raw_paid) / minor_units
            currency = str(raw_currency).upper()
        except (TypeError, ValueError):
            logger.error(
                "renewal_paid_bad_amount",
                invoice_id=getattr(invoice, "id", None),
                raw_paid=raw_paid,
                raw_currency=raw_currency,
            )
            return
        provider_payment_id = f"renew_{getattr(invoice, 'id', '') or sub_id or now.isoformat()}"

        from app.domain.services.section_entitlements import activate
        activate(org, plan_name or org.subscription_plan or "personal", start=start, end=end)
        await self.db.commit()
        await self._sync_user_subscription(
            user_uuid, org.subscription_plan, "active", start, end,
        )

        if profile:
            profile.status = "active"
            profile.plan_name = plan_name or profile.plan_name
            profile.current_period_start = start
            profile.current_period_end = end
            profile.cancel_at_period_end = False
            # Renewal recovered (paid, possibly via retry): clear the schedule.
            try:
                profile.renewal_retry_count = 0
                profile.renewal_next_retry_at = None
            except Exception:
                pass
            if sub_id and not profile.stripe_subscription_id:
                profile.stripe_subscription_id = str(sub_id)
            await self.db.commit()

        await self._book_stripe_revenue(
            org, user_uuid, plan_name, period, amount, currency, provider_payment_id,
        )
        renew_invoice_number = await self._create_stripe_invoice(
            org, user_uuid, plan_name, period, amount, currency,
            start, (end - start).days if end and start else days,
            provider_payment_id,
            _extract_card_brand(invoice),
        )
        await self._notify_user_stripe_activation(
            org.id, user_uuid, plan_name, amount, currency, period, start,
            (end - start).days if end and start else days,
            provider_payment_id, renew_invoice_number,
        )
        try:
            await self._notify_admins_stripe_payment(
                org.id, user_uuid, plan_name, amount, currency, kind="renewal",
            )
        except Exception:
            pass
        logger.info("renewal_paid_applied", org_id=str(org.id), plan=plan_name,
                    amount=amount, currency=currency)

    async def _on_renewal_failed(self, invoice) -> None:
        """invoice.payment_failed → record, notify, NEVER extend as if paid."""
        customer_id = getattr(invoice, "customer", None)
        if isinstance(customer_id, dict):
            customer_id = customer_id.get("id")
        sub_id = getattr(invoice, "subscription", None)
        if isinstance(sub_id, dict):
            sub_id = sub_id.get("id")
        if customer_id:
            res = await self.db.execute(
                select(StripeSubscription).where(
                    StripeSubscription.stripe_customer_id == str(customer_id)
                ).order_by(StripeSubscription.created_at.desc())
            )
            profile = res.scalars().first()
            if profile:
                first_failure = (profile.status != "past_due")
                profile.status = "past_due"
                if first_failure:
                    try:
                        profile.renewal_retry_count = 0
                        profile.renewal_next_retry_at = datetime.now(timezone.utc) + timedelta(days=1)
                    except Exception:
                        pass
                await self.db.commit()
                try:
                    await self._notify_renewal_failed(
                        profile.organization_id, profile.user_id,
                        profile.plan_name, invoice,
                    )
                except Exception:
                    pass
                logger.warning("renewal_payment_failed", subscription=str(sub_id))

    async def _notify_renewal_failed(self, org_id, user_uuid, plan_name, invoice) -> None:
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.services import push_service
        from sqlalchemy import select as _selnf

        invoice_id = getattr(invoice, "id", None)
        # Kind first: the idempotency payload is kind-specific, so an
        # expired-card failure and a balance failure for the same invoice
        # never mask each other — yet redeliveries of the same kind stay
        # exactly one notice.
        kind = self._classify_renewal_failure(
            self._extract_decline(invoice), "", False)
        fail_payload = "/subscription"
        if invoice_id:
            if kind == "expired":
                fail_payload = f"/subscription/update-card?renewal_expired={invoice_id}"
            elif kind == "insufficient":
                fail_payload = f"/subscription/invoice?renewal_balance={invoice_id}"
            else:
                fail_payload = f"/subscription?renewal_failed={invoice_id}"
        # ── Failure-notification idempotency (§10.J): one failure notice per
        # invoice+kind, even across Stripe's repeated payment_failed deliveries. ──
        try:
            dupf = (
                await self.db.execute(
                    _selnf(AppNotification).where(
                        AppNotification.user_id == user_uuid,
                        AppNotification.action_payload == fail_payload,
                        AppNotification.type == "warning",
                    )
                )
            ).scalar_one_or_none()
            if dupf is not None:
                logger.info("renewal_failed_notif_duplicate_skipped", payload=fail_payload)
                return
        except Exception as exc:
            logger.warning("renewal_failed_notif_dedup_check_failed", error=str(exc))

        amount = 0.0
        currency = "USD"
        try:
            amount = float(getattr(invoice, "amount_due", 0) or 0) / 100.0
            currency = (getattr(invoice, "currency", None) or "USD").upper()
        except Exception:
            pass
        plan_ar = {"personal": "الباقة الشخصية", "business": "باقة الأعمال", "premium": "باقة الأعمال + الشخصية"}.get(
            (plan_name or "").lower(), plan_name or "الباقة"
        )
        # Kind-specific first notice: expired cards deep-link the card-update
        # screen, insufficient balance explains top-up. (kind + payload were
        # resolved above, before the dedup check.)
        if kind == "expired":
            title = "بطاقتك منتهية — حدّثها لإتمام التجديد 💳"
            body = (
                f"فشل تجديد {plan_ar} ({amount:g} {currency}) لأن بطاقتك منتهية الصلاحية. "
                "اضغط هنا لتغيير البطاقة وإتمام الدفع."
            )
            cta = "اضغط هنا لتغيير البطاقة."
        elif kind == "insufficient":
            title = "رصيد البطاقة غير كافٍ للتجديد ⚠️"
            body = (
                f"فشل تجديد {plan_ar} ({amount:g} {currency}) بسبب عدم كفاية الرصيد. "
                "اشحن بطاقتك وسيُعاد الخصم تلقائيًا."
            )
            cta = "انقر هنا لعرض الاشتراك."
        else:
            title = "تعذر تجديد الاشتراك ⚠️"
            body = (
                f"فشل الدفع التلقائي لتجديد {plan_ar} ({amount:g} {currency}). "
                "اشتراكك الحالي يبقى فعالاً حتى نهاية مدته — حدّث وسيلة الدفع لتفادي الانقطاع."
            )
            cta = "انقر هنا لإدارة التجديد."
        try:
            self.db.add(AppNotification(
                organization_id=org_id, user_id=user_uuid, type="warning",
                title=title, message=f"{body} {cta}",
                action="open_screen", action_payload=fail_payload,
            ))
            await self.db.commit()
        except Exception as exc:  # noqa: BLE001
            logger.warning("renewal_failed_notify_failed", error=str(exc),
                           user_id=str(user_uuid))
            try:
                await self.db.rollback()
            except Exception:
                pass
        try:
            await push_service.notify_user(
                self.db, user_id=user_uuid, title=title, body=body,
                action="open_screen", action_payload=fail_payload,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("renewal_failed_push_failed", error=str(exc),
                           user_id=str(user_uuid))

    # ── Custom off-session retry schedule (days between attempts) ──
    # Attempt #n uses the card on file with NO user presence. Gaps escalate
    # (1d, then +2d, +3d, …) instead of hammering the card.
    RENEWAL_RETRY_GAPS = (1, 2, 3, 5, 7, 10, 15)
    # Attempts that trigger a user notice (plus a final notice at
    # exhaustion). Bounded and spaced — never per-attempt spam.
    RENEWAL_NOTICE_ATTEMPTS = (2, 4, 6)

    @staticmethod
    def _classify_renewal_failure(decline_code=None, message: str = "",
                                  pm_expired: bool = False) -> str:
        """Classify a renewal collection failure: expired card, insufficient
        balance, or other. Pure function — unit-tested, never raises."""
        try:
            if pm_expired:
                return "expired"
            code = str(decline_code or "").strip().lower()
            if code == "expired_card":
                return "expired"
            if code == "insufficient_funds":
                return "insufficient"
            msg = str(message or "").lower()
            if "expired" in msg and "card" in msg:
                return "expired"
            if "insufficient" in msg:
                return "insufficient"
        except Exception:
            pass
        return "other"

    async def _default_pm_expired(self, stripe, subscription_id) -> Optional[bool]:
        """True when the subscription's default card is past its expiry date.

        Date-based (deterministic): an expired card can never be charged, so
        the expired-card track applies even before Stripe says so. None when
        unknown (no method / lookup failed) — caller falls back to decline
        codes. Never raises.
        """
        try:
            live = stripe.Subscription.retrieve(subscription_id)
            pm_id = getattr(live, "default_payment_method", None)
            if not pm_id:
                cust = getattr(live, "customer", None)
                try:
                    c = stripe.Customer.retrieve(
                        cust if isinstance(cust, str) else getattr(cust, "id", ""))
                    inv = getattr(c, "invoice_settings", None) or {}
                    pm_id = inv.get("default_payment_method") if isinstance(inv, dict) \
                        else getattr(inv, "default_payment_method", None)
                except Exception:
                    pm_id = None
            if not pm_id:
                return None
            pm = stripe.PaymentMethod.retrieve(
                pm_id if isinstance(pm_id, str) else getattr(pm_id, "id", ""))
            card = getattr(pm, "card", None) or {}
            get = (lambda k: card.get(k) if isinstance(card, dict) else getattr(card, k, None))
            try:
                exp_y, exp_m = int(get("exp_year") or 0), int(get("exp_month") or 0)
            except (TypeError, ValueError):
                return None
            # Plausibility guard: mock/garbage values (e.g. year 1) must not
            # read as "expired" — only a real past date counts.
            if not (1 <= exp_m <= 12 and 2000 <= exp_y <= 2100):
                return None
            now = datetime.now(timezone.utc)
            return (exp_y, exp_m) < (now.year, now.month)
        except Exception:
            return None

    def _renewal_notice_text(self, kind: str, milestone: int, final: bool,
                             plan_ar: str, amount: float, currency: str):
        """Milestone-varied notice texts per failure kind (Arabic).

        milestone counts the user-visible repeat (1st/2nd/3rd scheduled
        notice); final is the exhaustion notice. Returns (title, body).
        """
        amt = f"{amount:g} {currency}".strip()
        if kind == "expired":
            if final:
                return ("توقف التجديد التلقائي ⚠️",
                        f"انتهت صلاحية بطاقتك وتعذر تجديد {plan_ar} ({amt}). "
                        "اضغط هنا لتغيير البطاقة وإتمام الدفع.")
            variants = [
                ("بطاقتك منتهية — حدّثها لإتمام التجديد 💳",
                 f"حاول النظام تجديد {plan_ar} ({amt}) لكن بطاقتك منتهية الصلاحية. "
                 "اضغط هنا لتغيير البطاقة وإتمام الدفع بدل البطاقة المنتهية."),
                ("ما زال التجديد متوقفًا — البطاقة منتهية 💳",
                 f"تعذر تجديد {plan_ar} ({amt}) مجددًا لأن البطاقة منتهية. "
                 "غيّر بطاقتك الآن ليتم الخصم تلقائيًا."),
                ("تنبيه أخير قبل إيقاف التجديد ⚠️",
                 f"بطاقتك ما زالت منتهية ولم يتم تجديد {plan_ar} ({amt}). "
                 "اضغط هنا لتغيير البطاقة قبل إيقاف التجديد نهائيًا."),
            ]
            return variants[min(max(milestone - 1, 0), len(variants) - 1)]
        if kind == "insufficient":
            if final:
                return ("توقف التجديد التلقائي ⚠️",
                        f"تعذر تحصيل تجديد {plan_ar} ({amt}) بعد عدة محاولات "
                        "بسبب عدم كفاية الرصيد. اشحن بطاقتك ثم جدد اشتراكك من التطبيق.")
            variants = [
                ("رصيد البطاقة غير كافٍ للتجديد ⚠️",
                 f"فشل تجديد {plan_ar} ({amt}) بسبب عدم كفاية الرصيد. "
                 "اشحن بطاقتك وسيُعاد الخصم تلقائيًا — لا حاجة لأي إجراء آخر."),
                ("تذكير: اشحن بطاقتك لإتمام التجديد ⚠️",
                 f"ما زال رصيد بطاقتك غير كافٍ لتجديد {plan_ar} ({amt}). "
                 "اشحنها وسيحاول النظام الخصم تلقائيًا."),
                ("محاولات التجديد مستمرة — الرصيد غير كافٍ ⚠️",
                 f"حاول النظام مجددًا تجديد {plan_ar} ({amt}) وما زال الرصيد غير كافٍ. "
                 "اشحن بطاقتك لتفادي انقطاع الاشتراك."),
            ]
            return variants[min(max(milestone - 1, 0), len(variants) - 1)]
        if final:
            return ("توقف التجديد التلقائي ⚠️",
                    f"تعذر تحصيل تجديد {plan_ar} ({amt}) بعد عدة محاولات. "
                    "حدث وسيلة الدفع ثم جدد اشتراكك من التطبيق.")
        return ("تعذر تجديد الاشتراك ⚠️",
                f"فشل الدفع التلقائي لتجديد {plan_ar} ({amt}). "
                "اشتراكك الحالي يبقى فعالاً حتى نهاية مدته — حدّث وسيلة الدفع لتفادي الانقطاع.")

    async def _notify_renewal_milestone(self, org_id, user_uuid, plan_name,
                                          amount, currency, sub_id, kind: str,
                                          milestone: int, attempt: int,
                                          final: bool = False) -> None:
        """Kind-specific repeat notice (expired card / insufficient balance).

        Fires only on spaced milestones (attempts 2/4/6) plus once at
        exhaustion — each repeat carries its own attempt-tagged payload so
        repeats are distinct rows while the same attempt can never duplicate
        (idempotent per subscription+kind+attempt). Goes to both the in-app
        center and the device tray. Expired-card taps deep-link the
        card-update screen; balance taps open the subscription invoice.
        """
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.services import push_service
        from sqlalchemy import select as _seln

        plan_ar = {"personal": "الباقة الشخصية", "business": "باقة الأعمال", "premium": "باقة الأعمال + الشخصية"}.get(
            (plan_name or "").lower(), plan_name or "الباقة"
        )
        try:
            amt = float(amount or 0)
            cur = (currency or "").upper()
        except (TypeError, ValueError):
            amt, cur = 0.0, (currency or "").upper()
        title, body = self._renewal_notice_text(
            kind, milestone, final, plan_ar, amt, cur)
        if kind == "expired":
            payload = f"/subscription/update-card?n={attempt}" if not final \
                else "/subscription/update-card?final=1"
        elif kind == "insufficient":
            payload = f"/subscription/invoice?renewal_balance={sub_id}&n={attempt}" if not final \
                else f"/subscription/invoice?renewal_balance={sub_id}&final=1"
        else:
            payload = f"/subscription?renewal_topup={sub_id}&n={attempt}" if not final \
                else f"/subscription?renewal_final={sub_id}"
        try:
            dup = (
                await self.db.execute(
                    _seln(AppNotification).where(
                        AppNotification.user_id == user_uuid,
                        AppNotification.action_payload == payload,
                        AppNotification.type == "warning",
                    )
                )
            ).scalar_one_or_none()
            if dup is not None:
                return
        except Exception as exc:
            logger.warning("renewal_milestone_dedup_check_failed", error=str(exc))
        cta = "اضغط هنا لتغيير البطاقة." if kind == "expired" and not final \
            else "انقر هنا لعرض الاشتراك."
        try:
            self.db.add(AppNotification(
                organization_id=org_id, user_id=user_uuid, type="warning",
                title=title, message=f"{body} {cta}",
                action="open_screen", action_payload=payload,
            ))
            await self.db.commit()
        except Exception as exc:  # noqa: BLE001
            logger.warning("renewal_milestone_notify_failed", error=str(exc),
                           user_id=str(user_uuid))
            try:
                await self.db.rollback()
            except Exception:
                pass
        try:
            await push_service.notify_user(
                self.db, user_id=user_uuid, title=title, body=body,
                action="open_screen", action_payload=payload,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("renewal_milestone_push_failed", error=str(exc),
                           user_id=str(user_uuid))

    async def retry_renewal_charge(self, profile) -> dict:
        """One scheduled collection attempt for a past-due renewal.

        Refreshes live Stripe state first: recovered/cancelled/expired
        subscriptions stop the schedule instead of charging. On failure the
        next attempt follows RENEWAL_RETRY_GAPS; kind-specific notices
        (expired card vs insufficient balance) fire on spaced milestones
        plus once at exhaustion. Returns a small outcome dict.
        """
        now = datetime.now(timezone.utc)
        try:
            stripe = await self._stripe()
            live = stripe.Subscription.retrieve(
                profile.stripe_subscription_id, expand=["latest_invoice"])
        except Exception as exc:
            logger.warning("renewal_retry_retrieve_failed",
                           subscription=str(getattr(profile, "stripe_subscription_id", "")),
                           error=str(exc))
            return {"outcome": "error", "error": "retrieve_failed"}
        status = getattr(live, "status", "") or ""
        if status in ("active", "trialing"):
            profile.status = status
            profile.renewal_retry_count = 0
            profile.renewal_next_retry_at = None
            await self.db.commit()
            return {"outcome": "recovered", "status": status}
        if status in ("canceled", "incomplete_expired", "unpaid"):
            profile.status = status
            profile.renewal_next_retry_at = None
            await self.db.commit()
            return {"outcome": "stopped", "status": status}
        invoice = getattr(live, "latest_invoice", None)
        if isinstance(invoice, str):
            try:
                invoice = stripe.Invoice.retrieve(invoice)
            except Exception:
                invoice = None
        inv_status = getattr(invoice, "status", "") if invoice else ""
        if invoice is None or inv_status == "paid":
            profile.status = status or profile.status
            profile.renewal_retry_count = 0
            profile.renewal_next_retry_at = None
            await self.db.commit()
            return {"outcome": "recovered", "status": profile.status}
        if inv_status != "open":
            return {"outcome": "skipped", "invoice_status": inv_status or "unknown"}

        def _minor(cur, raw):
            try:
                return int(raw or 0) / self.STRIPE_CURRENCY_MINOR_UNITS.get(
                    str(cur or "").lower(), 100)
            except (TypeError, ValueError):
                return 0.0

        inv_id = getattr(invoice, "id", "")
        inv_amount = _minor(getattr(invoice, "currency", ""),
                            getattr(invoice, "amount_due", 0))
        inv_currency = str(getattr(invoice, "currency", "") or "").upper()
        # Card-expiry truth (date-based): an expired card can never be
        # charged — the expired track applies even before Stripe says so.
        try:
            pm_expired = await self._default_pm_expired(
                stripe, profile.stripe_subscription_id)
        except Exception:
            pm_expired = None
        pay_error = None
        try:
            paid = stripe.Invoice.pay(inv_id)
            if getattr(paid, "status", "") == "paid":
                profile.renewal_retry_count = 0
                profile.renewal_next_retry_at = None
                await self.db.commit()
                # invoice.paid webhook extends + notifies; nothing more here.
                return {"outcome": "paid", "invoice": inv_id}
            raise ValueError(f"invoice still {getattr(paid, 'status', 'unknown')}")
        except Exception as exc:
            pay_error = exc
        kind = self._classify_renewal_failure(
            getattr(pay_error, "decline_code", None)
            or self._extract_decline(invoice),
            str(pay_error or ""),
            pm_expired is True)
        attempt = int(getattr(profile, "renewal_retry_count", 0) or 0) + 1
        profile.renewal_retry_count = attempt
        gaps = self.RENEWAL_RETRY_GAPS
        milestone = len([m for m in self.RENEWAL_NOTICE_ATTEMPTS if m <= attempt])
        if attempt >= len(gaps):
            profile.renewal_next_retry_at = None
            await self.db.commit()
            await self._notify_renewal_milestone(
                profile.organization_id, profile.user_id,
                getattr(profile, "plan_name", ""), inv_amount, inv_currency,
                profile.stripe_subscription_id, kind, milestone, attempt,
                final=True)
            logger.warning("renewal_retry_exhausted",
                           subscription=str(profile.stripe_subscription_id),
                           kind=kind, attempts=attempt,
                           error=str(pay_error or ""))
            return {"outcome": "exhausted", "attempt": attempt, "kind": kind}
        profile.renewal_next_retry_at = now + timedelta(days=gaps[attempt])
        await self.db.commit()
        if attempt in self.RENEWAL_NOTICE_ATTEMPTS:
            await self._notify_renewal_milestone(
                profile.organization_id, profile.user_id,
                getattr(profile, "plan_name", ""), inv_amount, inv_currency,
                profile.stripe_subscription_id, kind, milestone, attempt,
                final=False)
        logger.info("renewal_retry_failed",
                    subscription=str(profile.stripe_subscription_id),
                    kind=kind, attempt=attempt,
                    next_in_days=gaps[attempt], error=str(pay_error or ""))
        return {"outcome": "failed", "attempt": attempt, "kind": kind,
                "next_in_days": gaps[attempt]}

    @staticmethod
    def _extract_decline(invoice) -> Optional[str]:
        """Decline code from an invoice's last payment error (dict/object)."""
        try:
            err = getattr(invoice, "last_payment_error", None)
            if err is None:
                return None
            if isinstance(err, dict):
                return err.get("decline_code") or err.get("code")
            return getattr(err, "decline_code", None) or getattr(err, "code", None)
        except Exception:
            return None


def _as_bool(v) -> bool:
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    return str(v).strip().lower() in ("1", "true", "yes", "y", "on")


def _as_str(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def _to_uuid(value):
    if value is None:
        return None
    if isinstance(value, UUID):
        return value
    try:
        return UUID(value)
    except (TypeError, ValueError, AttributeError):
        return None


def _looks_uuid(value: str) -> bool:
    if not isinstance(value, str):
        return False
    try:
        UUID(value)
        return True
    except (TypeError, ValueError):
        return False


def _from_ts(ts) -> Optional[datetime]:
    if not ts:
        return None
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc)
    except (TypeError, ValueError, OSError):
        return None


def _plan_catalog_dict(p: Plan, stripe_amount_monthly=None, stripe_amount_yearly=None, stripe_currency=None,
                       quote_amount_monthly=None, quote_amount_yearly=None, quote_currency=None,
                       quote_charge_currency=None, quote_fx_rate=None, quote_fx_source=None,
                       quote_fallback_usd=False) -> dict:
    return {
        "id": str(p.id),
        "name": p.name,
        "name_en": p.name_en,
        "description": p.description,
        "price_monthly": p.price_monthly or 0,
        "price_yearly": p.price_yearly or 0,
        "currency": p.currency or "SAR",
        "features": loads_features(p.features),
        "color": p.color,
        "icon": p.icon,
        "is_active": p.is_active,
        "stripe_product_id": p.stripe_product_id,
        "stripe_price_id_monthly": p.stripe_price_id_monthly,
        "stripe_price_id_yearly": p.stripe_price_id_yearly,
        "stripe_price_amount_monthly": stripe_amount_monthly[0] / 100.0 if stripe_amount_monthly else None,
        "stripe_price_amount_yearly": stripe_amount_yearly[0] / 100.0 if stripe_amount_yearly else None,
        "stripe_currency": (stripe_currency or "").upper() or None,
        # Server-sided quoted prices (optional, when target_currency supplied)
        "quote_amount_monthly": quote_amount_monthly,
        "quote_amount_yearly": quote_amount_yearly,
        "quote_currency": quote_currency,
        "quote_charge_currency": quote_charge_currency,
        "quote_fx_rate": quote_fx_rate,
        "quote_fx_source": quote_fx_source,
        "quote_fallback_usd": quote_fallback_usd,
    }


def _payment_to_dict(p: StripePayment) -> dict:
    return {
        "id": str(p.id),
        "user_id": str(p.user_id) if p.user_id else None,
        "organization_id": str(p.organization_id) if p.organization_id else None,
        "plan_id": str(p.plan_id) if p.plan_id else None,
        "provider": p.provider,
        "stripe_checkout_session_id": p.stripe_checkout_session_id,
        "stripe_payment_intent_id": p.stripe_payment_intent_id,
        "stripe_event_id": p.stripe_event_id,
        "amount": float(p.amount) if p.amount is not None else None,
        "amount_minor": p.amount_minor,
        "currency": p.currency,
        "base_currency": p.base_currency,
        "base_amount": float(p.base_amount) if p.base_amount is not None else None,
        "exchange_rate": p.exchange_rate,
        "fx_source": p.fx_source,
        "mode": p.mode,
        "idempotency_key": p.idempotency_key,
        "status": p.status,
        "plan_name": p.plan_name,
        "period": p.period,
        "created_at": p.created_at.isoformat() if p.created_at else None,
        "updated_at": p.updated_at.isoformat() if p.updated_at else None,
    }


def _subscription_to_dict(s: StripeSubscription) -> dict:
    return {
        "id": str(s.id),
        "user_id": str(s.user_id) if s.user_id else None,
        "organization_id": str(s.organization_id) if s.organization_id else None,
        "plan_id": str(s.plan_id) if s.plan_id else None,
        "stripe_customer_id": s.stripe_customer_id,
        "stripe_subscription_id": s.stripe_subscription_id,
        "plan_name": s.plan_name,
        "status": s.status,
        "current_period_start": s.current_period_start.isoformat() if s.current_period_start else None,
        "current_period_end": s.current_period_end.isoformat() if s.current_period_end else None,
        "cancel_at_period_end": s.cancel_at_period_end,
        "created_at": s.created_at.isoformat() if s.created_at else None,
        "updated_at": s.updated_at.isoformat() if s.updated_at else None,
    }
