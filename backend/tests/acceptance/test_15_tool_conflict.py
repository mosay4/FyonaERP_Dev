"""Production Readiness 6 — Tool Conflict & Ordering.

A chained command ("أنشئ معاملة ثم احذفها ثم أنشئ غيرها") must execute in the
requested order with no conflicts: every successful mutation applies exactly
once, rejected/unknown operations mutate nothing, and balances stay consistent.
"""

from decimal import Decimal

from sqlalchemy import select

from app.domain.entities.finance_entities import BankAccount, BankTransaction

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, parallel_tool_calls, tool_call


async def _balance(db, name):
    result = await db.execute(select(BankAccount).where(BankAccount.account_name == name))
    return result.scalars().first().balance


async def test_create_delete_create_sequence_ordered_without_conflict(make_agent, seed, openai_client, db):
    """+250 deposit → (attempted) delete → +100 deposit.

    The app has no delete_transaction tool: the loop rejects the unknown tool
    WITHOUT touching the DB, feeds the error back, and the model continues with
    the next step. Final balance = 1000 + 250 + 100 = 1350.
    """
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 250, "account_name": "الراجحي",
            "description": "أول معاملة",
        }),
        tool_call("delete_transaction", {"id": "not-a-real-id"}),  # not an app tool
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 100, "account_name": "الراجحي",
            "description": "معاملة بعد الحذف",
        }),
        final_content("أودعت 250 ثم حاولت الحذف لكنه غير مدعوم، ثم أودعت 100."),
    ])
    agent = make_agent()
    resp = await agent.process(
        "أنشئ معاملة 250 ثم احذفها ثم أنشئ أخرى 100",
        make_ctx(seed),
    )

    assert_no_technical_leak(resp.text)
    assert await _balance(db, "الراجحي") == Decimal("1350.00")

    # Ordering proof: success of the 250 came before the rejected delete tool,
    # and the delete rejection was fed back to the model.
    tool_msgs = [
        m.get("content", "")
        for msgs in client.chat.completions.calls for m in msgs
        if m.get("role") == "tool"
    ]
    idx_create1 = next(i for i, c in enumerate(tool_msgs) if "تم إيداع" in c and "250" in c)
    idx_delete = next(i for i, c in enumerate(tool_msgs) if "أداة غير معروفة" in c)
    idx_create2 = next(i for i, c in enumerate(tool_msgs) if "تم إيداع" in c and "100" in c)
    assert idx_create1 < idx_delete < idx_create2

    # Exactly three transaction rows now exist for the account (seed had 1).
    result = await db.execute(select(BankTransaction).where(BankTransaction.description.in_(
        ["أول معاملة", "معاملة بعد الحذف"]
    )))
    assert len(result.scalars().all()) == 2


async def test_parallel_tool_calls_apply_sequentially_no_double_apply(make_agent, seed, openai_client, db):
    """Two create_transaction calls in ONE round must both apply, in order,
    exactly once each — no double-apply, no lost update."""
    client = openai_client(script=[
        parallel_tool_calls(
            {"name": "create_transaction", "arguments": {
                "operation": "deposit", "amount": 250, "account_name": "الراجحي",
            }},
            {"name": "create_transaction", "arguments": {
                "operation": "withdraw", "amount": 50, "account_name": "الراجحي",
            }},
        ),
        final_content("أودعت 250 وسحبت 50."),
    ])
    agent = make_agent()
    resp = await agent.process("أودع 250 ثم اسحب 50 من الراجحي", make_ctx(seed))

    assert_no_technical_leak(resp.text)
    # 1000 + 250 - 50 = 1200 exactly once.
    assert await _balance(db, "الراجحي") == Decimal("1200.00")


async def test_transfer_then_reverse_keeps_consistency(make_agent, seed, openai_client, db):
    """Transfer from الراجحي (1000) to الأهلي (500), then back: net zero."""
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "transfer", "amount": 200,
            "from_account_name": "الراجحي", "to_account_name": "الأهلي",
        }),
        tool_call("create_transaction", {
            "operation": "transfer", "amount": 200,
            "from_account_name": "الأهلي", "to_account_name": "الراجحي",
        }),
        final_content("نفذت التحويل ثم أعدته."),
    ])
    agent = make_agent()
    resp = await agent.process("حوّل 200 من الراجحي للأهلي ثم أعده", make_ctx(seed))

    assert_no_technical_leak(resp.text)
    assert await _balance(db, "الراجحي") == Decimal("1000.00")
    assert await _balance(db, "الأهلي") == Decimal("500.00")
