#!/usr/bin/env bash
# Run backend unit tests against a throw-away PostgreSQL (unix socket only).
set -euo pipefail
umask 077
export TMPDIR=/tmp/opencode
mkdir -p /tmp/opencode
work="$(cd "$(dirname "$0")/../.." && pwd)"
pg=/usr/lib/postgresql/18/bin
py=/root/fyona-erp/backend/.venv/bin/python
cut=$(mktemp -d /tmp/opencode/fyona-cutover-XXXXXXXX)
cleanup() {
  if test -e "$cut/data/postmaster.pid"; then
    runuser -u postgres -- "$pg/pg_ctl" -D "$cut/data" -m fast -w stop >/dev/null || true
  fi
  [[ "$cut" == /tmp/opencode/fyona-cutover-* ]] && rm -r -- "$cut"
}
trap cleanup EXIT
chmod 0711 "$cut"
install -d -o postgres -g postgres -m 0700 "$cut/data" "$cut/socket"
runuser -u postgres -- "$pg/initdb" -D "$cut/data" -U root --auth-local=trust --auth-host=reject > "$cut/init.log" 2>&1
runuser -u postgres -- "$pg/pg_ctl" -D "$cut/data" -l "$cut/data/server.log" -o "-c listen_addresses='' -k $cut/socket -c unix_socket_permissions=0700" -w start > "$cut/start.log" 2>&1
"$pg/createdb" -h "$cut/socket" -U root fyona_cutover_fixture
cd "$work"
env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR=/tmp/opencode PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$work/backend" \
  JWT_SECRET_KEY=synthetic-test-only-key-6193 DATABASE_URL="postgresql+asyncpg://root@/fyona_cutover_fixture?host=$cut/socket" \
  REDIS_URL="unix://$cut/socket/test-only-redis.sock" CELERY_BROKER_URL=memory:// CELERY_RESULT_BACKEND=cache+memory:// \
  FYONA_TEST_CUTOVER_SOCKET="$cut/socket" \
  "$py" -m pytest -c backend/pytest.ini -q -p no:cacheprovider "$@"
