#!/bin/bash
set -e

ADMIN_DIR="/opt/fyona/admin"
ADMIN_WEB="${ADMIN_DIR}/web"
MASTER_KEY=$(sudo grep '^ADMIN_MASTER_KEY=' /opt/fyona/backend/.env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")

if [ ! -f "${ADMIN_DIR}/server/admin_server.py" ]; then
    echo "ERROR: Admin files not found at ${ADMIN_DIR}/server/admin_server.py"
    exit 1
fi

sudo pip3 install -q fastapi uvicorn httpx 2>/dev/null || true

sudo tee "${ADMIN_DIR}/server/.env" > /dev/null << ENVEOF
FYONA_API=http://127.0.0.1:8001
ADMIN_EMAIL=admin@fyona.erp
ADMIN_PASSWORD=msf$mrold$fyona_erp
ADMIN_MASTER_KEY=${MASTER_KEY}
ENVEOF

sudo tee /etc/systemd/system/fyona-admin.service > /dev/null << SVCEOF
[Unit]
Description=FYONA Admin Panel
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/fyona/admin/server
ExecStart=/usr/bin/python3 -m uvicorn admin_server:app --host 0.0.0.0 --port 8080 --log-level info
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable fyona-admin
sudo systemctl restart fyona-admin
sleep 3

if curl -sf http://127.0.0.1:8080/api/version; then
    echo ""
    echo "Admin panel confirmed running on port 8080"
else
    echo "ERROR: Admin panel failed to start"
    sudo systemctl status fyona-admin --no-pager 2>&1 | tail -20
    exit 1
fi

NGINX_DIR="/www/server/panel/vhost/nginx"
test -d "$NGINX_DIR" || NGINX_DIR="/etc/nginx/conf.d"
NGINX_CONF="$NGINX_DIR/admin.dssdfs.fun.conf"

SSL_CERT=$(find /etc/letsencrypt/live -name fullchain.pem 2>/dev/null | head -1)
SSL_KEY=$(find /etc/letsencrypt/live -name privkey.pem 2>/dev/null | head -1)

if test -n "$SSL_CERT" && test -f "$SSL_CERT"; then
    sudo tee "$NGINX_CONF" > /dev/null << NGINXSSL
server {
    listen 80;
    server_name admin.dssdfs.fun;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name admin.dssdfs.fun;
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    client_max_body_size 50M;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINXSSL
    echo "Nginx config created for admin.dssdfs.fun (SSL)"
else
    sudo tee "$NGINX_CONF" > /dev/null << NGINXHTTP
server {
    listen 80;
    server_name admin.dssdfs.fun;
    client_max_body_size 50M;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINXHTTP
    echo "Nginx config created for admin.dssdfs.fun (HTTP only)"
fi
sudo nginx -t 2>&1 && sudo nginx -s reload 2>/dev/null || echo "Nginx reload skipped"
