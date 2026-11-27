"""Backup key management (owner's decision 27-11-2026).

Every backup (device file or cloud) is encrypted ON THE DEVICE with a key
that belongs to the account: the Personal key of a user, or the Business
key of an organisation (owner only). That key is derived here from a
server master secret kept in the server's private secret file — never in
the database, never next to the backups (Cloudflare R2 / device folders).
Stealing the backups alone is therefore not enough to read them; a new
device gets the key after signing in (and the app's own fingerprint/PIN
check), so no recovery code is needed.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
from uuid import UUID

from fastapi import HTTPException

_ENV = "FYONA_BACKUP_MASTER_KEY"


def _master() -> bytes:
    raw = (os.environ.get(_ENV) or "").strip()
    if len(raw) < 32:
        raise HTTPException(503, detail={"code": "backup_keys_unavailable",
                                         "message": "خدمة مفاتيح النسخ غير مهيأة"})
    return raw.encode()


def account_key(kind: str, owner: UUID) -> str:
    """32-byte key (base64) for `u` (Personal user) or `o` (organisation)."""
    if kind not in ("u", "o"):
        raise ValueError(kind)
    mac = hmac.new(_master(), f"fyona.backup.account-key.v1|{kind}|{owner.hex}".encode(), hashlib.sha256)
    return base64.b64encode(mac.digest()).decode()
