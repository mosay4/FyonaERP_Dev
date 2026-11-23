set -euo pipefail
umask 077
export TMPDIR=/tmp/opencode
work="$PWD"
proof="$work/../verification/business-arbitration-continuation"
pg=/usr/lib/postgresql/18/bin
py=/root/fyona-erp/backend/.venv/bin/python
cut=$(mktemp -d /tmp/opencode/fyona-cutover-XXXXXXXX)
cash=$(mktemp -d /tmp/opencode/fyona-cash-XXXXXXXX)
cleanup() {
  for area in "$cut" "$cash"; do
    if test -e "$area/data/postmaster.pid"; then
      runuser -u postgres -- "$pg/pg_ctl" -D "$area/data" -m fast -w stop >/dev/null || continue
    fi
    if [[ "$area" == /tmp/opencode/fyona-cutover-* || "$area" == /tmp/opencode/fyona-cash-* ]]; then
      rm -r -- "$area"
    fi
  done
}
trap cleanup EXIT
for area in "$cut" "$cash"; do
  chmod 0711 "$area"
  install -d -o postgres -g postgres -m 0700 "$area/data" "$area/socket"
  runuser -u postgres -- "$pg/initdb" -D "$area/data" -U root --auth-local=trust --auth-host=reject > "$area/init.log" 2>&1
  runuser -u postgres -- "$pg/pg_ctl" -D "$area/data" -l "$area/data/server.log" -o "-c listen_addresses='' -k $area/socket -c unix_socket_permissions=0700" -w start > "$area/start.log" 2>&1
  test "$("$pg/psql" -h "$area/socket" -U root -d postgres -Atc 'show listen_addresses')" = ''
done
"$pg/createdb" -h "$cut/socket" -U root fyona_cutover_fixture
local_py() {
  env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR=/tmp/opencode PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$work/backend" \
    JWT_SECRET_KEY=synthetic-test-only-key-6193 DATABASE_URL="postgresql+asyncpg://root@/fyona_cutover_fixture?host=$cut/socket" \
    REDIS_URL="unix://$cut/socket/test-only-redis.sock" CELERY_BROKER_URL=memory:// CELERY_RESULT_BACKEND=cache+memory:// \
    FYONA_TEST_CUTOVER_SOCKET="$cut/socket" FYONA_TEST_CASH_SOCKET="$cash/socket" \
    "$py" -m pytest -c backend/pytest.ini -q -p no:cacheprovider "$@"
}
run_fl() {
  local log=$1
  shift
  flock /tmp/opencode/fyona-business-flutter.lock /opt/fyona/flutter/bin/flutter test --no-pub --reporter expanded "$@" > "$proof/$log" 2>&1 || {
    tail -125 "$proof/$log"
    return 1
  }
  tail -3 "$proof/$log"
}
if [[ "${1:-all}" = all || "$1" = backend ]]; then
  local_py backend/tests/unit/test_local_business_cash.py backend/tests/unit/test_local_business_stock_transfer.py \
    backend/tests/unit/test_qa_business_cash_relay.py backend/tests/unit/test_qa_business_ledger.py \
    > "$proof/postgres-source.log" 2>&1 || { tail -160 "$proof/postgres-source.log"; exit 1; }
  tail -4 "$proof/postgres-source.log"
fi
if [[ "${1:-all}" = all || "$1" = flutter ]]; then
  FYONA_TEST_CUTOVER_SOCKET="$cut/socket" FYONA_TEST_CASH_WIRE_PYTHON="$py" \
    run_fl flutter-isolated-source.log \
    --dart-define=FYONA_DIRECTORY_PILOT=true --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true \
    --dart-define=FYONA_BUSINESS_LEDGER_QA=true --dart-define=FYONA_BUSINESS_CASH_RELAY_QA=true \
    --dart-define=FYONA_DIRECTORY_ACCOUNT=b722efef-8a1c-4830-885b-3ad90492e837 \
    --dart-define=FYONA_DIRECTORY_ORG=0f683120-9e30-4876-ac15-6dd2decafaa6 \
    --dart-define=FYONA_DIRECTORY_BRANCH=da2e39ff-3990-4c16-863d-293fb902b93d \
    test/business_cash_delivery_test.dart test/business_cash_relay_runtime_test.dart \
    test/business_local_backup_test.dart test/business_reconciliation_test.dart \
    test/business_money_report_test.dart test/business_transfer_scope_test.dart
fi
