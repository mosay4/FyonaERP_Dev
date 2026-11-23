"""Migration-chain consistency (drift detection) without touching a database.

Regression for audit finding: `alembic current` = 019 while `alembic heads` =
020, so production was silently missing the schema changes in 020 while
`init_db` (Base.metadata.create_all) masked the drift at startup.
"""

from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory

BACKEND = Path(__file__).resolve().parents[2]


def _scripts() -> ScriptDirectory:
    # Build the config explicitly (no alembic.ini load) to avoid the
    # prepend_sys_path deprecation warning and keep CWD-independent paths.
    cfg = Config()
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("prepend_sys_path", str(BACKEND))
    cfg.set_main_option("path_separator", "os")
    return ScriptDirectory.from_config(cfg)


def _head_revision() -> str:
    """Return the highest migration revision number as a zero-padded string."""
    versions_dir = BACKEND / "migrations" / "versions"
    revisions = []
    for path in versions_dir.glob("*.py"):
        if path.name.startswith("__"):
            continue
        prefix = path.name.split("_", 1)[0]
        if prefix.isdigit():
            revisions.append(int(prefix))
    return str(max(revisions)).zfill(3)


def test_migration_chain_has_single_linear_head():
    """The chain has exactly one head (no branch points)."""
    heads = _scripts().get_heads()
    assert len(heads) == 1, f"multiple heads found: {heads}"


def test_no_migration_is_newer_than_head():
    """No version file exists beyond the current head revision."""
    expected = int(_head_revision())
    versions_dir = BACKEND / "migrations" / "versions"
    for path in versions_dir.glob("*.py"):
        if path.name.startswith("__"):
            continue
        prefix = path.name.split("_", 1)[0]
        assert prefix.isdigit(), f"non-numeric revision prefix: {path.name}"
        assert int(prefix) <= expected, f"migration newer than head: {path.name}"


def test_migration_020_upgrade_is_additive_only():
    """020 only adds a nullable column — no table drops / data-loss in upgrade.

    This is what makes applying 020 safe in production (still requires a fresh
    backup per policy, but it cannot destroy data).
    """
    src = (
        BACKEND / "migrations" / "versions" / "020_add_suggestion_admin_read_at.py"
    ).read_text(encoding="utf-8")
    upgrade = src[src.index("def upgrade()"): src.index("def downgrade()")]
    assert "op.add_column" in upgrade
    assert "op.drop_column" not in upgrade
    assert "op.drop_table" not in upgrade
    assert "nullable=True" in upgrade


def test_migration_021_upgrade_is_additive_only():
    """021 only adds nullable columns + a partial unique index.

    Like 020 it must not drop anything in upgrade so applying it to production
    cannot destroy data.
    """
    src = (
        BACKEND / "migrations" / "versions" / "021_phone_validation_columns.py"
    ).read_text(encoding="utf-8")
    upgrade = src[src.index("def upgrade()"): src.index("def downgrade()")]
    assert "op.add_column" in upgrade
    assert "op.create_index" in upgrade
    assert "op.drop_column" not in upgrade
    assert "op.drop_table" not in upgrade
    assert "op.drop_index" not in upgrade
    assert "nullable" in upgrade


def test_migration_022_upgrade_is_additive_only():
    """022 only adds nullable columns using idempotent checks.

    Migration 022 extends platform_bank_accounts with payment method fields.
    All columns are nullable and the upgrade uses _column_exists() guards,
    making it safe for production (cannot destroy data).
    """
    src = (
        BACKEND / "migrations" / "versions" / "022_extend_bank_accounts.py"
    ).read_text(encoding="utf-8")
    upgrade = src[src.index("def upgrade()"): ]
    assert "op.add_column" in upgrade
    assert "op.drop_column" not in src
    assert "op.drop_table" not in src
    assert "_column_exists" in src  # idempotent guard


def test_migration_023_upgrade_is_additive_only():
    """023 adds a nullable column + unique constraint for fanout idempotency.

    All changes are additive — no drops, no data loss.
    """
    src = (
        BACKEND / "migrations" / "versions" / "023_fanout_idempotency.py"
    ).read_text(encoding="utf-8")
    upgrade = src[src.index("def upgrade()"): ]
    assert "op.add_column" in upgrade
    assert "op.create_unique_constraint" in upgrade
    assert "op.drop_column" not in src
    assert "op.drop_table" not in src
    assert "op.drop_index" not in src
    assert "op.drop_constraint" not in src
    assert "_column_exists" in src
    assert "_constraint_exists" in src
