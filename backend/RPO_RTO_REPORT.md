# FYONA ERP — RPO/RTO Analysis & Report

## Executive Summary

| Metric | Current State | Target (Post Phase 2) | Industry Standard |
|--------|---------------|----------------------|-------------------|
| **RPO** (Recovery Point Objective) | Unknown (no scheduled backups) | **24 hours** | 1-24 hours |
| **RTO** (Recovery Time Objective) | Unknown (no DR plan) | **2 hours** | 1-8 hours |
| **Backup Frequency** | Manual, unscheduled | Daily automated | Daily-Hourly |
| **Backup Verification** | None | Weekly automated | Weekly |
| **Off-site Copies** | None | Daily | Daily |
| **Restore Testing** | None | Monthly | Monthly |

---

## 1. Current State Assessment

### What Exists
- ✅ `backup.sh` — Basic pg_dump script (not scheduled)
- ✅ `restore.sh` — Basic restore script (no safety checks)
- ✅ `DEPLOYMENT.md` references cron at 03:00 (not configured)
- ✅ Docker volumes: `pgdata`, `redisdata`, `miniodata` (all local)

### What's Missing
- ❌ No automated backup schedule (cron not configured)
- ❌ No WAL archiving (no PITR capability)
- ❌ No off-site backup copies
- ❌ No backup encryption
- ❌ No backup verification
- ❌ No restore testing
- ❌ No MinIO backup
- ❌ No alerting on failure
- ❌ No DR runbook

### Risk Assessment
| Risk | Impact | Likelihood | Severity |
|------|--------|------------|----------|
| VPS failure | Total data loss | Medium | **CRITICAL** |
| Database corruption | Data loss since last backup | Medium | **HIGH** |
| Accidental deletion | Partial data loss | High | **HIGH** |
| Ransomware | Total data loss | Low | **CRITICAL** |

---

## 2. PostgreSQL Data Size Analysis

### Estimated Size (Based on Typical SaaS)
```
Businesses table:        ~100 rows × 2KB    = 200 KB
Users table:             ~500 rows × 1KB    = 500 KB
Suggestions table:       ~10,000 rows × 5KB = 50 MB
Banners table:           ~100 rows × 1KB    = 100 KB
Subscription proofs:     ~2,000 rows × 10KB = 20 MB
Platform bank accounts:  ~10 rows × 1KB     = 10 KB
Other tables:            ~5,000 rows × 2KB  = 10 MB
─────────────────────────────────────────────────
Estimated total:         ~80 MB uncompressed
With pg_dump --compress: ~20 MB compressed
```

### WAL Volume Estimate
```
Daily WAL generation (typical SaaS): ~100 MB - 500 MB
7-day WAL retention:                  ~700 MB - 3.5 GB
```

---

## 3. Target Architecture

### Backup Strategy
```
┌─────────────────────────────────────────────────────────┐
│                    FYONA ERP VPS                         │
├─────────────────────────────────────────────────────────┤
│  PostgreSQL                                              │
│  ├── WAL Archiving → /opt/fyona/backups/wal/            │
│  ├── Daily pg_dump → /opt/fyona/backups/fyona_db_*.sql  │
│  └── Weekly verification (test restore)                  │
│                                                          │
│  MinIO                                                   │
│  └── Daily mirror → /opt/fyona/backups/minio/           │
│                                                          │
│  Cron Jobs                                               │
│  ├── 02:00 - Full database backup                        │
│  ├── 03:00 - MinIO backup                                │
│  ├── 04:00 Sun - Backup verification                     │
│  └── 01:00 - WAL cleanup                                 │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│              Off-Site Storage (rclone)                    │
│  └── s3://fyona-backups/ or rsync://remote/              │
└─────────────────────────────────────────────────────────┘
```

### Recovery Scenarios

| Scenario | RPO | RTO | Method |
|----------|-----|-----|--------|
| Database corruption | 24 hours | 1-2 hours | `restore-full.sh` |
| Complete VPS loss | 24 hours | 2-4 hours | New VPS + off-site restore |
| MinIO data loss | 24 hours | 30 minutes | `backup-minio.sh` restore |
| Application failure | 0 (no data loss) | 5-15 minutes | `deploy-backend.sh` |

---

## 4. Cost Analysis

### Off-Site Storage Options

| Option | Monthly Cost | Pros | Cons |
|--------|-------------|------|------|
| **Backblaze B2** | ~$0.50/GB | Cheap, S3-compatible | Requires setup |
| **AWS S3** | ~$0.023/GB | Industry standard | More expensive |
| **DigitalOcean Spaces** | $5/mo flat | Simple, 250GB included | Limited regions |
| **VPS rsync** | Free (if second VPS) | Full control | Need second VPS |

