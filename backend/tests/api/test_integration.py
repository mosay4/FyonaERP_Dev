import pytest
from httpx import AsyncClient, ASGITransport
from app.main import app
from app.core.database import get_db
from app.core.config import settings
from unittest.mock import AsyncMock

pytestmark = pytest.mark.asyncio


@pytest.fixture
def mock_db():
    mock_session = AsyncMock()
    mock_session.execute.return_value.scalar_one_or_none.return_value = None
    mock_session.execute.return_value.scalars.return_value.all.return_value = []
    mock_session.execute.return_value.unique.return_value.scalar_one_or_none.return_value = (
        None
    )
    return mock_session


@pytest.fixture
async def client(mock_db):
    app.dependency_overrides[get_db] = lambda: mock_db
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
        yield ac
    app.dependency_overrides.clear()


class TestAPIAuth:
    async def test_health_endpoint(self, client):
        resp = await client.get(f"{settings.API_PREFIX}/health")
        assert resp.status_code == 200

    async def test_health_returns_json(self, client):
        resp = await client.get(f"{settings.API_PREFIX}/health")
        data = resp.json()
        assert "status" in data

    async def test_legacy_register_endpoint_removed(self, client):
        resp = await client.post(
            f"{settings.API_PREFIX}/auth/register",
            json={"full_name": "T", "email": "bad", "password": "weak"},
        )
        assert resp.status_code == 404

    async def test_legacy_login_endpoint_removed(self, client):
        resp = await client.post(
            f"{settings.API_PREFIX}/auth/login",
            json={"email": "test@test.com", "password": "StrongPass1"},
        )
        assert resp.status_code == 404

    async def test_uploads_require_auth(self, client):
        resp = await client.get("/uploads/banners/whatever.png")
        assert resp.status_code in (401, 403)


class TestAPICustomers:
    async def test_create_customer_unauthorized(self, client):
        resp = await client.post(
            f"{settings.API_PREFIX}/customers",
            json={"name": "Test Customer"},
        )
        assert resp.status_code in (401, 403)

    async def test_list_customers_unauthorized(self, client):
        resp = await client.get(f"{settings.API_PREFIX}/customers")
        assert resp.status_code in (401, 403)


class TestAPIProducts:
    async def test_create_product_no_auth(self, client):
        resp = await client.post(
            f"{settings.API_PREFIX}/products",
            json={"name": "Test", "price": 100},
        )
        assert resp.status_code in (401, 403)

    async def test_list_products_no_auth(self, client):
        resp = await client.get(f"{settings.API_PREFIX}/products")
        assert resp.status_code in (401, 403)


class TestAPIInvoices:
    async def test_create_invoice_no_auth(self, client):
        resp = await client.post(
            f"{settings.API_PREFIX}/invoices",
            json={
                "invoice_type": "sale",
                "items": [{"description": "item", "quantity": 1, "unit_price": 100}],
            },
        )
        assert resp.status_code in (401, 403)


class TestSecurityHeaders:
    async def test_security_headers_present(self, client):
        resp = await client.get(f"{settings.API_PREFIX}/health")
        assert resp.headers.get("x-content-type-options") == "nosniff"
        assert resp.headers.get("x-frame-options") == "DENY"
        assert resp.headers.get("referrer-policy") == "strict-origin-when-cross-origin"


class TestAPIPermissions:
    async def test_all_mutate_endpoints_require_auth(self, client):
        endpoints = [
            ("POST", f"{settings.API_PREFIX}/customers", {"name": "T"}),
            ("POST", f"{settings.API_PREFIX}/products", {"name": "T", "price": 10}),
            (
                "POST",
                f"{settings.API_PREFIX}/invoices",
                {
                    "invoice_type": "sale",
                    "items": [{"description": "x", "quantity": 1, "unit_price": 10}],
                },
            ),
            ("POST", f"{settings.API_PREFIX}/categories", {"name": "T"}),
            ("POST", f"{settings.API_PREFIX}/suppliers", {"name": "T"}),
        ]
        for method, url, body in endpoints:
            if method == "POST":
                resp = await client.post(url, json=body)
            else:
                resp = await client.get(url)
            assert resp.status_code in (
                401,
                403,
            ), f"{method} {url} returned {resp.status_code}"
