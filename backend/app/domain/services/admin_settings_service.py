"""Persistent admin configuration backed by the encrypted `app_config` table.

Replaces the previous module-level in-memory stores (`_system_settings`,
`_api_keys_store`, `_currencies_config`, `_banners_store`) so admin data
survives container restarts and is never seeded/fake.

All values are stored as JSON blobs encrypted at rest (Fernet via the
`app_config` table).

Secret keys (SMTP password, SMS API key, Maps API key, Stripe keys, etc.) are
NOT stored here anymore: they live in the server `.env` file only. The admin
panel reads a `*_configured` boolean and never sees or edits the raw value.
"""
import json
import uuid as uuid_lib
from datetime import datetime, timezone
from typing import Any, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import encrypt_secret, decrypt_secret
from app.domain.entities.payment_entities import AppSetting


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _as_bool(v) -> bool:
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


def _env_configured(env_name: str) -> bool:
    """True when the env secret is set to a non-empty value."""
    return bool((getattr(settings, env_name, None) or "").strip())


# Secret env keys reported to the admin panel as status (never the value).
ENV_SECRET_KEYS: tuple = (
    ("smtp_password", "SMTP_PASSWORD"),
    ("sms_api_key", "SMS_API_KEY"),
    ("map_api_key", "MAP_API_KEY"),
)


