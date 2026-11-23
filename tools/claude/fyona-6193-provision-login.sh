#!/usr/bin/env bash
# Pre-provision the private cloned QA emulator with the seeded QA lab account
# (valid premium subscription on the QA API) through the app's own login form.
# This runs BEFORE the update gate so that the gate itself keeps a retained,
# entitled session. No subscription gate is skipped or modified: the account
# is genuinely entitled on the server. Only this disposable emulator clone is
# touched; no user device or «فرع حده» data is involved.
set -euo pipefail
umask 077
cd /root/.local/share/fyona-erp/qa/phase-one-6193/implementation
box="$(realpath ../verification/1230-update-sandbox)"
lab="$(realpath ../android-lab)"
proof="$(realpath -e "${1:?Evidence folder required}")"
clone="$(realpath -e "$(<"$box/avd-path.txt")")"
[[ "$proof" == "$(realpath ../verification)/"* ]]
[[ "$clone" == "$box"/avd-* && -d "$clone/home" && -d "$clone/state" ]]
prior="$box/FYONA-Offline-Commerce-internal-x86_64.apk"
test "$(sha256sum "$prior" | cut -d' ' -f1)" = 1525dd9e527cfbce9c8714cd110961401a16241393388687ae0d643be90f1a48
test ! -e "$proof/provision-login.txt"
run=/var/lib/private/fyona-directory-qa-enroll/run
test -s "$run/fixture.json"
socket_dir="$(mktemp -d /tmp/opencode/fyona-1244-relay.XXXXXXXX)"
sock="$socket_dir/qa.sock"
# The private QA run folder is only readable on the host side; copy the QA
# lab credentials into the private temp area before entering the namespace.
cp "$run/fixture.json" "$socket_dir/credentials.json"
chmod 600 "$socket_dir/credentials.json"
export FYONA_QA_CREDENTIALS="$socket_dir/credentials.json"
python3 -B "$box/qa-https-bridge.py" host "$sock" >"$proof/host-relay-provision.log" 2>&1 &
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
unshare --user --map-root-user --net -- bash /tmp/opencode/fyona-6193-provision-steps.sh \
  "$box" "$clone" "$lab" "$prior" "$proof" "$sock" </dev/null
