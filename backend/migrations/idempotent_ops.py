"""Fresh-database-safe DDL helpers for Alembic migrations.

Migration 025 runs ``Base.metadata.create_all(checkfirst=True)`` (it must run
before 015), which on a FRESH database creates every modern table with its
CURRENT columns. Any later migration that adds a column/table/index that the
current models already define must therefore be idempotent, while still
applying the change on older databases that lack it (e.g. production was
created before those columns existed).

These helpers are intentionally tiny and only skip when the object already
exists; they never alter the intended effect on an older schema.
"""
from typing import Iterable, Sequence

import sqlalchemy as sa
from alembic import op


def _inspector():
    return sa.inspect(op.get_bind())


def add_column_if_missing(table: str, column: sa.Column) -> None:
    existing = {c["name"] for c in _inspector().get_columns(table)}
    if column.name not in existing:
        op.add_column(table, column)


def create_table_if_missing(table_name: str, *args, **kwargs) -> None:
    existing = set(_inspector().get_table_names())
    if table_name not in existing:
        op.create_table(table_name, *args, **kwargs)


def create_index_if_missing(
    index_name: str,
    table_name: str,
    columns: Sequence,
    **kwargs,
) -> None:
    existing = {i["name"] for i in _inspector().get_indexes(table_name)}
    if index_name not in existing:
        op.create_index(index_name, table_name, columns, **kwargs)


def create_unique_constraint_if_missing(
    constraint_name: str,
    table_name: str,
    columns: Iterable[str],
    **kwargs,
) -> None:
    existing = {
        c.get("name") for c in _inspector().get_unique_constraints(table_name)
    }
    if constraint_name not in existing:
        op.create_unique_constraint(constraint_name, table_name, list(columns), **kwargs)


def create_foreign_key_if_missing(
    constraint_name: str,
    source_table: str,
    referent_table: str,
    local_cols: Iterable[str],
    remote_cols: Iterable[str],
    **kwargs,
) -> None:
    existing = {
        c.get("name") for c in _inspector().get_foreign_keys(source_table)
    }
    if constraint_name not in existing:
        op.create_foreign_key(
            constraint_name,
            source_table,
            referent_table,
            list(local_cols),
            list(remote_cols),
            **kwargs,
        )