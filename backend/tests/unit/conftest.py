"""Shared fixtures for the unit tests."""
import pytest

from app.core.rate_limiter import InMemoryRateLimiter


@pytest.fixture(autouse=True)
def _fresh_rate_limits():
    """Each test starts with an empty request window: logins counted by one
    test (same client IP 127.0.0.1) must not throttle the next one."""
    InMemoryRateLimiter.reset_all()
    yield
