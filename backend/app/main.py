import os
import signal
import asyncio
from contextlib import asynccontextmanager
from uuid import uuid4

import sentry_sdk
from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from .core.config import settings
from .core.logging import setup_logging, get_logger, set_correlation_id, set_request_id
from .core.database import init_db, close_db, async_session_factory
from .core.redis import close_redis
from .core.firebase import initialize_firebase
from .domain.services.role_bootstrap import ensure_system_role_permissions
from .core.security_middleware import SecurityHeadersMiddleware
from .core.rate_limiter import RateLimitMiddleware
from .core.all_branches_guard import AllBranchesReadOnlyMiddleware
from .core.employee_response_guard import EmployeeBankResponseGuard
from .core.metrics import PrometheusMiddleware
from .core.version import get_version_info
from .api.v1.health import router as health_router
from .api.v1.auth import router as auth_router
from .api.v1.business import router as business_router
from .api.v1.branches import router as branches_router
from .api.v1.business_media_transit import router as media_transit_router
from .api.v1.business_relay import router as business_relay_router
from .api.v1.business_peer_relay import router as business_peer_relay_router
from .api.v1.personal_relay import router as personal_relay_router
from .api.v1.business_local_migration import router as business_local_migration_router
from .api.v1.personal_local import router as personal_local_router
from .api.v1.reconciliation import router as reconciliation_router
from .api.v1.business_reports import router as business_reports_router
from .api.v1.invoices import router as invoice_router
from .api.v1.sales import router as sales_router
from .api.v1.purchases import router as purchases_router
from .api.v1.accounting import router as accounting_router
from .api.v1.hr import router as hr_router
from .api.v1.employees import router as employees_router
from .api.v1.project_settings import router as project_settings_router
from .api.v1.reports import router as reports_router
from .api.v1.ai import router as ai_router
from .api.v1.business_sara import router as business_sara_router
from .api.v1.sync import router as sync_router
from .api.v1.finance import router as finance_router
from .api.v1.subscription import router as subscription_router
from .api.v1.exchange_rates import router as exchange_rates_router
from .api.v1.admin_exchange_rates import router as admin_exchange_rates_router
from .api.v1.admin_personal import router as admin_personal_router
from .api.v1.personal_finance import router as personal_finance_router
from .api.v1.backups import router as backups_router
from .api.v1.admin import router as admin_router
from .api.v1.debug import router as debug_router
from .api.v1.notifications import router as notifications_router
from .api.v1.merchant_links import router as merchant_links_router
from .api.v1.chat import router as chat_router
from .api.v1.suggestions import router as suggestions_router
from .api.v1.files import router as files_router
from .api.v1.payments import router as payments_router
from .api.v1.push import router as push_router
from .api.v1.subscription_invoices import router as subscription_invoices_router
from .api.deps import require_maintenance_allowed
from functools import partial

logger = get_logger("main")

# ── Maintenance (server-side) router guards ──
# Section-level: personal / business. Feature-level is derived per path inside
# require_maintenance_allowed (banks, transactions, goals, debts, budget, ai).
_personal_maint = [Depends(partial(require_maintenance_allowed, "personal"))]
_business_maint = [Depends(partial(require_maintenance_allowed, "business"))]

# ── Sentry ──
if settings.SENTRY_DSN:
    from .core.version import get_git_commit

    def _sentry_before_send(event, hint):
        """Filter PII from Sentry events."""
        # Remove request headers that may contain auth tokens
        if "request" in event and "headers" in event["request"]:
            headers = event["request"]["headers"]
            for key in ("Authorization", "X-API-Key", "Cookie"):
                headers.pop(key, None)
        return event

    sentry_sdk.init(
        dsn=settings.SENTRY_DSN,
        environment="production" if not settings.DEBUG else "development",
        release=get_git_commit(),
        traces_sample_rate=0.2,
        profiles_sample_rate=0.2,
        before_send=_sentry_before_send,
        send_default_pii=False,
    )
    logger.info("sentry_initialized")


