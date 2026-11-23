"""Business branch cutover rehearsal. No route, startup hook or grant issuer.

This works only in a freshly created, socket-only fixture database. It freezes
the covered legacy financial/inventory tables and captures a reproducible
branch snapshot. The device's import receipt is deliberately not permission to
run a new ledger: archived rows still need complete operational projections.
"""

from base64 import b64decode, b64encode
from dataclasses import dataclass
from decimal import Decimal
from hashlib import sha256
from io import BytesIO
import json
import re
from typing import Mapping
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine


FIXTURE_DB = "fyona_cutover_fixture"
SOCKET_PATH = re.compile(r"/tmp/opencode/fyona-cutover-[a-zA-Z0-9]+/socket")
FIXTURE_SERVER = "https://cutover.example.test/api/v1"


class CutoverRejected(Exception):
    pass


@dataclass(frozen=True)
class CutoverScope:
    organization_id: UUID
    account_id: UUID
    branch_id: UUID

    def params(self):
        return vars(self)


@dataclass(frozen=True)
class CutoverSnapshot:
    id: UUID
    digest: str
    body: bytes


@dataclass(frozen=True)
class CatalogImage:
    """Bytes and digest obtained from the authorized fixture export, not a URL."""

    reference: str
    digest: str
    data: bytes


_CatalogImages = Mapping[tuple[str, UUID], CatalogImage]
_image_prefix = "fyona-product-image:"
_image_limit = 1024 * 1024  # The encoded row must fit Android's CursorWindow.
_catalog_images_limit = 16 * 1024 * 1024


@dataclass(frozen=True)
class _Parent:
    column: str
    table: str
    discriminator: tuple[str, str] | None = None


@dataclass(frozen=True)
class _Rule:
    direct: tuple[str, ...] = ()
    parents: tuple[_Parent, ...] = ()
    archive: bool = True


