"""Admin view of the Personal section: counts only.

Personal data lives only on the users' devices (docs/PERSONAL_LOCAL_PLAN.md):
the server relays it between a user's devices and keeps nothing. Admins see
how many users there are and how far the move to the devices is (migration
and relay replica counts) — never an account, an amount or a record. Every
per-user data route answers 410.
"""
from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_user_id, require_admin_perm
from ...api.responses import ok
from ...core.database import get_db
from ...domain.entities.auth_entities import User
from ...domain.services import personal_local_migration as migration

router = APIRouter(tags=["Admin - Personal Finance"])

GONE_MESSAGE = "البيانات الشخصية محفوظة على أجهزة المستخدم فقط"


def _gone() -> JSONResponse:
    return JSONResponse(
        {"success": False, "code": "personal_local",
         "message": GONE_MESSAGE, "detail": "data lives on the user's devices"},
        status_code=410,
    )


async def _replica_counts(db: AsyncSession) -> dict:
    conn = await db.connection()
    if not await conn.scalar(text("SELECT to_regclass('public.personal_relay_replicas') IS NOT NULL")):
        return {"devices": 0, "users_with_devices": 0}
    row = (await conn.execute(text("""
        SELECT COUNT(*) AS devices, COUNT(DISTINCT user_id) AS users_with_devices
        FROM public.personal_relay_replicas WHERE retired = false
    """))).mappings().one()
    return dict(row)


@router.get("/admin/personal/stats")
async def get_personal_stats(
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    """Counts only: users, devices and the move of legacy rows to devices."""
    total_users = (await db.execute(
        select(func.count(User.id)).where(User.role == "personal")
    )).scalar() or 0
    active_users = (await db.execute(
        select(func.count(User.id)).where(User.role == "personal", User.status == "active")
    )).scalar() or 0
    return ok(data={
        "total_users": total_users,
        "active_users": active_users,
        "data_location": "devices",
        "relay": await _replica_counts(db),
        "migration": await migration.counts(await db.connection()),
    })


@router.get("/admin/personal/users")
async def list_personal_users(
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
):
    return _gone()


_GONE_ROUTES = (
    ("GET", "/admin/personal/users/{user_id}", "read"),
    ("GET", "/admin/personal/users/{user_id}/accounts", "read"),
    ("PATCH", "/admin/personal/users/{user_id}/accounts/{item_id}", "update"),
    ("DELETE", "/admin/personal/users/{user_id}/accounts/{item_id}", "delete"),
    ("GET", "/admin/personal/users/{user_id}/transactions", "read"),
    ("PATCH", "/admin/personal/users/{user_id}/transactions/{item_id}", "update"),
    ("DELETE", "/admin/personal/users/{user_id}/transactions/{item_id}", "delete"),
    ("GET", "/admin/personal/users/{user_id}/goals", "read"),
    ("PATCH", "/admin/personal/users/{user_id}/goals/{item_id}", "update"),
    ("DELETE", "/admin/personal/users/{user_id}/goals/{item_id}", "delete"),
    ("GET", "/admin/personal/users/{user_id}/debts", "read"),
    ("PATCH", "/admin/personal/users/{user_id}/debts/{item_id}", "update"),
    ("DELETE", "/admin/personal/users/{user_id}/debts/{item_id}", "delete"),
)


def _gone_route(action: str):
    async def handler(
        _user_id: str = Depends(get_current_user_id),
        _perm: bool = Depends(require_admin_perm("personal_finance", action)),
    ):
        return _gone()
    return handler


for _method, _path, _action in _GONE_ROUTES:
    router.add_api_route(_path, _gone_route(_action), methods=[_method],
                         summary="Personal data lives on the user's devices (410)")