# ── Graceful shutdown tracking ──
_shutting_down = False


def _handle_sigterm(*args):
    global _shutting_down
    _shutting_down = True
    logger.info("received_sigterm")


async def _warm_currency_rates() -> None:
    from .domain.services.currency_service import CentralFXEngine
    while True:
        delay = 60
        try:
            data = await CentralFXEngine.get_instance().get_all_rates(force_refresh=True)
            yemen = data.get('yemen') or {}
            if len(data.get('global') or {}) > 1 and \
                    (yemen.get('sanaa') or {}).get('USD') and \
                    (yemen.get('aden') or {}).get('USD') and \
                    all((data.get('meta') or {}).get('provider_refresh', {}).get(k)
                        for k in ('global','yemen')):
                delay = 3600
            logger.info('currency_rates_warmed')
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning('currency_rates_warm_failed', error=str(exc))
        await asyncio.sleep(delay)


signal.signal(signal.SIGTERM, _handle_sigterm)


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    logger.info("starting_up", app=settings.APP_NAME, version=settings.APP_VERSION)
    await init_db()
    initialize_firebase()
    try:
        async with async_session_factory() as session:
            added = await ensure_system_role_permissions(session)
        if added:
            logger.info("role_permissions_bootstrap", added=added)
    except Exception as exc:  # pragma: no cover - startup resilience
        logger.warning("role_permissions_bootstrap_failed", error=str(exc))
    # Warm exchange rates in the background (populates the per-currency store)
    rate_task = asyncio.create_task(_warm_currency_rates())
    # Daily server-side expiry notifications (Business warehouses).
    try:
        from app.domain.services import inventory_expiry_jobs as _expiry_jobs

        asyncio.create_task(_expiry_jobs.expiry_scheduler())
    except Exception:
        pass
    # Hourly Personal maintenance in-process (QA runs no Celery beat): the
    # relay retention and the purge of migrated legacy Personal rows.
    try:
        from app.workers import personal_maintenance as _personal_maintenance

        asyncio.create_task(_personal_maintenance.scheduler())
    except Exception:
        pass
    # Advertise on the LAN (mDNS) so phones find the backend with zero
    # configuration. Best-effort: never affects the API itself.
    try:
        from app.core import mdns as _mdns

        asyncio.create_task(_mdns.start_advertisement(8001))
    except Exception:
        pass
    # Warn if running with DEBUG in production
    if settings.DEBUG:
        logger.warning("running_in_debug_mode")
    yield
    rate_task.cancel()
    await asyncio.gather(rate_task, return_exceptions=True)
    logger.info("shutting_down_draining_requests")
    try:
        from app.core import mdns as _mdns_shutdown

        await _mdns_shutdown.stop_advertisement()
    except Exception:
        pass
    await close_db()
    from .domain.services.chat_live_service import chat_live_hub
    await chat_live_hub.stop()
    await close_redis()
    logger.info("shutdown_complete")


app = FastAPI(
    title=settings.APP_NAME,
    version=settings.APP_VERSION,
    docs_url=settings.DOCS_URL if settings.DEBUG else None,
    redoc_url=settings.REDOC_URL if settings.DEBUG else None,
    lifespan=lifespan,
)


# ── API root endpoint ──
@app.get(f"{settings.API_PREFIX}", tags=["System"])
async def api_root():
    return {
        "name": settings.APP_NAME,
        "version": settings.APP_VERSION,
        "docs": settings.DOCS_URL,
        "health": f"{settings.API_PREFIX}/health/ready",
    }


# ── Version endpoint ──
@app.get("/version", tags=["System"])
async def version():
    return get_version_info()


# ── Health endpoint (top-level) ──
@app.get("/health", tags=["System"])
async def health(response: Response):
    from .api.v1.health import health_check
    return await health_check(response)


# ── Prometheus metrics endpoint ──
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

@app.get("/metrics", tags=["System"])
async def metrics():
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )


