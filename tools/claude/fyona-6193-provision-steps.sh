#!/usr/bin/env bash
# Inner step of fyona-6193-provision-login.sh inside the private network
# namespace. Boot the private clone, put the exact 1244 bytes on it, sign in
# through the app's own login form with the seeded QA lab account (an account
# the QA API itself reports as an active premium subscription) and prove the
# Business dashboard opens. Nothing here edits the subscription gate.
set -euo pipefail
box="$1"
clone="$2"
lab="$3"
prior="$4"
evidence="$5"
sock="$6"
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
python3 -B "$box/qa-https-bridge.py" isolated "$sock" >"$evidence/private-relay-provision.log" 2>&1 &
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
  -memory 1920 -cores 2 -ports 5574,5575 -no-metrics -feature -Vulkan -dns-server 192.0.2.17 \
  >"$evidence/emulator-provision.log" 2>&1 &
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
timeout 320 "$ADB" -s "$serial" install --no-streaming -r "$prior"
line="$("$ADB" -s "$serial" shell -n pm path "$pkg" | tr -d '\r')"
[[ "$line" == package:/data/app/"$pkg"-*/base.apk ]]
[[ "$(timeout 90 "$ADB" -s "$serial" shell -n sha256sum "${line#package:}" | awk '{print $1}')" == \
   "$(sha256sum "$prior" | awk '{print $1}')" ]]
# The software-rendered clone ANRs its System UI under animation load.
"$ADB" -s "$serial" shell -n settings put global window_animation_scale 0
"$ADB" -s "$serial" shell -n settings put global transition_animation_scale 0
"$ADB" -s "$serial" shell -n settings put global animator_duration_scale 0
# Pre-provisioning only: this disposable QA emulator clone still held the
# expired 24-hour trial account of earlier rounds. Clear this clone's app
# state so the app's own login form can sign in the entitled QA lab account.
# The update gate that runs afterwards performs no wipe of its own.
"$ADB" -s "$serial" shell -n pm clear "$pkg" >/dev/null
"$ADB" -s "$serial" shell -n input keyevent KEYCODE_WAKEUP
"$ADB" -s "$serial" shell -n wm dismiss-keyguard
# Let the software-rendered system finish the first-run work before driving
# any UI; the Flutter engine and SQLCipher setup otherwise starve System UI.
sleep 25
python3 -B - "$ADB" "$serial" "$evidence" "${FYONA_QA_CREDENTIALS:?}" <<'PY'
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

adb, serial, evidence, credentials_path = sys.argv[1:]
adb = [adb, "-s", serial]
pkg = "com.fyona.erp.fyona_flutter.directorypilot"
account = json.load(open(credentials_path))["owner"]


def labels(node):
    return [line for value in (node.get("text", ""), node.get("content-desc", ""))
            for line in value.replace("\u200f", "").replace("\u200e", "").splitlines()]


def screen_text(root):
    return " ".join(label for node in root.iter("node") for label in labels(node))


def adb_run(args, timeout=60):
    for attempt in range(3):
        try:
            return subprocess.run([*adb, *args], timeout=timeout,
                                  capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            # The software-rendered input pipeline can block behind a System
            # UI ANR; retry instead of dying.
            time.sleep(3)
    return None


def dump():
    for _ in range(3):
        try:
            run = subprocess.run([*adb, "exec-out", "uiautomator", "dump", "/dev/tty"],
                                 capture_output=True, text=True, timeout=45)
            match = re.search(r"<\?xml .*?</hierarchy>", run.stdout, re.S)
            if match:
                return ET.fromstring(match[0]), match[0]
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1)
    return None, ""


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(x, y):
    adb_run(["shell", "input", "tap", str(x), str(y)])


def type_text(value):
    adb_run(["shell", "input", "text", value])


def save(tag, xml):
    with open(f"{evidence}/provision-{tag}-ui-dump.xml", "w", encoding="utf-8") as out:
        out.write(xml)


def ensure_app():
    run = adb_run(["shell", "pidof", pkg], timeout=25)
    if run is not None and run.stdout.strip():
        return
    adb_run(["shell", "am", "start", "-n",
             f"{pkg}/com.fyona.erp.fyona_flutter.MainActivity"])


def handle_anr(root):
    # A software-rendered System UI ANR. Close the stuck owner and bring the
    # app back up; nothing else on the device is touched.
    for node in root.iter("node"):
        if "Close app" in labels(node):
            tap(*center(node))
            break
    else:
        for node in root.iter("node"):
            if "Wait" in labels(node):
                tap(*center(node))
                break
    time.sleep(3)
    ensure_app()


def wait_for(predicate, seconds, label):
    deadline = time.monotonic() + seconds
    last, xml = "", ""
    while time.monotonic() < deadline:
        root, xml = dump()
        if root is not None:
            text = screen_text(root)
            last = text
            if "isn't responding" in text:
                handle_anr(root)
                continue
            hit = predicate(root, text)
            if hit:
                return root, xml, text
        time.sleep(2)
    save("stuck", xml)
    raise SystemExit(f"{label}: not reached; last screen: {last[:1200]}")


def tap_label(root, needle):
    matches = [node for node in root.iter("node")
               if any(needle in label for label in labels(node))]
    assert matches, f"no node labelled {needle!r}"
    tap(*center(matches[-1]))


def dashboard(root, text):
    return "فاتورة بيع" in text or "صافي الثروة" in text


def handle_intermediate(root, text):
    for node in root.iter("node"):
        joined = labels(node)
        if node.get("clickable") != "true":
            continue
        if any("اختر الفرع" in label or "اختيار الفرع" in label for label in joined):
            continue
        for label in joined:
            if label.startswith("فرع") and len(label) < 40:
                tap(*center(node))
                return True
    return False


ensure_app()

# 1) The app's own login form.
root, xml, _ = wait_for(
    lambda root, text: "تسجيل الدخول" in text and "إنشاء حساب جديد" in text,
    480, "login form",
)
save("login-form", xml)
fields = [node for node in root.iter("node") if node.get("class") == "android.widget.EditText"]
assert len(fields) >= 2, f"expected email and password fields, found {len(fields)}"
tap(*center(fields[0]))
time.sleep(0.5)
type_text(account["email"])
time.sleep(0.5)
tap(*center(fields[1]))
time.sleep(0.5)
type_text(account["password"])
time.sleep(0.5)
root, xml, _ = wait_for(
    lambda root, text: any(
        "تسجيل الدخول" in labels(node) and node.get("class") == "android.widget.Button"
        for node in root.iter("node")),
    60, "login button",
)
typed, _ = dump()
if typed is not None and account["email"] not in screen_text(typed):
    raise SystemExit("provision-login: the e-mail field did not retain the typed address")
for node in root.iter("node"):
    if node.get("class") == "android.widget.Button" and "تسجيل الدخول" in labels(node):
        tap(*center(node))
        break
login_tapped = time.monotonic()

# 2) Through any branch/usage chooser to the Business dashboard.
deadline = time.monotonic() + 300
last, xml = "", ""
while time.monotonic() < deadline:
    root, xml = dump()
    if root is not None:
        text = screen_text(root)
        last = text
        if "isn't responding" in text:
            handle_anr(root)
            continue
        if dashboard(root, text):
            save("dashboard", xml)
            with open(f"{evidence}/provision-login.txt", "w", encoding="utf-8") as out:
                out.write("Signed in through the app's own login form with the seeded QA lab "
                          "account (active premium subscription on the QA API) and reached the "
                          "Business dashboard without touching any subscription gate.\n")
            print("provision-login: dashboard reached", flush=True)
            break
        # The form is still on screen right after the tap; only a return to it
        # from a later screen is a rejected sign-in.
        if ("البريد الإلكتروني" in text and "إنشاء حساب جديد" in text
                and time.monotonic() - login_tapped > 45):
            save("bounce", xml)
            raise SystemExit("provision-login: bounced back to the login form")
        handle_intermediate(root, text)
    time.sleep(3)
else:
    with open(f"{evidence}/provision-login.txt", "w", encoding="utf-8") as out:
        out.write(f"provision-login: dashboard not reached\n{last[:2000]}")
    raise SystemExit("provision-login: business dashboard was not reached")
PY
