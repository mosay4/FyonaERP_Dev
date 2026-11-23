#!/usr/bin/env bash
# Replace the old APK on the existing, isolated QA emulator only.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
q="$HOME/.local/share/fyona-erp/qa/phase-one-6193"
state=/var/lib/private/fyona-directory-qa-enroll/run
prior="$q/verification/enrollment-android-verified"
first="$q/verification/enrollment-android-35mb-verified"
offline="$q/verification/enrollment-android-35mb-recheck"
case "${1:-}" in
  "") evidence="$first" ;;
  --resume-installed) evidence="$offline" ;;
  --finish-after-offline)
    test -s "$offline/offline-restart.txt"
    suffix="${2:-final}"
    [[ "$suffix" =~ ^[a-z0-9-]+$ && $# -le 2 ]]
    evidence="$q/verification/enrollment-android-35mb-$suffix"
    ;;
  *) printf '%s\n' 'Unknown argument' >&2; exit 2 ;;
esac
apk="$q/artifacts/FYONA-Phase1-QA-35MB-x86_64.apk"
serial=emulator-5574
package=com.fyona.erp.fyona_flutter.directorypilot
[[ ! -e "$evidence" && -s "$apk" && -f "$state/ready" ]]

export ADB=/opt/fyona/android-sdk/platform-tools/adb
export ANDROID_HOME="$q/android-lab" ANDROID_SDK_ROOT="$q/android-lab"
export ANDROID_USER_HOME="$q/android-lab/.android" ANDROID_AVD_HOME="$q/android-lab/.android/avd"
export LD_LIBRARY_PATH="$ANDROID_HOME/deps/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
if [[ -n "$(ss -ltnH '( sport = :5574 or sport = :5575 )')" ]]; then
  printf '%s\n' 'QA emulator ports are already in use. Not starting another emulator.' >&2
  exit 1
fi
"$ANDROID_HOME/emulator/emulator" -avd FYONA_Phase_One_AOSP -accel off \
  -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot \
  -memory 1280 -cores 2 -ports 5574,5575 -no-metrics -feature -Vulkan \
  >"$evidence-emulator.log" 2>&1 &
emulator_pid=$!
trap 'kill -TERM "$emulator_pid" 2>/dev/null || true' EXIT

python3 -B - "$ADB" "$serial" <<'PY'
import subprocess
import sys
import time

adb = [sys.argv[1], "-s", sys.argv[2]]
until = time.monotonic() + 330
while time.monotonic() < until:
    try:
        ready = subprocess.check_output(
            [*adb, "shell", "getprop sys.boot_completed; service check package"],
            text=True, stderr=subprocess.DEVNULL, timeout=14,
        )
        if ready.startswith("1\nService package: found"):
            name = subprocess.check_output([*adb, "emu", "avd", "name"], text=True, timeout=12)
            assert name.splitlines()[0] == "FYONA_Phase_One_AOSP"
            break
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
    time.sleep(4)
else:
    sys.exit("QA emulator did not finish booting.")
PY

installed_digest() {
  local line
  line=$("$ADB" -s "$serial" shell pm path "$package" | tr -d '\r')
  [[ "$line" == package:/data/app/"$package"-*/base.apk ]] || return 1
  "$ADB" -s "$serial" shell sha256sum "${line#package:}" | awk '{print $1}'
}
candidate=$(sha256sum "$apk" | awk '{print $1}')
python3 -B - "$q/verification/verify-enrollment-qa-35mb-x64.json" "$candidate" <<'PY'
from pathlib import Path
import json
import sys
assert json.loads(Path(sys.argv[1]).read_text())["sha256"] == sys.argv[2]
PY
if [[ "$evidence" == "$first" ]]; then
  [[ "$(installed_digest)" == "$(<"$prior/apk.sha256")" ]]
  timeout 430 "$ADB" -s "$serial" install --no-streaming -r "$apk"
  [[ "$(installed_digest)" == "$candidate" ]]
  printf '%s\n' 'Minified x86_64 APK installed over the verified previous QA build; data not cleared.'
else
  [[ "$(installed_digest)" == "$candidate" ]]
  [[ "$(<"$first/apk.sha256")" == "$candidate" ]]
  grep -Fq 'Minified x86_64 APK installed over the verified previous QA build; data not cleared.' \
    "$q/verification/enrollment-android-35mb.log"
  printf '%s\n' 'Resuming on the same installed compact APK; no reinstall and no data reset.'
fi
"$ADB" -s "$serial" shell 'settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0'
if [[ "${1:-}" == --finish-after-offline ]]; then
  python3 -B tools/check_directory_pilot_android.py "$state/fixture.json" "$evidence" "$offline" --resume-after-offline
else
  python3 -B tools/check_directory_pilot_android.py "$state/fixture.json" "$evidence" "$prior" --upgrade
fi
python3 -B tools/verify_directory_android_isolation.py "$state" "$evidence"