_party = (
    _Parent("party_id", "customers", ("party_kind", "customer")),
    _Parent("party_id", "suppliers", ("party_kind", "supplier")),
)
# Supported ownership graph for this rehearsal. For example, a legacy opening
# invoice can have a NULL branch column but still belong to its concrete party.
# Both OLD and NEW ownership are checked, including every transfer endpoint.
_rules = {
    "branches": _Rule(("id",)),
    "branch_invitations": _Rule(("branch_id",), archive=False),
    "customers": _Rule(("branch_id",)),
    "suppliers": _Rule(("branch_id",)),
    "bank_accounts": _Rule(("branch_id",)),
    "bank_transactions": _Rule(parents=(_Parent("bank_account_id", "bank_accounts"),)),
    "expenses": _Rule(("branch_id",), (_Parent("bank_account_id", "bank_accounts"),)),
    "financial_payments": _Rule(("branch_id",), archive=False),
    "cheques": _Rule(("branch_id",), archive=False),
    "debt_groups": _Rule(parents=_party),
    "invoices": _Rule(("branch_id",), (
        _Parent("customer_id", "customers"), _Parent("supplier_id", "suppliers"),
        _Parent("debt_group_id", "debt_groups"),
    )),
    "invoice_items": _Rule(parents=(
        _Parent("invoice_id", "invoices"), _Parent("product_id", "products"),
        _Parent("unit_id", "product_units"),
    )),
    "invoice_item_changes": _Rule(parents=(
        _Parent("invoice_id", "invoices"), _Parent("item_id", "invoice_items"),
    )),
    "payments": _Rule(("branch_id",), (
        _Parent("invoice_id", "invoices"), _Parent("bank_account_id", "bank_accounts"),
    )),
    "customer_receivables": _Rule(parents=(
        _Parent("invoice_id", "invoices"), _Parent("customer_id", "customers"),
    )),
    "supplier_payables": _Rule(parents=(
        _Parent("invoice_id", "invoices"), _Parent("supplier_id", "suppliers"),
    )),
    "invoice_returns": _Rule(parents=(_Parent("invoice_id", "invoices"),)),
    "invoice_return_items": _Rule(parents=(
        _Parent("return_id", "invoice_returns"), _Parent("invoice_item_id", "invoice_items"),
        _Parent("product_id", "products"),
    )),
    "purchase_returns": _Rule(parents=(
        _Parent("invoice_id", "invoices"), _Parent("supplier_id", "suppliers"),
        _Parent("purchase_order_id", "purchase_orders"),
    )),
    "purchase_return_items": _Rule(parents=(
        _Parent("purchase_return_id", "purchase_returns"),
        _Parent("invoice_item_id", "invoice_items"), _Parent("product_id", "products"),
    )),
    "products": _Rule(("branch_id",)),
    "product_units": _Rule(parents=(_Parent("product_id", "products"),)),
    "product_barcodes": _Rule(parents=(
        _Parent("product_id", "products"), _Parent("unit_id", "product_units"),
    )),
    "product_prices": _Rule(parents=(_Parent("product_id", "products"),)),
    "expiry_notifications": _Rule(parents=(_Parent("product_id", "products"),), archive=False),
    "branch_stock": _Rule(("branch_id",), (_Parent("product_id", "products"),)),
    "inventory_lots": _Rule(("branch_id",), (
        _Parent("product_id", "products"), _Parent("supplier_id", "suppliers"),
        _Parent("purchase_invoice_id", "invoices"), _Parent("invoice_item_id", "invoice_items"),
        _Parent("unit_id", "product_units"),
    )),
    "inventory_lot_consumptions": _Rule(parents=(
        _Parent("lot_id", "inventory_lots"), _Parent("invoice_item_id", "invoice_items"),
    )),
    "inventory_movements": _Rule(("branch_id",), (
        _Parent("product_id", "products"),
        _Parent("reference_id", "invoices", ("reference_type", "invoice")),
        _Parent("reference_id", "invoice_returns", ("reference_type", "invoice_return")),
        _Parent("reference_id", "purchase_returns", ("reference_type", "purchase_return")),
        _Parent("reference_id", "reconciliations", ("reference_type", "reconciliation")),
        _Parent("reference_id", "branch_transfers", ("reference_type", "branch_transfer")),
    )),
    "branch_transfers": _Rule(("from_branch_id", "to_branch_id"), (
        _Parent("from_account_id", "bank_accounts"), _Parent("to_account_id", "bank_accounts"),
    ), archive=False),
    "branch_transfer_items": _Rule(parents=(
        _Parent("transfer_id", "branch_transfers"),
        _Parent("from_product_id", "products"), _Parent("to_product_id", "products"),
        _Parent("from_unit_id", "product_units"), _Parent("to_unit_id", "product_units"),
    ), archive=False),
    "branch_transfer_lot_moves": _Rule(parents=(
        _Parent("transfer_item_id", "branch_transfer_items"),
        _Parent("source_lot_id", "inventory_lots"), _Parent("target_lot_id", "inventory_lots"),
    ), archive=False),
    "reconciliations": _Rule(("branch_id",), archive=False),
    "org_invoice_designs": _Rule(("branch_id",), archive=False),
    "journal_entries": _Rule(("branch_id",), (
        _Parent("reference_id", "invoices", ("reference_type", "invoice")),
    ), archive=False),
    "journal_entry_lines": _Rule(parents=(_Parent("journal_entry_id", "journal_entries"),),
                                 archive=False),
    "merchant_links": _Rule(parents=_party, archive=False),
    "settlement_requests": _Rule(parents=(
        *_party, _Parent("link_id", "merchant_links"), _Parent("payment_id", "payments"),
    ), archive=False),
    "employee_salary_payments": _Rule(("branch_id",), archive=False),
    "employee_debts": _Rule(("branch_id",), archive=False),
    # Earlier Business documents also own inventory/party references, even
    # without a branch column. They are fenced, not imported as invoices.
    "sales_orders": _Rule(parents=(_Parent("customer_id", "customers"),), archive=False),
    "sales_order_items": _Rule(parents=(
        _Parent("sales_order_id", "sales_orders"), _Parent("product_id", "products"),
    ), archive=False),
    "sales_returns": _Rule(parents=(
        _Parent("sales_order_id", "sales_orders"), _Parent("customer_id", "customers"),
    ), archive=False),
    "sales_return_items": _Rule(parents=(
        _Parent("sales_return_id", "sales_returns"), _Parent("product_id", "products"),
    ), archive=False),
    "sales_quotes": _Rule(parents=(_Parent("customer_id", "customers"),), archive=False),
    "quote_items": _Rule(parents=(
        _Parent("quote_id", "sales_quotes"), _Parent("product_id", "products"),
    ), archive=False),
    "delivery_notes": _Rule(parents=(
        _Parent("sales_order_id", "sales_orders"), _Parent("customer_id", "customers"),
    ), archive=False),
    "delivery_note_items": _Rule(parents=(
        _Parent("delivery_note_id", "delivery_notes"), _Parent("product_id", "products"),
    ), archive=False),
    "purchase_orders": _Rule(parents=(_Parent("supplier_id", "suppliers"),), archive=False),
    "purchase_order_items": _Rule(parents=(
        _Parent("purchase_order_id", "purchase_orders"), _Parent("product_id", "products"),
    ), archive=False),
    "purchase_receipts": _Rule(parents=(
        _Parent("purchase_order_id", "purchase_orders"), _Parent("supplier_id", "suppliers"),
    ), archive=False),
    "purchase_receipt_items": _Rule(parents=(
        _Parent("purchase_receipt_id", "purchase_receipts"), _Parent("product_id", "products"),
    ), archive=False),
    "supplier_bills": _Rule(parents=(
        _Parent("purchase_order_id", "purchase_orders"), _Parent("supplier_id", "suppliers"),
    ), archive=False),
}
_locked_tables = ", ".join(f"public.{name}" for name in sorted(_rules))
_branch_function = "public.fyona_qa_business_row_branches"
_registry = "public.fyona_qa_business_cutovers"
_catalog_snapshots = "public.fyona_qa_business_catalog_snapshots"


