# -*- coding: utf-8 -*-
"""
FYONA Admin Web App — Backend Proxy Server (independent from the mobile app).

Security model:
  * ADMIN_MASTER_KEY lives in THIS server's .env only; it is NEVER sent to the
    browser. The proxy injects `X-Admin-Master-Key` into every forwarded request.
  * Log-in validates the master admin credentials against the FYONA backend;
    on success a short-lived HttpOnly session cookie is set (random token kept
    in-memory) — no master key/secret ever reaches the client.
  * Every /api/{path} request is proxied to the FYONA backend with the master
    key attached. Requests without a valid session cookie are rejected (401).

Features wired: subscriptions, users, accounting, notifications, banners,
plans, orgs (trial control), suggestions read/reply, dashboard stats.

Run:  python admin_server.py   (serves the SPA at http://127.0.0.1:8080)
"""
import asyncio
import hashlib
import json
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Optional

import httpx
import uvicorn
from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

BASE_DIR = Path(__file__).resolve().parent


def _load_env() -> None:
    """Minimal .env loader (server-side secrets only)."""
    env_path = BASE_DIR / ".env"
    if not env_path.is_file():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_env()

# Web SPA lives one level up: Desktop/fyona_admin/web
WEB_DIR = BASE_DIR.parent / "web"

# ── Server-side secrets (this file's own .env) ──
MASTER_KEY = os.getenv("ADMIN_MASTER_KEY", "").strip()
FYONA_API = os.getenv("FYONA_API", "http://127.0.0.1:8001").rstrip("/")
ADMIN_LOGIN_EMAIL = os.getenv("ADMIN_EMAIL", "")
ADMIN_LOGIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")
PUBLIC_ORIGIN = os.getenv("ADMIN_PUBLIC_ORIGIN", "").rstrip("/")
COOKIE_PATH = os.getenv("ADMIN_COOKIE_PATH", "/")
SESSION_TTL = 8 * 3600  # 8h

app = FastAPI(title="FYONA Admin Proxy", docs_url=None, redoc_url=None)

# ── In-memory session store: token -> {expiry, mode, jwt}
_sessions: dict[str, dict] = {}
_login_lock = asyncio.Lock()


def _sha(data: str) -> str:
    return hashlib.sha256(data.encode()).hexdigest()


async def login_to_fyona() -> Optional[str]:
    """Authenticate against FYONA backend and return a fresh JWT (for identity
    purposes). The proxy still enforces its own session binding."""
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.post(
            f"{FYONA_API}/api/v1/auth/login",
            json={"email": ADMIN_LOGIN_EMAIL, "password": ADMIN_LOGIN_PASSWORD},
        )
        if r.status_code != 200:
            return None
        data = r.json().get("data") or {}
        token = data.get("access_token") or (data.get("tokens") or {}).get("access")
        user = data.get("user") or {}
        if user.get("is_platform_admin") is not True and str(user.get("role")) != "super_admin":
            return None
        return token


async def proxy(request: Request, path: str):
    sess = _sessions.get(request.cookies.get("fyona_sess", ""))
    if not sess or sess.get("exp") < time.time():
        raise HTTPException(status_code=401, detail="غير مصرح — سجل الدخول أولاً")

    url = f"{FYONA_API}/api/v1/{path}"
    body = await request.body()
    headers = {
        "Content-Type": request.headers.get("content-type", "application/json"),
        "Accept": "application/json",
    }
    if sess.get("mode") == "employee" and sess.get("jwt"):
        # Employee logged in with own credentials → use their JWT so the
        # backend enforces their granted admin permissions (RBAC).
        headers["Authorization"] = f"Bearer {sess['jwt']}"
    else:
        if not MASTER_KEY:
            raise HTTPException(status_code=503, detail="ADMIN_MASTER_KEY غير مُعدّ")
        # Admin master → full access via the master API key.
        headers["X-Admin-Master-Key"] = MASTER_KEY

    async with httpx.AsyncClient(timeout=60) as client:
        r = await client.request(
            request.method, url, content=body, headers=headers,
            params=request.query_params, follow_redirects=False,
        )
    content = r.content
    if r.status_code == 204:
        return Response(status_code=204)
    try:
        return JSONResponse(status_code=r.status_code, content=r.json())
    except Exception:
        return Response(content=content, status_code=r.status_code, media_type="application/json")


