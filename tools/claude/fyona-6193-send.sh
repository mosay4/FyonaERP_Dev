#!/usr/bin/env bash
# One authorized APK send for the 6193 device-link round. Fails closed: any
# missing or mismatched evidence stops before Telegram is contacted. An
# uncertain upload is never retried.
set -euo pipefail
umask 077
cd /root/.local/share/fyona-erp/qa/phase-one-6193/implementation
proof="$(realpath -e ../verification/business-link-and-transfer-6193)"
artifacts="$(realpath ../artifacts)"
apk="$proof/FYONA-1.4.133-6193-internal-arm64.apk"
twin="$proof/FYONA-1.4.133-6193-internal-x64.apk"
delivery="$artifacts/FYONA-1.4.133-6193-Branch-Offline-Fixes-ARM64.apk"
log="$proof/telegram-send.log"
test ! -e "$log"
test ! -e "$delivery"

# ── 1. The reviewed source tree is still the built one. ──
sha256sum --quiet -c "$proof/source-arm64.after"

# ── 2. Package, size, signature and compatibility with the four QA bundles. ──
export JAVA_HOME=/opt/fyona/java17 ANDROID_HOME=/opt/fyona/android-sdk
export PATH="$JAVA_HOME/bin:$PATH"
python3 -B tools/verify_business_delivery_candidate.py "$apk" "$artifacts" \
  > "$proof/arm64-send-gate.json"
python3 -B - "$apk" "$twin" "$proof" "$delivery" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, "tools")
apk, twin, proof, delivery = map(Path, sys.argv[1:])
gate = json.loads((proof / "arm64-send-gate.json").read_text())
digest = hashlib.file_digest(apk.open("rb"), "sha256").hexdigest()
assert gate["sha256"] == digest, "the verified candidate is not this APK"
assert 0 < gate["bytes"] < 35_000_000, "size budget"
assert gate["cash_link_build"] is True, "cash link is missing from the build"
assert gate["static_compatibility_only"] == ["1230", "1238", "1242", "1244"]
from verify_directory_pilot_update import compare_emulator
compare_emulator(apk, twin)
print("ARM64 candidate and the emulator twin share Android runtime code, manifest and Flutter assets.")
delivery.write_bytes(apk.read_bytes())
assert hashlib.file_digest(delivery.open("rb"), "sha256").hexdigest() == digest
print(f"delivery copy identical: {delivery.name} {delivery.stat().st_size} bytes")
PY

# ── 3. The update over the exact message-1244 bytes kept the session. ──
for step in restore-1244.txt update.txt boot.txt apk.sha256 boot-ui-dump.xml; do
  test -s "$proof/$step"
done
test "$(<"$proof/apk.sha256")" = "$(sha256sum "$twin" | awk '{print $1}')"
grep -Fxq 'The clone now holds the exact message-1244 application bytes with its saved session and data; the Business dashboard opened without login.' "$proof/restore-1244.txt"
grep -Fxq 'Prior 1244 x86_64 counterpart verified byte-for-byte before the update.' "$proof/update.txt"
grep -Fxq 'Updated over the exact x86_64 counterpart of 1244 without clearing data or re-registering.' "$proof/update.txt"
grep -Fq 'retained QA session' "$proof/boot.txt"

# ── 4. Desktop and managed QA evidence for the reviewed tree. ──
grep -Fq 'All tests passed!' "$proof/flutter-branch-fix.log"
grep -Fq 'All tests passed!' "$proof/flutter-branch-cache.log"
grep -Fq 'All tests passed!' "$proof/flutter-live-universal.log"
grep -Fq 'All tests passed!' "$proof/managed-flutter-live.log"
grep -Fq 'All tests passed!' "$proof/flutter-flags-off-final.log"
grep -Fq 'All tests passed!' "$proof/flutter-cash-guard-and-personal.log"
grep -Eq '^[0-9]+ passed' "$proof/postgres-transit.log"
python3 -B - "$proof/managed-continuity-before-link.log" "$proof/managed-continuity-after-link.log" <<'PY'
import json
import sys
before, after = (json.loads(open(path).read()) for path in sys.argv[1:])
assert before == after, "QA ledger grants changed during the link trial"
assert any(v.get("default_cash_sha256") for v in after.values()), "the fenced real branch grant is missing"
print("QA grants unchanged: the fenced real branch and its saved session were not touched.")
PY

# ── 5. The QA origin is the reviewed lab, still ready. ──
curl -q --noproxy '*' --fail --silent --show-error --max-time 10 \
  https://qa.fyonacompany.com:18443/api/v1/health/ready |
  python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready"'
systemctl show -p ActiveState --value fyona-directory-qa-api | grep -Fxq active
systemctl show -p ActiveState --value fyona-directory-qa-tls | grep -Fxq active

# ── 6. One APK, one send, one message id. ──
printf '%s\n' "Single APK send started; check for the Telegram message_id below." > "$log"
python3 -B tools/send_telegram.py "$delivery" \
  --caption "$(<"$proof/caption-ar.txt")" 2>&1 | tee -a "$log"
grep -Eq "^Sent FYONA-1.4.133-6193-Branch-Offline-Fixes-ARM64.apk; Telegram message_id=[1-9][0-9]*$" "$log"