def _fixture_socket(engine: AsyncEngine) -> str:
    url = engine.url
    socket = url.query.get("host")
    if (url.drivername != "postgresql+asyncpg" or url.host is not None
            or url.database != FIXTURE_DB or url.username != "root"
            or not isinstance(socket, str) or not SOCKET_PATH.fullmatch(socket)):
        raise CutoverRejected("A disposable Business fixture socket is required")
    return socket


async def _require_socket(conn: AsyncConnection, socket: str):
    if not await conn.scalar(text("""
        SELECT current_database() = :db
          AND inet_server_addr() IS NULL
          AND current_setting('listen_addresses') = ''
          AND current_setting('unix_socket_directories') = :socket
    """), {"socket": socket, "db": FIXTURE_DB}):
        raise CutoverRejected("The Business fixture must have no TCP listener")


def _row_branches_sql() -> str:
    cases = []
    for table, rule in _rules.items():
        direct = ", ".join(f"(row_data ->> '{column}')::uuid" for column in rule.direct)
        parts = [f"ARRAY[{direct}]::uuid[]"]
        for parent in rule.parents:
            filter_sql = ""
            if parent.discriminator:
                field, value = parent.discriminator
                filter_sql = f"AND row_data ->> '{field}' = '{value}'"
            parts.append(f"""COALESCE((
                SELECT {_branch_function}('{parent.table}', to_jsonb(p))
                FROM public.{parent.table} p
                WHERE p.id = (row_data ->> '{parent.column}')::uuid {filter_sql}
            ), ARRAY[]::uuid[])""")
        cases.append(f"WHEN '{table}' THEN RETURN array_remove({' || '.join(parts)}, NULL);")
    return f"""
        CREATE FUNCTION {_branch_function}(table_name text, row_data jsonb)
        RETURNS uuid[] LANGUAGE plpgsql VOLATILE
        SET search_path = pg_catalog, public AS $$
        BEGIN
          CASE table_name
            {' '.join(cases)}
          ELSE
            RAISE EXCEPTION 'Unknown Business fixture table';
          END CASE;
        END;
        $$
    """


