"""Deploy script must ship api + celery together and stay rollbackable.

Regression for audit finding: `docker compose up -d --build --no-deps api`
only rebuilt the API image, leaving celery-worker/celery-beat running stale
code for days.

Updated for GHCR-based deployment: images are pulled from GHCR (not built
on VPS), deployment is locked, and rollback uses SHA tags from metadata.
"""

from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = BACKEND / "scripts" / "deploy-backend.sh"


def _content() -> str:
    return DEPLOY_SCRIPT.read_text(encoding="utf-8")


def test_deploy_script_exists_and_is_managed():
    assert DEPLOY_SCRIPT.is_file()


def test_deploy_script_pull_from_ghcr():
    """Deploy must pull images from GHCR, not build on VPS."""
    content = _content()
    assert "docker pull" in content
    assert "GHCR_IMAGE" in content
    assert "ghcr.io" in content
    assert "--build" not in content  # Must NOT build on VPS


def test_compose_up_for_all_app_services():
    """api + both celery services are deployed in a single compose invocation."""
    content = _content()
    assert "SERVICES=" in content
    assert "api celery-worker celery-beat" in content


def test_rollback_uses_sha_tags_not_latest():
    """Rollback must use GHCR SHA tags, not 'latest'."""
    content = _content()
    # Must have rollback function
    assert "rollback()" in content
    # Must pull specific SHA (not latest) during rollback
    assert "DEPLOY_SHA" in content
    # Must reference previous successful deployment
    assert "rollback-info" in content or "current-deploy" in content


def test_celery_containers_gated_before_success():
    """Deploy must not report HEALTH_OK if a worker is not running."""
    content = _content()
    assert "CELERY_NOT_RUNNING" in content or "CELERY_GATE" in content
    assert "docker inspect" in content


def test_deployment_lock():
    """Deploy must use a lock file to prevent concurrent deployments."""
    content = _content()
    assert "deploy-lock" in content or "LOCK_FILE" in content


def test_deployment_metadata_tracked():
    """Deploy must record metadata: SHA, time, status, previous version."""
    content = _content()
    assert "deploy-metadata" in content
    assert "CURRENT_SHA" in content
    assert "DEPLOY_SHA" in content
