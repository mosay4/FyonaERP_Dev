#!/usr/bin/env bash
# Only the separate Phase 1 application ID. Never uses the production signer.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

base="${1:?Usage: build_directory_pilot_apk.sh LAB_BASE_URL OUTPUT_APK [arm64|x64] [--include-ledger-qa]}"
output="${2:?Supply an unused destination path outside the stable build}"
architecture="${3:-arm64}"
ledger="${4:-}"
if [[ $# -gt 4 || ( -n "$ledger" && "$ledger" != --include-ledger-qa ) ]]; then
  printf '%s\n' 'Unknown build option.' >&2
  exit 2
fi
if [[ -e "$output" ]]; then
  printf '%s\n' 'Refusing to overwrite a previous APK.' >&2
  exit 1
fi
case "$base" in
  http://127.0.0.1:18083/api/v1|https://qa.fyonacompany.com:18443/api/v1) ;;
  *) printf '%s\n' 'Only the dedicated QA origins are permitted.' >&2; exit 1 ;;
esac
if [[ "$base" == https:* ]]; then
  # A staged phone APK must never be handed off with an unprovisioned origin.
  curl -q --noproxy '*' --fail --silent --show-error --max-time 10 "$base/health/ready" |
    python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready" and s["version"]["environment"]=="phase-one-qa" and s["version"]["deploy_sha"]=="phase-one-qa-enroll-6193"'
fi

export FYONA_DIRECTORY_PILOT_APK=1 FYONA_LOCAL_ANDROID_SIGNING=1
# The large diagnostic APK was built without Android code/resource shrinking.
# Never inherit that quick-build switch for a directory pilot deliverable.
unset FYONA_QUICK_TEST_APK
if [[ "$base" == https:* ]]; then
  export FYONA_DIRECTORY_PILOT_HTTPS=1
else
  unset FYONA_DIRECTORY_PILOT_HTTPS
fi
case "$architecture" in
  arm64) unset FYONA_DIRECTORY_PILOT_EMULATOR ;;
  x64) export FYONA_DIRECTORY_PILOT_EMULATOR=1 ;;
  *) printf '%s\n' 'Architecture must be arm64 or x64.' >&2; exit 1 ;;
esac

defines=(
  --dart-define=FYONA_DIRECTORY_PILOT=true
  --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true
  --dart-define="FYONA_DIRECTORY_SETUP_URL=$base"
  --dart-define=FYONA_DIRECTORY_ACCOUNT=b722efef-8a1c-4830-885b-3ad90492e837
  --dart-define=FYONA_DIRECTORY_ORG=0f683120-9e30-4876-ac15-6dd2decafaa6
  --dart-define=FYONA_DIRECTORY_BRANCH=da2e39ff-3990-4c16-863d-293fb902b93d
)
# Include the experimental client paths without granting a live branch write
# access. The app still requires the branch's separate server cutover claim.
if [[ "$ledger" == --include-ledger-qa ]]; then
  defines+=(--dart-define=FYONA_BUSINESS_LEDGER_QA=true)
fi
flutter build apk --release --no-pub --target-platform "android-$architecture" "${defines[@]}"
test -s build/app/outputs/mapping/release/mapping.txt

sdk="${ANDROID_HOME:?Set ANDROID_HOME}"
aapt="$sdk/build-tools/36.0.0/aapt"
signer="$sdk/build-tools/36.0.0/apksigner"
apk=build/app/outputs/flutter-apk/app-release.apk
package="$("$aapt" dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
[[ "$package" == com.fyona.erp.fyona_flutter.directorypilot ]]
"$signer" verify "$apk"
python3 - "$apk" "$architecture" <<'PY'
from pathlib import Path
import sys
from zipfile import ZipFile
apk=Path(sys.argv[1])
abi='arm64-v8a' if sys.argv[2]=='arm64' else 'x86_64'
with ZipFile(apk) as z:
    assert z.testzip() is None
    assert {'lib/'+abi+'/'+n for n in ('libapp.so','libflutter.so','libsqlcipher.so')} <= set(z.namelist())
print(f'Signed {abi} APK: {apk.stat().st_size:,} bytes')
if abi=='arm64-v8a' and apk.stat().st_size > 35_000_000:
    raise SystemExit('APK exceeds the 35,000,000-byte delivery budget')
PY
install -m 600 "$apk" "$output"
sha256sum "$output"
