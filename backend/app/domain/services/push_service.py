"""FCM push notification helpers using the already-initialized Firebase app.

The Firebase Admin SDK is initialized once at startup (app.core.firebase).
These helpers are best-effort: any failure is logged and swallowed so a push
failure never breaks the API request that triggered it.

Hardening guarantees:
- ``send_each`` is chunked into batches of at most :data:`FCM_BATCH_LIMIT`
  tokens so broadcasts of any size never exceed the FCM batch ceiling.
- One bad batch never kills a broadcast (per-batch isolation).
- A single bounded re-attempt covers transport-level failures.
- Invalid/unknown registration tokens are classified from per-message
  failures and deactivated in ``device_tokens`` (``is_active=False``).
- Structured logs carry user/type/error context only — token strings and
  secrets are NEVER logged.
"""

import asyncio
from datetime import datetime, timezone
from typing import Iterable, Optional
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.firebase import initialize_firebase, is_enabled
from app.core.logging import get_logger
from app.domain.entities.auth_entities import User
from app.domain.entities.push_entities import DeviceToken

logger = get_logger("push")

# Android notification channel used for push messages (created by the app).
ANDROID_CHANNEL_ID = "suggestions_channel"

# Transport: when False (current), Android tokens receive notification{} +
# data so the OS can paint the Notification Tray even when the app is in
# background or terminated (data-only never reaches a dead process reliably).
# data[] still carries action / action_payload / title / body / body_en so
# foreground rendering and deep-links are unchanged. Flip to True only to
# force data-only rich local render for all Android tokens.
ANDROID_DATA_ONLY = False

# FCM send_each ceiling: never send more than this many messages per call.
FCM_BATCH_LIMIT = 400

# Single bounded re-attempt on transport-level failures (no infinite retry).
FCM_TRANSPORT_RETRIES = 1


def _utc_ts() -> str:
    return datetime.now(timezone.utc).isoformat()


async def register_token(
    db: AsyncSession, *, user_id: UUID, token: str, platform: str = "android"
) -> None:
    """Upsert an FCM token per (user, token).

    A device used by MULTIPLE accounts keeps one row per user: the token is
    NEVER stolen from another account (that silently broke pushes for the
    previous user on shared phones).
    """
    stmt = select(DeviceToken).where(
        DeviceToken.token == token,
        DeviceToken.user_id == UUID(str(user_id)),
    )
    existing = (await db.execute(stmt)).scalar_one_or_none()
    if existing:
        existing.platform = platform or "android"
        existing.is_active = True
    else:
        db.add(
            DeviceToken(
                user_id=UUID(str(user_id)),
                token=token,
                platform=platform or "android",
                is_active=True,
            )
        )
    await db.commit()


async def unregister_token(db: AsyncSession, *, token: str) -> None:
    """Deactivate/remove an FCM token (logout or token rotation)."""
    stmt = select(DeviceToken).where(DeviceToken.token == token)
    existing = (await db.execute(stmt)).scalar_one_or_none()
    if existing:
        existing.is_active = False
        await db.commit()


async def tokens_for_users(db: AsyncSession, user_ids: Iterable[UUID]) -> list[str]:
    """Collect active FCM tokens belonging to any of the given users."""
    ids = [UUID(str(u)) for u in user_ids]
    if not ids:
        return []
    stmt = (
        select(DeviceToken.token)
        .where(DeviceToken.user_id.in_(ids), DeviceToken.is_active.is_(True))
    )
    rows = await db.execute(stmt)
    return list(dict.fromkeys(rows.scalars().all()))


async def platform_admin_ids(db: AsyncSession) -> list[UUID]:
    """Return the ids of every platform admin (super admins)."""
    stmt = select(User.id).where(User.is_platform_admin.is_(True), User.status == "active")
    rows = await db.execute(stmt)
    return list(rows.scalars().all())


def _data_payload(*, action: str, action_payload: str) -> dict:
    return {"action": action, "action_payload": action_payload}


def _chunk_tokens(tokens: list[str], size: int = FCM_BATCH_LIMIT) -> list[list[str]]:
    """Split a token list into batches of at most ``size`` (generic)."""
    if size <= 0:
        return [list(tokens)]
    return [list(tokens[i:i + size]) for i in range(0, len(tokens), size)]


