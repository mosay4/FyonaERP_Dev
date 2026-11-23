#!/usr/bin/env bash
# Deploy the cash-link and two-branch writer trial to the managed QA
# enrollment service only. Production, Caddy and the second QA API are
# untouched. Existing QA grants (including the fenced real branch) stay.
set -euo pipefail
umask 077
work=/root/.local/share/fyona-erp/qa/phase-one-6193/implementation
base=/opt/fyona-directory-qa
run=/var/lib/private/fyona-directory-qa-enroll/run
drop=/run/systemd/system/fyona-directory-qa-enroll.service.d/60-business-6193.conf
cd "$work"
release="$base/releases/business-6193.$(openssl rand -hex 4)"
test ! -e "$release"
install -d -m 0755 "$release/tools" "$release/backend" "$release/rollback"
chmod 0755 "$release"
install -m 0644 tools/run_directory_pilot_lab.py "$release/tools/run_directory_pilot_lab.py"
cp -a backend/app "$release/backend/app"
find "$release/backend" -name '__pycache__' -type d -prune -exec rm -r {} +
find "$release/backend" -type d -exec chmod 0755 {} +
find "$release/backend" -type f -exec chmod 0644 {} +
ln -s "$base/python" "$release/python"
install -m 0600 "$base/releases/business-6193.FbMJiVeL/rollback/ledger-continuity" \
  "$release/rollback/ledger-continuity"
install -m 0600 "$drop" "$release/rollback/60-business-6193.before-link.conf"
cat > "$drop" <<EOF
[Service]
Environment=FYONA_QA_ENROLL_NEW_LEDGER=1 FYONA_QA_CASH_RELAY=1 FYONA_QA_EMPLOYEE_FINANCE=1 FYONA_QA_BUSINESS_PROBES=1 FYONA_QA_CASH_LINK=1 FYONA_QA_BUSINESS_LINK_PROBES=1
LoadCredential=ledger-continuity:$release/rollback/ledger-continuity
ExecStart=
ExecStart=/bin/sh -c 'exec /usr/bin/python3 $release/tools/run_directory_pilot_lab.py "\$\$STATE_DIRECTORY/run"'
EOF
systemctl daemon-reload
systemctl restart fyona-directory-qa-enroll
printf '%s\n' "$release" > "$work/../verification/business-link-and-transfer-6193/managed-release.path"
for _ in $(seq 1 240); do
  if curl -q --noproxy '*' -fsS --max-time 5 https://qa.fyonacompany.com:18443/api/v1/health/ready |
       python3 -c 'import json,sys; h=json.load(sys.stdin); assert h["status"]=="ready"; print(h["version"]["deploy_sha"])' > /tmp/opencode/fyona-link-sha; then
    break
  fi
  sleep 1
done
cat /tmp/opencode/fyona-link-sha
grep -Fx 'phase-one-qa-enroll-6193-link' /tmp/opencode/fyona-link-sha
test -f "$run/ready"
echo "Managed QA link trial active; other services unchanged."
