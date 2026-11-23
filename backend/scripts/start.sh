#!/bin/bash
# ── FYONA ERP — Container Entry Point ──
# This runs inside the Docker container.
# Runs migrations then starts the API server.

set -e

echo "Starting FYONA API..."

# Run migrations
alembic upgrade head

# Start server
exec uvicorn app.main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 2 \
    --loop uvloop \
    --http httptools \
    --proxy-headers \
    --forwarded-allow-ips 127.0.0.1
