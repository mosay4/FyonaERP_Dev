"""Device-only Personal mode (Stage 6 of docs/PERSONAL_LOCAL_PLAN.md).

For a "local Personal" user every Personal record lives only on the user's
devices (encrypted ledger). The server relays changes between the user's
devices (/personal-relay) and, once, hands the user's existing server rows to
the devices (/personal-local export → ack); a purge job deletes those rows
after the grace period. Writes to the old Personal stores are refused
(personal_local_guard).

QA rollout: every user of the QA service is local. On by default there
(FYONA_QA_LOCAL_PERSONAL, "0" turns it off); off elsewhere unless the
variable is set to "1".
"""

from __future__ import annotations

import os
from datetime import timedelta

from app.core import qa_directory


def _qa_service() -> bool:
    return bool(qa_directory.INVITES) or os.getenv("FYONA_QA_REMOTE") == "1"


def _flag() -> bool:
    raw = os.getenv("FYONA_QA_LOCAL_PERSONAL")
    if raw is None:
        return _qa_service()
    return raw.strip() == "1"


ENABLED = _flag()

# How long the server keeps a user's legacy rows after the first device
# confirmed it stored them (7 days on QA). FYONA_PERSONAL_LOCAL_GRACE_HOURS
# overrides it.
try:
    GRACE = timedelta(hours=float(os.getenv("FYONA_PERSONAL_LOCAL_GRACE_HOURS", "168")))
except ValueError:
    GRACE = timedelta(days=7)

# Builds that understand device-only Personal send this header (value ≥
# PROTOCOL). Older builds get a clear "update the app" answer instead of
# retry loops.
PROTOCOL_HEADER = "x-fyona-personal-protocol"
PROTOCOL = 6

CODE_LOCAL = "personal_local"
CODE_UPDATE = "update_required"


def enabled_for(user) -> bool:
    """[user]: a User row (or anything with ``status``)."""
    return ENABLED and getattr(user, "status", "active") in (None, "active")


def enabled_for_id(user_id) -> bool:
    """Without a database read: on QA every account is local."""
    return ENABLED and bool(user_id)


def client_protocol(request) -> int:
    try:
        return int((request.headers.get(PROTOCOL_HEADER) or "0").strip())
    except (ValueError, AttributeError):
        return 0


def current_client(request) -> bool:
    return client_protocol(request) >= PROTOCOL
