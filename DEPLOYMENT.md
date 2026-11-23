# FYONA ERP — Deployment Guide (Ubuntu 24.04 + aaPanel + Docker)

## Overview

This guide covers deploying FYONA ERP on a production Ubuntu 24.04 server
with aaPanel as the control panel and Docker for service orchestration.

**Architecture:**

```
Internet → aaPanel (Nginx) → Docker (FastAPI) → PostgreSQL / Redis / MinIO
                            ↓
                    Celery Workers (background jobs)
```

**VPS Specs Used:** 2 CPU, 8 GB RAM, 96 GB SSD

---

## Prerequisites

- Ubuntu 24.04 server with root/sudo access
- Domain name (e.g., `api.fyona.com`) pointed to the server IP
- aaPanel installed (see section 1)
- Docker & Docker Compose v2

---

## 1. Initial Server Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Set timezone (Riyadh for Arabic users)
sudo timedatectl set-timezone Asia/Riyadh

# Install essential tools
sudo apt install -y curl wget git ufw

# Enable firewall
sudo ufw allow 22/tcp          # SSH
sudo ufw allow 80/tcp          # HTTP
sudo ufw allow 443/tcp         # HTTPS
sudo ufw allow 8888/tcp        # aaPanel
sudo ufw --force enable
```

---

## 2. Install aaPanel

```bash
# Official aaPanel installation (Ubuntu 24)
wget -O install.sh https://www.aapanel.com/script/install-ubuntu_6.0_en.sh
sudo bash install.sh
```

After installation, save the displayed URL, username, and password.
Login to aaPanel at `http://<SERVER_IP>:8888`.

**In aaPanel:**

1. Navigate to **App Store** → Install **Nginx** (not Apache)
2. Optional: Install **PostgreSQL 16** via aaPanel if you prefer managing the DB
   outside Docker (recommended: use Docker as per this guide)

---

## 3. Install Docker & Docker Compose

```bash
# Install Docker
curl -fsSL https://get.docker.com | sudo bash

# Add your user to docker group
sudo usermod -aG docker $USER

# Apply group change
newgrp docker

# Verify
docker --version
docker compose version

# Enable Docker on boot
sudo systemctl enable --now docker
```

---

## 4. Set Up the Project on the Server

```bash
# Create project directory
sudo mkdir -p /var/www/fyona
sudo chown -R $USER:$USER /var/www/fyona
cd /var/www/fyona

# Clone the repository
git clone <YOUR_REPO_URL> .
cd backend
```

### Recommended Directory Structure on Server

```
/var/www/fyona/
├── backend/
│   ├── app/                 # FastAPI application code
│   ├── migrations/          # Alembic migrations
│   ├── nginx/               # aaPanel nginx config template
│   ├── scripts/             # Backup & maintenance scripts
│   ├── requirements.txt     # Python dependencies
│   ├── Dockerfile           # Production Docker image
│   ├── docker-compose.yml   # Service orchestration
│   ├── .dockerignore
│   └── .env                 # Environment variables (NOT in git)
├── backup.sh                # Database backup script
└── backups/                 # Backup output directory
```

---

## 5. Configure Environment Variables

```bash
cd /var/www/fyona/backend
cp .env.example .env
nano .env
```

### Required Variables

Generate secrets for each:

```bash
# Generate a secure JWT_SECRET_KEY
openssl rand -base64 32
```

| Variable | Example Value | Description |
|---|---|---|
| `JWT_SECRET_KEY` | `Yd3xP8mR5sK9vN2qL7jW4tB1cF6hA0eG` | JWT signing key (min 32 chars) |
| `DATABASE_URL` | `postgresql+asyncpg://fyona:STRONG_PASS@db:5432/fyona_erp` | PostgreSQL connection |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection |
| `S3_ACCESS_KEY` | `minioadmin` | MinIO access key |
| `S3_SECRET_KEY` | `CHANGE_THIS_TO_STRONG_SECRET` | MinIO secret key |
| `CELERY_BROKER_URL` | `redis://redis:6379/1` | Celery broker |
| `CELERY_RESULT_BACKEND` | `redis://redis:6379/2` | Celery result backend |
| `CORS_ORIGINS` | `["https://example.com"]` | Allowed CORS origins |
| `ALLOWED_HOSTS` | `["api.fyona.com"]` | Allowed host headers |
| `DEBUG` | `false` | Must be false in production |

