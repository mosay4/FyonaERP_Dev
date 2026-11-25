from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase
import sqlalchemy as sa
from .config import settings

_is_sqlite = settings.DATABASE_URL.startswith("sqlite")

_engine_kwargs = {}
if not _is_sqlite:
    _engine_kwargs = dict(
        pool_size=settings.DATABASE_POOL_SIZE,
        max_overflow=settings.DATABASE_MAX_OVERFLOW,
        pool_timeout=settings.DATABASE_POOL_TIMEOUT,
        pool_recycle=settings.DATABASE_POOL_RECYCLE,
        pool_pre_ping=True,
    )

engine = create_async_engine(
    settings.DATABASE_URL,
    echo=settings.DATABASE_ECHO,
    **_engine_kwargs,
)

async_session_factory = async_sessionmaker(
    engine, class_=AsyncSession, expire_on_commit=False
)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncSession:
    async with async_session_factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()


async def init_db() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # The column safety-net below is Postgres-specific (information_schema).
        # SQLite (dev/E2E runs) gets the full schema from create_all directly.
        if conn.dialect.name != "postgresql":
            return
        # Safety net: ensure columns that were added after the initial
        # create_all exist. create_all only adds new tables, not new columns.
        for table, column, col_def in (
            ("personal_debts", "reminder", "BOOLEAN NOT NULL DEFAULT FALSE"),
            ("personal_debts", "is_paid", "BOOLEAN NOT NULL DEFAULT FALSE"),
            ("personal_debts", "paid_date", "DATE"),
            ("personal_debts", "due_date", "DATE"),
            # جاري/توفير; NULL = never stated (legacy) and reads as current.
            ("personal_bank_accounts", "account_type", "VARCHAR(20)"),
            ("subscription_requests", "currency", "VARCHAR(10)"),
            ("organizations", "avatar", "VARCHAR(500)"),
            ("branches", "is_archived", "BOOLEAN NOT NULL DEFAULT false"),
            ("branches", "archived_at", "TIMESTAMPTZ"),
            ("branches", "updated_at", "TIMESTAMPTZ"),
            ("customers", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("suppliers", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("products", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("bank_accounts", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("expenses", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("payments", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("financial_payments", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
            ("journal_entries", "branch_id",
             "UUID REFERENCES branches(id) ON DELETE SET NULL"),
        ):
            exist = await conn.execute(
                sa.text(
                    "SELECT 1 FROM information_schema.columns "
                    "WHERE table_name=:t AND column_name=:c"
                ),
                {"t": table, "c": column},
            )
            if exist.scalar() is None:
                await conn.execute(
                    sa.text(
                        f"ALTER TABLE {table} ADD COLUMN {column} {col_def}"
                    )
                )
        for _t in ("customers", "suppliers", "products", "bank_accounts",
                   "expenses", "payments", "financial_payments",
                   "journal_entries"):
            try:
                await conn.execute(sa.text(
                    f"CREATE INDEX IF NOT EXISTS ix_{_t}_branch_id "
                    f"ON {_t} (branch_id)"))
            except Exception:  # noqa: BLE001
                pass
        # Composite debt event ids (debt_edited:<invoice>:<link>) exceed the
        # legacy varchar(80) — widen it once; ALTER TYPE is idempotent.
        try:
            await conn.execute(sa.text(
                "ALTER TABLE app_notifications "
                "ALTER COLUMN event_id TYPE VARCHAR(200)"
            ))
        except Exception:  # noqa: BLE001
            pass
        # ── Branch backfill (idempotent, never deletes rows) ──
        try:
            import re as _re
            import uuid as _uuid

            def _clean_branch_name(value):
                n = _re.sub(r"\s*'s\s+organization\s*$", "",
                            (value or "").strip(), flags=_re.I).strip()
                return (n or "Business")[:200]

            rows = (await conn.execute(sa.text(
                "SELECT o.id, o.name FROM organizations o "
                "WHERE (o.subscription_plan IN ('business','premium') "
                "       OR o.business_setup_completed IS TRUE) "
                "  AND NOT EXISTS (SELECT 1 FROM branches b "
                "                  WHERE b.organization_id=o.id)"
            ))).all()
            for oid, oname in rows:
                await conn.execute(sa.text(
                    "INSERT INTO branches (id, organization_id, name, "
                    "is_default, is_active, is_archived, created_at, updated_at) "
                    "VALUES (:id,:org,:name,true,true,false,now(),now())"
                ), {"id": str(_uuid.uuid4()), "org": str(oid),
                    "name": _clean_branch_name(oname)})
            # Rename untouched legacy defaults to the business display name.
            legacy = (await conn.execute(sa.text(
                "SELECT b.id, b.name, o.name, b.organization_id "
                "FROM branches b JOIN organizations o ON o.id=b.organization_id "
                "WHERE b.is_default IS TRUE "
                "  AND b.name IN ('الفرع الرئيسي','Main Branch','Business')"
            ))).all()
            for bid, bname, oname, oid in legacy:
                clean = _clean_branch_name(oname)
                if not clean or clean == bname:
                    continue
                exists = (await conn.execute(sa.text(
                    "SELECT 1 FROM branches WHERE organization_id=:org AND name=:n"
                ), {"org": str(oid), "n": clean})).scalar()
                if exists is None:
                    await conn.execute(sa.text(
                        "UPDATE branches SET name=:n, updated_at=now() "
                        "WHERE id=:id"
                    ), {"n": clean, "id": str(bid)})
            # Existing rows without a branch → the org's default branch.
            # Invoice payments inherit their invoice's branch (exact relation).
            try:
                await conn.execute(sa.text(
                    "UPDATE payments p SET branch_id = i.branch_id "
                    "FROM invoices i WHERE p.invoice_id = i.id "
                    "AND p.branch_id IS NULL AND i.branch_id IS NOT NULL"))
            except Exception:  # noqa: BLE001
                pass
            for table in ("invoices", "inventory_lots",
                          "inventory_movements", "reconciliations",
                          "customers", "suppliers", "products",
                          "bank_accounts", "expenses", "payments",
                          "financial_payments", "journal_entries"):
                await conn.execute(sa.text(
                    f"UPDATE {table} t SET branch_id = ("
                    "  SELECT b.id FROM branches b "
                    "  WHERE b.organization_id=t.organization_id "
                    "    AND b.is_default IS TRUE "
                    "  ORDER BY b.created_at LIMIT 1) "
                    "WHERE t.branch_id IS NULL AND EXISTS ("
                    "  SELECT 1 FROM branches b "
                    "  WHERE b.organization_id=t.organization_id "
                    "    AND b.is_default IS TRUE)"
                ))
            # ── Per-branch stock (Option A) ──
            # Existing quantities stay on the MAIN branch only; no copying to
            # other branches and no change to Product.stock.
            try:
                await conn.execute(sa.text(
                    "INSERT INTO branch_stock (id, organization_id, branch_id, "
                    "product_id, quantity, avg_cost, created_at, updated_at) "
                    "SELECT gen_random_uuid(), p.organization_id, b.id, p.id, "
                    "       p.stock, COALESCE(p.cost_price, 0), now(), now() "
                    "FROM products p "
                    "JOIN branches b ON b.organization_id = p.organization_id "
                    "                AND b.is_default IS TRUE "
                    "WHERE COALESCE(p.stock, 0) <> 0 "
                    "  AND NOT EXISTS (SELECT 1 FROM branch_stock s "
                    "                  WHERE s.branch_id = b.id "
                    "                    AND s.product_id = p.id)"
                ))
            except Exception:  # noqa: BLE001
                pass
        except Exception:  # noqa: BLE001
            pass


async def close_db() -> None:
    await engine.dispose()
