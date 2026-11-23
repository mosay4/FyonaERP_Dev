#!/usr/bin/env bash
# Deploy the current backend/app (with the Business relay) to the managed QA
# enrollment service only. Same environment/credentials as the running
# release; on failure it restores the previous release automatically.
set -euo pipefail
umask 077
work=/root/.local/share/fyona-erp/qa/phase-one-6193/implementation
base=/opt/fyona-directory-qa
drop=/run/systemd/system/fyona-directory-qa-enroll.service.d/60-business-6193.conf
previous=$(sed -n "s#.*\($base/releases/[^/]*\)/tools.*#\1#p" "$drop" | head -1)
test -d "$previous"
cd "$work"
release="$base/releases/business-6193-relay.$(openssl rand -hex 4)"
install -d -m 0755 "$release/tools" "$release/backend" "$release/rollback"
chmod 0755 "$release"
install -m 0644 "$previous/tools/run_directory_pilot_lab.py" "$release/tools/run_directory_pilot_lab.py"
cp -a backend/app "$release/backend/app"
find "$release/backend" -name '__pycache__' -type d -prune -exec rm -r {} +
find "$release/backend" -type d -exec chmod 0755 {} +
find "$release/backend" -type f -exec chmod 0644 {} +
ln -s "$base/python" "$release/python"
install -m 0600 "$previous/rollback/ledger-continuity" "$release/rollback/ledger-continuity"
install -m 0600 "$drop" "$release/rollback/60-business-6193.previous.conf"
sed "s#$previous#$release#g" "$release/rollback/60-business-6193.previous.conf" > "$drop"
systemctl daemon-reload
systemctl restart fyona-directory-qa-enroll
for _ in $(seq 1 240); do
  if curl -q --noproxy '*' -fsS --max-time 5 https://qa.fyonacompany.com:18443/api/v1/health/ready | grep -q '"ready"'; then
    echo "ready: $release (previous: $previous)"
    exit 0
  fi
  sleep 1
done
echo "NOT READY — restoring previous release"
install -m 0600 "$release/rollback/60-business-6193.previous.conf" "$drop"
systemctl daemon-reload
systemctl restart fyona-directory-qa-enroll
exit 1
