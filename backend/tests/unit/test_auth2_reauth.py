"""/auth2/reauth confirms the account password (app-lock PIN reset)."""
from app.api.v1 import auth2


def test_reauth_route_registered_and_requires_auth():
    paths = {r.path for r in auth2.router.routes}
    assert "/reauth" in paths or any(p.endswith("/reauth") for p in paths)
    route = next(r for r in auth2.router.routes if r.path.endswith("/reauth"))
    names = {d.call.__name__ for d in route.dependant.dependencies}
    assert "get_current_user_uuid" in names
