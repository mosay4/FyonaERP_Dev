"""Parity source for the Dart port (lib/features/personal/domain/services/
personal_analytics.dart): runs the REAL build_financial_analytics on the
shared fixture (test/fixtures/personal_analytics_parity.json) and checks the
expected outputs stored there — the Dart test reads the same file.

sqlite stands in for PostgreSQL; two dialect differences are normalized to
what PostgreSQL returns: timestamps come back timezone-aware (UTC), and
COALESCE(SUM(empty), 0) is the integer 0 ("0"), not "0.00".
Regenerate after an intended change: SARA_PARITY_WRITE=1 pytest <this file>.
"""
import asyncio
import json
import os
import re
import uuid
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pytest

aiosqlite = pytest.importorskip("aiosqlite")

FIXTURE = Path(__file__).resolve().parents[3] / "test" / "fixtures" / "personal_analytics_parity.json"


def _dt(value):
    return datetime.fromisoformat(value) if value else None


def _day(value):
    return date.fromisoformat(value) if value else None


def _dec(value):
    return Decimal(value) if value is not None else None


async def _run_case(data, case):
    from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
    from app.domain.entities import personal_entities as pe
    from app.domain.services.sara_analytics import build_financial_analytics

    engine = create_async_engine("sqlite+aiosqlite://")
    tables = [pe.PersonalBankAccount.__table__, pe.PersonalTransaction.__table__,
              pe.PersonalSavingsGoal.__table__, pe.PersonalDebt.__table__,
              pe.PersonalDebtPayment.__table__, pe.PersonalBudget.__table__,
              pe.PersonalBudgetCategory.__table__, pe.PersonalRecurringTransaction.__table__]
    try:
        async with engine.begin() as conn:
            await conn.run_sync(lambda s: pe.Base.metadata.create_all(s, tables=tables))
        uid = uuid.UUID("abcd0000-0000-4000-8000-00000000abcd")  # non-numeric hex (sqlite affinity)
        U = uuid.UUID
        async with AsyncSession(engine) as db:
            for a in data["accounts"]:
                db.add(pe.PersonalBankAccount(id=U(a["id"]), user_id=uid, bank_name=a["bank_name"],
                                              currency=a["currency"], balance=_dec(a["balance"])))
            for b in data["budgets"]:
                db.add(pe.PersonalBudget(id=U(b["id"]), user_id=uid, name=b["name"], currency=b["currency"],
                                         total_amount=_dec(b["total_amount"]), spent=_dec(b["spent"]),
                                         period_type=b["period_type"]))
                for c in b["categories"]:
                    db.add(pe.PersonalBudgetCategory(id=U(c["id"]), budget_id=U(b["id"]), name=c["name"],
                                                     type=c["type"], currency=c["currency"],
                                                     allocated_amount=_dec(c["allocated_amount"]),
                                                     spent_amount=_dec(c["spent_amount"])))
            for g in data["goals"]:
                db.add(pe.PersonalSavingsGoal(id=U(g["id"]), user_id=uid, name=g["name"], currency=g["currency"],
                                              target_amount=_dec(g["target_amount"]),
                                              current_amount=_dec(g["current_amount"]),
                                              deadline=_day(g["deadline"]), is_completed=g["is_completed"]))
            for d in data["debts"]:
                db.add(pe.PersonalDebt(id=U(d["id"]), user_id=uid, person_name=d["person_name"],
                                       debt_type=d["debt_type"], currency=d["currency"], amount=_dec(d["amount"]),
                                       due_date=_day(d["due_date"]), is_paid=d["is_paid"]))
                for p in d["payments"]:
                    db.add(pe.PersonalDebtPayment(id=U(p["id"]), debt_id=U(d["id"]), user_id=uid,
                                                  amount=_dec(p["amount"]), currency=p["currency"],
                                                  payment_date=_dt(p["payment_date"])))
            for r in data["recurring"]:
                db.add(pe.PersonalRecurringTransaction(
                    id=U(r["id"]), user_id=uid, name=r["name"], currency=r["currency"], amount=_dec(r["amount"]),
                    tx_type=r["tx_type"], frequency=r["frequency"], interval_value=r["interval_value"],
                    category=r["category"], bank_account_id=U(r["bank_account_id"]) if r["bank_account_id"] else None,
                    last_executed_at=_dt(r["last_executed_at"]), next_run_date=_day(r["next_run_date"]),
                    is_active=r["is_active"]))
            await db.flush()
            for t in data["transactions"]:
                db.add(pe.PersonalTransaction(
                    id=U(t["id"]), user_id=uid, tx_type=t["tx_type"], amount=_dec(t["amount"]),
                    currency=t["currency"], category=t["category"], description=t["description"],
                    bank_account_id=U(t["bank_account_id"]) if t["bank_account_id"] else None,
                    budget_id=U(t["budget_id"]) if t["budget_id"] else None,
                    goal_id=U(t["goal_id"]) if t["goal_id"] else None,
                    goal_amount=_dec(t["goal_amount"]), date=_dt(t["date"])))
            await db.commit()
            out = await build_financial_analytics(db, uid, case["period"], now=_dt(case["now"]), tz=case["tz"])
        return _normalize(json.loads(json.dumps(out, default=str)))
    finally:
        await engine.dispose()


_NAIVE_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?$")


def _normalize(node):
    """sqlite → PostgreSQL output (see module doc); drops run-time fields."""
    if isinstance(node, dict):
        out = {k: _normalize(v) for k, v in node.items() if k not in ("generated_at", "source")}
        if out.get("payment_count") == 0 and out.get("paid") == "0.00":
            out["paid"] = "0"
        return out
    if isinstance(node, list):
        return [_normalize(v) for v in node]
    if isinstance(node, str) and _NAIVE_ISO.match(node):
        return node + "+00:00"
    return node


def test_python_analytics_matches_the_shared_fixture():
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for case in data["cases"]:
        got = asyncio.run(_run_case(data, case))
        if os.environ.get("SARA_PARITY_WRITE") == "1":
            case["expected"] = got
        else:
            assert got == case["expected"], case["name"]
    if os.environ.get("SARA_PARITY_WRITE") == "1":
        FIXTURE.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