def _is_invalid_token_error(exc) -> bool:
    """True when an FCM per-message exception means the token is dead.

    Covers UNREGISTERED / NotRegistered / registration-token-not-registered /
    invalid-argument / invalid-registration variants across SDK versions.
    Pure function — never raises, never logs token material.
    """
    try:
        if exc is None:
            return False
        code = str(getattr(exc, "code", "") or "").lower()
        msg = ""
        try:
            msg = str(exc).lower()
        except Exception:
            msg = ""
        tname = type(exc).__name__.lower()
        blob = f"{code} {msg} {tname}"
        markers = (
            "registration-token-not-registered",
            "registration_token_not_registered",
            "not-registered",
            "notregistered",
            "not_registered",
            "unregistered",
            "invalid-argument",
            "invalid_argument",
            "invalid-registration",
            "invalid_registration",
        )
        return any(m in blob for m in markers)
    except Exception:
        return False


def classify_invalid_tokens(tokens: list[str], responses) -> list[str]:
    """Return the subset of ``tokens`` whose send response is an invalid-token.

    ``responses`` is the ``send_each`` BatchResponse.responses list (aligned
    1:1 with ``tokens``).  Short/ragged responses are tolerated: only aligned
    indices are inspected.  Never raises.
    """
    try:
        invalid: list[str] = []
        for idx, token in enumerate(tokens):
            try:
                resp = responses[idx] if idx < len(responses) else None
            except Exception:
                continue
            if resp is None:
                continue
            try:
                ok = bool(getattr(resp, "success", True))
            except Exception:
                continue
            if ok:
                continue
            try:
                exc = getattr(resp, "exception", None)
            except Exception:
                exc = None
            if _is_invalid_token_error(exc):
                invalid.append(token)
        # De-duplicate, preserve order.
        return list(dict.fromkeys(invalid))
    except Exception:
        return []


def _build_message(token: str, *, title: str, body: str, data: dict,
                   data_only: bool = False):
    from firebase_admin import messaging

    if data_only:
        # Data-only rich local render: title/body/routing travel INSIDE
        # data; the app paints the notification itself. Used only when
        # ANDROID_DATA_ONLY is forced on (or for silent data pushes).
        payload = {str(k): str(v) for k, v in dict(data).items()}
        payload.setdefault("title", str(title or ""))
        payload.setdefault("body", str(body or ""))
        return messaging.Message(
            token=token,
            data=payload,
            android=messaging.AndroidConfig(priority="high"),
        )
    # notification{} + data: the OS renders the tray row (with SOUND 1 from
    # suggestions_channel) in background/terminated, while data[] keeps
    # action / action_payload / title / body for deep-links and the
    # foreground bridge. No largeIcon — default_notification_icon =
    # @mipmap/ic_launcher (approved app icon only).
    payload = {str(k): str(v) for k, v in dict(data).items()}
    payload.setdefault("title", str(title or ""))
    payload.setdefault("body", str(body or ""))
    # Optional stable tray tag: the OS-rendered row REPLACES any row with the
    # same tag (e.g. the app's own local welcome) instead of stacking a
    # duplicate. Absent → unchanged behaviour.
    tag = str(payload.get("notif_tag") or "").strip() or None
    return messaging.Message(
        token=token,
        notification=messaging.Notification(title=title, body=body,
            image=payload.get('image_url') if payload.get('image_url', '').startswith(('http://', 'https://')) else None),
        data=payload,
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(
                channel_id=ANDROID_CHANNEL_ID,
                color="#000000",
                click_action="FLUTTER_NOTIFICATION_CLICK",
                **({"tag": tag} if tag else {}),
            ),
        ),
        **({"apns": messaging.APNSConfig(headers={"apns-collapse-id": tag})}
           if tag else {}),
    )