async def install_fixture_guard(engine: AsyncEngine):
    """One-time installation on test tables. Never called by the application."""
    socket = _fixture_socket(engine)
    async with engine.begin() as conn:
        await _require_socket(conn, socket)
        await conn.execute(text(f"""
            CREATE TABLE {_registry} (
              branch_id uuid PRIMARY KEY,
              organization_id uuid NOT NULL,
              account_id uuid NOT NULL,
              snapshot_id uuid NOT NULL UNIQUE,
              digest text NOT NULL CHECK (length(digest) = 64),
              allow_negative boolean NOT NULL,
              imported_at timestamptz
            )
        """))
        await conn.execute(text("""
            CREATE TABLE public.fyona_qa_business_fence (
              singleton boolean PRIMARY KEY CHECK (singleton),
              generation bigint NOT NULL
            )
        """))
        await conn.execute(text("INSERT INTO public.fyona_qa_business_fence VALUES (true, 0)"))
        await conn.execute(text(_row_branches_sql()))
        # Table locks drain DML that was already executing when freeze starts.
        # The updated fence row also invalidates old Repeatable Read/Serializable
        # snapshots before any later DML can consult a stale branch registry.
        await conn.execute(text(f"""
            CREATE FUNCTION public.fyona_qa_business_write_fence()
            RETURNS trigger LANGUAGE plpgsql VOLATILE
            SET search_path = pg_catalog, public AS $$
            BEGIN
              PERFORM 1 FROM public.fyona_qa_business_fence WHERE singleton FOR SHARE;
              IF NOT FOUND THEN
                RAISE EXCEPTION 'Business cutover fence is unavailable' USING ERRCODE = '40001';
              END IF;
              IF TG_OP = 'TRUNCATE' AND EXISTS (SELECT 1 FROM {_registry}) THEN
                RAISE EXCEPTION 'Business branch is frozen' USING ERRCODE = '23514';
              END IF;
              RETURN NULL;
            END;
            $$
        """))
        await conn.execute(text(f"""
            CREATE FUNCTION public.fyona_qa_business_write_guard()
            RETURNS trigger LANGUAGE plpgsql VOLATILE
            SET search_path = pg_catalog, public AS $$
            DECLARE affected uuid[] := ARRAY[]::uuid[];
            BEGIN
              IF TG_OP <> 'INSERT' THEN
                affected := {_branch_function}(TG_TABLE_NAME, to_jsonb(OLD));
              END IF;
              IF TG_OP <> 'DELETE' THEN
                affected := affected || {_branch_function}(TG_TABLE_NAME, to_jsonb(NEW));
              END IF;
              IF EXISTS (SELECT 1 FROM {_registry} WHERE branch_id = ANY(affected)) THEN
                RAISE EXCEPTION 'Business branch is frozen' USING ERRCODE = '23514';
              END IF;
              IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
              RETURN NEW;
            END;
            $$
        """))
        for name in sorted(_rules):
            await conn.execute(text(f"""
                CREATE TRIGGER fyona_qa_business_fence
                BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.{name}
                FOR EACH STATEMENT EXECUTE FUNCTION public.fyona_qa_business_write_fence()
            """))
            await conn.execute(text(f"""
                CREATE TRIGGER fyona_qa_business_guard
                BEFORE INSERT OR UPDATE OR DELETE ON public.{name}
                FOR EACH ROW EXECUTE FUNCTION public.fyona_qa_business_write_guard()
            """))


