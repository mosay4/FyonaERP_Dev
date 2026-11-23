"""Shared filesystem paths for uploaded content."""

import os

UPLOAD_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "uploads")
)
