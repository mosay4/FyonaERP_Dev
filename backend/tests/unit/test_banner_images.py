"""Banner upload validation + missing-image detection (regression tests).

Guards the fix for disappearing banner images:
- uploads are validated (extension + content-type) before being written,
- an image_url is never persisted for a file that is not on disk,
- every banner response carries an `image_missing` flag so clients and the
  admin panel can show a placeholder / re-upload prompt instead of a broken image.
"""

import os

from app.domain.services.banner_images import (
    banner_image_extension,
    banner_image_missing,
    banner_image_path,
    banner_with_image_status,
)


def test_extension_validation():
    assert banner_image_extension("image/jpeg", "photo.jpg") == "jpg"
    assert banner_image_extension("image/png", "photo.PNG") == "png"
    assert banner_image_extension("image/webp", "a.webp") == "webp"
    # Extension not allowed
    assert banner_image_extension("image/png", "evil.txt") is None
    # Content-type does not match an image
    assert banner_image_extension("text/html", "photo.png") is None
    assert banner_image_extension("", "photo.png") == "png"  # no content-type sent
    assert banner_image_extension("image/png", "") is None


def test_image_path_resolves_within_upload_root(tmp_path, monkeypatch):
    monkeypatch.setattr("app.domain.services.banner_images.UPLOAD_ROOT", str(tmp_path))
    path = banner_image_path("/uploads/banners/a.jpg")
    assert path == os.path.join(str(tmp_path), "banners", "a.jpg")
    # Traversal / foreign URLs are rejected
    assert banner_image_path("/uploads/../etc/passwd") is None
    assert banner_image_path("https://evil.com/x.jpg") is None
    assert banner_image_path(None) is None
    assert banner_image_path("") is None


def test_image_missing_detection(tmp_path, monkeypatch):
    monkeypatch.setattr("app.domain.services.banner_images.UPLOAD_ROOT", str(tmp_path))
    banners_dir = tmp_path / "banners"
    banners_dir.mkdir()
    present = banners_dir / "present.jpg"
    present.write_bytes(b"x")

    assert banner_image_missing("/uploads/banners/present.jpg") is False
    assert banner_image_missing("/uploads/banners/gone.jpg") is True
    assert banner_image_missing(None) is False


def test_with_image_status_never_persists_flag(tmp_path, monkeypatch):
    monkeypatch.setattr("app.domain.services.banner_images.UPLOAD_ROOT", str(tmp_path))
    banners_dir = tmp_path / "banners"
    banners_dir.mkdir()
    (banners_dir / "ok.jpg").write_bytes(b"x")

    enriched = banner_with_image_status({"id": "1", "image_url": "/uploads/banners/ok.jpg"})
    assert enriched["image_missing"] is False

    missing = banner_with_image_status({"id": "2", "image_url": "/uploads/banners/nope.jpg"})
    assert missing["image_missing"] is True