# ── Standardized error responses ──
@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    return JSONResponse(
        content={"success": False, "message": exc.detail},
        status_code=exc.status_code,
    )


@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception):
    logger.error("unhandled_exception", error=str(exc))
    # Automatic Telegram alert for any unhandled server error.
    try:
        from app.core.telegram_alert import alert_exception

        await alert_exception(
            exc,
            component=f"{request.method} {request.url.path}",
        )
    except Exception:  # pragma: no cover - alerting must never break the API
        pass
    return JSONResponse(
        content={"success": False, "message": "Internal server error"},
        status_code=500,
    )


# ── Middleware (order matters: outermost first) ──
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=settings.ALLOWED_HOSTS,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Correlation-ID", "X-Request-ID"],
)
app.add_middleware(AllBranchesReadOnlyMiddleware)
app.add_middleware(EmployeeBankResponseGuard)
app.add_middleware(SecurityHeadersMiddleware)
app.add_middleware(PrometheusMiddleware)
if settings.RATE_LIMIT_ENABLED:
    app.add_middleware(
        RateLimitMiddleware,
        per_ip=settings.RATE_LIMIT_PER_MINUTE,
        per_user=settings.RATE_LIMIT_PER_MINUTE,
        auth_per_ip=settings.AUTH_RATE_LIMIT_PER_IP_MINUTE,
        auth_per_user=settings.AUTH_RATE_LIMIT_PER_MINUTE,
    )
    logger.info("rate_limit_enabled", per_minute=settings.RATE_LIMIT_PER_MINUTE)


from .core.business_local_guard import guard as _business_local_guard


@app.middleware("http")
async def business_data_stays_on_devices(request, call_next):
    return await _business_local_guard(request, call_next)


from .core.personal_local_guard import guard as _personal_local_guard


@app.middleware("http")
async def personal_data_stays_on_devices(request, call_next):
    return await _personal_local_guard(request, call_next)


@app.middleware("http")
async def strip_metrics_cors(request, call_next):
    """Strip CORS headers from /metrics responses (Prometheus doesn't need them)."""
    response = await call_next(request)
    if request.url.path == "/metrics":
        for header in ("access-control-allow-origin", "access-control-allow-methods",
                        "access-control-allow-headers", "access-control-allow-credentials"):
            response.headers.pop(header, None)
    return response


@app.middleware("http")
async def add_request_id_middleware(request, call_next):
    if _shutting_down:
        return JSONResponse(
            content={"success": False, "message": "Server is shutting down"},
            status_code=503,
        )
    correlation_id = request.headers.get("X-Correlation-ID", str(uuid4()))
    request_id = str(uuid4())
    set_correlation_id(correlation_id)
    set_request_id(request_id)
    response = await call_next(request)
    response.headers["X-Correlation-ID"] = correlation_id
    response.headers["X-Request-ID"] = request_id
    return response


# ── Routers ──
app.include_router(health_router, prefix=settings.API_PREFIX, tags=["Health"])
app.include_router(auth_router, prefix=f"{settings.API_PREFIX}/auth", tags=["Auth"])
app.include_router(business_router, prefix=f"{settings.API_PREFIX}", tags=["Business"], dependencies=_business_maint)
app.include_router(branches_router, prefix=f"{settings.API_PREFIX}", tags=["Branches"])
app.include_router(media_transit_router,
                   prefix=f"{settings.API_PREFIX}/business/media-transit",
                   tags=["Business media transit"])
app.include_router(business_relay_router,
                   prefix=f"{settings.API_PREFIX}/business-relay",
                   tags=["Business relay"])
app.include_router(personal_relay_router,
                   prefix=f"{settings.API_PREFIX}/personal-relay",
                   tags=["Personal relay"])
app.include_router(business_peer_relay_router,
                   prefix=f"{settings.API_PREFIX}/peer-relay",
                   tags=["Peer relay"])
app.include_router(business_local_migration_router,
                   prefix=f"{settings.API_PREFIX}/local-migration",
                   tags=["Local migration"])
