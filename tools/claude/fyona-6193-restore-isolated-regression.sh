set -euo pipefail
umask 077
export TMPDIR=/tmp/opencode
work="$PWD"
proof="$work/../verification/business-restore-continuation"
pg=/usr/lib/postgresql/18/bin
py=/root/fyona-erp/backend/.venv/bin/python
cut=$(mktemp -d /tmp/opencode/fyona-cutover-XXXXXXXX)
cash=$(mktemp -d /tmp/opencode/fyona-cash-XXXXXXXX)
for area in "$cut" "$cash"; do
  chmod 0711 "$area"
  install -d -o postgres -g postgres -m 0700 "$area/data" "$area/socket"
done
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
  runuser -u postgres -- "$pg/initdb" -D "$area/data" -U root --auth-local=trust --auth-host=reject > "$area/init.log" 2>&1
  runuser -u postgres -- "$pg/pg_ctl" -D "$area/data" -l "$area/data/server.log" -o "-c listen_addresses='' -k $area/socket -c unix_socket_permissions=0700" -w start > "$area/start.log" 2>&1
  test "$("$pg/psql" -h "$area/socket" -U root -d postgres -Atc 'show listen_addresses')" = ''
done
"$pg/createdb" -h "$cut/socket" -U root fyona_cutover_fixture
mkdir "$cut/handoff"
local_py() {
  env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR=/tmp/opencode PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$work/backend" \
    JWT_SECRET_KEY=synthetic-test-only-key-6193 DATABASE_URL="postgresql+asyncpg://root@/fyona_cutover_fixture?host=$cut/socket" \
    REDIS_URL="unix://$cut/socket/test-only-redis.sock" CELERY_BROKER_URL=memory:// CELERY_RESULT_BACKEND=cache+memory:// \
    FYONA_TEST_CUTOVER_SOCKET="$cut/socket" FYONA_TEST_CUTOVER_EXPORT_DIR="$cut/handoff" \
    FYONA_TEST_CUTOVER_REQUIRE_RECEIPT="${FYONA_TEST_CUTOVER_REQUIRE_RECEIPT:-}" FYONA_TEST_CASH_SOCKET="$cash/socket" \
    "$py" -m pytest -c backend/pytest.ini -q -p no:cacheprovider "$@"
}
local_py backend/tests/unit/test_qa_business_ledger.py backend/tests/unit/test_qa_business_cash_relay.py backend/tests/unit/test_qa_business_party_sharing.py backend/tests/unit/test_local_business_cutover.py -k 'not device_receipt_is_recorded_only_after_reopen' > "$proof/postgres-regression.log" 2>&1 || { tail -100 "$proof/postgres-regression.log"; exit 1; }
local_py backend/tests/unit/test_local_business_cash.py > "$proof/postgres-cash-regression.log" 2>&1 || { tail -100 "$proof/postgres-cash-regression.log"; exit 1; }
tail -4 "$proof/postgres-regression.log"
tail -4 "$proof/postgres-cash-regression.log"
FYONA_TEST_CUTOVER_SOCKET="$cut/socket" FYONA_TEST_CUTOVER_EXPORT_DIR="$cut/handoff" FYONA_TEST_CASH_WIRE_PYTHON="$py" flock /tmp/opencode/fyona-business-flutter.lock /opt/fyona/flutter/bin/flutter test --no-pub --reporter expanded --dart-define=FYONA_DIRECTORY_PILOT=true --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true --dart-define=FYONA_BUSINESS_LEDGER_QA=true --dart-define=FYONA_BUSINESS_CASH_RELAY_QA=true test/business_cash_delivery_test.dart test/business_cutover_archive_test.dart > "$proof/cipher-postgres-regression.log" 2>&1 || { tail -100 "$proof/cipher-postgres-regression.log"; exit 1; }
FYONA_TEST_CUTOVER_REQUIRE_RECEIPT=1 local_py backend/tests/unit/test_local_business_cutover.py::test_device_receipt_is_recorded_only_after_reopen > "$proof/postgres-device-receipt.log" 2>&1 || { tail -50 "$proof/postgres-device-receipt.log"; exit 1; }
tail -9 "$proof/cipher-postgres-regression.log"
tail -4 "$proof/postgres-device-receipt.log"