def send_push(tokens: list[str], *, title: str, body: str, data: dict,
              data_only: bool = False) -> dict:
    """Send an FCM notification to every token. Best-effort; never raises.

    Batched at :data:`FCM_BATCH_LIMIT` with per-batch isolation and a single
    re-attempt on transport failures.  Returns per-token failure details::

        {"sent": int, "failed": int, "invalid_tokens": [token, ...]}

    Callers that own a DB session (``notify_*``) deactivate
    ``invalid_tokens`` via :func:`deactivate_tokens`.  Returning details
    instead of ``None`` keeps this function usable without a DB while the
    internal callers handle cleanup.  Token strings are never logged.
    """
    result: dict = {"sent": 0, "failed": 0, "invalid_tokens": []}
    if not tokens:
        return result
    if not is_enabled():
        logger.warning("fcm_disabled_skipping_push", count=len(tokens), at=_utc_ts())
        return result
    try:
        initialize_firebase()
        from firebase_admin import messaging
    except Exception as exc:  # noqa: BLE001 - never break the caller
        logger.warning("fcm_init_failed", error=str(exc), count=len(tokens), at=_utc_ts())
        result["failed"] = len(tokens)
        return result
    deduped = list(dict.fromkeys(tokens))
    batches = _chunk_tokens(deduped, FCM_BATCH_LIMIT)
    total_batches = len(batches)
    for batch_idx, batch in enumerate(batches):
        messages = [_build_message(t, title=title, body=body, data=data,
                                   data_only=data_only) for t in batch]
        resp = None
        try:
            resp = messaging.send_each(messages)
        except Exception as exc:  # noqa: BLE001 - transport failure: one retry
            logger.warning(
                "fcm_batch_transport_error",
                error=str(exc),
                batch_index=batch_idx,
                total_batches=total_batches,
                batch_size=len(batch),
                type="push",
                at=_utc_ts(),
            )
            try:
                resp = messaging.send_each(messages)
                logger.info(
                    "fcm_batch_retry_succeeded",
                    batch_index=batch_idx,
                    total_batches=total_batches,
                    batch_size=len(batch),
                    type="push",
                    at=_utc_ts(),
                )
            except Exception as exc2:  # noqa: BLE001 - retry also failed
                logger.warning(
                    "fcm_batch_retry_failed",
                    error=str(exc2),
                    batch_index=batch_idx,
                    total_batches=total_batches,
                    batch_size=len(batch),
                    type="push",
                    at=_utc_ts(),
                )
                result["failed"] += len(batch)
                continue
        try:
            responses = list(getattr(resp, "responses", []) or [])
        except Exception:
            responses = []
        batch_invalid = classify_invalid_tokens(batch, responses)
        batch_failed = 0
        for r in responses:
            try:
                if not bool(getattr(r, "success", True)):
                    batch_failed += 1
            except Exception:
                batch_failed += 1
        # If the SDK returned fewer responses than messages, count the gap
        # as failed (never silently drop).
        if len(responses) < len(batch):
            batch_failed += len(batch) - len(responses)
        result["sent"] += len(batch) - batch_failed
        result["failed"] += batch_failed
        result["invalid_tokens"].extend(batch_invalid)
        if batch_failed:
            logger.warning(
                "fcm_partial_failure",
                sent=len(batch) - batch_failed,
                failed=batch_failed,
                invalid=len(batch_invalid),
                batch_index=batch_idx,
                total_batches=total_batches,
                type="push",
                at=_utc_ts(),
            )
    result["invalid_tokens"] = list(dict.fromkeys(result["invalid_tokens"]))
    return result


