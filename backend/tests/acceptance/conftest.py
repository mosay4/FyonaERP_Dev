"""Shared fixtures for Sara AI Agent acceptance tests.

A real on-disk SQLite database is used (same engine the app's tools query), seeded
with two organisations so multi-tenant isolation can be proven. The only thing that
is mocked is the remote OpenAI transport (see mock_openai.py).
"""

from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
import openai
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import Base
from app.domain.models.agent_models import AgentContext

import app.domain.entities.finance_entities  # noqa: F401  (register tables on Base)
import app.domain.entities.business_entities  # noqa: F401  (register tables on Base)
import app.domain.entities.analytics_entities  # noqa: F401  (register tables on Base)
import app.domain.entities.suggestions_entities  # noqa: F401  (register tables on Base)
import app.domain.entities.notification_entities  # noqa: F401  (register tables on Base)
import app.domain.entities.auth_entities  # noqa: F401  (register tables on Base)

from app.domain.services import sara_agent_service
from app.domain.services.sara_agent_service import AgentMemoryStore, SaraAgentService

from tests.acceptance.mock_openai import MockAsyncOpenAI


# ═══════════════════════════════════════════════════════════════
#  DATABASE — real SQLite file, real SQLAlchemy queries
# ═══════════════════════════════════════════════════════════════

@pytest.fixture(scope="session")
def db_file(tmp_path_factory):
    return str(tmp_path_factory.mktemp("acceptance") / "acceptance.db")


@pytest.fixture(scope="session")
def sync_engine(db_file):
    eng = create_engine(f"sqlite:///{db_file}")
    with eng.begin():
        Base.metadata.drop_all(eng)
        Base.metadata.create_all(eng)
    return eng


@pytest.fixture(scope="session")
def async_engine(db_file):
    return create_async_engine(f"sqlite+aiosqlite:///{db_file}", echo=False)


@pytest.fixture(scope="session")
def async_session_factory(async_engine):
    return async_sessionmaker(async_engine, expire_on_commit=False)


@pytest_asyncio.fixture()
async def db(async_session_factory):
    async with async_session_factory() as session:
        yield session


# ═══════════════════════════════════════════════════════════════
#  SEED DATA — two organisations, fully isolated
# ═══════════════════════════════════════════════════════════════

_ORG_A = uuid4()
_ORG_B = uuid4()


def _now():
    return datetime.now(timezone.utc)


def _seed(sync_engine):
    from app.domain.entities.finance_entities import (
        BankAccount, BankTransaction, Expense,
    )
    from app.domain.entities.business_entities import (
        Customer, Product, ProductCategory,
    )
    from app.domain.entities.analytics_entities import AgentAnalyticsEvent
    from app.domain.entities.suggestions_entities import Suggestion

    with Session(sync_engine) as s:
        for t in [AgentAnalyticsEvent, Suggestion, BankTransaction, BankAccount, Expense, Product, ProductCategory, Customer]:
            s.execute(t.__table__.delete())
        s.commit()
    with Session(sync_engine) as s:
        # ── Org A (personal finance) ─────────────────────────────
        a_bank = BankAccount(
            id=uuid4(), organization_id=_ORG_A,
            bank_name="مصرف الراجحي", account_name="الراجحي",
            account_number="SA001", balance=Decimal("1000.00"), currency="SAR",
        )
        a_bank2 = BankAccount(
            id=uuid4(), organization_id=_ORG_A,
            bank_name="البنك الأهلي", account_name="الأهلي",
            account_number="SA002", balance=Decimal("500.00"), currency="SAR",
        )
        a_tx = BankTransaction(
            id=uuid4(), organization_id=_ORG_A, bank_account_id=a_bank.id,
            date=_now(), description="راتب شهر", tx_type="deposit",
            amount=Decimal("1000.00"), running_balance=Decimal("1000.00"),
        )
        a_expense = Expense(
            id=uuid4(), organization_id=_ORG_A, expense_no="EXP-001",
            category="مطاعم", amount=Decimal("250.00"),
            description="عشاء", payment_method="cash", expense_date=_now(),
        )

        # ── Org B (business) ─────────────────────────────────────
        b_bank = BankAccount(
            id=uuid4(), organization_id=_ORG_B,
            bank_name="مصرف الراجحي", account_name="الراجحي",
            account_number="SB001", balance=Decimal("99999.00"), currency="SAR",
        )
        b_tx = BankTransaction(
            id=uuid4(), organization_id=_ORG_B, bank_account_id=b_bank.id,
            date=_now(), description="بيع بضاعة", tx_type="deposit",
            amount=Decimal("99999.00"), running_balance=Decimal("99999.00"),
        )
        b_expense = Expense(
            id=uuid4(), organization_id=_ORG_B, expense_no="EXP-002",
            category="تسويق", amount=Decimal("100.00"),
            description="إعلان", payment_method="cash", expense_date=_now(),
        )

        # ── Business entities (org A) ────────────────────────────
        a_cat = ProductCategory(id=uuid4(), organization_id=_ORG_A, name="أجهزة")
        a_customer = Customer(
            id=uuid4(), organization_id=_ORG_A, name="شركة النور",
            phone="0500000001", email="noor@test.com",
            credit_limit=Decimal("5000.00"),
        )
        a_product = Product(
            id=uuid4(), organization_id=_ORG_A, category_id=a_cat.id,
            name="منتج أ", sku="SKU-A", price=Decimal("100.00"),
            stock=5, min_stock=10,
        )

        # ── Business entities (org B) ────────────────────────────
        b_cat = ProductCategory(id=uuid4(), organization_id=_ORG_B, name="مواد")
        b_customer = Customer(
            id=uuid4(), organization_id=_ORG_B, name="شركة الظلام",
            phone="0500000002", credit_limit=Decimal("100.00"),
        )
        b_product = Product(
            id=uuid4(), organization_id=_ORG_B, category_id=b_cat.id,
            name="منتج ب", sku="SKU-B", price=Decimal("10.00"),
            stock=200, min_stock=5,
        )

        s.add_all([
            a_bank, a_bank2, a_tx, a_expense,
            b_bank, b_tx, b_expense,
            a_cat, a_customer, a_product,
            b_cat, b_customer, b_product,
        ])
        s.commit()

    return {
        "org_a": _ORG_A,
        "org_b": _ORG_B,
        "bank_a": "الراجحي",
        "bank_b": "الراجحي",
        "customer_a": "شركة النور",
        "customer_b": "شركة الظلام",
        "product_a": "منتج أ",
        "product_b": "منتج ب",
    }