class AdminSettingsService:
    """Persistent key/value admin store backed by the encrypted app_config table."""

    KEY_SETTINGS = "admin_settings"
    KEY_CURRENCIES = "currencies"
    KEY_BANNERS = "banners"
    KEY_PLATFORM_CONTROLS = "platform_controls"
    KEY_NOTIFY_EMAILS = "admin_notify_emails"

    DEFAULT_PLATFORM_CONTROLS: dict = {
        # إيقاف الأقسام (صيانة): personal | business | all — القيم من تفعيل/تعطيل
        "maintenance": {
            "personal": False,
            "business": False,
            "all": False,
            "message": "",
        },
        # أزرار معطلة مؤقتاً لكل قسم (يُظهر للمستخدم رسالة "في وضع الصيانة")
        "disabled_buttons": {
            "personal": [],
            "business": [],
        },
        # التحكم بالاشتراك التجريبي للمستخدمين الجدد
        # الوحدة: hours | days | weeks | months — مع قيمة رقمية
        "trial": {
            "enabled": True,
            "unit": "hours",
            "value": 24,
            "hours": 24,  # legacy fallback
            "days": 1,    # legacy fallback
        },
        # إجبار جميع المستخدمين على اشتراك مدفوع (لا تجريبي ولا دخول بدون اشتراك)
        "force_paid_subscription": False,
        # ── Marketing / selling features (admin web) ──
        # Per-plan percentage discounts: {package_type: {"percent": int, "ends_on": iso-date}}
        "discounts": {},
        # Urgency countdown: fake descending timers shown on the plan cards.
        # enabled: bool · per-plan start seconds (min 60 → shows <10min)
        # plans: which plan cards show the chip
        #   ["personal"] → ONLY personal · ["personal","business","premium"] → all
        #   empty/absent → every plan with seconds>0 (legacy behavior)
        "urgency_countdown": {
            "enabled": False,
            "personal": 540,
            "business": 480,
            "premium": 420,
            "plans": ["personal", "business", "premium"],
        },
        # Paid-subscribers counter (fake social proof shown in plans page).
        # enabled: bool · base: starting count · step: +N per interval seconds
        "subscriber_counter": {
            "enabled": False,
            "base": 1240,
            "step": 1,
            "interval_seconds": 10,
        },
    }

    DEFAULT_SETTINGS: dict = {
        "app_name": "FYONA ERP",
        "app_description": "",
        "maintenance_mode": False,
        "registration_open": True,
        "max_users_per_org": 10,
        "trial_days": 1,
        "trial_hours": 24,
        "default_currency": "SAR",
        "supported_currencies": ["SAR", "USD", "EUR", "AED", "EGP", "KWD", "QAR", "BHD", "OMR", "TRY"],
        "max_file_size_mb": 50,
        "backup_frequency": "daily",
        "smtp_host": "",
        "smtp_port": 587,
        "smtp_user": "",
        "smtp_password": "",
        "smtp_from": "",
        "sms_gateway": "",
        "sms_api_key": "",
        "map_provider": "",
        "map_api_key": "",
        "support_whatsapp_number": "966570234694",
    }

    DEFAULT_CURRENCIES: dict = {
        "SAR": {"name": "ريال سعودي", "symbol": "ر.س", "enabled": True, "rate": 1.0, "auto_update": False},
        "USD": {"name": "دولار أمريكي", "symbol": "$", "enabled": True, "rate": 3.75, "auto_update": True},
        "EUR": {"name": "يورو", "symbol": "€", "enabled": True, "rate": 4.10, "auto_update": True},
        "AED": {"name": "درهم إماراتي", "symbol": "د.إ", "enabled": True, "rate": 1.02, "auto_update": True},
        "EGP": {"name": "جنيه مصري", "symbol": "ج.م", "enabled": True, "rate": 0.077, "auto_update": True},
        "KWD": {"name": "دينار كويتي", "symbol": "د.ك", "enabled": True, "rate": 12.20, "auto_update": True},
        "QAR": {"name": "ريال قطري", "symbol": "ر.ق", "enabled": True, "rate": 1.03, "auto_update": True},
        "BHD": {"name": "دينار بحريني", "symbol": "د.ب", "enabled": True, "rate": 9.95, "auto_update": True},
        "OMR": {"name": "ريال عماني", "symbol": "ر.ع", "enabled": True, "rate": 9.74, "auto_update": True},
        "TRY": {"name": "ليرة تركية", "symbol": "₺", "enabled": True, "rate": 0.11, "auto_update": True},
        "YER_OLD": {"name": "ريال يمني (قديم - صنعاء)", "symbol": "ر.ي", "enabled": True, "rate": 250.0, "auto_update": False},
        "YER_NEW": {"name": "ريال يمني (جديد - عدن)", "symbol": "ر.ي.ج", "enabled": True, "rate": 0.25, "auto_update": False},
    }

    def __init__(self, db: AsyncSession):
        self.db = db

    # ── low-level JSON blob helpers ──────────────────────────────
    async def _get_json(self, key: str, default):
        row = (
            await self.db.execute(select(AppSetting).where(AppSetting.key == key))
        ).scalar_one_or_none()
        if row is None or not row.value_encrypted:
            return default
        try:
            return json.loads(decrypt_secret(row.value_encrypted))
        except Exception:
            return default

    async def _set_json(self, key: str, value) -> None:
        raw = json.dumps(value, ensure_ascii=False, default=str)
        encrypted = encrypt_secret(raw)
        row = (
            await self.db.execute(select(AppSetting).where(AppSetting.key == key))
        ).scalar_one_or_none()
        if row is None:
            self.db.add(AppSetting(key=key, value_encrypted=encrypted))
        else:
            row.value_encrypted = encrypted
        await self.db.commit()

    # ── System settings ──────────────────────────────────────────
    async def get_settings(self) -> dict:
        stored = await self._get_json(self.KEY_SETTINGS, {}) or {}
        merged = dict(self.DEFAULT_SETTINGS)
        merged.update(stored)
        # Secrets are never exposed: replace raw values with configured status.
        for db_key, env_name in ENV_SECRET_KEYS:
            merged.pop(db_key, None)
            merged[f"{db_key}_configured"] = _env_configured(env_name)
        return merged

    async def save_settings(self, updates: dict) -> dict:
        current = await self.get_settings()
        clean = {k: v for k, v in (updates or {}).items() if v is not None}
        # Secret keys are managed from .env only — never persist through admin.
        for db_key, env_name in ENV_SECRET_KEYS:
            clean.pop(db_key, None)
            clean.pop(f"{db_key}_configured", None)
        current.update(clean)
        await self._set_json(self.KEY_SETTINGS, current)
        return current

    # ── Env-managed API keys (status only) ───────────────────────
    async def env_key_statuses(self) -> list:
        return [
            {
                "service": "openai",
                "key_type": "openai",
                "name": "OpenAI",
                "configured": _env_configured("OPENAI_API_KEY"),
            },
            {
                "service": "stripe",
                "key_type": "stripe",
                "name": "Stripe",
                "configured": _env_configured("STRIPE_SECRET_KEY"),
            },
            {
                "service": "sms",
                "key_type": "sms",
                "name": "SMS",
                "configured": _env_configured("SMS_API_KEY"),
            },
            {
                "service": "email",
                "key_type": "email",
                "name": "البريد (SMTP)",
                "configured": _env_configured("SMTP_PASSWORD"),
            },
            {
                "service": "maps",
                "key_type": "maps",
                "name": "الخرائط",
                "configured": _env_configured("MAP_API_KEY"),
            },
            {
                "service": "currency",
                "key_type": "currency",
                "name": "العملات",
                "configured": _env_configured("EXCHANGE_RATE_HOST_KEY")
                or _env_configured("EGCURRENCY_API_KEY"),
            },
        ]

    # ── Currencies ───────────────────────────────────────────────
    async def get_currencies(self) -> dict:
        stored = await self._get_json(self.KEY_CURRENCIES, {}) or {}
        merged = dict(self.DEFAULT_CURRENCIES)
        for code, cfg in stored.items():
            prev = merged.get(code, {})
            if isinstance(cfg, dict):
                merged[code] = {**prev, **cfg}
            else:
                merged[code] = prev
        return merged

    async def save_currencies(self, currencies: dict) -> dict:
        await self._set_json(self.KEY_CURRENCIES, currencies)
        return currencies

    async def toggle_currency(self, code: str) -> Optional[dict]:
        currencies = await self.get_currencies()
        code = code.upper()
        if code not in currencies:
            return None
        currencies[code]["enabled"] = not _as_bool(currencies[code].get("enabled"))
        await self.save_currencies(currencies)
        return currencies[code]

    async def create_currency(self, payload) -> Optional[dict]:
        currencies = await self.get_currencies()
        code = payload.code.upper()
        if code in currencies:
            return None
        currencies[code] = {
            "name": payload.name,
            "symbol": payload.symbol,
            "enabled": _as_bool(getattr(payload, "enabled", True)),
            "rate": float(getattr(payload, "rate", 1.0) or 1.0),
            "auto_update": _as_bool(getattr(payload, "auto_update", False)),
        }
        await self.save_currencies(currencies)
        return {"code": code, **currencies[code]}

    async def update_currency(self, code: str, body) -> Optional[dict]:
        currencies = await self.get_currencies()
        code = code.upper()
        if code not in currencies:
            return None
        if body.name is not None:
            currencies[code]["name"] = body.name
        if body.symbol is not None:
            currencies[code]["symbol"] = body.symbol
        await self.save_currencies(currencies)
        return {"code": code, **currencies[code]}

    async def update_currency_rate(self, code: str, rate: float) -> Optional[dict]:
        currencies = await self.get_currencies()
        code = code.upper()
        if code not in currencies:
            return None
        if rate <= 0:
            return "invalid-rate"
        currencies[code]["rate"] = rate
        currencies[code]["auto_update"] = False
        await self.save_currencies(currencies)
        return {"code": code, **currencies[code]}

    async def auto_update_rates(self, has_currency_key: bool) -> dict:
        currencies = await self.get_currencies()
        updated = []
        for code, cfg in currencies.items():
            if _as_bool(cfg.get("auto_update")) and code != "SAR":
                updated.append(code)
        if not has_currency_key:
            return {"error": "no-key"}
        await self.save_currencies(currencies)
        return {"updated_currencies": updated, "total_updated": len(updated)}

    # ── Banners ──────────────────────────────────────────────────
    async def list_banners(self) -> list:
        return await self._get_json(self.KEY_BANNERS, []) or []

    async def save_banners(self, banners: list) -> None:
        await self._set_json(self.KEY_BANNERS, banners)

    async def get_banner(self, banner_id: str) -> Optional[dict]:
        return next((b for b in await self.list_banners() if b["id"] == banner_id), None)

    async def create_banner(self, payload) -> dict:
        banners = await self.list_banners()
        new_id = str(uuid_lib.uuid4())
        banner = {
            "id": new_id,
            "title_key": payload.title_key,
            "subtitle_key": payload.subtitle_key,
            "icon_name": payload.icon_name,
            "color_start": payload.color_start,
            "color_end": payload.color_end,
            "image_url": payload.image_url,
            "media_url": getattr(payload, "media_url", None),
            "audio_url": getattr(payload, "audio_url", None),
            "video_url": getattr(payload, "video_url", None),
            "text": getattr(payload, "text", None),
            "click_url": payload.click_url,
            "duration_days": getattr(payload, "duration_days", 0) or 0,
            "carousel_seconds": getattr(payload, "carousel_seconds", None) or 4,
            "start_date": payload.start_date,
            "end_date": payload.end_date,
            "click_count": 0,
            "view_count": 0,
            "watch_seconds": 0,
            "is_active": _as_bool(payload.is_active),
            "sort_order": getattr(payload, "sort_order", 0) or 0,
            "media_x": getattr(payload, "media_x", None),
            "media_y": getattr(payload, "media_y", None),
            "media_w": getattr(payload, "media_w", None),
            "media_h": getattr(payload, "media_h", None),
            "media_fit": getattr(payload, "media_fit", None),
            "created_at": _now_iso(),
        }
        banners.append(banner)
        await self.save_banners(banners)
        return banner

    async def update_banner(self, banner_id: str, body) -> Optional[dict]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                for k, v in body.model_dump(exclude_none=True).items():
                    b[k] = v
                b["updated_at"] = _now_iso()
                await self.save_banners(banners)
                return b
        return None

    async def delete_banner(self, banner_id: str) -> bool:
        banners = await self.list_banners()
        filtered = [b for b in banners if b["id"] != banner_id]
        if len(filtered) == len(banners):
            return False
        await self.save_banners(filtered)
        return True

    async def set_banner_link(self, banner_id: str, click_url: str) -> Optional[dict]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                b["click_url"] = click_url
                b["updated_at"] = _now_iso()
                await self.save_banners(banners)
                return b
        return None

    async def update_banner_image(self, banner_id: str, image_url: str) -> Optional[dict]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                b["image_url"] = image_url
                b["updated_at"] = _now_iso()
                await self.save_banners(banners)
                return b
        return None

    async def record_banner_click(self, banner_id: str) -> Optional[int]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                b["click_count"] = int(b.get("click_count") or 0) + 1
                await self.save_banners(banners)
                return b["click_count"]
        return None

    async def record_banner_view(self, banner_id: str) -> Optional[int]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                b["view_count"] = int(b.get("view_count") or 0) + 1
                await self.save_banners(banners)
                return b["view_count"]
        return None

    async def record_banner_watch(self, banner_id: str, seconds: int) -> Optional[int]:
        banners = await self.list_banners()
        for b in banners:
            if b["id"] == banner_id:
                b["watch_seconds"] = int(b.get("watch_seconds") or 0) + max(int(seconds or 0), 0)
                await self.save_banners(banners)
                return b["watch_seconds"]
        return None

    # ── Platform controls (sections/buttons/trial/force-paywall) ──
    # Canonical maintenance feature keys (single source of truth shared with
    # the mobile app and any admin console reading /controls).
    FEATURES_CATALOG: dict = {
        "personal": [
            "personal/debts",
            "personal/savings",
            "personal/banks",
            "personal/budget",
            "personal/transactions",
            "personal/ai",
            "personal/suggestions",
        ],
        "business": [],
    }

    @staticmethod
    def normalize_disabled_buttons(raw) -> dict:
        """Keep ONLY the canonical maintenance feature keys.

        The admin console may POST bare segment names ('banks'), canonical
        keys ('personal/banks') or junk — everything else is dropped so the
        personal maintenance list can NEVER contain more than the 7 real app
        features (debts, goals, banks, budget, transactions, sara,
        suggestions). Business has no developed features yet → always empty.
        """
        out: dict = {}
        for mode, allowed in AdminSettingsService.FEATURES_CATALOG.items():
            lst = raw.get(mode) if isinstance(raw, dict) else None
            cleaned: list = []
            if isinstance(lst, list):
                for x in lst:
                    s = str(x or "").strip().strip("/")
                    if not s:
                        continue
                    low = s.lower()
                    if "/" not in low:
                        cand = f"{mode}/{low}"
                        if cand in allowed:
                            s = cand
                    if s in allowed and s not in cleaned:
                        cleaned.append(s)
            out[mode] = cleaned
        return out

    async def get_controls(self) -> dict:
        stored = await self._get_json(self.KEY_PLATFORM_CONTROLS, {}) or {}
        default = json.loads(json.dumps(self.DEFAULT_PLATFORM_CONTROLS, ensure_ascii=False))
        merged = default
        # deep-merge one level for the known nested keys
        for section, sec_value in stored.items():
            if section in default and isinstance(sec_value, dict) and isinstance(default[section], dict):
                merged[section].update(sec_value)
            else:
                merged[section] = sec_value
        merged["features_catalog"] = self.FEATURES_CATALOG
        # Clamp on read too: legacy/junk feature keys from older saves must
        # never surface into diffs or admin listings.
        merged["disabled_buttons"] = self.normalize_disabled_buttons(
            merged.get("disabled_buttons")
        )
        return merged

    async def save_controls(self, controls: dict) -> dict:
        current = await self.get_controls()
        for k, v in (controls or {}).items():
            if v is None:
                continue
            current[k] = v
        # Enforce the canonical maintenance features only (personal 7;
        # business none yet) — junk keys are dropped on every save.
        current["disabled_buttons"] = self.normalize_disabled_buttons(
            current.get("disabled_buttons")
        )
        await self._set_json(self.KEY_PLATFORM_CONTROLS, current)
        return current

    # ── Admin notify-emails (who gets subscription-pending emails) ──
    async def get_notify_emails(self) -> list:
        return await self._get_json(self.KEY_NOTIFY_EMAILS, []) or []

    async def save_notify_emails(self, emails: list) -> list:
        import re
        clean = []
        for e in emails:
            s = str(e).strip().lower()
            if not s or not re.match(r'^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$', s):
                continue
            # Skip clearly invalid domains
            domain = s.split('@')[-1] if '@' in s else ''
            if domain in {'fyona.erp', 'example.com', 'test.com', 'localhost'}:
                continue
            clean.append(s)
        await self._set_json(self.KEY_NOTIFY_EMAILS, clean)
        return clean

    # ── Helpers for dashboards ───────────────────────────────────
    async def counts(self) -> dict:
        statuses = await self.env_key_statuses()
        currencies = await self.get_currencies()
        banners = await self.list_banners()
        return {
            "api_keys": sum(1 for s in statuses if s.get("configured")),
            "currencies": len(currencies),
            "banners": len(banners),
            "active_banners": len([b for b in banners if _as_bool(b.get("is_active"))]),
        }