def send_data_push(tokens: list[str], *, data: dict) -> dict:
    """Send a SILENT data-only FCM event (no visible notification).

    Used for cross-device state sync (e.g. profile-picture version bumps):
    the app handles the payload in the foreground handler or, when killed,
    records a pending flag for the next launch. Carries identifiers and
    versions only — never file bytes. Best-effort; never raises.

    Batched + single retry like :func:`send_push`; returns the same
    ``{"sent","failed","invalid_tokens"}`` details dict.
    """
    result: dict = {"sent": 0, "failed": 0, "invalid_tokens": []}
    if not tokens:
        return result
    if not is_enabled():
        logger.warning("fcm_disabled_skipping_push", count=len(tokens), at=_utc_ts())
        return result
    try:
        initialize_firebase()
        from firebase_admin import messaging
    except Exception as exc:  # noqa: BLE001 - never break the caller
        logger.warning("fcm_data_init_failed", error=str(exc), count=len(tokens), at=_utc_ts())
        result["failed"] = len(tokens)
        return result
    deduped = list(dict.fromkeys(tokens))
    batches = _chunk_tokens(deduped, FCM_BATCH_LIMIT)
    total_batches = len(batches)
    try:
        clean = {str(k): str(v) for k, v in data.items()}
    except Exception:
        clean = {}
    for batch_idx, batch in enumerate(batches):
        messages = [messaging.Message(token=t, data=clean) for t in batch]
        resp = None
        try:
            resp = messaging.send_each(messages)
        except Exception as exc:  # noqa: BLE001 - transport failure: one retry
            logger.warning(
                "fcm_data_batch_transport_error",
                error=str(exc),
                batch_index=batch_idx,
                total_batches=total_batches,
                batch_size=len(batch),
                type="data_push",
                at=_utc_ts(),
            )
            try:
                resp = messaging.send_each(messages)
            except Exception as exc2:  # noqa: BLE001
                logger.warning(
                    "fcm_data_batch_retry_failed",
                    error=str(exc2),
                    batch_index=batch_idx,
                    total_batches=total_batches,
                    batch_size=len(batch),
                    type="data_push",
                    at=_utc_ts(),
                )
                result["failed"] += len(batch)
                continue
        try:
            responses = list(getattr(resp, "responses", []) or [])
        except Exception:
            responses = []
        batch_invalid = classify_invalid_tokens(batch, responses)
        batch_failed = 0
        for r in responses:
            try:
                if not bool(getattr(r, "success", True)):
                    batch_failed += 1
            except Exception:
                batch_failed += 1
        if len(responses) < len(batch):
            batch_failed += len(batch) - len(responses)
        result["sent"] += len(batch) - batch_failed
        result["failed"] += batch_failed
        result["invalid_tokens"].extend(batch_invalid)
        if batch_failed:
            logger.warning(
                "fcm_data_partial_failure",
                sent=len(batch) - batch_failed,
                failed=batch_failed,
                invalid=len(batch_invalid),
                batch_index=batch_idx,
                total_batches=total_batches,
                type="data_push",
                at=_utc_ts(),
            )
    result["invalid_tokens"] = list(dict.fromkeys(result["invalid_tokens"]))
    return result


async def deactivate_tokens(db: AsyncSession, tokens: list[str]) -> int:
    """Mark dead FCM tokens inactive (``is_active=False``).

    Called by the ``notify_*`` helpers after :func:`send_push` classifies
    per-message failures.  Best-effort; never raises.  Only the COUNT is
    logged — token strings are never logged.
    """
    uniq = list(dict.fromkeys([t for t in (tokens or []) if t]))
    if not uniq or db is None:
        return 0
    try:
        stmt = (
            update(DeviceToken)
            .where(DeviceToken.token.in_(uniq), DeviceToken.is_active.is_(True))
            .values(is_active=False)
        )
        res = await db.execute(stmt)
        try:
            await db.commit()
        except Exception as exc:  # noqa: BLE001 - commit best-effort
            logger.warning("fcm_token_cleanup_commit_failed", error=str(exc), at=_utc_ts())
            try:
                await db.rollback()
            except Exception:
                pass
            return 0
        count = 0
        try:
            count = int(res.rowcount or 0)
        except Exception:
            count = 0
        if count:
            logger.info("fcm_tokens_deactivated", count=count, type="push_cleanup", at=_utc_ts())
        return count
    except Exception as exc:  # noqa: BLE001 - cleanup never breaks pushes
        logger.warning("fcm_token_cleanup_failed", error=str(exc), at=_utc_ts())
        try:
            await db.rollback()
        except Exception:
            pass
        return 0


async def notify_avatar_updated(
    db: AsyncSession, *, user_id: UUID, avatar: str
) -> None:
    """Tell every device of the user that the profile picture changed.

    Payload carries only the new relative path (with its ?v= version);
    receivers download it themselves when newer than what they hold.
    Fire-and-forget with the same bounds as visible pushes.
    """
    try:
        tokens = await tokens_for_users(db, [user_id])
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_avatar_tokens_failed", error=str(exc),
                       user_id=str(user_id), type="data_push", at=_utc_ts())
        return
    if tokens:
        data = {"type": "avatar_updated", "avatar": avatar,
                "user_id": str(user_id)}
        try:
            result = await asyncio.wait_for(
                asyncio.to_thread(send_data_push, tokens, data=data),
                timeout=8.0,
            )
        except Exception as exc:  # noqa: BLE001 - timeout or send failure
            logger.warning("fcm_avatar_event_failed", error=str(exc),
                           user_id=str(user_id), type="data_push", at=_utc_ts())
            return
        try:
            invalid = (result or {}).get("invalid_tokens") or []
            if invalid:
                await deactivate_tokens(db, invalid)
        except Exception as exc:  # noqa: BLE001
            logger.warning("fcm_avatar_cleanup_failed", error=str(exc),
                           user_id=str(user_id), type="data_push", at=_utc_ts())


