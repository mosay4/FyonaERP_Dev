#!/usr/bin/env bash
# Disposable x86_64 emulator. Never use a host device or the public QA origin.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
proof="$(realpath -e "${1:?Evidence directory required}")"
apk="$(realpath -e "${2:?Internal loopback x86_64 APK required}")"
fixture="${FYONA_QA_SCENARIO_FIXTURE:?Run through run_business_delivery_lab.sh}"
[[ "$(readlink /proc/self/ns/net)" != "${FYONA_SCENARIO_HOST_NETNS:?}" ]]
[[ -s "$fixture" && "$apk" == "$proof/"* && -z "$(ip route show default)" ]]
prior="$(realpath -e ../verification/1230-update-sandbox/FYONA-Offline-Commerce-internal-x86_64.apk)"
test "$(sha256sum "$prior" | cut -d' ' -f1)" = 1525dd9e527cfbce9c8714cd110961401a16241393388687ae0d643be90f1a48
export ADB=/opt/fyona/android-sdk/platform-tools/adb
export ANDROID_HOME="$(realpath ../android-lab)" ANDROID_SDK_ROOT="$(realpath ../android-lab)"
export LD_LIBRARY_PATH="$ANDROID_HOME/deps/usr/lib/x86_64-linux-gnu"
area="$(mktemp -d "$proof/emulator.XXXXXXXX")"
export ANDROID_USER_HOME="$area/home" ANDROID_EMULATOR_HOME="$area/home" ANDROID_AVD_HOME="$area/home/avd"
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
  ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS ANDROID_ADB_SERVER_PORT ADB_VENDOR_KEYS
serial=emulator-5572
avd=FYONA_Business_Loopback
pkg=com.fyona.erp.fyona_flutter.directorypilot
install -d "$ANDROID_AVD_HOME/$avd.avd"
sed "s/FYONA_Phase_One_AOSP/$avd/g" "$ANDROID_HOME/phase-one-enroll-aosp.avd/config.ini" \
  > "$ANDROID_AVD_HOME/$avd.avd/config.ini"
printf 'avd.ini.encoding=UTF-8\npath=%s\ntarget=android-28\n' "$ANDROID_AVD_HOME/$avd.avd" \
  > "$ANDROID_AVD_HOME/$avd.ini"
emulator=
adb() { "$ADB" -s "$serial" "$@"; }
cleanup() {
  if [[ -n "$emulator" ]]; then
    timeout 10 "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || kill -TERM "$emulator" 2>/dev/null || true
    wait "$emulator" 2>/dev/null || true
  fi
  "$ADB" kill-server >/dev/null 2>&1 || true
  rm -r -- "$area"
}
trap cleanup EXIT
"$ADB" start-server
"$ANDROID_HOME/emulator/emulator" -avd "$avd" -ports 5572,5573 -memory 1280 -cores 2 \
  -accel off -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot \
  -no-metrics -feature -Vulkan >"$proof/android-emulator.log" 2>&1 &
emulator=$!
for ((attempt=0; attempt<100; attempt++)); do
  if [[ "$(timeout 8 "$ADB" -s "$serial" shell -n getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    break
  fi
  kill -0 "$emulator"
  sleep 3
done
test "$(adb emu avd name | head -1 | tr -d '\r')" = "$avd"
test "$(adb shell -n getprop sys.boot_completed | tr -d '\r')" = 1
test -z "$(adb shell -n pm path "$pkg" || true)"
installed_digest() {
  local entry
  entry="$(adb shell -n pm path "$pkg" | tr -d '\r')"
  [[ "$entry" == package:/data/app/"$pkg"-*/base.apk ]]
  adb shell -n sha256sum "${entry#package:}" | cut -d' ' -f1
}
# The older HTTPS binary is not given credentials or network. Prove Android
# accepts the replacement, not that this localhost APK can reuse an HTTPS login.
adb install --no-streaming "$prior"
test "$(installed_digest)" = "$(sha256sum "$prior" | cut -d' ' -f1)"
adb install --no-streaming -r "$apk"
test "$(installed_digest)" = "$(sha256sum "$apk" | cut -d' ' -f1)"
printf '%s\n' '1244 x86_64 counterpart replaced in place; package/installer check only, no prior user session.' \
  > "$proof/android-update-package-only.txt"
python3 -B tools/check_directory_pilot_android.py "$fixture" "$proof/android-ui" --business-scenarios