### Recommended
For ~80 MB database + ~500 MB MinIO:
- **Backblaze B2**: ~$0.15/month
- **DigitalOcean Spaces**: $5/month (includes 250GB)

---

## 5. Implementation Checklist

- [ ] PostgreSQL WAL archiving enabled
- [ ] `backup-full.sh` with verification + encryption
- [ ] `backup-minio.sh` for MinIO protection
- [ ] `backup-verify.sh` for automated testing
- [ ] `restore-full.sh` with safety checks
- [ ] Cron jobs configured
- [ ] Off-site storage configured (rclone)
- [ ] Backup alerting configured
- [ ] DR runbook created
- [ ] First backup verified
- [ ] First restore test completed

---

## 6. Monitoring & Alerting

### Backup Monitoring
- **Success**: Log to `backup.log`, optional webhook
- **Failure**: Log to `alerts.log`, webhook + email
- **Weekly**: Verification report

### Key Metrics to Track
1. Backup size trend (detect data growth)
2. Backup duration (detect performance issues)
3. Restore time (validate RTO)
4. Off-site sync status

---

## 7. Maintenance Schedule

| Task | Frequency | Duration |
|------|-----------|----------|
| Verify backup restorability | Weekly | 10 minutes |
| Full restore test | Monthly | 30 minutes |
| DR drill (Scenario 2) | Quarterly | 2 hours |
| Review and update runbook | Annually | 1 hour |
| Rotate encryption keys | Annually | 15 minutes |
| Review retention policy | Quarterly | 15 minutes |

---

## Conclusion

### Implementation Status (Honest Assessment)

| Component | Code Written | Deployed to VPS | Activated | Tested |
|-----------|-------------|-----------------|-----------|--------|
| `backup-full.sh` | ✅ | ❌ | ❌ | ❌ |
| `restore-full.sh` | ✅ | ❌ | ❌ | ❌ |
| `backup-verify.sh` | ✅ | ❌ | ❌ | ❌ |
| `backup-minio.sh` | ✅ | ❌ | ❌ | ❌ |
| `setup-wal-archiving.sh` | ✅ | ❌ | ❌ | ❌ |
| `setup-backup-cron.sh` | ✅ | ❌ | ❌ | ❌ |
| `backup-alerting.sh` | ✅ | ❌ | ❌ | ❌ |
| `DR_RUNBOOK.md` | ✅ | N/A | N/A | N/A |
| `RPO_RTO_REPORT.md` | ✅ | N/A | N/A | N/A |
| WAL volume mount (prod) | ✅ | ❌ | ❌ | ❌ |
| Off-site (rclone) | ❌ | ❌ | ❌ | ❌ |
| GPG encryption key | ❌ | ❌ | ❌ | ❌ |

**What this means:**
- All scripts are written and code-reviewed
- Bugs have been identified and fixed
- Nothing has been deployed to the VPS yet
- Nothing has been activated or tested
- Off-site storage is NOT configured (no rclone, no remote)
- Encryption is NOT configured (no GPG passphrase)

### Actual RPO/RTO (Current State — Before VPS Deployment)

| Metric | Actual Value | Notes |
|--------|-------------|-------|
| **RPO** | **Unknown / ∞** | No backups are running. No cron jobs installed. |
| **RTO** | **Unknown / ∞** | No restore has been tested. No DR drill performed. |

### Target RPO/RTO (After Full Deployment + Testing)

| Metric | Target | Prerequisites |
|--------|--------|---------------|
| **RPO** | **24 hours** | Cron jobs installed + first backup verified |
| **RPO (with PITR)** | **5 minutes** | WAL archiving activated + tested |
| **RTO** | **2 hours** | First full restore test completed |

### What Must Happen Before Claiming Phase 2 Complete

1. Deploy all scripts to VPS
2. Install cron jobs (`setup-backup-cron.sh`)
3. Run first backup (`backup-full.sh`)
4. Verify backup (`backup-verify.sh --full`)
5. Test restore to temp database (`restore-full.sh --verify-only`)
6. Enable WAL archiving (`setup-wal-archiving.sh` + restart db)
7. Verify WAL files are being archived
8. Configure rclone for off-site storage (requires your approval)
9. Configure GPG passphrase for encryption (requires your decision)
10. Run first MinIO backup (`backup-minio.sh`)
11. Complete full DR drill (Scenario 2 from runbook)

**Estimated Production Readiness Score after full deployment + testing: 90-95/100**