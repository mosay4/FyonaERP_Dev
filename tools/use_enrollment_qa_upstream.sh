#!/usr/bin/env bash
# Only reconfigure the existing disposable QA TLS proxy; not prod or firewall.
set -euo pipefail
umask 077

q="$HOME/.local/share/fyona-erp/qa/phase-one-6193"
state=/var/lib/private/fyona-directory-qa-enroll/run
service=fyona-directory-qa-tls.service
proxy=/opt/fyona-directory-qa/tools
hostname=qa.fyonacompany.com
certs="$q/tls-qa/conf/live/$hostname"
mode="${1:-enroll}"
config="$(cd "$(dirname "$0")" && pwd)/directory_pilot_qa.Caddyfile"
export FYONA_QA_CERT="$certs/fullchain.pem" FYONA_QA_KEY="$certs/privkey.pem"
export FYONA_QA_TLS_BIND=148.230.115.21

case "$mode" in
  enroll)
    test -f "$state/ready"
    port=18085
    sha=phase-one-qa-enroll-6193
    ;;
  baseline)
    port=18084
    sha=phase-one-qa-6193
    ;;
  *) exit 2 ;;
esac
curl -q --noproxy '*' -fsS --max-time 8 "http://127.0.0.1:$port/api/v1/health/ready" |
  python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["status"]=="ready" and s["version"]["deploy_sha"]==sys.argv[1]' "$sha"
export FYONA_QA_UPSTREAM=127.0.0.1:$port
"$proxy/caddy" validate --config "$config" --adapter caddyfile
install -m 644 "$config" "$proxy/Caddyfile"
systemctl show --property=FragmentPath --value "$service" |
  grep -Fx "/run/systemd/transient/$service"

test -d "/run/systemd/system"
mkdir -p "/run/systemd/system/$service.d"
printf '[Service]\nEnvironment=FYONA_QA_UPSTREAM=%s\n' "$FYONA_QA_UPSTREAM" \
  > "/run/systemd/system/$service.d/95-phase-one-upstream.conf"
systemctl daemon-reload
systemctl restart "$service"
