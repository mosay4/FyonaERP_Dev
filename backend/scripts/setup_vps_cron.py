#!/usr/bin/env python3
"""Set up cron jobs for FYONA ERP backup system."""
import os
import sys
import paramiko

VPS_HOST = os.environ.get("VPS_HOST", "187.77.84.224")
VPS_PORT = int(os.environ.get("VPS_PORT", "22"))
VPS_USER = os.environ.get("VPS_USER", "root")
VPS_PASS = os.environ.get("VPS_PASS", "")

if not VPS_PASS:
    print("ERROR: VPS_PASS environment variable is required.", file=sys.stderr)
    print("Usage: VPS_PASS='your-password' python setup_vps_cron.py", file=sys.stderr)
    sys.exit(1)

CRON_ENTRIES = """
# ─── FYONA ERP Automated Backups ──
# Daily PostgreSQL backup (encrypted) at 02:30
30 2 * * * BACKUP_GPG_PASSPHRASE=$(cat /opt/fyona/.backup-encryption-key) /opt/fyona/backup.sh >> /opt/fyona/backups/backup.log 2>&1

# Daily MinIO backup at 03:00
0  3 * * * /opt/fyona/backend/scripts/backup-minio.sh >> /opt/fyona/backups/minio_backup.log 2>&1

# Weekly backup verification (Sunday 04:00)
0  4 * * 0 LATEST=$(ls -t /opt/fyona/backups/daily/fyona_*.sql.gz 2>/dev/null | head -1); if [ -n "$LATEST" ]; then gzip -t "$LATEST" 2>>/opt/fyona/backups/verify.log && echo "Verify OK: $LATEST" >> /opt/fyona/backups/verify.log || echo "Verify FAIL: $LATEST" >> /opt/fyona/backups/verify.log; fi

# WAL archive cleanup (daily 01:00, keep 7 days)
0  1 * * * find /opt/fyona/backups/wal -name '0*' -mtime +7 -delete 2>/dev/null

# Log cleanup (weekly Monday 05:00, keep 30 days)
0  5 * * 1 find /opt/fyona/backups -name 'cron_*.log' -mtime +30 -delete 2>/dev/null
"""

def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(VPS_HOST, port=VPS_PORT, username=VPS_USER, password=VPS_PASS, timeout=30)
    
    # Get existing cron (excluding old FYONA backup entry)
    stdin, stdout, stderr = client.exec_command("crontab -l 2>/dev/null | grep -v '/opt/fyona/backup.sh' || true")
    existing = stdout.read().decode('utf-8', errors='replace')
    
    # Combine old + new
    new_crontab = existing.strip() + "\n" + CRON_ENTRIES
    
    # Set new crontab
    stdin, stdout, stderr = client.exec_command(f"echo '{new_crontab}' | crontab -")
    stdout.channel.recv_exit_status()
    
    # Verify
    stdin, stdout, stderr = client.exec_command("crontab -l")
    print(stdout.read().decode('utf-8', errors='replace'))
    
    client.close()
    print("Cron jobs installed successfully")

if __name__ == "__main__":
    main()
