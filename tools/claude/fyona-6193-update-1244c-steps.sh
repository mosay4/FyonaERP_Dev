#!/usr/bin/env bash
# Inner step of fyona-6193-update-1244c.sh inside the private network
# namespace. First put the exact message-1244 application bytes back on the
# clone (same package data, nothing deleted), prove its retained session opens
# the Business dashboard, then update with the new twin and prove it again.
set -euo pipefail
box="$1"
clone="$2"
lab="$3"
prior="$4"
apk="$5"
evidence="$6"
sock="$7"
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
python3 -B "$box/qa-https-bridge.py" isolated "$sock" >"$evidence/private-relay-1244c.log" 2>&1 &
private_relay=$!
emulator=
cleanup() {
  if [[ -n "$emulator" ]]; then
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || kill -TERM "$emulator" 2>/dev/null || true
    wait "$emulator" 2>/dev/null || true
  fi
  "$ADB" kill-server >/dev/null 2>&1 || true
  kill "$private_relay" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  if ss -ltnH '( sport = :18443 )' | grep -Fq '127.0.0.1:18443'; then break; fi
  kill -0 "$private_relay"
  sleep .05
done
curl -q --noproxy '*' --resolve qa.fyonacompany.com:18443:127.0.0.1 -fsS --max-time 15 \
  https://qa.fyonacompany.com:18443/api/v1/health/ready |
  python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready"; print("Private emulator namespace: verified TLS to the QA host only.")'
"$lab/emulator/emulator" -avd FYONA_Phase_One_AOSP -accel off \
  -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot \
  -memory 1280 -cores 2 -ports 5574,5575 -no-metrics -feature -Vulkan -dns-server 192.0.2.17 \
  >"$evidence/emulator-1244c.log" 2>&1 &
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
installed_digest() {
  local line
  line="$("$ADB" -s "$serial" shell -n pm path "$pkg" | tr -d '\r')"
  [[ "$line" == package:/data/app/"$pkg"-*/base.apk ]] || return 1
  timeout 90 "$ADB" -s "$serial" shell -n sha256sum "${line#package:}" | awk '{print $1}'
}
boot_smoke() {
  python3 -B - "$ADB" "$serial" "$evidence" "$1" "$2" <<'PY'
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
adb, serial, evidence, tag, message = sys.argv[1:]
adb = [adb]


def labels(node):
    return [line for value in (node.get("text", ""), node.get("content-desc", ""))
            for line in value.replace("\u200f", "").replace("\u200e", "").splitlines()]


deadline = time.monotonic() + 180
last = ""
while time.monotonic() < deadline:
    try:
        dump = subprocess.run([*adb, "-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"],
                              capture_output=True, text=True, timeout=30)
        match = re.search(r"<\?xml .*?</hierarchy>", dump.stdout, re.S)
        if match:
            root = ET.fromstring(match[0])
            text = " ".join(label for node in root.iter("node") for label in labels(node))
            last = text
            if "isn't responding" in text:
                for node in root.iter("node"):
                    if "Wait" in labels(node):
                        x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
                        subprocess.run([*adb, "-s", serial, "shell", "input", "tap",
                                        str((x1 + x2) // 2), str((y1 + y2) // 2)],
                                       timeout=15)
                        break
                time.sleep(2)
                continue
            if "تسجيل الدخول" in text or "البريد الإلكتروني" in text:
                raise SystemExit(f"{tag}: the retained session was lost and login was asked.")
            if "فاتورة بيع" in text or "صافي الثروة" in text:
                with open(f"{evidence}/{tag}.txt", "w", encoding="utf-8") as out:
                    out.write(message + "\n")
                with open(f"{evidence}/{tag}-ui-dump.xml", "w", encoding="utf-8") as out:
                    out.write(match[0])
                print(f"{tag}: dashboard reached", flush=True)
                break
    except subprocess.TimeoutExpired:
        pass
    time.sleep(3)
else:
    with open(f"{evidence}/{tag}.txt", "w", encoding="utf-8") as out:
        out.write(f"{tag}: dashboard not reached\n" + last[:2000])
    raise SystemExit(f"{tag}: business dashboard was not reached")
PY
}
prior_sha="$(sha256sum "$prior" | awk '{print $1}')"
candidate_sha="$(sha256sum "$apk" | awk '{print $1}')"

# ── The state before the update: exactly message 1244, same data and login. ──
timeout 320 "$ADB" -s "$serial" install --no-streaming -r "$prior"
[[ "$(installed_digest)" == "$prior_sha" ]]
"$ADB" -s "$serial" shell -n am force-stop "$pkg"
"$ADB" -s "$serial" shell -n input keyevent KEYCODE_WAKEUP
"$ADB" -s "$serial" shell -n wm dismiss-keyguard
"$ADB" -s "$serial" shell -n am start -n "$pkg/com.fyona.erp.fyona_flutter.MainActivity"
boot_smoke restore-1244 'The clone now holds the exact message-1244 application bytes with its saved session and data; the Business dashboard opened without login.'

# ── The update itself, over those exact bytes, with no data loss. ──
[[ "$(installed_digest)" == "$prior_sha" ]]
printf '%s\n' 'Prior 1244 x86_64 counterpart verified byte-for-byte before the update.' |
  tee "$evidence/update.txt"
timeout 320 "$ADB" -s "$serial" install --no-streaming -r "$apk"
[[ "$(installed_digest)" == "$candidate_sha" ]]
printf '%s\n' 'Updated over the exact x86_64 counterpart of 1244 without clearing data or re-registering.' |
  tee -a "$evidence/update.txt"
printf '%s\n' "$candidate_sha" > "$evidence/apk.sha256"
"$ADB" -s "$serial" shell -n am force-stop "$pkg"
"$ADB" -s "$serial" shell -n input keyevent KEYCODE_WAKEUP
"$ADB" -s "$serial" shell -n wm dismiss-keyguard
"$ADB" -s "$serial" shell -n am start -n "$pkg/com.fyona.erp.fyona_flutter.MainActivity"
boot_smoke boot 'Business dashboard cold-started after the update over 1244 with the retained QA session and saved data.'