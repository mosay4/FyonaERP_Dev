#!/usr/bin/env bash
# Real-UI checks for the Business «التقارير» section on the private cloned QA
# emulator, after the update gate left the new twin and the retained session
# on it. Five report cards with their real motion scenes, entry-scene cancel
# back to the hub, reopen, period and type changes, the QA relay down (offline
# device-ledger reads) and a cold restart with retained data.
set -euo pipefail
umask 077
box="$(realpath ../verification/1230-update-sandbox)"
lab="$(realpath ../android-lab)"
proof="$(realpath -e "${1:?Evidence folder required}")"
clone="$(realpath -e "$(<"$box/avd-path.txt")")"
[[ "$proof" == "$(realpath ../verification)/"* && "$clone" == "$box"/avd-* ]]
test -s "$proof/apk.sha256"
test ! -e "$proof/report-ui-online1.txt"
pkg=com.fyona.erp.fyona_flutter.directorypilot
serial=emulator-5574
socket_dir="$(mktemp -d /tmp/opencode/fyona-report-ui-relay.XXXXXXXX)"
sock="$socket_dir/qa.sock"
python3 -B "$box/qa-https-bridge.py" host "$sock" >"$proof/host-relay-report-ui.log" 2>&1 &
relay=$!
export FYONA_QA_HOST_NETNS="$(readlink /proc/self/ns/net)"
emulator=
private_relay=
cleanup() {
  if [[ -n "$emulator" ]]; then
    /opt/fyona/android-sdk/platform-tools/adb -s "$serial" emu kill >/dev/null 2>&1 || true
    wait "$emulator" 2>/dev/null || true
  fi
  /opt/fyona/android-sdk/platform-tools/adb kill-server >/dev/null 2>&1 || true
  [[ -z "$private_relay" ]] || kill "$private_relay" 2>/dev/null || true
  kill "$relay" 2>/dev/null || true
  rm -r -- "$socket_dir"
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  test ! -S "$sock" || break
  kill -0 "$relay"
  sleep .05
done
test -S "$sock"
unshare --user --map-root-user --net -- bash /tmp/opencode/fyona-6193-report-ui-steps.sh \
  "$box" "$clone" "$lab" "$proof" "$sock" </dev/null
