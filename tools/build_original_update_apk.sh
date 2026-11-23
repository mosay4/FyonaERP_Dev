#!/usr/bin/env bash
# Rebuild the verified original package in an extracted Phase Zero workspace.
# This never deploys the backend, sends Telegram, or turns on the pilot.
set -euo pipefail
umask 077

if (( $# != 3 )); then
  printf 'Usage: bash %s RESTORED_PHASE_ZERO_DIR REFERENCE_APK UNUSED_OUTPUT_APK\n' "$0" >&2
  exit 2
fi
tools="$(cd "$(dirname "$0")" && pwd)"
work="$(realpath -e "$1")"
reference="$(realpath -e "$2")"
output="$(realpath -m "$3")"
baseline="$HOME/.local/share/fyona-erp/baselines/phase-zero-1.4.133_6193"
api='https://api.jeetak-lounge.com/api/v1'
if [[ "$work" != "$HOME/.local/share/fyona-erp/qa/"* || -e "$output" ]]; then
  printf '%s\n' 'Use a separate restored QA workspace and an unused output path.' >&2
  exit 1
fi
test "$reference" = "$baseline/stable-apk-as-tested-1.4.133_6193.apk"
(cd "$baseline" && sha256sum --quiet -c SHA256SUMS)
(cd "$work" && sha256sum --quiet -c "$baseline/source-files.sha256")

toolchain="${FYONA_TOOLCHAIN_DIR:-/opt/fyona}"
export ANDROID_HOME="${ANDROID_HOME:-$toolchain/android-sdk}"
export JAVA_HOME="${JAVA_HOME:-$toolchain/java17}"
export PATH="$toolchain/flutter/bin:$JAVA_HOME/bin:$PATH"
unset FYONA_DIRECTORY_PILOT_APK FYONA_DIRECTORY_PILOT_EMULATOR
export FYONA_LOCAL_ANDROID_SIGNING=1 FYONA_QUICK_TEST_APK=1

check="$tools/verify_original_update_apk.py"
firebase="$work/android/app/google-services.json"
python3 "$check" "$reference" "$reference" --google-services "$firebase" --api-base "$api"
cd "$work"
flutter pub get --offline --enforce-lockfile
flutter build apk --release --no-pub --target-platform android-arm64 \
  --dart-define="API_BASE_URL=$api"
apk="$work/build/app/outputs/flutter-apk/app-release.apk"
python3 "$check" "$reference" "$apk" --google-services "$firebase" --api-base "$api"
test "$(stat -c %s "$apk")" -le 50000000
install -m 600 "$apk" "$output"
sha256sum "$output"
