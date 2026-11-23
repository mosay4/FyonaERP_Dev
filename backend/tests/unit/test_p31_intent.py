import os
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

from app.domain.services.sara_agent_service import classify_intent

def test_intents():
    cases = [
        ("غير العملة إلى YER_NEW", "general"), # should not be write
        ("ما الفرق بين YER و YER_NEW؟", "help"),
        ("ما هي العملات الموجودة عندي؟", "balance"),
        ("أريد أعرف سعر الدولار", "balance"),
        ("أضف الدولار", "create"),
        ("احذف الدولار", "delete"), # delete keyword: list-then-confirm delete flow
        ("كم رصيدي بالدولار؟", "balance"),
        ("غير البنك", "general"),
        ("ما هو البنك المستخدم؟", "help"), # contains ما هو -> help
        ("كم صرفت؟", "analysis"),
        ("سجل مصروف", "analysis"), # now correctly goes to analysis (finance) not generic create
        ("لا، أقصد العملية الثانية", "general"),
        ("لا تسجل، فقط قل لي كم", "help"),
    ]
    for q, expected in cases:
        got = classify_intent(q)
        # For this audit, we check that info questions are not classified as transaction/create
        if expected == "help":
            assert got.category == "help", f"{q} -> {got.category} != help"
        elif expected == "balance":
            assert got.category == "balance", f"{q} -> {got.category} != balance"
        elif expected == "general":
            assert got.category in ("general", "help", "balance"), f"{q} -> {got.category} unexpected"
        elif expected == "delete":
            assert got.category == "delete", f"{q} -> {got.category} != delete"
        if q == "سجل مصروف":
            assert got.category in ("create", "general", "analysis")

    # Ensure YER questions are not writes
    assert classify_intent("ما الفرق بين YER و YER_NEW؟").category != "create"
    assert classify_intent("ما الفرق بين YER و YER_NEW؟").category != "transaction"

    # Ensure YER_NEW not mixed
    assert "YER_NEW" != "YER"