app.include_router(personal_local_router,
                   prefix=f"{settings.API_PREFIX}/personal-local",
                   tags=["Personal local migration"])
app.include_router(reconciliation_router, prefix=f"{settings.API_PREFIX}", tags=["Reconciliation"])
app.include_router(business_reports_router, prefix=f"{settings.API_PREFIX}", tags=["Business Reports"])
app.include_router(invoice_router, prefix=f"{settings.API_PREFIX}", tags=["Invoices"])
app.include_router(sales_router, prefix=f"{settings.API_PREFIX}", tags=["Sales"])
app.include_router(purchases_router, prefix=f"{settings.API_PREFIX}", tags=["Purchases"])
app.include_router(accounting_router, prefix=f"{settings.API_PREFIX}", tags=["Accounting"])
app.include_router(hr_router, prefix=f"{settings.API_PREFIX}", tags=["HR"])
app.include_router(employees_router, prefix=f"{settings.API_PREFIX}", tags=["Employees"])
app.include_router(project_settings_router, prefix=settings.API_PREFIX, dependencies=_business_maint)
app.include_router(reports_router, prefix=f"{settings.API_PREFIX}", tags=["Reports"])
app.include_router(ai_router, prefix=f"{settings.API_PREFIX}", tags=["AI"], dependencies=_personal_maint)
app.include_router(business_sara_router, prefix=settings.API_PREFIX, dependencies=_business_maint)
app.include_router(sync_router, prefix=f"{settings.API_PREFIX}", tags=["Sync"])
app.include_router(finance_router, prefix=f"{settings.API_PREFIX}", tags=["Finance"])
app.include_router(subscription_router, prefix=settings.API_PREFIX, tags=["Subscription"])
app.include_router(exchange_rates_router, prefix=settings.API_PREFIX, tags=["Currency"], dependencies=_personal_maint)
app.include_router(admin_exchange_rates_router, prefix=settings.API_PREFIX, tags=["Admin"])
app.include_router(admin_personal_router, prefix=settings.API_PREFIX, tags=["Admin"])
app.include_router(personal_finance_router, prefix=settings.API_PREFIX, tags=["Personal Finance"], dependencies=_personal_maint)
app.include_router(backups_router, prefix=settings.API_PREFIX, tags=["Backups"], dependencies=_personal_maint)
app.include_router(admin_router, prefix=settings.API_PREFIX, tags=["Admin"])
app.include_router(debug_router, prefix=f"{settings.API_PREFIX}/debug", tags=["Debug"])
app.include_router(notifications_router, prefix=settings.API_PREFIX, tags=["Notifications"])
app.include_router(merchant_links_router, prefix=settings.API_PREFIX, tags=["Merchant Accounts"])
from .core.qa_directory import INVITES as _qa_directory_invites
if _qa_directory_invites:
    from .api.v1.qa_business_party_sharing import router as _qa_party_share_router
    app.include_router(_qa_party_share_router, prefix=settings.API_PREFIX, dependencies=_business_maint)
    from .api.v1 import qa_business_cash_relay as _qa_cash_relay
    if _qa_cash_relay.relay_enabled():
        app.include_router(_qa_cash_relay.router, prefix=settings.API_PREFIX, dependencies=_business_maint)
    from .api.v1 import qa_employee_finance as _qa_employee_finance
    if _qa_employee_finance.finance.enabled():
        app.include_router(_qa_employee_finance.router, prefix=settings.API_PREFIX, dependencies=_business_maint)
app.include_router(chat_router, prefix=settings.API_PREFIX, tags=["Chat"])
app.include_router(suggestions_router, prefix=settings.API_PREFIX, tags=["Suggestions"], dependencies=_personal_maint)
app.include_router(files_router)
app.include_router(payments_router, prefix=settings.API_PREFIX, tags=["Payments"])
app.include_router(push_router, prefix=settings.API_PREFIX, tags=["Push"])
app.include_router(subscription_invoices_router, prefix=settings.API_PREFIX, tags=["Subscription Invoices"])
