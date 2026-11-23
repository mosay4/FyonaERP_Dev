#!/usr/bin/env bash
# Start all processes (including test clients) behind an isolated loopback.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
root="$PWD"
export TMPDIR=/tmp/opencode
if [[ "${1:-}" != --isolated ]]; then
  export FYONA_SCENARIO_HOST_NETNS="$(readlink /proc/self/ns/net)"
  exec unshare --net -- "$BASH" "$0" --isolated "$@"
fi
shift
[[ -n "${FYONA_SCENARIO_HOST_NETNS:-}" && "$(readlink /proc/self/ns/net)" != "$FYONA_SCENARIO_HOST_NETNS" ]]
ip link set lo up
test -z "$(ip route show default)"
proof="$(realpath -e "${1:?Evidence directory required}")"
shift
[[ "$proof" == "$(realpath ../verification)/"* && $# -ge 1 ]]
run="$(mktemp -d "$TMPDIR/fyona-business-run.XXXXXXXX")"
export FYONA_QA_SCENARIO_FIXTURE="$run/lab/business-scenarios.json"
python="${FYONA_PYTHON:-/root/fyona-erp/backend/.venv/bin/python}"
FYONA_QA_REMOTE=0 FYONA_QA_SIGNUP=1 FYONA_QA_BUSINESS_SCENARIOS=1 \
  "$python" -B "$root/tools/run_directory_pilot_lab.py" "$run/lab" >"$proof/lab.log" 2>&1 &
lab=$!
cleanup() {
  kill -TERM "$lab" 2>/dev/null || true
  wait "$lab" 2>/dev/null || true
  # Keep diagnostic output separate from the credentials, upload and DB files.
  if [[ -s "$run/lab/api.log" ]]; then
    grep -E '"(GET|POST|PUT|DELETE|PATCH) /api/v1/[^?"]+[^"]*" [0-9]{3}' \
      "$run/lab/api.log" >"$proof/http-requests.log" || true
  fi
  rm -r -- "$run"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for ((i=0; i<100; i++)); do
  if [[ -s "$FYONA_QA_SCENARIO_FIXTURE" ]]; then break; fi
  if ! kill -0 "$lab" 2>/dev/null; then
    exit 1
  fi
  sleep 1
done
test -s "$FYONA_QA_SCENARIO_FIXTURE"
"$@"