async def _require_owner(conn: AsyncConnection, scope: CutoverScope):
    slug = await conn.scalar(text("""
        SELECT org.slug FROM public.branches b
        JOIN public.organizations org ON org.id = b.organization_id
        JOIN public.users u ON u.organization_id = org.id
        WHERE b.id = :branch_id AND org.id = :organization_id AND u.id = :account_id
          AND b.is_active AND NOT b.is_default AND NOT b.is_archived
          AND u.role = 'owner' AND u.status = 'active' AND org.is_active
          AND u.email = org.slug || '@example.test'
    """), scope.params())
    if slug is None or not re.fullmatch(r"ledger-cutover-[a-f0-9]{32}", slug):
        raise CutoverRejected("Expected the synthetic owner of a non-default fixture branch")


def _scaled(value, factor: int) -> int:
    if not isinstance(value, (Decimal, int)) or isinstance(value, bool):
        raise CutoverRejected("Missing exact numerical source value")
    scaled = Decimal(value) * factor
    if not scaled.is_finite() or scaled != scaled.to_integral_value() or abs(scaled) > 999_999_999_999_999:
        raise CutoverRejected("Unsupported numerical precision in fixture")
    return int(scaled)


def _encode(value):
    if isinstance(value, Decimal):
        return format(value, "f")
    raise TypeError(type(value).__name__)


async def _catalogue(
    conn: AsyncConnection, scope: CutoverScope, products: list[dict],
    supplied: _CatalogImages | None,
):
    """Branch-owned products plus only the shared categories they reference.

    The caller can attach already authorized bytes. Never open or fetch the
    stored reference: old references aren't proof of file access or content.
    """
    refs = {UUID(row["category_id"]) for row in products if row["category_id"] is not None}
    cats = [
        json.loads(row)
        for row in (await conn.scalars(text("""
            SELECT jsonb_build_object(
                'id', c.id, 'organization_id', c.organization_id, 'name', c.name,
                'is_active', c.is_active, 'image', c.image
            )::text FROM public.product_categories c
            WHERE c.organization_id = :organization_id
              AND c.id = ANY(CAST(:refs AS uuid[])) AND NOT c.is_deleted
            ORDER BY c.id
        """), {"organization_id": scope.organization_id, "refs": sorted(refs)})).all()
    ] if refs else []
    if {UUID(row["id"]) for row in cats} != refs:
        raise CutoverRejected("Unresolved shared product category")
    settings = (await conn.scalars(text("""
        SELECT jsonb_build_object(
            'id', w.id, 'organization_id', w.organization_id,
            'expiry_warn_days', w.expiry_warn_days, 'expiry_enabled', w.expiry_enabled
        )::text FROM public.warehouse_settings w
        WHERE w.organization_id = :organization_id
    """), scope.params())).all()
    settings = [json.loads(row) for row in settings]
    for row in settings:
        if (type(row["expiry_warn_days"]) is not int or not 1 <= row["expiry_warn_days"] <= 365
                or type(row["expiry_enabled"]) is not bool):
            raise CutoverRejected("Invalid recorded warehouse expiry settings")

    remaining = dict(supplied or {})
    total = 0
    if remaining:
        from PIL import Image

        for table, rows in (("products", products), ("product_categories", cats)):
            for row in rows:
                key = (table, UUID(row["id"]))
                if key not in remaining:
                    continue
                item = remaining.pop(key)
                if (not isinstance(item, CatalogImage) or not item.reference
                        or item.reference != row["image"]
                        or not isinstance(item.data, bytes)
                        or not 0 < len(item.data) <= _image_limit
                        or sha256(item.data).hexdigest() != item.digest):
                    raise CutoverRejected("Image does not match the captured inventory row")
                total += len(item.data)
                if total > _catalog_images_limit:
                    raise CutoverRejected("Inventory image bundle is too large")
                try:
                    with Image.open(BytesIO(item.data)) as decoded:
                        if (decoded.format not in {"JPEG", "PNG", "WEBP"}
                                or max(decoded.size) > 4096
                                or getattr(decoded, "n_frames", 1) != 1):
                            raise ValueError("Unsupported image")
                        decoded.verify()
                    # verify() alone does not decode all JPEG/WebP data.
                    with Image.open(BytesIO(item.data)) as decoded:
                        decoded.load()
                except (OSError, SyntaxError, ValueError, Image.DecompressionBombError) as exc:
                    raise CutoverRejected("Unusable supplied inventory photo") from exc
                row["device_image"] = _image_prefix + b64encode(item.data).decode("ascii")
                row["device_image_sha256"] = item.digest
    if remaining:
        raise CutoverRejected("Image outside the captured inventory scope")
    if cats or settings or total:
        return {"product_categories": cats, "warehouse_settings": settings}
    return {}