SUBSCRIPTION_CHANGED_EVENT = "subscription_changed"


async def notify_subscription_changed(db: AsyncSession, org_id) -> dict:
    """Silent data push: the org's plan/status changed (e.g. by an admin).

    Every active member's devices refresh the subscription snapshot +
    profile on receipt (badge colour, plan card), without any tray row.
    Data-only, so the OS never paints anything. Never raises.
    """
    empty = {"sent": 0, "failed": 0, "invalid_tokens": []}
    try:
        oid = UUID(str(org_id))
        rows = await db.execute(
            select(User.id).where(User.organization_id == oid,
                                  User.status == "active"))
        user_ids = list(rows.scalars().all())
        tokens = await tokens_for_users(db, user_ids) if user_ids else []
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_subscription_changed_lookup_failed", error=str(exc),
                       type="data_push", at=_utc_ts())
        return empty
    if not tokens:
        return empty
    result = await _send_data_push_bounded(
        tokens, data={"type": SUBSCRIPTION_CHANGED_EVENT, "org_id": str(oid)})
    try:
        invalid = (result or {}).get("invalid_tokens") or []
        if invalid:
            await deactivate_tokens(db, invalid)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_subscription_changed_cleanup_failed", error=str(exc),
                       type="data_push", at=_utc_ts())
    return result


async def token_platforms(db: AsyncSession, tokens: Iterable[str]) -> dict:
    """Map each token string to its registered platform (lowercased).

    Unknown/token-less rows map to ``""`` (treated as legacy iOS-safe:
    notification{} shape).  Never raises.
    """
    wanted = [t for t in dict.fromkeys(tokens or []) if t]
    if not wanted or db is None:
        return {}
    try:
        stmt = select(DeviceToken.token, DeviceToken.platform).where(
            DeviceToken.token.in_(wanted)
        )
        rows = await db.execute(stmt)
        return {str(tok): str(plat or "").strip().lower() for tok, plat in rows.all()}
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_platform_lookup_failed", error=str(exc), at=_utc_ts())
        return {}


async def _send_push_bounded(
    tokens: list[str], *, title: str, body: str, data: dict, timeout: float = 8.0,
    data_only: bool = False,
) -> dict:
    """Run the blocking FCM call off the event loop with a hard timeout so a
    slow/unreachable push endpoint can NEVER stall the API request.

    Returns the :func:`send_push` details dict (``sent/failed/invalid_tokens``)
    so the caller can deactivate dead tokens.  Never raises.
    """
    empty: dict = {"sent": 0, "failed": len(tokens or []), "invalid_tokens": []}
    if not tokens:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(send_push, tokens, title=title, body=body,
                              data=data, data_only=data_only),
            timeout=timeout,
        )
        if isinstance(result, dict):
            return result
        return empty
    except Exception as exc:  # noqa: BLE001 - timeout or send failure
        logger.warning("fcm_send_bounded_failed", error=str(exc),
                       count=len(tokens), type="push", at=_utc_ts())
        return empty


async def _send_data_push_bounded(
    tokens: list[str], *, data: dict, timeout: float = 8.0
) -> dict:
    """Bounded variant for silent data pushes.  Never raises."""
    if not tokens:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(send_data_push, tokens, data=data),
            timeout=timeout,
        )
        if isinstance(result, dict):
            return result
        return {"sent": 0, "failed": len(tokens), "invalid_tokens": []}
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_data_send_bounded_failed", error=str(exc),
                       count=len(tokens), type="data_push", at=_utc_ts())
        return {"sent": 0, "failed": len(tokens), "invalid_tokens": []}


