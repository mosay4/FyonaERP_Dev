"""Pure helpers for banner image upload validation and missing-image detection.

Kept free of FastAPI/SQLAlchemy imports so it can be unit-tested without a
database or env config, and so the upload flow stays consistent everywhere.
"""

import os
from typing import Optional

from app.core.paths import UPLOAD_ROOT

_ALLOWED_EXTS = frozenset({"jpg", "jpeg", "png", "webp", "gif"})
_ALLOWED_MIMES = frozenset({"image/jpeg", "image/png", "image/webp", "image/gif"})


def banner_image_extension(content_type: Optional[str], filename: Optional[str]) -> Optional[str]:
    """Validate a banner image upload.

    Returns the normalized extension (e.g. 'png') when the file passes both the
    extension and content-type checks, otherwise None.
    """
    ext = (os.path.splitext(filename or "")[1] or "").lower().lstrip(".")
    if ext not in _ALLOWED_EXTS:
        return None
    mime = (content_type or "").split(";")[0].strip().lower()
    if mime and mime not in _ALLOWED_MIMES:
        return None
    return ext


def banner_image_path(image_url: Optional[str]) -> Optional[str]:
    """Resolve a stored banner image_url ('/uploads/banners/x.jpg') to a safe
    absolute path under UPLOAD_ROOT, or None when the URL is unusable/unsafe."""
    if not image_url or not image_url.startswith("/uploads/"):
        return None
    relative = image_url[len("/uploads/"):].lstrip("/")
    if ".." in relative.split("/"):
        return None
    root = os.path.abspath(UPLOAD_ROOT)
    full = os.path.abspath(os.path.join(root, relative))
    if not full.startswith(root + os.sep):
        return None
    return full


def banner_image_missing(image_url: Optional[str]) -> bool:
    """True when the banner references an image that no longer exists on disk."""
    path = banner_image_path(image_url)
    return path is not None and not os.path.isfile(path)


def banner_with_image_status(banner: dict) -> dict:
    """Return a banner dict enriched with the computed `image_missing` flag
    (never persisted — derived at read time). Checks BOTH the classic image_url
    and the uploaded media_url so admin-uploaded banners render in the app."""
    img = banner.get("image_url")
    media = banner.get("media_url")
    ref = None
    if img:
        ref = img
    elif media:
        # media_url may look like /uploads/banners_media/x.jpg or a bare path
        ref = media if media.startswith("/uploads/") else f"/uploads/{media.lstrip('/')}"
    return {**banner, "image_missing": banner_image_missing(ref)}