async def _snapshot(
    conn: AsyncConnection, scope: CutoverScope, snapshot_id: UUID,
    allow_negative: bool, *, capture_catalog: bool, images: _CatalogImages | None = None,
):
    tables = {}
    for name, rule in sorted(_rules.items()):
        result = await conn.execute(text(f"""
            SELECT to_jsonb(src)::text AS body, ownership.ids
            FROM public.{name} src
            CROSS JOIN LATERAL (
              SELECT {_branch_function}('{name}', to_jsonb(src)) AS ids
            ) ownership
            WHERE :branch_id = ANY(ownership.ids)
            ORDER BY src.id
        """), {"branch_id": scope.branch_id})
        rows = []
        for body, branches in result:
            if not rule.archive or set(branches) != {scope.branch_id}:
                raise CutoverRejected(f"Unsupported or cross-branch rows: {name}")
            row = json.loads(body, parse_float=Decimal)
            if row.get("organization_id", str(scope.organization_id)) != str(scope.organization_id):
                raise CutoverRejected(f"Organization mismatch: {name}")
            rows.append(row)
        if rule.archive:
            tables[name] = rows

    # A shared, null-branch catalogue row cannot safely start a private
    # branch ledger. Reject missing/ambiguous parent ownership rather than
    # pulling another branch's records into this snapshot.
    keys = {table: {row["id"] for row in rows} for table, rows in tables.items()}
    for table, rows in tables.items():
        if table == "bank_accounts" and any(row["bank_group_key"] is not None for row in rows):
            raise CutoverRejected("Unsupported confirmed bank link")
        for parent in _rules[table].parents:
            for row in rows:
                if parent.discriminator:
                    field, value = parent.discriminator
                    if row.get(field) != value:
                        continue
                ref = row.get(parent.column)
                if ref is not None and ref not in keys.get(parent.table, ()):
                    raise CutoverRejected(f"Unresolved branch ownership: {table}.{parent.column}")

    # Independent reads of the authoritative values, not totals emitted from
    # the archived JSON. The receiving DB checks these by ID after insert.
    params = scope.params()
    accounts = (await conn.execute(text("""
        SELECT id, currency, balance FROM public.bank_accounts
        WHERE branch_id = :branch_id AND organization_id = :organization_id ORDER BY id
    """), params)).all()
    stock = (await conn.execute(text("""
        SELECT product_id, quantity, avg_cost FROM public.branch_stock
        WHERE branch_id = :branch_id AND organization_id = :organization_id ORDER BY product_id
    """), params)).all()
    # Old opening debts can inherit their branch from the party. Any debt
    # with unresolved ownership is not promoted into the operational ledger.
    invoices = (await conn.execute(text("""
        SELECT i.id, i.currency, i.total, i.paid_amount, i.balance
        FROM public.invoices i
        LEFT JOIN public.customers c ON c.id = i.customer_id
        LEFT JOIN public.suppliers s ON s.id = i.supplier_id
        WHERE i.organization_id = :organization_id
          AND (i.branch_id = :branch_id OR c.branch_id = :branch_id OR s.branch_id = :branch_id)
        ORDER BY i.id
    """), params)).all()
    if ({str(r.id) for r in invoices} != keys["invoices"] or
            {str(r.id) for r in accounts} != keys["bank_accounts"] or
            len(stock) != len(keys["branch_stock"])):
        raise CutoverRejected("Unreconciled source rows")
    catalogue = await _catalogue(conn, scope, tables["products"], images) if capture_catalog else {}
    if catalogue:
        tables["branches"][0]["device_catalogue"] = True
    body = json.dumps({
        "version": 3 if catalogue else 2,
        "snapshot_id": str(snapshot_id),
        "server": FIXTURE_SERVER,
        "allow_negative": allow_negative,
        **{k: str(v) for k, v in params.items()},
        "tables": {**tables, **catalogue},
        "controls": {
            "accounts": [[str(k), c, _scaled(b, 100)] for k, c, b in accounts],
            "invoices": [[str(k), c, _scaled(t, 100), _scaled(p, 100), _scaled(b, 100)]
                         for k, c, t, p, b in invoices],
            "stock": [[str(k), _scaled(q, 1000), _scaled(a, 10_000)] for k, q, a in stock],
        },
    }, default=_encode, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return CutoverSnapshot(snapshot_id, sha256(body).hexdigest(), body)


async def freeze_fixture_branch(
    engine: AsyncEngine, scope: CutoverScope, *,
    inventory_images: _CatalogImages | None = None,
) -> CutoverSnapshot:
    """Drain writers, freeze and verify the scope in one committed transaction.

    No rows in the legacy ledger are rewritten or deleted. A retry reuses
    the frozen bytes (or verifies reconstruction of v2) and never replaces them.
    """
    socket = _fixture_socket(engine)
    async with engine.begin() as conn:
        await _require_socket(conn, socket)
        if await conn.get_isolation_level() != "READ COMMITTED":
            raise CutoverRejected("The freeze must see the writers it drains")
        await conn.execute(text("SET LOCAL lock_timeout = '5s'"))
        await conn.execute(text("SET LOCAL TIME ZONE 'UTC'"))
        await conn.execute(text(f"LOCK TABLE {_locked_tables} IN SHARE ROW EXCLUSIVE MODE"))
        await _require_owner(conn, scope)
        current = (await conn.execute(text(f"""
            SELECT organization_id, account_id, snapshot_id, digest, allow_negative FROM {_registry}
            WHERE branch_id = :branch_id
        """), scope.params())).one_or_none()
        if current is not None:
            if (current.organization_id, current.account_id) != (scope.organization_id, scope.account_id):
                raise CutoverRejected("Branch was frozen by a different scope")
            # v3 retains the exact handoff bytes so a lost response doesn't
            # require another export or re-read mutable shared catalog data.
            body = None
            if await conn.scalar(text("SELECT to_regclass(:name)"), {"name": _catalog_snapshots}):
                body = await conn.scalar(text(f"""
                    SELECT body FROM {_catalog_snapshots} WHERE snapshot_id = :id
                """), {"id": current.snapshot_id})
            if body is not None:
                if sha256(body).hexdigest() != current.digest:
                    raise CutoverRejected("Frozen snapshot drifted")
                if inventory_images:
                    _require_same_photos(body, inventory_images)
                return CutoverSnapshot(current.snapshot_id, current.digest, body)
            if inventory_images:
                raise CutoverRejected("Cannot attach photos to an already frozen snapshot")
            # v2 did not capture org metadata. Its original bytes and receipt
            # must still match after the source gains a catalogue or settings.
            snapshot = await _snapshot(conn, scope, current.snapshot_id, current.allow_negative,
                                       capture_catalog=False)
            if snapshot.digest != current.digest:
                raise CutoverRejected("Frozen snapshot drifted")
            return snapshot
        # The connected money service reads this organization-wide setting.
        # Capture it at the fence, but do not freeze settings for sibling
        # branches. A retry of this branch uses its originally fenced value.
        await conn.execute(text("LOCK TABLE public.business_project_settings IN SHARE MODE"))
        encoded = await conn.scalar(text("""
            SELECT settings FROM public.business_project_settings
            WHERE organization_id = :organization_id
        """), scope.params())
        try:
            settings = json.loads(encoded) if encoded is not None else {}
        except ValueError as exc:
            raise CutoverRejected("Unsupported organization overdraft policy") from exc
        if not isinstance(settings, dict) or not isinstance(settings.get("allow_negative", False), bool):
            raise CutoverRejected("Unsupported organization overdraft policy")
        await conn.execute(text("""
            LOCK TABLE public.product_categories, public.warehouse_settings IN SHARE MODE
        """))
        snapshot = await _snapshot(conn, scope, uuid4(), settings.get("allow_negative", False),
                                   capture_catalog=True, images=inventory_images)
        await conn.execute(text("""
            UPDATE public.fyona_qa_business_fence SET generation = generation + 1 WHERE singleton
        """))
        await conn.execute(text(f"""
            INSERT INTO {_registry} (branch_id, organization_id, account_id, snapshot_id,
                                     digest, allow_negative)
            VALUES (:branch_id, :organization_id, :account_id, :snapshot_id,
                    :digest, :allow_negative)
        """), {**scope.params(), "snapshot_id": snapshot.id, "digest": snapshot.digest,
               "allow_negative": settings.get("allow_negative", False)})
        if json.loads(snapshot.body)["version"] == 3:
            # Only in this disposable socket DB, including fixtures that
            # already installed the v2 guard. The old registry stays intact.
            await conn.execute(text(f"""
                CREATE TABLE IF NOT EXISTS {_catalog_snapshots} (
                    snapshot_id uuid PRIMARY KEY REFERENCES {_registry}(snapshot_id),
                    body bytea NOT NULL
                )
            """))
            await conn.execute(text(f"""
                INSERT INTO {_catalog_snapshots} (snapshot_id, body) VALUES (:id, :body)
            """), {"id": snapshot.id, "body": snapshot.body})
    return snapshot


def _require_same_photos(body: bytes, supplied: _CatalogImages):
    tables = json.loads(body)["tables"]
    captured = {
        (table, UUID(row["id"])): row for table in ("products", "product_categories")
        for row in tables[table] if "device_image" in row
    }
    for key, image in supplied.items():
        row = captured.get(key)
        if row is None:
            raise CutoverRejected("Cannot attach photos to an already frozen snapshot")
        if (not isinstance(image, CatalogImage) or image.reference != row["image"]
                or image.digest != row["device_image_sha256"]
                or image.data != b64decode(row["device_image"][len(_image_prefix):])):
            raise CutoverRejected("Cannot change photos in an already frozen snapshot")


async def acknowledge_fixture_import(
    engine: AsyncEngine, scope: CutoverScope, snapshot_id: UUID, digest: str,
):
    """Records only the exact device receipt; never returns a ledger claim."""
    socket = _fixture_socket(engine)
    async with engine.begin() as conn:
        await _require_socket(conn, socket)
        await _require_owner(conn, scope)
        accepted = await conn.scalar(text(f"""
            UPDATE {_registry} SET imported_at = COALESCE(imported_at, clock_timestamp())
            WHERE branch_id = :branch_id AND organization_id = :organization_id
              AND account_id = :account_id AND snapshot_id = :snapshot_id AND digest = :digest
            RETURNING imported_at
        """), {**scope.params(), "snapshot_id": snapshot_id, "digest": digest})
        if accepted is None:
            raise CutoverRejected("No matching frozen Business snapshot")
        return accepted
