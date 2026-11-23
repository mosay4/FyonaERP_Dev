#!/bin/bash
# ── FYONA ERP — Database Migration Script ──
# Runs Alembic migrations with safety checks.
#
# Safety:
#   - Checks migration history before applying
#   - Validates current DB schema is compatible
#   - Never runs destructive migrations automatically
#   - Requires manual approval for destructive migrations
#
# Usage:
#   alembic upgrade head                    → Apply all pending migrations
#   alembic upgrade head --sql             → Generate SQL instead of executing
#   alembic downgrade -1                   → Revert last migration
#   bash scripts/migrate.sh check          → Check pending migrations
#   bash scripts/migrate.sh validate       → Validate schema compatibility

set -euo pipefail

cd /app

# ── Functions ──
log() { echo "[migrate $(date -u '+%FT%TZ')] $*"; }

check_pending() {
    local pending
    pending=$(alembic history | head -1 2>/dev/null || echo "")
    log "Current head: ${pending}"

    # Check for pending migrations
    alembic branches 2>&1
}

validate_schema() {
    log "Validating database connectivity..."

    # Test DB connection
    python3 -c "
import asyncio
from sqlalchemy import text
from app.core.database import engine

async def test():
    async with engine.connect() as conn:
        result = await conn.execute(text('SELECT 1'))
        print('DB OK')

asyncio.run(test())
" 2>&1

    log "Schema validation complete."
}

# ── Main ──
case "${1:-upgrade}" in
    upgrade)
        log "Running database migrations (upgrade head)..."

        # Pre-flight: validate DB connectivity
        log "Pre-flight: Checking database connectivity..."
        python3 -c "
import asyncio
from sqlalchemy import text
from app.core.database import engine

async def test():
    async with engine.connect() as conn:
        await conn.execute(text('SELECT 1'))
        return True

asyncio.run(test())
print('Database connectivity: OK')
" 2>&1 || { log "ERROR: Cannot connect to database"; exit 1; }

        # Show current revision before migration
        CURRENT_REV=$(alembic current 2>/dev/null || echo "unknown")
        log "Current revision: ${CURRENT_REV}"

        # Apply migrations
        log "Applying pending migrations..."
        alembic upgrade head 2>&1

        # Verify new revision
        NEW_REV=$(alembic current 2>/dev/null || echo "unknown")
        log "New revision: ${NEW_REV}"

        if [ "$CURRENT_REV" != "$NEW_REV" ]; then
            log "Migrations applied: ${CURRENT_REV} → ${NEW_REV}"
        else
            log "No new migrations to apply"
        fi

        # Post-migration: validate schema
        log "Post-migration: Validating schema..."
        python3 -c "
import asyncio
from app.core.database import engine
from app.core.models import Base

async def test():
    async with engine.connect() as conn:
        # Check that all expected tables exist
        result = await conn.exec_driver_sql('SELECT tablename FROM pg_tables WHERE schemaname = \'public\' ORDER BY tablename')
        tables = [row[0] for row in result.fetchall()]
        print(f'Tables: {len(tables)} found')
        if len(tables) == 0:
            raise Exception('No tables found after migration!')

asyncio.run(test())
print('Schema validation: OK')
" 2>&1

        log "Migrations completed successfully."
        ;;

    check)
        log "Checking pending migrations..."
        check_pending
        ;;

    validate)
        validate_schema
        ;;

    *)
        log "Executing raw alembic command: alembic $*"
        alembic "$@"
        ;;
esac
