"""Firebase Admin SDK helpers for verifying ID tokens."""
import os
import time
from typing import Any, Dict, Optional

import firebase_admin
from firebase_admin import credentials, auth
import httpx

from app.core.config import settings
from app.core.logging import get_logger

logger = get_logger("firebase")

_GOOGLE_TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo"

_app = None
_init_error: Optional[str] = None


def initialize_firebase() -> None:
    """Initialize the Firebase Admin app exactly once at application startup."""
    global _app, _init_error
    if _app is not None:
        return
    if firebase_admin._apps:
        _app = list(firebase_admin._apps.values())[0]
        logger.info("firebase_admin_already_initialized")
        return

    cred_path = settings.FIREBASE_CREDENTIALS_PATH
    project_id = settings.FIREBASE_PROJECT_ID

    if not cred_path:
        _init_error = "FIREBASE_CREDENTIALS_PATH غير مضبوط في متغيرات البيئة"
        logger.error("firebase_init_failed", error=_init_error)
        return

    if not os.path.exists(cred_path):
        _init_error = f"ملف شهادة Firebase غير موجود في المسار: {cred_path}"
        logger.error("firebase_init_failed", error=_init_error)
        return

    try:
        cred = credentials.Certificate(cred_path)
        options = {"projectId": project_id} if project_id else None
        _app = firebase_admin.initialize_app(cred, options=options)
        _init_error = None
        logger.info(
            "firebase_admin_initialized",
            credentials=cred_path,
            project_id=project_id,
        )
    except Exception as e:  # noqa: BLE001
        _init_error = str(e)
        logger.error("firebase_init_failed", error=_init_error)


def _verify_via_google_tokeninfo(id_token: str) -> Optional[Dict[str, Any]]:
    """Fallback: verify token directly with Google's tokeninfo endpoint.

    Used when Firebase Admin SDK fails (e.g. clock skew, project mismatch).
    Returns claims dict compatible with Firebase's verify_id_token output.
    """
    try:
        resp = httpx.get(
            _GOOGLE_TOKENINFO_URL,
            params={"id_token": id_token},
            timeout=5.0,
        )
        if resp.status_code != 200:
            logger.warning(
                "google_tokeninfo_rejected",
                status_code=resp.status_code,
                body=resp.text[:200],
            )
            return None

        data = resp.json()
        aud = data.get("aud", "")
        email = (data.get("email") or "").lower()
        sub = data.get("sub", "")

        if not email or not sub:
            logger.warning("google_tokeninfo_missing_fields", data=data)
            return None

        # Build a claims dict that matches what auth_service.login_with_firebase expects
        claims: Dict[str, Any] = {
            "uid": sub,
            "email": email,
            "email_verified": data.get("email_verified", "false") == "true",
            "name": data.get("name"),
            "picture": data.get("picture"),
            "firebase": {
                "sign_in_provider": "google.com",
            },
        }
        logger.info(
            "google_tokeninfo_success",
            uid=sub,
            email=email,
            aud=aud,
        )
        return claims
    except Exception as e:  # noqa: BLE001
        logger.warning("google_tokeninfo_error", error=str(e))
        return None


def verify_id_token(
    id_token: str, *, google_id_token: str | None = None,
) -> Optional[Dict[str, Any]]:
    """Verify a Firebase ID token and return its claims, or None if invalid.

    Strategy:
    1. Try Firebase Admin SDK (preferred — verifies signature + expiry)
    2. Fallback to Google's tokeninfo endpoint using the raw Google ID token
    """
    if _app is None:
        initialize_firebase()
    if _app is None:
        logger.warning(
            "firebase_not_initialized",
            error=_init_error or "unknown",
        )
        return None
    try:
        logger.info("firebase_verify_attempt", token_prefix=id_token[:20] + "...", token_len=len(id_token))
        result = auth.verify_id_token(id_token, app=_app, check_revoked=False)
        logger.info("firebase_verify_success", uid=result.get("uid"), email=result.get("email"))
        return result
    except Exception as e:  # noqa: BLE001
        error_type = type(e).__name__
        error_msg = str(e)
        logger.warning(
            "firebase_token_verification_failed",
            error=error_msg,
            error_type=error_type,
            token_prefix=id_token[:20] + "...",
            token_len=len(id_token),
            app_project=_app.project_id if _app else None,
        )

        # Fallback: verify the raw Google ID token via Google's public tokeninfo endpoint
        if google_id_token:
            logger.info("google_tokeninfo_fallback", token_prefix=google_id_token[:20] + "...")
            fallback_claims = _verify_via_google_tokeninfo(google_id_token)
            if fallback_claims:
                logger.info("google_tokeninfo_fallback_success", uid=fallback_claims.get("uid"))
                return fallback_claims
        else:
            logger.warning("google_tokeninfo_fallback_skipped", reason="no_google_id_token_provided")

        logger.error("all_verification_methods_failed")
        return None


def is_enabled() -> bool:
    return bool(
        settings.FIREBASE_CREDENTIALS_PATH
        or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    )