async def _push_and_cleanup(
    db: AsyncSession,
    tokens: list[str],
    *,
    title: str,
    body: str,
    data: dict,
    log_ctx: Optional[dict] = None,
    data_only: bool = False,
) -> dict:
    """Awaited push + invalid-token cleanup (shared by fire-and-forget and
    worker paths).  Never raises; every failure is logged with context and
    without token material."""
    ctx = dict(log_ctx or {})
    try:
        result = await _send_push_bounded(tokens, title=title, body=body,
                                          data=data, data_only=data_only)
    except Exception as exc:  # noqa: BLE001 - defensive; bounded never raises
        logger.warning("fcm_push_and_cleanup_send_failed", error=str(exc),
                       type=ctx.get("type", "push"), at=_utc_ts(), **{k: v for k, v in ctx.items() if k != "type"})
        return {"sent": 0, "failed": len(tokens or []), "invalid_tokens": []}
    try:
        invalid = (result or {}).get("invalid_tokens") or []
        if invalid and db is not None:
            await deactivate_tokens(db, invalid)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_push_cleanup_failed", error=str(exc),
                       type=ctx.get("type", "push"), at=_utc_ts())
    return result if isinstance(result, dict) else {"sent": 0, "failed": 0, "invalid_tokens": []}


async def _push_visible_split_detached(
    tokens: list[str],
    *,
    title: str,
    body: str,
    data: dict,
    log_ctx: Optional[dict] = None,
) -> dict:
    """Fire-and-forget entry point with its OWN DB session.

    Request-scoped sessions are committed/closed by ``get_db`` as soon as
    the API response is sent; sharing that session with a background task
    races the connection (asyncpg ``InterfaceError: another operation is
    in progress``) and kills the push before FCM send. Never raises.
    """
    from app.core.database import async_session_factory

    try:
        async with async_session_factory() as session:
            return await _push_visible_split(
                session, tokens, title=title, body=body, data=data,
                log_ctx=log_ctx,
            )
    except Exception as exc:  # noqa: BLE001 - background must never crash the loop
        logger.warning(
            "fcm_detached_push_failed",
            error=str(exc),
            type=(log_ctx or {}).get("type", "push"),
            at=_utc_ts(),
        )
        return {"sent": 0, "failed": len(tokens or []), "invalid_tokens": []}


async def _push_visible_split(
    db: AsyncSession,
    tokens: list[str],
    *,
    title: str,
    body: str,
    data: dict,
    log_ctx: Optional[dict] = None,
) -> dict:
    """Visible push with per-platform transport (single call site for all
    user-visible pushes).

    - Default (``ANDROID_DATA_ONLY=False``): every token gets
      notification{} + data so the OS paints the Notification Tray in
      background/terminated; data[] keeps action / action_payload /
      title / body for deep-links and the foreground bridge.
    - When ``ANDROID_DATA_ONLY`` is forced on: android tokens get
      DATA-ONLY messages (local-only render); everything else keeps
      notification{}.

    Results (sent/failed/invalid) are merged across both shapes; invalid
    tokens from either shape are deactivated.  Never raises.
    """
    ctx = dict(log_ctx or {})
    merged: dict = {"sent": 0, "failed": 0, "invalid_tokens": []}
    uniq = list(dict.fromkeys([t for t in (tokens or []) if t]))
    if not uniq:
        return merged
    try:
        plats = await token_platforms(db, uniq)
    except Exception:
        plats = {}
    if ANDROID_DATA_ONLY:
        android_tokens = [t for t in uniq if plats.get(t) == "android"]
    else:
        android_tokens = []
    rest = [t for t in uniq if t not in set(android_tokens)]
    if android_tokens:
        try:
            r = await _push_and_cleanup(
                db, android_tokens, title=title, body=body, data=data,
                log_ctx={**ctx, "shape": "data_only"}, data_only=True)
        except Exception as exc:  # noqa: BLE001
            logger.warning("fcm_split_android_failed", error=str(exc),
                           type=ctx.get("type", "push"), at=_utc_ts())
            r = {"sent": 0, "failed": len(android_tokens), "invalid_tokens": []}
        merged["sent"] += int(r.get("sent") or 0)
        merged["failed"] += int(r.get("failed") or 0)
        merged["invalid_tokens"].extend(r.get("invalid_tokens") or [])
    if rest:
        try:
            r = await _push_and_cleanup(
                db, rest, title=title, body=body, data=data,
                log_ctx={**ctx, "shape": "notification"}, data_only=False)
        except Exception as exc:  # noqa: BLE001
            logger.warning("fcm_split_legacy_failed", error=str(exc),
                           type=ctx.get("type", "push"), at=_utc_ts())
            r = {"sent": 0, "failed": len(rest), "invalid_tokens": []}
        merged["sent"] += int(r.get("sent") or 0)
        merged["failed"] += int(r.get("failed") or 0)
        merged["invalid_tokens"].extend(r.get("invalid_tokens") or [])
    merged["invalid_tokens"] = list(dict.fromkeys(merged["invalid_tokens"]))
    return merged


