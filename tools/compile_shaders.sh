#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"
FLUTTER_BIN="$(readlink -f "$(command -v flutter)")"
SDK="$(dirname "$(dirname "$FLUTTER_BIN")")"
case "$(uname -m)" in
  x86_64) HOST=linux-x64 ;;
  aarch64|arm64) HOST=linux-arm64 ;;
  *) printf 'Unsupported shader compiler host\n' >&2; exit 1 ;;
esac
ENGINE="$SDK/bin/cache/artifacts/engine/$HOST"
COMPILER="$ENGINE/impellerc"
test -x "$COMPILER" || { printf 'BLOCKER: impellerc unavailable: %s\n' "$COMPILER" >&2; exit 1; }
SPIRV="$(mktemp "$ROOT/assets/shaders/.sara-fluid.XXXXXX")"
trap 'rm -f -- "$SPIRV"' EXIT
# IPLR is Flutter's runtime-stage container, not raw SPIR-V. Include SkSL for
# headless/Skia plus every native Impeller runtime backend in the same asset.
"$COMPILER" --sksl --runtime-stage-metal --runtime-stage-gles \
  --runtime-stage-gles3 --runtime-stage-vulkan --iplr --input-type=frag \
  --spirv="$SPIRV" \
  --include="$ENGINE/shader_lib" \
  --input="$ROOT/assets/shaders/sara_fluid.frag" \
  --sl="$ROOT/assets/shaders/sara_fluid.frag.sprv"
printf 'Compiled with %s\n' "$COMPILER"
wc -c "$ROOT/assets/shaders/sara_fluid.frag.sprv"
sha256sum "$ROOT/assets/shaders/sara_fluid.frag.sprv"
