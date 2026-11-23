#!/usr/bin/env bash
# Update over the exact x86_64 counterpart of message bundle 1244, on a
# private emulator clone, without clearing app data or re-registering.
# Reads the frozen 1244 sandbox only; writes nothing there.
set -euo pipefail
umask 077
cd /root/.local/share/fyona-erp/qa/phase-one-6193/implementation
box="$(realpath ../verification/1230-update-sandbox)"
lab="$(realpath ../android-lab)"
proof="$(realpath -e "${1:?Evidence folder required}")"
candidate="$(realpath -e "${2:?New internal x86_64 APK required}")"
clone="${3:-$(realpath -e "$(<"$box/avd-path.txt")")}"
[[ "$proof" == "$(realpath ../verification)/"* && "$candidate" == "$proof/"* ]]
[[ "$clone" == "$box"/avd-* && -d "$clone/home" && -d "$clone/state" ]]
prior="$box/FYONA-Offline-Commerce-internal-x86_64.apk"
test "$(sha256sum "$prior" | cut -d' ' -f1)" = 1525dd9e527cfbce9c8714cd110961401a16241393388687ae0d643be90f1a48
socket_dir="$(mktemp -d /tmp/opencode/fyona-1244-relay.XXXXXXXX)"
sock="$socket_dir/qa.sock"
python3 -B "$box/qa-https-bridge.py" host "$sock" >"$proof/host-relay.log" 2>&1 &
relay=$!
export FYONA_QA_HOST_NETNS="$(readlink /proc/self/ns/net)"
cleanup() {
  kill "$relay" 2>/dev/null || true
  rm -r -- "$socket_dir"
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  test ! -S "$sock" || break
  kill -0 "$relay"
  sleep .05
done
test -S "$sock"
unshare --user --map-root-user --net -- bash /tmp/opencode/fyona-6193-update-1244-steps.sh \
  "$box" "$clone" "$lab" "$candidate" "$proof" "$sock"