@pytest.fixture()
def seed(sync_engine):
    return _seed(sync_engine)


# ═══════════════════════════════════════════════════════════════
#  AGENT / OPENAI / MEMORY fixtures
# ═══════════════════════════════════════════════════════════════

@pytest.fixture()
def openai_client(monkeypatch):
    """Provide a scripted mock OpenAI client + fake API key.

    The mock is patched by default (so any agent run is deterministic), and a
    factory lets a test supply a script: openai_client(script=[...], **kwargs).
    """
    monkeypatch.setattr(settings, "OPENAI_API_KEY", "sk-acceptance-test")
    monkeypatch.setattr(settings, "OPENAI_MODEL", "gpt-4o-mini")

    default = MockAsyncOpenAI()
    monkeypatch.setattr(sara_agent_service, "AsyncOpenAI", lambda api_key: default)
    monkeypatch.setattr(openai, "AsyncOpenAI", lambda api_key: default)

    def _make(script=None, **kwargs):
        mock = MockAsyncOpenAI(script=script, **kwargs)
        monkeypatch.setattr(sara_agent_service, "AsyncOpenAI", lambda api_key: mock)
        monkeypatch.setattr(openai, "AsyncOpenAI", lambda api_key: mock)
        return mock

    return _make


@pytest.fixture()
def no_api_key(monkeypatch):
    monkeypatch.setattr(settings, "OPENAI_API_KEY", None)
    yield


@pytest.fixture(autouse=True)
def _isolated_memory(monkeypatch):
    """Every test gets a fresh in-process memory store (no cross-test pollution)."""
    fresh = AgentMemoryStore()
    monkeypatch.setattr(sara_agent_service, "MEMORY_STORE", fresh)
    return fresh


@pytest.fixture()
def memory(_isolated_memory):
    return _isolated_memory


@pytest.fixture()
def make_agent(db, seed):
    def _make(org=None, user=None):
        org_id = org or seed["org_a"]
        user_id = user or org_id
        return SaraAgentService(db, org_id, user_id)
    return _make


def make_ctx(seed, **overrides):
    """Build an AgentContext with app-awareness fields for org A."""
    base = dict(
        user_id=str(seed["org_a"]),
        user_name="سارة اختبار",
        account_type="personal",
        current_screen="الرئيسية",
        subscription_plan="Pro",
        subscription_status="active",
        network_status="online",
        current_tab="personal",
        last_screen="البنوك",
        last_operation="",
        pending_operations=[],
    )
    base.update(overrides)
    return AgentContext(**base)


# ═══════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════

TECHNICAL_PATTERNS = [
    "Exception", "Traceback", "traceback", "status:null", "  File ",
    "RuntimeError", "KeyError", "TypeError", "ValueError", "sqlalchemy",
    "AsyncOpenAI", "at 0x", "Traceback (most",
]


def assert_no_technical_leak(text: str):
    """User must never see technical/exception content."""
    for pat in TECHNICAL_PATTERNS:
        assert pat.lower() not in (text or "").lower(), (
            f"Technical content leaked to user: {pat!r} in {text!r}"
        )


def last_tool_message(messages: list) -> str:
    """Return the most recent tool-role message content."""
    for msg in reversed(messages):
        if msg.get("role") == "tool":
            return msg.get("content", "")
    return ""


def system_prompt(client) -> str:
    """System prompt of the first create() call."""
    return client.chat.completions.call_kwargs[0]["messages"][0]["content"]
