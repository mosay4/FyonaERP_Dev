#!/usr/bin/env bash
# Inner step of fyona-6193-report-ui.sh inside the private network namespace.
set -euo pipefail
box="$1"
clone="$2"
lab="$3"
proof="$4"
sock="$5"
pkg=com.fyona.erp.fyona_flutter.directorypilot
serial=emulator-5574
export ADB=/opt/fyona/android-sdk/platform-tools/adb
export ANDROID_HOME="$lab" ANDROID_SDK_ROOT="$lab"
export ANDROID_USER_HOME="$clone/home" ANDROID_EMULATOR_HOME="$clone/home" \
  ANDROID_AVD_HOME="$clone/home/avd"
export TMPDIR=/tmp/opencode
export LD_LIBRARY_PATH="$lab/deps/usr/lib/x86_64-linux-gnu"
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
  ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS ANDROID_ADB_SERVER_PORT
[[ "$(readlink /proc/self/ns/net)" != "${FYONA_QA_HOST_NETNS:?}" ]]
ip link set lo up
ip addr add 192.0.2.17/32 dev lo
test -z "$(ip route show default)"
private_relay=
emulator=
start_relay() {
  python3 -B "$box/qa-https-bridge.py" isolated "$sock" >>"$proof/private-relay-report-ui.log" 2>&1 &
  private_relay=$!
  for _ in $(seq 1 100); do
    if ss -ltnH '( sport = :18443 )' | grep -Fq '127.0.0.1:18443'; then return 0; fi
    kill -0 "$private_relay"
    sleep .05
  done
  return 1
}
cleanup() {
  if [[ -n "$emulator" ]]; then
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || kill -TERM "$emulator" 2>/dev/null || true
    wait "$emulator" 2>/dev/null || true
  fi
  "$ADB" kill-server >/dev/null 2>&1 || true
  [[ -z "$private_relay" ]] || kill "$private_relay" 2>/dev/null || true
}
trap cleanup EXIT
start_relay
curl -q --noproxy '*' --resolve qa.fyonacompany.com:18443:127.0.0.1 -fsS --max-time 15 \
  https://qa.fyonacompany.com:18443/api/v1/health/ready |
  python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready"; print("Private emulator namespace: verified TLS to the QA host only.")'
"$lab/emulator/emulator" -avd FYONA_Phase_One_AOSP -accel off \
  -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot \
  -memory 1920 -cores 2 -ports 5574,5575 -no-metrics -feature -Vulkan -dns-server 192.0.2.17 \
  >"$proof/emulator-report-ui.log" 2>&1 &
emulator=$!
python3 -B - "$ADB" "$serial" <<'PY'
import subprocess
import sys
import time
adb = [sys.argv[1], "-s", sys.argv[2]]
deadline = time.monotonic() + 330
while time.monotonic() < deadline:
    try:
        state = subprocess.run([*adb, "shell", "getprop sys.boot_completed; service check package"],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=12)
        if state.stdout.startswith("1\nService package: found"):
            name = subprocess.check_output([*adb, "emu", "avd", "name"], text=True, timeout=10)
            assert name.splitlines()[0] == "FYONA_Phase_One_AOSP"
            print("Private QA emulator booted.", flush=True)
            break
    except subprocess.TimeoutExpired:
        pass
    time.sleep(3)
else:
    raise SystemExit("Private emulator did not boot.")
PY
line="$("$ADB" -s "$serial" shell -n pm path "$pkg" | tr -d '\r')"
[[ "$line" == package:/data/app/"$pkg"-*/base.apk ]]
[[ "$(timeout 90 "$ADB" -s "$serial" shell -n sha256sum "${line#package:}" | awk '{print $1}')" == \
   "$(tr -d ' \n' < "$proof/apk.sha256")" ]]
echo "Installed twin matches the update-gate candidate digest."
"$ADB" -s "$serial" shell -n settings put global window_animation_scale 0
"$ADB" -s "$serial" shell -n settings put global transition_animation_scale 0
"$ADB" -s "$serial" shell -n settings put global animator_duration_scale 0
# Let the software-rendered system settle before driving any UI.
"$ADB" -s "$serial" shell -n input keyevent KEYCODE_WAKEUP
"$ADB" -s "$serial" shell -n wm dismiss-keyguard
sleep 30

python3 -B /tmp/opencode/fyona-6193-report-ui.py "$ADB" "$serial" "$proof" online1

# ── Offline: drop the only network path to the QA host. ──
kill "$private_relay"
wait "$private_relay" 2>/dev/null || true
private_relay=
for _ in $(seq 1 40); do
  ss -ltnH '( sport = :18443 )' | grep -Fq '127.0.0.1:18443' || break
  sleep .1
done
! ss -ltnH '( sport = :18443 )' | grep -Fq '127.0.0.1:18443'
echo "QA relay down: the emulator has no network path to the QA API."
python3 -B /tmp/opencode/fyona-6193-report-ui.py "$ADB" "$serial" "$proof" offline

# ── Back online for the cold-restart retention check. ──
start_relay
curl -q --noproxy '*' --resolve qa.fyonacompany.com:18443:127.0.0.1 -fsS --max-time 15 \
  https://qa.fyonacompany.com:18443/api/v1/health/ready >/dev/null
echo "QA relay restored."
python3 -B /tmp/opencode/fyona-6193-report-ui.py "$ADB" "$serial" "$proof" online2
