"""Cloudflare R2 (S3-compatible) — signing only, no SDK.

The FYONA server never streams user files: it decides WHO may touch WHICH key
and hands the device a short-lived presigned URL (AWS Signature V4). Bytes go
device ⇄ R2 directly. The server itself only issues small signed requests
(HEAD to verify an upload, DELETE, LIST of backup parts).

Keys (from the server environment only — never in the app or the repo):
CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import hmac
import os
import html
import re
from dataclasses import dataclass
from typing import Mapping, Optional
from urllib.parse import quote

import httpx

_REGION = "auto"
_SERVICE = "s3"
_UNSIGNED = "UNSIGNED-PAYLOAD"
_EMPTY_SHA = hashlib.sha256(b"").hexdigest()
_KEY_RE = re.compile(r"^[A-Za-z0-9._\-/]{1,512}$")


class R2NotConfigured(RuntimeError):
    pass


@dataclass(frozen=True)
class R2Config:
    account_id: str
    access_key: str
    secret_key: str
    bucket: str

    @property
    def host(self) -> str:
        return f"{self.account_id}.r2.cloudflarestorage.com"

    @staticmethod
    def from_env(env: Mapping[str, str] | None = None) -> "R2Config":
        e = env if env is not None else os.environ
        vals = [e.get(k, "").strip() for k in
                ("CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET")]
        if not all(vals):
            raise R2NotConfigured("R2 is not configured on this server")
        return R2Config(*vals)


def configured() -> bool:
    try:
        R2Config.from_env()
        return True
    except R2NotConfigured:
        return False


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date: str) -> bytes:
    k = _hmac(("AWS4" + secret).encode("utf-8"), date)
    k = _hmac(k, _REGION)
    k = _hmac(k, _SERVICE)
    return _hmac(k, "aws4_request")


def check_key(key: str) -> str:
    """Object keys are built by the server; still, refuse anything odd."""
    if not _KEY_RE.match(key) or ".." in key or key.startswith("/"):
        raise ValueError("invalid object key")
    return key


def _canonical_query(params: Mapping[str, str]) -> str:
    return "&".join(f"{quote(k, safe='-_.~')}={quote(str(v), safe='-_.~')}"
                    for k, v in sorted(params.items()))


def presign(cfg: R2Config, method: str, key: str, *, expires: int = 600,
            headers: Optional[Mapping[str, str]] = None,
            query: Optional[Mapping[str, str]] = None,
            now: Optional[_dt.datetime] = None) -> str:
    """A presigned URL. [headers] are SIGNED: the client must send exactly
    these values (e.g. content-type, content-length) or R2 refuses."""
    check_key(key)
    t = (now or _dt.datetime.now(_dt.timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    date = t[:8]
    scope = f"{date}/{_REGION}/{_SERVICE}/aws4_request"
    hdrs = {"host": cfg.host}
    for k, v in (headers or {}).items():
        hdrs[k.lower()] = str(v).strip()
    signed = ";".join(sorted(hdrs))
    q = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{cfg.access_key}/{scope}",
        "X-Amz-Date": t,
        "X-Amz-Expires": str(max(1, min(expires, 7 * 24 * 3600))),
        "X-Amz-SignedHeaders": signed,
        **(query or {}),
    }
    path = f"/{cfg.bucket}/{quote(key, safe='/-_.~')}"
    canonical = "\n".join([
        method.upper(), path, _canonical_query(q),
        "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs)), signed, _UNSIGNED,
    ])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", t, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    sig = hmac.new(_signing_key(cfg.secret_key, date), to_sign.encode(), hashlib.sha256).hexdigest()
    return f"https://{cfg.host}{path}?{_canonical_query(q)}&X-Amz-Signature={sig}"


def _auth_headers(cfg: R2Config, method: str, key: str, query: Mapping[str, str],
                  payload_sha: str) -> dict:
    t = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date = t[:8]
    scope = f"{date}/{_REGION}/{_SERVICE}/aws4_request"
    hdrs = {"host": cfg.host, "x-amz-content-sha256": payload_sha, "x-amz-date": t}
    signed = ";".join(sorted(hdrs))
    path = f"/{cfg.bucket}/{quote(key, safe='/-_.~')}" if key else f"/{cfg.bucket}"
    canonical = "\n".join([method, path, _canonical_query(query),
                           "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs)), signed, payload_sha])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", t, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    sig = hmac.new(_signing_key(cfg.secret_key, date), to_sign.encode(), hashlib.sha256).hexdigest()
    return {
        "x-amz-content-sha256": payload_sha,
        "x-amz-date": t,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={cfg.access_key}/{scope}, "
                         f"SignedHeaders={signed}, Signature={sig}",
    }


async def _request(cfg: R2Config, method: str, key: str = "",
                   query: Optional[Mapping[str, str]] = None, body: bytes = b"",
                   timeout: float = 10.0) -> httpx.Response:
    if key:
        check_key(key)
    q = dict(query or {})
    sha = hashlib.sha256(body).hexdigest() if body else _EMPTY_SHA
    headers = _auth_headers(cfg, method, key, q, sha)
    path = f"/{cfg.bucket}/{quote(key, safe='/-_.~')}" if key else f"/{cfg.bucket}"
    url = f"https://{cfg.host}{path}" + (f"?{_canonical_query(q)}" if q else "")
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await client.request(method, url, headers=headers, content=body or None)


async def put(cfg: R2Config, key: str, body: bytes, content_type: str = "application/octet-stream") -> None:
    """Server-side upload (small objects only, e.g. an encrypted backup the
    device sent through the API)."""
    url = presign(cfg, "PUT", key, expires=600, headers={"content-type": content_type,
                                                        "content-length": str(len(body))})
    async with httpx.AsyncClient(timeout=120.0) as client:
        r = await client.put(url, content=body, headers={"content-type": content_type})
    r.raise_for_status()


async def get(cfg: R2Config, key: str) -> Optional[bytes]:
    url = presign(cfg, "GET", key, expires=300)
    async with httpx.AsyncClient(timeout=120.0) as client:
        r = await client.get(url)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.content


async def head(cfg: R2Config, key: str) -> Optional[int]:
    """Size of the object, or None when it does not exist."""
    r = await _request(cfg, "HEAD", key)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return int(r.headers.get("content-length", "0"))


async def delete(cfg: R2Config, key: str) -> None:
    r = await _request(cfg, "DELETE", key)
    if r.status_code not in (200, 204, 404):
        r.raise_for_status()


async def list_prefix(cfg: R2Config, prefix: str, limit: int = 1_000_000) -> list[tuple[str, int]]:
    """(key, size) of every object under [prefix] (all pages, up to [limit]).

    One listing page holds at most 1000 keys: a backup with thousands of
    parts (product pictures) used to be counted from the first page only,
    so its size was short and newer sets were missing."""
    return [(k, size) for k, size, _ in await list_objects(cfg, prefix, limit)]


async def list_objects(cfg: R2Config, prefix: str, limit: int = 1_000_000) -> list[tuple[str, int, str]]:
    """(key, size, last_modified ISO) under [prefix], following every page."""
    check_key(prefix)
    out: list[tuple[str, int, str]] = []
    token: Optional[str] = None
    while len(out) < limit:
        q = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
        if token:
            q["continuation-token"] = token
        r = await _request(cfg, "GET", "", q)
        r.raise_for_status()
        for block in re.findall(r"<Contents>(.*?)</Contents>", r.text, re.S):
            key = re.search(r"<Key>([^<]+)</Key>", block)
            size = re.search(r"<Size>(\d+)</Size>", block)
            when = re.search(r"<LastModified>([^<]+)</LastModified>", block)
            if key and size:
                out.append((html.unescape(key.group(1)), int(size.group(1)), when.group(1) if when else ""))
        nxt = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", r.text)
        if "<IsTruncated>true</IsTruncated>" not in r.text or not nxt:
            break
        token = html.unescape(nxt.group(1))
    return out[:limit]
