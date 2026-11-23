#!/usr/bin/env bash
set -euo pipefail
umask 077
arch="${1:?arm64 or x64}"
proof="${2:?private evidence folder}"
reference="${3:?APK from 1244}"
test -d "$proof"
test "$(sha256sum "$reference" | cut -d' ' -f1)" = 8a2aeeb41850364dd06a518d60dc6aa99364c77a7d493f3d123f8a00a7a60fda
export ANDROID_HOME=/opt/fyona/android-sdk ANDROID_SDK_ROOT=/opt/fyona/android-sdk
export JAVA_HOME=/opt/fyona/java17 TMPDIR=/tmp/opencode
export PATH="/opt/fyona/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export FYONA_DIRECTORY_PILOT_APK=1 FYONA_LOCAL_ANDROID_SIGNING=1
unset FYONA_QUICK_TEST_APK
if [[ "${FYONA_DIAGNOSTIC_X64:-0}" == 1 ]]; then
  test "$arch" = x64
  export FYONA_QUICK_TEST_APK=1
  printf '%s\n' 'Emulator-only diagnostic build: R8/resource shrinking disabled. Not a delivery candidate.'
fi
case "$arch" in
  arm64)
    export FYONA_DIRECTORY_PILOT_HTTPS=1
    unset FYONA_DIRECTORY_PILOT_EMULATOR
    base=https://qa.fyonacompany.com:18443/api/v1
    ;;
  x64)
    export FYONA_DIRECTORY_PILOT_EMULATOR=1
    unset FYONA_DIRECTORY_PILOT_HTTPS
    # The twin used for the update and DEX contract must expose the same
    # Android manifest as the phone artifact: same cleartext decision.
    if [[ "${FYONA_TWIN_HTTPS:-0}" == 1 ]]; then
      export FYONA_DIRECTORY_PILOT_HTTPS=1
      base=https://qa.fyonacompany.com:18443/api/v1
    else
      base=http://127.0.0.1:18083/api/v1
    fi
    ;;
  *) exit 2 ;;
esac
artifact="$proof/FYONA-1.4.133-6193-internal-$arch.apk"
test ! -e "$artifact"
fingerprint() {
  python3 -B - <<'PY'
import hashlib
from pathlib import Path
paths = [p for root in map(Path, ("lib", "assets", "android/app/src"))
         for p in root.rglob("*") if p.is_file()]
paths += [Path(p) for p in ("pubspec.yaml", "pubspec.lock", "android/app/build.gradle.kts",
                           "android/settings.gradle.kts", "android/gradle.properties",
                           "android/app/proguard-rules.pro",
                           "android/app/google-services.json")]
for p in sorted(paths):
    with p.open("rb") as stream:
        print(hashlib.file_digest(stream, "sha256").hexdigest(), p.as_posix())
PY
}
fingerprint > "$proof/source-$arch.before"
sha256sum "$proof/source-$arch.before"
flutter build apk --release --no-pub --target-platform "android-$arch" \
  --dart-define=FYONA_DIRECTORY_PILOT=true --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true \
  --dart-define="FYONA_DIRECTORY_SETUP_URL=$base" \
  --dart-define=FYONA_BUSINESS_LEDGER_QA=true --dart-define=FYONA_BUSINESS_CASH_RELAY_QA=true \
  --dart-define=FYONA_BUSINESS_EMPLOYEE_FINANCE_QA=true \
  --dart-define=FYONA_DIRECTORY_ACCOUNT=b722efef-8a1c-4830-885b-3ad90492e837 \
  --dart-define=FYONA_DIRECTORY_ORG=0f683120-9e30-4876-ac15-6dd2decafaa6 \
  --dart-define=FYONA_DIRECTORY_BRANCH=da2e39ff-3990-4c16-863d-293fb902b93d
fingerprint > "$proof/source-$arch.after"
cmp "$proof/source-$arch.before" "$proof/source-$arch.after"
if [[ "${FYONA_QUICK_TEST_APK:-0}" != 1 ]]; then
  test -s build/app/outputs/mapping/release/mapping.txt
fi
apk=build/app/outputs/flutter-apk/app-release.apk
build_tools="$ANDROID_HOME/build-tools/36.0.0"
python3 -B - "$apk" "$reference" "$arch" "$build_tools" <<'PY'
from pathlib import Path
from subprocess import check_output
from zipfile import ZipFile
import sys
apk, reference, arch, bt = sys.argv[1:]
aapt, sig = f"{bt}/aapt", f"{bt}/apksigner"
badges = lambda p: check_output([aapt, "dump", "badging", p], text=True)
expected = "package: name='com.fyona.erp.fyona_flutter.directorypilot' versionCode='6193' versionName='1.4.133'"
assert badges(apk).startswith(expected) and badges(reference).startswith(expected)
info = check_output([sig, "verify", "--print-certs", apk], text=True)
assert "certificate SHA-256 digest: d5cf41c2a4d13c12b85571bfbf7ed4541ba93c302036394731940504de59cb7e" in info
abi = {"arm64": "arm64-v8a", "x64": "x86_64"}[arch]
libs = {"libapp.so", "libflutter.so", "libsqlcipher.so"}
with ZipFile(apk) as new, ZipFile(reference) as old:
    assert new.testzip() is None
    assert {entry for entry in new.namelist() if entry.startswith("lib/")
            and entry.rsplit("/", 1)[-1] in libs} == {f"lib/{abi}/{name}" for name in libs}
    code = new.read(f"lib/{abi}/libapp.so")
    assert b"/business/employee-finance" in code
    assert b"api.jeetak-lounge.com" not in code
    if arch == "arm64":
        assert new.read("AndroidManifest.xml") == old.read("AndroidManifest.xml")
        assert set(check_output([aapt, "dump", "permissions", apk], text=True).splitlines()) == \
               set(check_output([aapt, "dump", "permissions", reference], text=True).splitlines())
        assert 0 < Path(apk).stat().st_size < 35_000_000
print(f"{abi}: signature, manifest contract and native libraries verified; {Path(apk).stat().st_size} bytes")
PY
install -m 600 "$apk" "$artifact"
sha256sum "$artifact"
