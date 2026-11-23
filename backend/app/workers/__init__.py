from .celery_app import celery
from . import tasks  # noqa: F401 — register all tasks

__all__ = ["celery"]
