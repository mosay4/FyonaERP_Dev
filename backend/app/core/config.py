from pydantic_settings import BaseSettings
from pydantic import Field, field_validator
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