> ⚠️ **CORS_ORIGINS** and **ALLOWED_HOSTS** default to `[]` (empty).
> You MUST set them explicitly or all requests will be blocked.

> ⚠️ Change the default PostgreSQL and MinIO passwords in `.env` AND in
> `docker-compose.yml` under the db/minio service environment variables. In
> production, use `docker-compose.yml` variables or a separate `.env.db` file.

**Production `.env` example:**

```ini
APP_NAME=FYONA ERP API
APP_VERSION=1.0.0
DEBUG=false

JWT_SECRET_KEY=<openssl rand -base64 32 output>

DATABASE_URL=postgresql+asyncpg://fyona:STRONG_DB_PASSWORD@db:5432/fyona_erp
REDIS_URL=redis://redis:6379/0

STORAGE_BACKEND=minio
S3_ENDPOINT_URL=http://minio:9000
S3_ACCESS_KEY=minioadmin
S3_SECRET_KEY=STRONG_MINIO_SECRET
S3_BUCKET=fyona-files

CELERY_BROKER_URL=redis://redis:6379/1
CELERY_RESULT_BACKEND=redis://redis:6379/2

CORS_ORIGINS=["https://app.fyona.com"]
ALLOWED_HOSTS=["api.fyona.com"]

OPENAI_API_KEY=
EXCHANGE_RATE_HOST_KEY=
SENTRY_DSN=
LOG_LEVEL=INFO
```

---

## 6. Launch Services with Docker Compose

```bash
cd /var/www/fyona/backend

# Build and start all services
docker compose up -d --build

# Check service status
docker compose ps

# View logs
docker compose logs -f --tail=50 api
```

### Expected Output

```
NAME                 IMAGE                        STATUS                   PORTS
fyona-api            backend-api                  Up (healthy)             127.0.0.1:8000->8000/tcp
fyona-db             postgres:16-alpine            Up (healthy)             127.0.0.1:5432->5432/tcp
fyona-redis          redis:7-alpine                Up (healthy)             127.0.0.1:6379->6379/tcp
fyona-minio          minio/minio:latest            Up (healthy)             127.0.0.1:9000,9001->9000,9001/tcp
fyona-celery         backend-api                   Up                      8000/tcp
fyona-celery-beat    backend-api                   Up                      8000/tcp
```

> All services bind to `127.0.0.1` only, so they are not exposed to the
> public internet. Only aaPanel's Nginx (port 80/443) is public.

---

## 7. Run Database Migrations

```bash
# Run Alembic migrations
docker compose exec api alembic upgrade head

# Verify current migration
docker compose exec api alembic current
```

---

## 8. Create Initial Admin User

```bash
docker compose exec api python -c "
from app.db.session import SessionLocal
from app.domain.services.user_service import UserService
import asyncio

async def create_admin():
    svc = UserService()
    user = await svc.create_super_admin(
        email='admin@fyona.com',
        password='<STRONG_ADMIN_PASSWORD>',
        full_name='مدير النظام'
    )
    print(f'Admin created: {user.email}')

asyncio.run(create_admin())
"
```

---

## 9. Configure aaPanel Reverse Proxy

### Step 9.1: Add Website

In aaPanel:
1. **Websites** → **Add Site**
2. Domain: `api.fyona.com` (replace with your actual domain)
3. Type: **Reverse Proxy**
4. Create the site

### Step 9.2: Configure Reverse Proxy

1. Click **Reverse Proxy** on your site
2. **Add Reverse Proxy** → Name: `fyona-api`
3. Target URL: `http://127.0.0.1:8000`

### Step 9.3: Replace with Optimized Config

Instead of the basic aaPanel config, use the advanced template:

1. Go to **Websites** → Click your site → **配置文件** (Config file)
2. Replace the contents with the template from `nginx/aaPanel-reverse-proxy.conf`
3. Change `api.yourdomain.com` to your actual domain
4. Update SSL certificate paths if needed

Or, manually apply these settings in aaPanel's config editor:

```nginx
upstream fyona_api {
    server 127.0.0.1:8000;
    keepalive 32;
}

server {
    listen 80;
    server_name api.fyona.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.fyona.com;

    # SSL will be added by aaPanel Let's Encrypt
    # DO NOT add ssl_certificate lines manually — aaPanel handles them

    location / {
        proxy_pass http://fyona_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
        client_max_body_size 100M;
    }

    # Deny access to sensitive paths
    location ~ /\.(env|git|venv|py) {
        deny all;
        return 404;
    }

    access_log /www/wwwlogs/api.fyona.com.log;
    error_log  /www/wwwlogs/api.fyona.com.error.log;
}
```

