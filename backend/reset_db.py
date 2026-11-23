"""Reset the FYONA ERP database to an empty state.

Drops the application database schema (all tables, sequences, types) and
recreates it cleanly, so the app starts fresh for testing.

NOTE: This does NOT drop the database itself — it drops every table in the
`public` schema, then the backend's `init_db()` (create_all) regenerates the
full schema on the next boot. Alembic migrations stay as documentation; the
runtime uses create_all as the single source of truth for the schema.
"""
import asyncio
import os
import sys

import asyncpg

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://fyona:fyona@localhost:5432/fyona_erp",
)

# asyncpg uses the same URL scheme minus "+asyncpg".
DSN = DATABASE_URL.replace("+asyncpg", "")


async def main() -> None:
    print(f"Resetting database: {DSN.split('@')[-1]}")
    conn = await asyncpg.connect(DSN)
    try:
        # Drop all tables (cascading), indexes, sequences, and types in the
        # public schema. This is schema-only — the database itself stays.
        tables = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        )
        table_names = [t["tablename"] for t in tables]
        if table_names:
            quoted = ", ".join(f'"{t}"' for t in table_names)
            # Drop with CASCADE to remove FK constraints in dependency order.
            await conn.execute(f'DROP TABLE IF EXISTS {quoted} CASCADE')
            print(f"Dropped {len(table_names)} tables: {', '.join(table_names[:10])}{'...' if len(table_names) > 10 else ''}")

        # Also drop any sequences / custom types to fully reset schema state.
        seqs = await conn.fetch(
            "SELECT sequence_name FROM information_schema.sequences"
            " WHERE sequence_schema = 'public'"
        )
        for seq in seqs:
            try:
                await conn.execute(f'DROP SEQUENCE IF EXISTS "{seq["sequence_name"]}" CASCADE')
            except Exception:  # noqa: BLE001
                pass

        types = await conn.fetch(
            "SELECT typname FROM pg_type"
            " WHERE typnamespace = 'public'::regnamespace"
            " AND typtype = 'e'"
        )
        for t in types:
            try:
                await conn.execute(f'DROP TYPE IF EXISTS "{t["typname"]}" CASCADE')
            except Exception:  # noqa: BLE001
                pass

        print("Schema reset complete.")
    finally:
        await conn.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)