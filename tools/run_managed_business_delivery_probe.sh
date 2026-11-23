#!/usr/bin/env bash
# Exercise the deployed HTTPS sandbox using only its separate OTP probe slots.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
proof="$(realpath -e "${1:?Evidence directory required}")"
[[ "$proof" == "$(realpath ../verification)/"* && $# -le 2 ]]
case "${2:-}" in
  "") mode=--managed-output; link=false; sha=phase-one-qa-enroll-6193-business ;;
  --link) mode=--managed-link-output; link=true; sha=phase-one-qa-enroll-6193-link ;;
  *) exit 2 ;;
esac
if [[ -e "$proof/managed-signups.log" || -e "$proof/managed-flutter-live.log" ]]; then
  printf '%s\n' 'Preserving existing evidence; the managed signup slots are single-use.' >&2
  exit 1
fi
run=/var/lib/private/fyona-directory-qa-enroll/run
origin=https://qa.fyonacompany.com:18443/api/v1
base=/opt/fyona-directory-qa
release="$(<"$proof/managed-release.path")"
[[ "$release" == "$base"/releases/business-6193.* && -f "$run/ready" ]]
exec_start="$(systemctl show -p ExecStart --value fyona-directory-qa-enroll)"
[[ "$exec_start" == *"$release/tools/run_directory_pilot_lab.py"* ]]
curl -q --noproxy '*' -fsS --max-time 8 "$origin/health/ready" |
  python3 -c 'import json,sys; h=json.load(sys.stdin); assert h["status"]=="ready" and h["version"]["deploy_sha"]==sys.argv[1]' "$sha"

area="$(mktemp -d /tmp/opencode/fyona-business-run.XXXXXXXX)"
trap 'rm -r -- "$area"' EXIT
export TMPDIR=/tmp/opencode
export FYONA_QA_SCENARIO_FIXTURE="$area/business-scenarios.json"
read -r pg_port redis_port < <(python3 -c 'import json,sys; print(*json.load(open(sys.argv[1]))[:2])' "$run/ports.json")
[[ "$pg_port" =~ ^[0-9]+$ && "$pg_port" != 5432 && "$redis_port" =~ ^[0-9]+$ ]]
env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 \
  PYTHONPATH="$release/backend:$base/python/site-packages" JWT_SECRET_KEY=qa-probe-db-only-6193 \
  DATABASE_URL="postgresql+asyncpg://directory_pilot:$(<"$run/db-password")@127.0.0.1:$pg_port/directory_pilot" \
  REDIS_URL="redis://127.0.0.1:$redis_port/0" CELERY_BROKER_URL=memory:// CELERY_RESULT_BACKEND=cache+memory:// \
  FYONA_QA_CASH_RELAY=1 FYONA_QA_CASH_LINK=1 \
  "$base/python/python3" -B tools/prepare_business_delivery_lab.py "$run" \
  "$mode" "$FYONA_QA_SCENARIO_FIXTURE" > "$proof/managed-signups.log" 2>&1

export NO_PROXY=qa.fyonacompany.com,127.0.0.1,localhost
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
flock /tmp/opencode/fyona-business-flutter.lock /opt/fyona/flutter/bin/flutter test \
  --no-pub --reporter expanded --concurrency=1 \
  --dart-define=FYONA_DIRECTORY_PILOT=true --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true \
  --dart-define=FYONA_DIRECTORY_SETUP_URL="$origin" --dart-define=FYONA_QA_MANAGED_BUSINESS_PROBE=true \
  --dart-define=FYONA_QA_MANAGED_BUSINESS_LINK_PROBE="$link" \
  --dart-define=FYONA_BUSINESS_LEDGER_QA=true --dart-define=FYONA_BUSINESS_CASH_RELAY_QA=true \
  --dart-define=FYONA_BUSINESS_EMPLOYEE_FINANCE_QA=true test/e2e/business_delivery_live_test.dart \
  > "$proof/managed-flutter-live.log" 2>&1
grep -E 'PASS|All tests passed!' "$proof/managed-flutter-live.log"