### Step 9.4: Enable SSL

1. In aaPanel → Website → **SSL**
2. Select **Let's Encrypt**
3. Check your domain and click **Apply**
4. Enable **Force HTTPS**

---

## 10. Verify the API

```bash
# Health endpoint (should return 200)
curl https://api.fyona.com/health

# Version endpoint
curl https://api.fyona.com/version

# API docs (if DEBUG=false, docs are disabled for security)
# Use health endpoints instead
```

### Expected Health Response

```json
{
  "status": "healthy",
  "version": {
    "app": "FYONA ERP API",
    "version": "1.0.0",
    "commit": "abc1234",
    "environment": "production",
    "python": ""
  },
  "checks": {
    "database": "ok",
    "redis": "ok"
  }
}
```

### Test Authentication

```bash
# Register a test user
curl -X POST https://api.fyona.com/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@fyona.com","password":"Test@123456","full_name":"Test User","organization_name":"Test Corp","organization_type":"company"}'

# Login
curl -X POST https://api.fyona.com/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@fyona.com","password":"Test@123456"}'
```

---

## 11. Build Flutter APK

On your development machine (NOT the server):

```bash
cd fyona_flutter

# Build release APK with production API URL
flutter build apk --release --split-per-abi \
  --dart-define=API_BASE_URL=https://api.fyona.com/api/v1

# Output location:
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk   (old Android)
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk     (modern Android)
# build/app/outputs/flutter-apk/app-x86_64-release.apk        (emulators)
```

### Distribution for Testing

Send the `app-arm64-v8a-release.apk` to your test users (including your
friend in Germany). The app will connect to your production API.

> **Note:** If you change the API URL later, you must rebuild the APK with
> the new `--dart-define=API_BASE_URL=...`.

---

## 12. Maintenance

### View Service Logs

```bash
# API logs (real-time)
docker compose logs -f --tail=100 api

# Database logs
docker compose logs -f --tail=50 db

# Celery worker logs
docker compose logs -f --tail=50 celery-worker
```

### Update the Deployment

```bash
cd /var/www/fyona/backend
git pull
docker compose up -d --build --force-recreate
docker compose exec api alembic upgrade head
```

### Backup Database

```bash
# Full backup with verification (recommended)
./scripts/backup-full.sh

# Quick backup (legacy, backward compatible)
./scripts/backup.sh

# Backup without off-site copy
./scripts/backup-full.sh --no-offsite

# Backup without encryption
./scripts/backup-full.sh --no-encrypt
```

### Verify Backup

```bash
# Quick verification (checksum + format)
./scripts/backup-verify.sh /opt/fyona/backups/fyona_db_LATEST.sql

# Full verification (includes test restore)
./scripts/backup-verify.sh /opt/fyona/backups/fyona_db_LATEST.sql --full
```

### Restore Database

```bash
# Interactive restore (prompts for confirmation)
./scripts/restore-full.sh /opt/fyona/backups/fyona_db_LATEST.sql

# Verify only (don't restore to production)
./scripts/restore-full.sh /opt/fyona/backups/fyona_db_LATEST.sql --verify-only

# Dry run (show what would happen)
./scripts/restore-full.sh /opt/fyona/backups/fyona_db_LATEST.sql --dry-run

# Non-interactive (for scripts/automation)
./scripts/restore-full.sh /opt/fyona/backups/fyona_db_LATEST.sql --yes
```

### MinIO Backup

```bash
# Backup MinIO buckets
./scripts/backup-minio.sh

# Backup with off-site copy
./scripts/backup-minio.sh --offsite
```

### Set Up Automated Backups (Cron)

```bash
# Install all backup cron jobs (recommended)
./scripts/setup-backup-cron.sh

# Preview what would be installed
./scripts/setup-backup-cron.sh --dry-run

# Manual cron setup (if preferred)
crontab -e
# Add:
0 2 * * * cd /var/www/fyona/backend && ./scripts/backup-full.sh --no-offsite
0 3 * * * cd /var/www/fyona/backend && ./scripts/backup-minio.sh
0 4 * * 0 cd /var/www/fyona/backend && ./scripts/backup-verify.sh $(ls -t /opt/fyona/backups/fyona_db_*.sql | head -1) --full
```

