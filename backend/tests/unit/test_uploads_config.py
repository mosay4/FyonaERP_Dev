"""Uploaded content must survive container recreate (persistence config).

Regression for audit finding: uploads lived in the container's writable layer
(/app/app/uploads) with no volume, so every `docker compose up` / deploy wiped
user-uploaded images (suggestions, banners, subscription proofs).
"""

import os
from pathlib import Path

from app.core.paths import UPLOAD_ROOT

BACKEND = Path(__file__).resolve().parents[2]


def test_compose_binds_uploads_dir_for_api():
    compose = (BACKEND / "docker-compose.yml").read_text(encoding="utf-8")
    # UPLOAD_ROOT resolves to backend/app/uploads -> mounted at /app/app/uploads
    assert "./app/uploads:/app/app/uploads" in compose


def test_dockerignore_does_not_bake_runtime_uploads():
    text = (BACKEND / ".dockerignore").read_text(encoding="utf-8")
    assert "app/uploads/" in text


def test_dockerfile_declares_uploads_mount_point():
    text = (BACKEND / "Dockerfile").read_text(encoding="utf-8")
    assert "mkdir -p /app/app/uploads" in text
    assert "chown fyona:fyona /app/app/uploads" in text


def test_upload_root_is_the_uploads_directory():
    assert os.path.basename(UPLOAD_ROOT) == "uploads"
