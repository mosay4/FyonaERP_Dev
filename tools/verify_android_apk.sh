#!/usr/bin/env bash
set -euo pipefail

toolchain="${FYONA_TOOLCHAIN_DIR:-/opt/fyona}"
sdk="${ANDROID_HOME:-$toolchain/android-sdk}"
export PATH="${JAVA_HOME:-$toolchain/java17}/bin:$PATH"
build_tools="$sdk/build-tools/36.0.0"

if (( $# != 1 )); then
  printf 'Usage: bash %s PATH_TO_APK\n' "$0" >&2
  exit 2
fi
apk="$1"
"$build_tools/apksigner" verify --verbose "$apk"
badging="$("$build_tools/aapt" dump badging "$apk")"
grep -E '^(package:|sdkVersion:|targetSdkVersion:|native-code:)' <<< "$badging"
python3 - "$apk" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
with zipfile.ZipFile(path) as apk:
    corrupt = apk.testzip()
    if corrupt:
        raise SystemExit(f"Corrupt APK entry: {corrupt}")
    files = set(apk.namelist())
    compiled_abis = {
        name.split("/")[1]
        for name in files
        if name.startswith("lib/") and name.endswith("/libapp.so")
    }
    if compiled_abis != {"arm64-v8a"} or "lib/arm64-v8a/libflutter.so" not in files:
        raise SystemExit(f"Unexpected Flutter binary ABIs: {sorted(compiled_abis)}")
print(f"APK integrity OK; native Flutter target: ARM64; size: {path.stat().st_size} bytes")
PY
