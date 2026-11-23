"""The cleanup must never remove connected Business or Personal records."""

import importlib.util
import os
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url


def test_retire_only_business_replica_objects():
    raw = os.getenv("FYONA_TEST_POSTGRES_URL")
    if not raw:
        pytest.skip("An explicit local PostgreSQL test URL is required")
    url = make_url(raw)
    if url.host not in ("127.0.0.1", "::1", "localhost"):
        pytest.fail("This fixture only accepts local PostgreSQL")
    path = Path(__file__).resolve().parents[2] / "migrations/versions/121_retire_business_offline_storage.py"
    spec = importlib.util.spec_from_file_location("revision_121", path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = create_engine(url.set(drivername="postgresql+psycopg2"))
    schema = "retire_test_" + uuid4().hex
    try:
        with engine.connect() as db, db.begin() as transaction:
            db.exec_driver_sql(f"CREATE SCHEMA {schema}")
            db.exec_driver_sql(f"SET LOCAL search_path TO {schema}")
            for table in ("customers", "personal_transactions", "cheques", "branch_transfer_lot_moves"):
                db.exec_driver_sql(f"CREATE TABLE {table} (id integer PRIMARY KEY)")
                db.exec_driver_sql(f"INSERT INTO {table} VALUES (1)")
            db.exec_driver_sql("CREATE TABLE business_sync_heads (id integer PRIMARY KEY)")
            db.exec_driver_sql("CREATE TABLE business_sync_changes (id integer REFERENCES business_sync_heads)")
            db.exec_driver_sql("CREATE TABLE business_sync_unrelated (id integer)")
            db.exec_driver_sql("""
                CREATE FUNCTION business_sync_example() RETURNS trigger
                LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$
            """)
            db.exec_driver_sql("""
                CREATE TRIGGER business_sync_example BEFORE INSERT ON customers
                FOR EACH ROW EXECUTE FUNCTION business_sync_example()
            """)
            with Operations.context(MigrationContext.configure(db)):
                migration.upgrade()
                migration.upgrade()
            for table in ("customers", "personal_transactions", "cheques", "branch_transfer_lot_moves"):
                assert db.exec_driver_sql(f"SELECT id FROM {table}").scalar_one() == 1
            assert db.exec_driver_sql("SELECT to_regclass('business_sync_unrelated')").scalar_one()
            assert not db.exec_driver_sql("SELECT to_regclass('business_sync_heads')").scalar_one()
            assert not db.exec_driver_sql("SELECT to_regclass('business_sync_changes')").scalar_one()
            assert not db.exec_driver_sql("SELECT to_regprocedure('business_sync_example()')").scalar_one()
            assert db.exec_driver_sql("INSERT INTO customers VALUES (2)").rowcount == 1
            transaction.rollback()
    finally:
        engine.dispose()
