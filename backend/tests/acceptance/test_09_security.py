"""Acceptance Test 9 — Security.

Proves: tools cannot be executed without a valid org scope, org A can never read
org B's data, inputs are validated, and unknown/untrusted tool names are refused.
"""

from decimal import Decimal

import pytest
from sqlalchemy import select, func

from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.business_entities import Customer, Product
from app.domain.services.sara_agent_service import ToolExecutor
from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import make_ctx


async def test_banking_data_is_isolated_per_org(db, seed):
    ex_a = ToolExecutor(db, seed["org_a"])
    r_a = await ex_a.execute("get_banking_data", {})
    names_a = {a["name"] for a in r_a["accounts"]}
    assert names_a == {"الراجحي", "الأهلي"}  # org A sees only its accounts

    ex_b = ToolExecutor(db, seed["org_b"])
    r_b = await ex_b.execute("get_banking_data", {})
    names_b = {a["name"] for a in r_b["accounts"]}
    assert names_b == {"الراجحي"}  # org B's "الراجحي" is a DIFFERENT record
    assert r_b["accounts"][0]["balance"] == "99999.00"  # not org A's 1000.00

    # Neither org's result leaks the other's data.
    a_balances = {a["balance"] for a in r_a["accounts"]}
    assert "99999.00" not in a_balances


async def test_agent_org_a_never_sees_org_b(make_agent, seed, openai_client):
    """The agent running for org A gets org A's data in tool results."""
    observed = {}

    def observe(messages):
        result = next(
            m["content"] for m in reversed(messages) if m.get("role") == "tool"
        )
        observed["result"] = result
        return final_content("تم.")

    client = openai_client(script=[
        tool_call("get_banking_data", {}),
        observe,
    ])
    agent = make_agent()
    await agent.process("حساباتي؟", make_ctx(seed))
    assert "1000.00" in observed["result"]      # org A balance
    assert "99999.00" not in observed["result"] # org B balance never leaks


async def test_customer_isolation(make_agent, seed, openai_client):
    observed = {}

    def observe(messages):
        result = next(
            m["content"] for m in reversed(messages) if m.get("role") == "tool"
        )
        observed["result"] = result
        return final_content("تم.")

    openai_client(script=[tool_call("get_customer_data", {}), observe])
    agent = make_agent()
    await agent.process("عملائي؟", make_ctx(seed))
    assert "شركة النور" in observed["result"]
    assert "شركة الظلام" not in observed["result"]


async def test_inventory_isolation(db, seed):
    ex_a = ToolExecutor(db, seed["org_a"])
    r_a = await ex_a.execute("get_inventory_data", {})
    assert r_a["products"][0]["name"] == "منتج أ"
    assert all(p["name"] != "منتج ب" for p in r_a["products"])


async def test_financial_execution_is_org_scoped(make_agent, seed, openai_client, db):
    """A deposit for org A only touches org A's account row."""
    openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 100, "account_name": "الراجحي",
        }),
        final_content("تم الإيداع."),
    ])
    agent = make_agent()
    await agent.process("أودع 100 في الراجحي", make_ctx(seed))

    a_acc = (await db.execute(
        select(BankAccount).where(
            BankAccount.organization_id == seed["org_a"],
            BankAccount.account_name == "الراجحي",
        )
    )).scalars().first()
    b_acc = (await db.execute(
        select(BankAccount).where(
            BankAccount.organization_id == seed["org_b"],
            BankAccount.account_name == "الراجحي",
        )
    )).scalars().first()
    assert a_acc.balance == Decimal("1100.00")   # org A mutated
    assert b_acc.balance == Decimal("99999.00")  # org B untouched


async def test_transaction_rejects_unknown_account(make_agent, seed, openai_client, db):
    openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 100, "account_name": "بنك وهمي",
        }),
        final_content("حساب غير موجود."),
    ])
    agent = make_agent()
    resp = await agent.process("أودع في بنك وهمي", make_ctx(seed))
    assert resp.text
    # Nothing was created: still 2 accounts, and the seeded transaction count.
    tx_count = (await db.execute(
        select(func.count(BankTransaction.id)).where(
            BankTransaction.organization_id == seed["org_a"]
        )
    )).scalar()
    assert tx_count == 1  # only the original "راتب شهر"


async def test_negative_and_zero_amounts_rejected(db, seed):
    ex = ToolExecutor(db, seed["org_a"])
    for amount in [-5, 0]:
        r = await ex.execute("create_transaction", {
            "operation": "deposit", "amount": amount, "account_name": "الراجحي",
        })
        assert "error" in r
        assert "المبلغ" in r["error"]


async def test_transfer_requires_two_real_accounts(db, seed):
    ex = ToolExecutor(db, seed["org_a"])
    r = await ex.execute("create_transaction", {
        "operation": "transfer", "amount": 10,
        "from_account_name": "الراجحي", "to_account_name": "حساب آخر",
    })
    assert "error" in r
    assert "لم أجد الحسابين" in r["error"]


async def test_same_account_transfer_rejected(db, seed):
    ex = ToolExecutor(db, seed["org_a"])
    r = await ex.execute("create_transaction", {
        "operation": "transfer", "amount": 10,
        "from_account_name": "الراجحي", "to_account_name": "الراجحي",
    })
    assert "error" in r


async def test_unknown_tool_cannot_execute(make_agent, seed, openai_client, db):
    """An unknown tool name is refused by the loop and cannot mutate anything."""
    openai_client(script=[
        tool_call("drop_database", {}),
        final_content("مرفوض."),
    ])
    agent = make_agent()
    resp = await agent.process("افعل الخطير", make_ctx(seed))
    assert resp.text
    assert resp.needs_clarification is True

    # Data still intact (org A counts unchanged from seed).
    acc_count = (await db.execute(
        select(func.count(BankAccount.id)).where(BankAccount.organization_id == seed["org_a"])
    )).scalar()
    cust_count = (await db.execute(
        select(func.count(Customer.id)).where(Customer.organization_id == seed["org_a"])
    )).scalar()
    prod_count = (await db.execute(
        select(func.count(Product.id)).where(Product.organization_id == seed["org_a"])
    )).scalar()
    assert acc_count == 2 and cust_count == 1 and prod_count == 1


async def test_executor_refuses_unregistered_tool(db, seed):
    ex = ToolExecutor(db, seed["org_a"])
    r = await ex.execute("get_secret_admin_data", {})
    assert "error" in r
    assert "Unknown tool" in r["error"]
