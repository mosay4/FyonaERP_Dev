from pydantic_settings import BaseSettings
from pydantic import AliasChoices, Field, field_validator
from typing import Optional, List


class Settings(BaseSettings):
    # ── Application ──
    APP_NAME: str = "FYONA ERP API"
    APP_VERSION: str = "1.0.0"
    DEBUG: bool = False
    API_PREFIX: str = "/api/v1"
    # Public base URL of this API (used to compute the Stripe webhook URL etc.).
    # Local dev: http://127.0.0.1:8001  ->  Production: https://api.jeetak-lounge.com
    API_BASE_URL: str = "http://127.0.0.1:8001"
    DOCS_URL: str = "/docs"
    REDOC_URL: str = "/redoc"

    # ── Security ──
    JWT_SECRET_KEY: str = Field(...)  # MUST be set via env
    JWT_ALGORITHM: str = "HS256"
    JWT_ACCESS_TOKEN_EXPIRE_MINUTES: int = 60
    JWT_REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    # Hard cap on devices signed into ONE account at the same time (active,
    # non-revoked, non-expired sessions). The same physical device signing in
    # again (same fingerprint) reuses its slot. Env: MAX_ACTIVE_SESSIONS.
    MAX_ACTIVE_SESSIONS: int = 3

    # ── Firebase Auth ──
    FIREBASE_CREDENTIALS_PATH: Optional[str] = None  # Service Account JSON path
    FIREBASE_PROJECT_ID: Optional[str] = None

    # ── Database ──
    DATABASE_URL: str = Field(...)  # MUST be set via env
    DATABASE_POOL_SIZE: int = 5
    DATABASE_MAX_OVERFLOW: int = 5
    DATABASE_POOL_TIMEOUT: int = 30
    DATABASE_POOL_RECYCLE: int = 1800
    DATABASE_ECHO: bool = False

    # ── Redis ──
    REDIS_URL: str = Field(...)  # MUST be set via env

    # ── Storage ──
    STORAGE_BACKEND: str = "s3"
    S3_ENDPOINT_URL: Optional[str] = None
    S3_ACCESS_KEY: Optional[str] = None  # MUST be set via env
    S3_SECRET_KEY: Optional[str] = None  # MUST be set via env
    S3_BUCKET: str = "fyona-files"
    S3_REGION: str = "us-east-1"
    MAX_FILE_SIZE_MB: int = 50

    # ── Rate Limiting ──
    RATE_LIMIT_ENABLED: bool = True
    RATE_LIMIT_PER_MINUTE: int = 300
    AUTH_RATE_LIMIT_PER_MINUTE: int = 10
    AUTH_RATE_LIMIT_PER_IP_MINUTE: int = 20
    # Phone add/update is abuse-prone (dedup + abuse-guard): tight per-user cap.
    PHONE_UPDATE_RATE_LIMIT_PER_MINUTE: int = 5

    # ── CORS ──
    CORS_ORIGINS: List[str] = []  # MUST be set explicitly for production

    # ── Trusted Hosts ──
    ALLOWED_HOSTS: List[str] = []  # MUST be set explicitly for production

    # ── Background Tasks ──
    CELERY_BROKER_URL: str = Field(...)  # MUST be set via env
    CELERY_RESULT_BACKEND: str = Field(...)  # MUST be set via env

    # ── Exchange Rates ──
    EXCHANGE_RATE_HOST_KEY: Optional[str] = None
    EGCURRENCY_API_KEY: Optional[str] = None

    # ── SMS / Maps ──
    SMS_API_KEY: Optional[str] = None
    MAP_API_KEY: Optional[str] = None

    # ── AI ──
    OPENAI_API_KEY: Optional[str] = None
    OPENAI_MODEL: str = "gpt-4o-mini"

    # ── DeepSeek (preferred when key present; OpenAI-compatible API) ──
    # deepseek-flash = DeepSeek-V4.1-Flash: ONE hybrid model with NATIVE
    # effort levels (low/high/max) chosen per question difficulty.
    DEEPSEEK_API_KEY: Optional[str] = None
    DEEPSEEK_BASE_URL: str = "https://api.deepseek.com"
    DEEPSEEK_MODEL: str = "deepseek-flash"
    SARA_API_KEY: Optional[str] = None
    SARA_BASE_URL: str = "https://api.deepseek.com"
    SARA_MODEL: str = "deepseek-flash"
    SARA_STT_MODEL: str = "small"
    # Load the speech model at startup (first voice upload is not slowed by
    # the model load). Off in environments without faster-whisper.
    SARA_STT_PRELOAD: bool = True

    # ── SMTP / Email ──
    SMTP_HOST: Optional[str] = None
    SMTP_PORT: int = 587
    SMTP_USER: Optional[str] = None
    SMTP_PASSWORD: Optional[str] = None
    SMTP_FROM: Optional[str] = None
    SMTP_TLS: bool = True

    # ── OTP ──
    OTP_TTL_SECONDS: int = 600
    OTP_MAX_ATTEMPTS: int = 5
    OTP_COOLDOWN_SECONDS: int = 60
    PENDING_REGISTRATION_TTL_MINUTES: int = 15

    # ── Auth v2 (phone-first, WhatsApp-first OTP, trusted devices) ──
    # Legacy email routes under /auth are disabled (410). Comma list of the
    # legacy routes that stay enabled: "" (none), "login" (QA scripts with
    # seeded fake users) or "all" (old unit tests).
    AUTH_LEGACY_EMAIL_ROUTES: str = ""
    # OTP engine timings / limits.
    AUTH_OTP_TTL_SECONDS: int = 300
    AUTH_OTP_MAX_ATTEMPTS: int = 5
    AUTH_OTP_MAX_RESENDS: int = 3
    AUTH_OTP_RESEND_COOLDOWNS: str = "30,60,120"
    # Seconds after the WhatsApp send was accepted with no 'delivered'
    # receipt before the SMS fallback becomes allowed (signup/phone_change/
    # password_reset only; never for new_device).
    AUTH_OTP_DELIVERY_DEADLINE_SECONDS: int = 25
    # Automatic SMS fallback at the deadline. Only active when the WhatsApp
    # webhook secret is configured (without delivery receipts every message
    # would look undelivered); the manual "send via SMS" stays available.
    AUTH_OTP_AUTO_SMS_FALLBACK: bool = True
    AUTH_OTP_WHATSAPP_MAX_ATTEMPTS: int = 3
    AUTH_OTP_WORKER_INTERVAL_SECONDS: float = 1.0
    # Caps: "hourly,daily" sends per phone / IP / device / account.
    AUTH_OTP_CAP_PHONE: str = "5,10"
    AUTH_OTP_CAP_IP: str = "10,30"
    AUTH_OTP_CAP_DEVICE: str = "6,15"
    AUTH_OTP_CAP_ACCOUNT: str = "6,15"
    # Cost guard (USD). Admin overrides live in the otp_budgets table.
    AUTH_OTP_BUDGET_SMS_DAILY_USD: float = 0.30
    AUTH_OTP_BUDGET_SMS_MONTHLY_USD: float = 3.00
    AUTH_OTP_BUDGET_WHATSAPP_DAILY_USD: float = 0.50
    AUTH_OTP_BUDGET_WHATSAPP_MONTHLY_USD: float = 5.00
    AUTH_OTP_BUDGET_GLOBAL_DAILY_USD: float = 0.80
    AUTH_OTP_BUDGET_GLOBAL_MONTHLY_USD: float = 8.00
    # Per-message estimates; JSON {"SA": 0.0107, ...} per ISO country.
    AUTH_OTP_COST_WHATSAPP_DEFAULT_USD: float = 0.03
    AUTH_OTP_COST_WHATSAPP_BY_COUNTRY: str = ""
    AUTH_OTP_COST_SMS_DEFAULT_USD: float = 0.08
    AUTH_OTP_COST_SMS_BY_COUNTRY: str = ""
    AUTH_PASSWORD_MAX_FAILURES_PER_15MIN: int = 8
    AUTH_PRIMARY_TRANSFER_HOURS: int = 48

    # ── WhatsApp Cloud API (secrets only from the private env file) ──
    WHATSAPP_ACCESS_TOKEN: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices(
            "WHATSAPP_ACCESS_TOKEN", "WHATSAPP_TOKEN", "META_ACCESS_TOKEN",
            "META_SYSTEM_USER_TOKEN", "WHATSAPP_SYSTEM_USER_TOKEN"),
    )
    WHATSAPP_PHONE_NUMBER_ID: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices(
            "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_PHONE_ID", "META_PHONE_NUMBER_ID"),
    )
    WHATSAPP_WABA_ID: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices(
            "WHATSAPP_WABA_ID", "WHATSAPP_BUSINESS_ACCOUNT_ID", "META_WABA_ID"),
    )
    WHATSAPP_VERIFY_TOKEN: Optional[str] = None
    WHATSAPP_GRAPH_VERSION: str = "v21.0"
    WHATSAPP_GRAPH_BASE_URL: str = "https://graph.facebook.com"
    WHATSAPP_TEMPLATE_NAME: str = "fyona_login_code"
    WHATSAPP_TEMPLATE_LANG_AR: str = "ar"
    WHATSAPP_TEMPLATE_LANG_EN: str = "en"
    META_APP_ID: Optional[str] = None
    META_APP_SECRET: Optional[str] = None
    # Secret of the Meta app the WABA webhooks are subscribed to. Required for
    # receipts and automatic SMS fallback; META_APP_SECRET is not used for it.
    META_WEBHOOK_APP_SECRET: Optional[str] = None

    # ── SMS.to ──
    SMS_TO_API_KEY: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("SMS_TO_API_KEY", "SMS_API_KEY", "SMS_TOKEN"),
    )
    SMS_SENDER_ID: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("SMS_SENDER_ID", "SMS_TO_SENDER_ID", "SMS_SENDER"),
    )
    SMS_TO_BASE_URL: str = Field(
        default="https://api.sms.to",
        validation_alias=AliasChoices("SMS_TO_BASE_URL", "SMS_BASE_URL"),
    )
    # Optional Android SMS Retriever app hash appended to the SMS text.
    SMS_ANDROID_APP_HASH: Optional[str] = None

    # ── Google / Apple sign-in ──
    GOOGLE_WEB_CLIENT_ID: str = (
        "1008683392214-2lmo76djt9t5bf77g3cunlc3ja8pfjik.apps.googleusercontent.com")
    APPLE_TEAM_ID: Optional[str] = None
    APPLE_KEY_ID: Optional[str] = None
    APPLE_BUNDLE_ID: str = "com.fyona.erp.fyonaFlutter"
    APPLE_PRIVATE_KEY_PATH: Optional[str] = None

    # ── Logging ──
    LOG_LEVEL: str = "INFO"
    SENTRY_DSN: Optional[str] = None

    # ── Stripe / Payments ──
    # All Stripe keys are read exclusively from this env file. They are never
    # stored or edited through the admin panel. `stripe_enabled` / `stripe_mode`
    # remain runtime-togglable, but the key values live here and here only.
    STRIPE_ENABLED: bool = False
    STRIPE_MODE: str = "test"  # "test" | "live"
    STRIPE_CURRENCY: str = "SAR"
    STRIPE_WEBHOOK_TOLERANCE: int = 300  # seconds of clock-skew tolerance
    STRIPE_PUBLISHABLE_KEY: Optional[str] = None  # public — safe to expose to clients
    STRIPE_SECRET_KEY: Optional[str] = None        # secret — kept server-side only
    STRIPE_WEBHOOK_SECRET: Optional[str] = None    # secret — kept server-side only

    # ── Administrative Master API key (external Admin Web App) ──
    # A single high-privilege key that unlocks EVERY /admin/* endpoint for the
    # external admin portal. Secret — server-side only, must NEVER ship in a
    # binary, Git, logs or client app. When empty, master-key auth is disabled.
    ADMIN_MASTER_KEY: str = ""
    # Email of the platform-admin user used as the *identity* behind the master
    # key (for audit trails: reviewed_by, etc.). Bootstrap with create_super_admin.py.
    ADMIN_MASTER_EMAIL: str = "admin@fyona.erp"

    # ── Telegram alert bot (system warnings/errors) ──
    TELEGRAM_BOT_TOKEN: Optional[str] = None
    TELEGRAM_CHAT_ID: Optional[str] = None

    # ── Multi-Tenant ──
    TENANT_ISOLATION: str = "ROW"  # ROW or SCHEMA

    # ── Sync ──
    SYNC_BATCH_SIZE: int = 100
    SYNC_MAX_RETRIES: int = 5
    SYNC_RETRY_DELAY_SECONDS: int = 30

    model_config = {"env_file": (".env", ".sara.env"), "case_sensitive": True, "extra": "ignore"}

    @property
    def database_url_sync(self) -> str:
        """Returns sync database URL for Alembic."""
        return self.DATABASE_URL.replace("+asyncpg", "")

    @field_validator("STRIPE_MODE")
    @classmethod
    def validate_stripe_mode(cls, v: str) -> str:
        if v not in ("test", "live"):
            raise ValueError("STRIPE_MODE must be 'test' or 'live'")
        return v

    @field_validator("JWT_SECRET_KEY")
    @classmethod
    def validate_jwt_secret(cls, v: str) -> str:
        if len(v) < 16:
            raise ValueError("JWT_SECRET_KEY must be at least 16 characters")
        return v

    @property
    def stripe_webhook_url(self) -> str:
        """Public webhook URL derived from the API base.

        Local: http://127.0.0.1:8001/api/v1/payments/stripe/webhook
        Prod:  https://api.jeetak-lounge.com/api/v1/payments/stripe/webhook
        Computed from env, never hardcoded.
        """
        base = self.API_BASE_URL.rstrip("/")
        return f"{base}{self.API_PREFIX}/payments/stripe/webhook"

    @property
    def config_master_key(self) -> bytes:
        """Fernet master key for encrypting runtime secrets (app_config).

        Derived from JWT_SECRET_KEY via PBKDF2 — no extra env var required.
        """
        import base64
        import hashlib
        kdf = hashlib.pbkdf2_hmac("sha256", self.JWT_SECRET_KEY.encode("utf-8"), b"fyona.app_config", 200_000)
        return base64.urlsafe_b64encode(kdf)



settings = Settings()
