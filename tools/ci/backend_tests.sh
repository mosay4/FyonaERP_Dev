#!/usr/bin/env bash
# CI: backend unit tests against a throw-away PostgreSQL (unix socket only).
# Runs as an unprivileged user (GitHub-hosted runner).
set -euo pipefail
pg=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
mkdir -p /tmp/opencode
cut=$(mktemp -d /tmp/opencode/fyona-cutover-XXXXXXXX)
trap '"$pg/pg_ctl" -D "$cut/data" -m fast -w stop >/dev/null 2>&1 || true' EXIT
mkdir -p "$cut/socket"
"$pg/initdb" -D "$cut/data" -U root --auth-local=trust --auth-host=reject > "$cut/init.log"
"$pg/pg_ctl" -D "$cut/data" -l "$cut/server.log" \
  -o "-c listen_addresses='' -k $cut/socket -c unix_socket_permissions=0700" -w start
"$pg/createdb" -h "$cut/socket" -U root fyona_cutover_fixture
export PYTHONPATH="$PWD/backend" JWT_SECRET_KEY=ci-only-not-a-secret-key-32-chars \
  DATABASE_URL="postgresql+asyncpg://root@/fyona_cutover_fixture?host=$cut/socket" \
  REDIS_URL="unix://$cut/socket/none.sock" CELERY_BROKER_URL=memory:// \
  CELERY_RESULT_BACKEND=cache+memory:// FYONA_TEST_CUTOVER_SOCKET="$cut/socket" \
  ALLOWED_HOSTS='["127.0.0.1","testserver","test","localhost"]'
python -m pytest -c backend/pytest.ini -q -p no:cacheprovider "$@"