### WAL Archiving (Point-in-Time Recovery)

```bash
# Enable WAL archiving (run once, then restart PostgreSQL)
./scripts/setup-wal-archiving.sh

# Restart PostgreSQL to apply changes
docker compose restart db
```

---

## 13. Resource Monitoring

```bash
# Check container resource usage
docker stats

# Check disk usage
df -h

# Check Docker disk usage
docker system df

# View recent Docker logs
docker compose logs --tail=50
```

### Monitor with aaPanel

In aaPanel:
- **Dashboard** → Real-time CPU, RAM, disk, network monitoring
- **Security** → Firewall, SSH status, login attempts
- **Files** → Browse and manage `/var/www/fyona/`

---

## 14. Production Checklist

| Item | Done? | Notes |
|---|---|---|
| `DEBUG=false` in `.env` | ☐ | Must be false |
| `JWT_SECRET_KEY` ≥ 32 random chars | ☐ | Generated with `openssl rand -base64 32` |
| `CORS_ORIGINS` set explictly | ☐ | Not `[]`, not `["*"]` |
| `ALLOWED_HOSTS` set explicitly | ☐ | Not `[]`, not `["*"]` |
| PostgreSQL password changed | ☐ | Changed from default in `.env` AND `docker-compose.yml` |
| MinIO credentials changed | ☐ | Changed from defaults |
| HTTPS enabled via Let's Encrypt | ☐ | In aaPanel SSL section |
| Firewall allows only needed ports | ☐ | 22, 80, 443, 8888 |
| Docker services all "healthy" | ☐ | `docker compose ps` |
| Database migrations ran | ☐ | `alembic upgrade head` |
| Admin user created | ☐ | Can login with admin credentials |
| APK built with production URL | ☐ | `--dart-define=API_BASE_URL=https://...` |
| Test user can login from APK | ☐ | End-to-end test |
| Daily backups configured | ☐ | `./scripts/setup-backup-cron.sh` |
| WAL archiving enabled | ☐ | `./scripts/setup-wal-archiving.sh` + restart db |
| Backup verification tested | ☐ | `./scripts/backup-verify.sh --full` |
| Off-site backup configured | ☐ | rclone configured for off-site storage |
| MinIO backup configured | ☐ | `./scripts/backup-minio.sh` |
| Restore tested | ☐ | `./scripts/restore-full.sh --verify-only` |
| DR runbook reviewed | ☐ | See `DR_RUNBOOK.md` |
| Sentry DSN configured (optional) | ☐ | For error tracking |

---

## 15. Troubleshooting

| Problem | Likely Cause | Solution |
|---|---|---|
| `docker compose up` fails | Port conflict (PostgreSQL already running on host) | Stop host Postgres: `sudo systemctl stop postgresql` |
| API returns 502 from Nginx | API container not running or not healthy | `docker compose ps` → check `api` status |
| API returns 503 | Server shutting down | Wait 10s, retry |
| CORS errors in Flutter app | `CORS_ORIGINS` not set in `.env` | Add `CORS_ORIGINS=["https://app.fyona.com"]` |
| `ERR_CERT_AUTHORITY_INVALID` | SSL not configured | Setup Let's Encrypt in aaPanel |
| "Database connection refused" | PostgreSQL still starting up | Wait 30s (start_period), check `docker compose logs db` |
| Alembic migration fails | Database URL mismatch | Ensure `DATABASE_URL` in `.env` matches docker-compose |
| "429 Too Many Requests" | Rate limit hit | Wait 60s, or increase `RATE_LIMIT_PER_MINUTE` in `.env` |
| APK connects to old server | Wrong `--dart-define` | Rebuild with correct `API_BASE_URL` |
| File upload fails | MinIO credentials mismatch | Check `S3_ACCESS_KEY` / `S3_SECRET_KEY` match in both `.env` and MinIO |

---

## 16. Zero-Downtime Update (Future)

For zero-downtime deployments in the future, add a load balancer or use
Docker Swarm / Kubernetes. The current setup has ~5-10s downtime during
`docker compose up --force-recreate`.

To minimize downtime:

```bash
# Start new containers alongside old ones, then switch
docker compose up -d --build --no-deps --scale api=2 api
# Then remove old container
docker compose up -d --no-deps --scale api=1 api
```