class _SessionCheck(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if (PUBLIC_ORIGIN and request.method not in {"GET", "HEAD", "OPTIONS"}
                and request.headers.get("origin") != PUBLIC_ORIGIN):
            return JSONResponse(status_code=403, content={"detail": "Origin not allowed"})
        # Permit login & static assets without a session.
        public = (
            request.url.path == "/api/login" or
            request.url.path == "/api/version" or
            request.url.path.startswith("/assets/") or
            request.url.path in ("/", "/index.html") or
            request.url.path.endswith((".js", ".css", ".png", ".ico", ".svg", ".woff2", ".json", ".map"))
        )
        if public or request.url.path.startswith("/api/logout"):
            return await call_next(request)
        if not request.url.path.startswith("/api"):
            # Non-API route → serve SPA (client-side routing).
            return await call_next(request)
        token = request.cookies.get("fyona_sess", "")
        sess = _sessions.get(token)
        if not sess or sess.get("exp") < time.time():
            return JSONResponse(status_code=401, content={"success": False, "message": "غير مصرح"})
        return await call_next(request)


app.add_middleware(_SessionCheck)


@app.post("/api/login")
async def api_login(request: Request):
    body = await request.json()
    email = (body.get("email") or "").strip().lower()
    password = body.get("password") or ""
    if not email or not password:
        raise HTTPException(status_code=400, detail="أدخل البريد وكلمة المرور")
    import hmac as _hmac
    expected = ADMIN_LOGIN_EMAIL.strip().lower()
    master_ok = bool(MASTER_KEY and expected and ADMIN_LOGIN_PASSWORD and
                     _hmac.compare_digest(email.encode(), expected.encode()) and
                     _hmac.compare_digest(password.encode(), ADMIN_LOGIN_PASSWORD.encode()))
    mode = "master"
    emp_jwt = ""
    if not master_ok:
        # Try a real FYONA user (employee/admin) login → RBAC applies on proxy.
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                rr = await client.post(
                    f"{FYONA_API}/api/v1/auth/login",
                    json={"email": email, "password": password},
                )
                if rr.status_code == 200:
                    data = rr.json() or {}
                    emp_jwt = data.get("access_token") or (data.get("tokens") or {}).get("access")
                    user = data.get("user") or {}
                    isAdmin = user.get("is_platform_admin") is True or str(user.get("role")) == "super_admin"
                    if not emp_jwt or not isAdmin:
                        raise HTTPException(status_code=401, detail="بيانات الدخول غير صحيحة")
                    mode = "employee"
                else:
                    raise HTTPException(status_code=401, detail="بيانات الدخول غير صحيحة")
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(status_code=401, detail="بيانات الدخول غير صحيحة")

    token = secrets.token_urlsafe(32)
    _sessions[token] = {"exp": time.time() + SESSION_TTL, "mode": mode, "jwt": emp_jwt}
    resp = JSONResponse({"success": True, "data": {"name": "FYONA Admin"}})
    resp.set_cookie("fyona_sess", token, httponly=True, secure=bool(PUBLIC_ORIGIN),
                    samesite="strict", max_age=SESSION_TTL, path=COOKIE_PATH)
    return resp


@app.post("/api/logout")
async def api_logout(request: Request):
    token = request.cookies.get("fyona_sess", "")
    _sessions.pop(token, None)
    resp = JSONResponse({"success": True, "message": "تم تسجيل الخروج"})
    resp.delete_cookie("fyona_sess", path=COOKIE_PATH, secure=bool(PUBLIC_ORIGIN),
                       httponly=True, samesite="strict")
    return resp


@app.get("/api/version")
async def api_version():
    return {"success": True, "data": {"version": "1.0", "admin": True}}


# ── Uploads asset proxy (proof images…) — MUST be defined BEFORE the generic
# `/api/{path:path}` catch-all, otherwise Starlette routes every request here
# into the generic proxy and this endpoint is never reached (proofs 404). ──
@app.get("/api/proxy-uploads")
async def proxy_uploads(request: Request, u: str = ""):
    """Serve an uploads asset (proof images…) through the master-keyed backend."""
    sess = _sessions.get(request.cookies.get("fyona_sess", ""))
    if not sess or (sess.get("exp") or 0) < time.time():
        raise HTTPException(status_code=401, detail="غير مصرح")
    if not u:
        raise HTTPException(status_code=400, detail="معرّف الملف مطلوب")
    from urllib.parse import unquote, urlsplit
    parsed = urlsplit(u)
    decoded = unquote(parsed.path)
    if (parsed.scheme or parsed.netloc or parsed.query or parsed.fragment
            or not decoded.startswith("/uploads/") or "\\" in decoded
            or any(p in ("", ".", "..") for p in decoded[len("/uploads/"):].split("/"))):
        raise HTTPException(status_code=400, detail="مسار الملف غير صالح")
    if sess.get("mode") == "employee" and sess.get("jwt"):
        headers = {"Authorization": f"Bearer {sess['jwt']}"}
    elif MASTER_KEY:
        headers = {"X-Admin-Master-Key": MASTER_KEY}
    else:
        raise HTTPException(status_code=401, detail="غير مصرح")
    url = f"{FYONA_API}{u}"
    try:
        async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
            r = await client.get(url, headers=headers)
    except httpx.HTTPError:
        return JSONResponse(status_code=502, content={"success": False, "message": "فشل الاتصال بالخادم"})
    ctype = r.headers.get("content-type", "application/octet-stream")
    if r.status_code != 200:
        return JSONResponse(status_code=r.status_code, content={"success": False, "message": "تعذر تحميل الملف"})
    return Response(content=r.content, media_type=ctype, status_code=200, headers={
        "Content-Security-Policy": "sandbox; default-src 'none'",
        "X-Content-Type-Options": "nosniff",
    })


# ── Proxy: every other /api/* → FYONA backend with master key ──
@app.api_route("/api/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def api_proxy(request: Request, path: str):
    return await proxy(request, path)


# ── Static SPA (no-cache so admin panel updates appear instantly) ──
_NO_CACHE = {"Cache-Control": "no-store, no-cache, must-revalidate", "Pragma": "no-cache"}
@app.get("/{full_path:path}")
async def spa(full_path: str):
    target = (WEB_DIR / full_path).resolve()
    if target.is_file() and target.is_relative_to(WEB_DIR.resolve()):
        return FileResponse(target, headers=_NO_CACHE)
    index = WEB_DIR / "index.html"
    if index.is_file():
        return FileResponse(index, headers=_NO_CACHE)
    return JSONResponse({"error": "SPA not built"}, status_code=500)


if __name__ == "__main__":
    host = os.getenv("ADMIN_HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=8080, log_level="info")
