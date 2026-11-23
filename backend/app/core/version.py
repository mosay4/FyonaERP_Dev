import os
import subprocess
from .config import settings


_commit_cache: str | None = None

def get_git_commit() -> str:
    global _commit_cache
    if _commit_cache is not None:
        return _commit_cache
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=0.4,
        )
        if result.returncode == 0:
            _commit_cache = result.stdout.strip()
            return _commit_cache
    except Exception:
        pass
    # Fallback to DEPLOY_SHA env var (set by CI/CD or deploy script)
    _commit_cache = os.environ.get("DEPLOY_SHA", "unknown")
    return _commit_cache


def get_version_info() -> dict:
    return {
        "app": settings.APP_NAME,
        "version": settings.APP_VERSION,
        "commit": get_git_commit(),
        "deploy_sha": os.environ.get("DEPLOY_SHA", "unknown"),
        "deploy_time": os.environ.get("DEPLOY_TIME", "unknown"),
        "environment": "production" if not settings.DEBUG else "development",
        "python": os.environ.get("PYTHON_VERSION", ""),
    }
