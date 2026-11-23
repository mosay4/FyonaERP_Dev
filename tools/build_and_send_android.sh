#!/usr/bin/env bash
set -euo pipefail

project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
toolchain="${FYONA_TOOLCHAIN_DIR:-/opt/fyona}"
export ANDROID_HOME="${ANDROID_HOME:-$toolchain/android-sdk}"
export JAVA_HOME="${JAVA_HOME:-$toolchain/java17}"
export PATH="$toolchain/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

if (( $# > 1 )); then
  printf 'Usage: bash %s [API_BASE_URL]\n' "$0" >&2
  exit 2
fi
api_url="${1:-http://127.0.0.1:8001/api/v1}"
if [[ ! "$api_url" =~ ^https?://[^[:space:]]+/api/v1$ ]]; then
  printf 'Provide an API URL ending in /api/v1.\n' >&2
  exit 2
fi

cd "$project"
export FYONA_LOCAL_ANDROID_SIGNING=1
flutter pub get --enforce-lockfile
flutter build apk --no-pub --release --target-platform android-arm64 \
  --dart-define="API_BASE_URL=$api_url"
apk=build/app/outputs/flutter-apk/app-release.apk
bash tools/verify_android_apk.sh "$apk"
python3 tools/send_telegram.py "$apk" --caption \
  "${FYONA_TELEGRAM_CAPTION:-FYONA ERP — نسخة تطوير Android ARM64، بتوقيع محلي وليست للنشر}"