async def push_to_users_now(
    db: AsyncSession,
    user_ids: Iterable[UUID],
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "notifications",
    log_type: str = "push",
) -> dict:
    """Awaited push to explicit users (for Celery/worker paths where
    fire-and-forget tasks would die with the worker loop).

    Looks tokens up on ``db``, sends with bounds + single retry, deactivates
    invalid tokens, and returns the details dict.  Never raises.
    """
    try:
        ids = [UUID(str(u)) for u in (user_ids or [])]
    except Exception:
        ids = []
    if not ids:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    try:
        tokens = await tokens_for_users(db, ids)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_tokens_lookup_failed", error=str(exc),
                       type=log_type, at=_utc_ts())
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    if not tokens:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    return await _push_visible_split(
        db, tokens, title=title, body=body,
        data=_data_payload(action=action, action_payload=action_payload),
        log_ctx={"type": log_type},
    )


async def push_to_org_now(
    db: AsyncSession,
    org_id,
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "notifications",
    log_type: str = "push",
    admins_only: bool = False,
    non_admins_only: bool = False,
) -> dict:
    """Awaited push to every active user in one organization.

    ``admins_only`` restricts to platform admins in the org; 
    ``non_admins_only`` restricts to regular members.  Never raises.
    """
    try:
        from uuid import UUID as _UUID

        oid = _UUID(str(org_id))
    except Exception:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    try:
        stmt = select(User.id).where(
            User.organization_id == oid, User.status == "active"
        )
        if admins_only:
            stmt = stmt.where(User.is_platform_admin.is_(True))
        elif non_admins_only:
            stmt = stmt.where(User.is_platform_admin.is_not(True))
        rows = await db.execute(stmt)
        user_ids = list(rows.scalars().all())
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_org_users_lookup_failed", error=str(exc),
                       type=log_type, at=_utc_ts())
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    if not user_ids:
        return {"sent": 0, "failed": 0, "invalid_tokens": []}
    return await push_to_users_now(
        db, user_ids, title=title, body=body, action=action,
        action_payload=action_payload, log_type=log_type,
    )


async def notify_user(
    db: AsyncSession,
    *,
    user_id: UUID,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "suggestions",
    image_url: str | None = None,
    tag: str | None = None,
):
    """Push to a single user (e.g. the suggestion owner on an admin reply).

    Fire-and-forget: the API responds immediately after commit while the push
    (plus invalid-token cleanup on the same ``db``) completes in the
    background.  Returns the background task so tests can await it; existing
    callers safely ignore the return value.
    """
    try:
        tokens = await tokens_for_users(db, [user_id])
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_tokens_lookup_failed", error=str(exc),
                       user_id=str(user_id), type="push", at=_utc_ts())
        return None
    if tokens:
        # Fire-and-forget on a FRESH session: the request session is closed
        # by get_db the moment the response is sent.
        try:
            task = asyncio.create_task(
                _push_visible_split_detached(
                    tokens, title=title, body=body,
                    data={**_data_payload(action=action, action_payload=action_payload),
                          **({'image_url': image_url} if image_url else {}),
                          **({'notif_tag': tag} if tag else {})},
                    log_ctx={"user_id": str(user_id), "type": "push"},
                )
            )
            return task
        except Exception as exc:  # noqa: BLE001 - no running loop (worker import)
            logger.warning("fcm_notify_schedule_failed", error=str(exc),
                           user_id=str(user_id), type="push", at=_utc_ts())
            return None
    return None


