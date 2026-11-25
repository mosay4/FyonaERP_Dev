"""The server never stores Personal data of a local Personal user.

Their Personal records live on their devices and travel only through the
Personal relay (/personal-relay). For such a user:

* an app build that does not speak the device-only protocol gets
  409 {"code": "update_required"} on the old Personal endpoints, instead of
  sync loops;
* once the one-time baseline export exists (/personal-local/export) the old
  Personal stores are frozen: writes (/personal/finance/*, /sync/push) get
  409 {"code": "personal_local"}, reads 410 {"code": "personal_local"};
* before that, a current build may still drain its old outbox into them.

Exempt: the migration (/personal-local) and the relay (/personal-relay).
"""

from __future__ import annotations

from uuid import UUID

from fastapi.responses import JSONResponse

from app.core import personal_local_mode as mode

_FINANCE = "/api/v1/personal/finance"
_SYNC = ("/api/v1/sync/push", "/api/v1/sync/pull")
_EXEMPT = ("/api/v1/personal-local", "/api/v1/personal-relay")

MESSAGE_LOCAL = "بياناتك الشخصية محفوظة على أجهزتك فقط"
MESSAGE_UPDATE = "حدّث التطبيق إلى آخر إصدار لمتابعة استخدام القسم الشخصي"


def _personal_path(path: str) -> bool:
    path = path.rstrip("/")
    if path.startswith(_EXEMPT):
        return False
    return path == _FINANCE or path.startswith(_FINANCE + "/") or path in _SYNC


def refusal(code: str, status: int, message: str) -> JSONResponse:
    return JSONResponse({"success": False, "code": code, "message": message,
                         "detail": message}, status_code=status)


def _user_of(request) -> UUID | None:
    from app.core.security import decode_token

    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    try:
        claims = decode_token(auth[7:]) or {}
        return UUID(str(claims.get("sub")))
    except Exception:
        return None


async def _frozen(user: UUID) -> bool:
    from app.core.database import async_session_factory
    from app.domain.services import personal_local_migration as migration

    async with async_session_factory() as db:
        return await migration.exported(await db.connection(), user)


async def guard(request, call_next):
    if mode.ENABLED and _personal_path(request.url.path):
        user = _user_of(request)
        if user is not None and mode.enabled_for_id(user):
            if not mode.current_client(request):
                return refusal(mode.CODE_UPDATE, 409, MESSAGE_UPDATE)
            if await _frozen(user):
                write = request.method not in ("GET", "HEAD", "OPTIONS") and \
                    request.url.path.rstrip("/") != "/api/v1/sync/pull"
                return refusal(mode.CODE_LOCAL, 409 if write else 410, MESSAGE_LOCAL)
    return await call_next(request)
