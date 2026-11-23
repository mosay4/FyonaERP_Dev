#!/usr/bin/env bash
# Release only the exact finished Phase 1 candidate, after its device probe.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
q="$HOME/.local/share/fyona-erp/qa/phase-one-6193"
apk="$q/artifacts/FYONA-1.4.133-6193-Phase1-QA-35MB-ARM64.apk"
log="$q/verification/telegram-enrollment-handoff.log"
apk_bytes="$(stat -c %s "$apk")"
(( apk_bytes > 0 && apk_bytes <= 35000000 ))
evidence="$(realpath -e "${1:?Supply a completed Android QA evidence folder}")"
[[ "$evidence" == "$q/verification/enrollment-android-35mb-"* ]]
for step in app-start login preserved-data online-local online-search offline-local offline-restart connected-isolation rest-after-device; do
  test -s "$evidence/$step.txt"
done
python3 -B - "$q" "$apk" "$evidence" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
from zipfile import ZipFile

root, apk, evidence = map(Path, sys.argv[1:])
x64 = root / "artifacts" / "FYONA-Phase1-QA-35MB-x86_64.apk"
for arch, filename, reference, abi in (
    ("arm64", apk.name, "ef6b4111b0208d74a4345b855693e28516e41c2eea1bd89686592d0752471f02", "arm64-v8a"),
    ("x64", x64.name, "e2071332e3cb5466afa24699b65da27335eda668d8d6ccf263801e1a4555cd5b", "x86_64"),
):
    data = json.loads((root / "verification" / f"verify-enrollment-qa-35mb-{arch}.json").read_text())
    selected = root / "artifacts" / filename
    with selected.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    assert data["apk"] == filename and data["sha256"] == sha256
    assert data["reference_sha256"] == reference and data["abi"] == abi
    assert data["bytes"] == selected.stat().st_size
    if arch == "arm64":
        assert selected == apk and 0 < data["bytes"] <= 35_000_000
        assert sha256 == "736960b543f698315eaee3d7bf11174cb6ddfc14a8760c04bde288556e585b09"
    else:
        assert (evidence / "apk.sha256").read_text().strip() == sha256

def android_code(path):
    with ZipFile(path) as zip_file:
        return {name: hashlib.sha256(zip_file.read(name)).digest()
                for name in zip_file.namelist()
                if name == "AndroidManifest.xml" or re.fullmatch(r"classes\d*\.dex", name)}

assert android_code(apk) == android_code(x64)
PY
grep -Fq 'All tests passed!' "$q/verification/enrollment-flutter-tests.log"
grep -Fq 'All tests passed!' "$q/verification/enrollment-disk-e2e-final.log"
grep -Fq 'the directory database file has no plaintext SQLite header.' \
  "$evidence/cipher-header.txt"
grep -Eq '^QA signup OTP relayed; Telegram message_id=[1-9][0-9]*$' \
  "$q/verification/enrollment-otp-probe.log"
grep -Fq 'Spare invite: live registration OTP delivered from Mailpit to the verified private chat.' \
  "$q/verification/enrollment-otp-probe.log"
curl -q --noproxy '*' -fsS --max-time 8 https://qa.fyonacompany.com:18443/api/v1/health/ready |
  python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready" and s["version"]["deploy_sha"]=="phase-one-qa-enroll-6193"'
systemctl is-active --quiet fyona-directory-qa-otp.service
test -f /var/lib/private/fyona-directory-qa-otp/receipts/relay-ready
test ! -e "$log"
python3 -B tools/relay_directory_pilot_otp.py invite --apk "$apk" \
  --guide docs/FYONA_PHASE_ONE_QA_SIGNUP_AR.txt --handoff-log "$log"