async def notify_platform_admins(
    db: AsyncSession,
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "admin_suggestions",
):
    """Push to every platform admin (e.g. when a new suggestion arrives)."""
    try:
        admin_ids = await platform_admin_ids(db)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_admin_ids_lookup_failed", error=str(exc),
                       type="push", at=_utc_ts())
        return None
    try:
        tokens = await tokens_for_users(db, admin_ids)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_tokens_lookup_failed", error=str(exc),
                       type="push", at=_utc_ts())
        return None
    if tokens:
        try:
            task = asyncio.create_task(
                _push_visible_split_detached(
                    tokens, title=title, body=body,
                    data=_data_payload(action=action, action_payload=action_payload),
                    log_ctx={"type": "push_admins"},
                )
            )
            return task
        except Exception as exc:  # noqa: BLE001
            logger.warning("fcm_notify_schedule_failed", error=str(exc),
                           type="push_admins", at=_utc_ts())
            return None
    return None


async def non_admin_user_ids(db: AsyncSession) -> list[UUID]:
    """Ids of every active NON-platform-admin user (generic, no hardcoding)."""
    stmt = select(User.id).where(
        User.is_platform_admin.is_not(True), User.status == "active"
    )
    rows = await db.execute(stmt)
    return list(rows.scalars().all())


async def notify_non_admin_users(
    db: AsyncSession,
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "notifications",
):
    """Push to every regular (non-platform-admin) user.  Target-aware helper
    for ``PlatformNotification.target == 'users'`` broadcasts."""
    try:
        user_ids = await non_admin_user_ids(db)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_user_ids_lookup_failed", error=str(exc),
                       type="push_users", at=_utc_ts())
        return None
    try:
        tokens = await tokens_for_users(db, user_ids)
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_tokens_lookup_failed", error=str(exc),
                       type="push_users", at=_utc_ts())
        return None
    if tokens:
        try:
            task = asyncio.create_task(
                _push_visible_split_detached(
                    tokens, title=title, body=body,
                    data=_data_payload(action=action, action_payload=action_payload),
                    log_ctx={"type": "push_users"},
                )
            )
            return task
        except Exception as exc:  # noqa: BLE001
            logger.warning("fcm_notify_schedule_failed", error=str(exc),
                           type="push_users", at=_utc_ts())
            return None
    return None


async def notify_by_target(
    db: AsyncSession,
    target: str,
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "notifications",
    body_en: Optional[str] = None,
):
    """Target-aware broadcast push: ``all`` → everyone, ``users`` → regular
    users only, ``admins`` → platform admins only.  Unknown/empty targets
    behave as ``all`` for backward compatibility; a SPECIFIC target never
    falls back to everyone."""
    t = (target or "all").strip().lower()
    if t == "admins":
        return await notify_platform_admins(
            db, title=title, body=body, action=action, action_payload=action_payload
        )
    if t == "users":
        return await notify_non_admin_users(
            db, title=title, body=body, action=action, action_payload=action_payload
        )
    return await notify_all_users(
        db, title=title, body=body, action=action,
        action_payload=action_payload, body_en=body_en,
    )


async def notify_all_users(
    db: AsyncSession,
    *,
    title: str,
    body: str,
    action: str = "open_screen",
    action_payload: str = "notifications",
    body_en: Optional[str] = None,
):
    """Push to EVERY active device FCM token (For platform-wide announcements)."""
    try:
        stmt = select(DeviceToken.token).where(DeviceToken.is_active.is_(True))
        rows = await db.execute(stmt)
        tokens = list(dict.fromkeys(rows.scalars().all()))
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_tokens_lookup_failed", error=str(exc),
                       type="push_all", at=_utc_ts())
        return None
    if not tokens:
        return None
    data = _data_payload(action=action, action_payload=action_payload)
    if body_en is not None:
        data["body_en"] = body_en
    try:
        task = asyncio.create_task(
            _push_visible_split_detached(
                tokens, title=title, body=body, data=data,
                log_ctx={"type": "push_all"},
            )
        )
        return task
    except Exception as exc:  # noqa: BLE001
        logger.warning("fcm_notify_schedule_failed", error=str(exc),
                       type="push_all", at=_utc_ts())
        return None
