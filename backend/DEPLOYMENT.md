# FYONA ERP — Production Deployment Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions CI/CD                    │
│                                                         │
│  Push to main → Tests → Build → GHCR → Deploy to VPS     │
│                                                         │
│  1. backend-tests  (pytest unit + health tests)           │
│  2. docker-build   (Docker Buildx → ghcr.io/fyona-api:SHA)│
│  3. trivy-scan     (vulnerability scan CRITICAL/HIGH)    │
│  4. deploy         (SSH → deploy-backend.sh on VPS)      │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    VPS (Ubuntu 24.04)                    │
│                                                         │
│  deploy-backend.sh:                                     │
│    ├─ Acquire deployment lock (flock)                     │
│    ├─ Authenticate to GHCR (via GHCR_TOKEN env var)       │
│    ├─ Pull fresh image from GHCR:SHA                      │
│    ├─ Stop current containers (graceful)                  │
│    ├─ Deploy new containers (docker compose up)           │
│    ├─ Wait for health check (/api/v1/health/ready)        │
│    ├─ Verify celery workers running                       │
│    ├─ Run smoke tests (20 checks)                         │
│    ├─ Record deployment metadata                          │
│    └─ On failure → Auto-rollback to last-known-good SHA    │
└─────────────────────────────────────────────────────────┘
```

## Image Versioning

Images are tagged with the **short Git SHA** (12 characters), never `latest`:

```
ghcr.io/fyona-erp/fyona-api:abc123def456
```

To rollback, redeploy with a previous SHA tag.

## Deployment Lock

File-based locking prevents concurrent deployments:

```bash
# Check status
bash /opt/fyona/backend/scripts/deploy-lock.sh status
# Output: LOCK_FREE or LOCK_HELD since=...

# Acquire (called internally by deploy-backend.sh)
bash /opt/fyona/backend/scripts/deploy-lock.sh acquire

# Release (on exit)
bash /opt/fyona/backend/scripts/deploy-lock.sh release
```

## Deployment Metadata

Every deployment is recorded with:

```bash
# Record a deployment
bash /opt/fyona/backend/scripts/deploy-metadata.sh record <sha> <status> <previous_sha>

# View current
bash /opt/fyona/backend/scripts/deploy-metadata.sh current

# View history
bash /opt/fyona/backend/scripts/deploy-metadata.sh history [n]

# Get rollback target
bash /opt/fyona/backend/scripts/deploy-metadata.sh rollback-info
```

## Health Checks

Three-tier health check system:

| Endpoint | Purpose | Frequency | Critical Deps |
|----------|---------|-----------|---------------|
| `/health/live` | Is the process alive? | 30s (Docker) | None |
| `/api/v1/health/ready` | Ready to serve traffic? | 30s (Docker + Deploy) | DB, Redis |
| `/health` | Full dependency check | On-demand (monitoring) | DB, Redis, MinIO |

## Smoke Tests

Post-deploy smoke tests verify 20 aspects:

1. Liveness check (HTTP 200)
2. Readiness check (HTTP 200, all deps ok)
3. Full health check (HTTP 200)
4. Health: database = ok
5. Health: redis = ok
6. Version endpoint with commit SHA
7. Health response time (<3s)
8. Subscription plans endpoint (HTTP 200)
9. Active banners endpoint (HTTP 200)
10. Auth login endpoint exists (HTTP 422)
11. Auth register endpoint exists (HTTP 422)
12-14. Protected endpoints return 401
15. Health response has status + checks fields
16. API prefix resolves (HTTP 404)
17-19. All containers running
20. MinIO health OK

## Rollback

Automatic rollback on failure:

1. **Health check failure** → Rollback
2. **Celery not running** → Rollback
3. **Smoke test failure** → Rollback

Rollback process:
1. Reads last successful SHA from deployment metadata
2. Pulls that SHA's image from GHCR
3. Recreates all app containers
4. Waits for health check to pass
5. Records rollback in metadata

## Secrets Management

- **Development secrets**: `.env` (local only, never committed)
- **Production secrets**: `.env.production` (on VPS only, never committed, permissions 600)
- **All secrets are separate**: production uses different keys from development
- **No secrets in Git**: `.gitignore` excludes all `.env*` except `.env.example` and `.env.production.example`
- **No secrets in CI/CD**: GitHub Actions uses `secrets.GITHUB_TOKEN` for GHCR and `secrets.GHCR_TOKEN` for VPS pulls

## Database Migrations

Migration safety:
- Backward-compatible migrations applied automatically
- Pre-flight DB connectivity check
- Post-migration schema validation
- Manual approval for destructive migrations

Run migrations:
```bash
sudo /opt/fyona/bin/migrate-backend.sh
# Or with specific SHA:
DEPLOY_SHA=<commit-sha> GHCR_TOKEN=<token> sudo /opt/fyona/bin/migrate-backend.sh
```

## Zero Downtime

Current architecture achieves minimal downtime through:
- Containers stop/start in seconds
- Health check gate prevents premature routing
- If health check fails, rollback restores service
- Data volumes are never destroyed during deployment

For true zero-downtime, consider:
- Adding `--wait` flag to docker compose
- Using blue-green deployment with duplicate service sets
- Adding HAProxy/nginx upstream with backup servers

## CI/CD Pipeline Triggers

| Trigger | Action |
|---------|--------|
| Push to `main` | Full CI/CD: tests → build → scan → **auto-deploy** |
| Push to `develop` | Tests + build only (no deploy) |
| PR to `main` | Tests + build only (no deploy, uses GITHUB_TOKEN) |
| `workflow_dispatch` | Manual deploy with optional migrations |

## Required GitHub Secrets

| Secret | Used By | Purpose |
|--------|--------|---------|
| `SERVER_HOST` | deploy job | VPS IP address |
| `SERVER_USER` | deploy job | SSH username (root) |
| `SERVER_PORT` | deploy job | SSH port |
| `SSH_PRIVATE_KEY` | deploy job | SSH key for VPS access |
| `GHCR_TOKEN` | deploy/migrate jobs | Pull images from GHCR |

## Required GitHub Permissions

| Permission | Purpose |
|------------|---------|
| `contents: read` | Checkout code |
| `packages: read` | Pull/push GHCR images |
| `id-token: write` | (Future) OIDC auth for GHCR |
