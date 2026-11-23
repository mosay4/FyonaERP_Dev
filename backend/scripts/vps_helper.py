#!/usr/bin/env python3
"""SSH helper for FYONA VPS audit and Phase 2 activation."""
import os
import paramiko
import sys
import time

VPS_HOST = os.environ.get("VPS_HOST", "187.77.84.224")
VPS_PORT = int(os.environ.get("VPS_PORT", "22"))
VPS_USER = os.environ.get("VPS_USER", "root")
VPS_PASS = os.environ.get("VPS_PASS", "")

if not VPS_PASS:
    print("ERROR: VPS_PASS environment variable is required.", file=sys.stderr)
    print("Usage: VPS_PASS='your-password' python vps_helper.py ...", file=sys.stderr)
    sys.exit(1)

def get_client():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(VPS_HOST, port=VPS_PORT, username=VPS_USER, password=VPS_PASS, timeout=15)
    return client

def run(cmd, timeout=30):
    """Run a command on the VPS and return (exit_code, stdout, stderr)."""
    client = get_client()
    try:
        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode('utf-8', errors='replace').strip()
        err = stderr.read().decode('utf-8', errors='replace').strip()
        return exit_code, out, err
    finally:
        client.close()

def run_safe(cmd, timeout=30):
    """Run and print output. Returns True on success."""
    code, out, err = run(cmd, timeout)
    if out:
        sys.stdout.buffer.write((out + "\n").encode('utf-8', errors='replace'))
        sys.stdout.buffer.flush()
    if err and code != 0:
        sys.stdout.buffer.write((f"STDERR: {err}\n").encode('utf-8', errors='replace'))
        sys.stdout.buffer.flush()
    return code == 0

def upload(local_path, remote_path):
    """Upload a local file to the VPS via SSH."""
    client = get_client()
    try:
        sftp = client.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
        return True
    except Exception as e:
        print(f"Upload error: {e}", file=sys.stderr)
        return False
    finally:
        client.close()

def download(remote_path, local_path):
    """Download a file from the VPS via SSH."""
    client = get_client()
    try:
        sftp = client.open_sftp()
        sftp.get(remote_path, local_path)
        sftp.close()
        return True
    except Exception as e:
        print(f"Download error: {e}", file=sys.stderr)
        return False
    finally:
        client.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python vps_helper.py <command> [args]")
        print("Commands:")
        print("  audit                         - Run full VPS audit")
        print("  run <cmd>                     - Run command on VPS")
        print("  upload <local> <remote>       - Upload file to VPS")
        print("  download <remote> <local>     - Download file from VPS")
        sys.exit(1)

    if sys.argv[1] == "audit":
        print("=" * 60)
        print("FYONA ERP VPS READ-ONLY AUDIT")
        print("=" * 60)
        
        sections = [
            ("OS Information", "cat /etc/os-release | head -5"),
            ("Disk Space", "df -h / /opt 2>/dev/null"),
            ("Memory", "free -h"),
            ("Docker Version", "docker --version; docker compose version"),
            ("Running Containers", "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"),
            ("All Containers", "docker ps -a --format 'table {{.Names}}\t{{.Status}}'"),
            ("Docker Volumes", "docker volume ls"),
            ("Docker Compose Project", "find /opt -name 'docker-compose.yml' -o -name 'docker-compose.prod.yml' 2>/dev/null"),
            ("Cron Jobs", "crontab -l 2>/dev/null || echo 'No crontab configured'"),
            ("rclone", "which rclone 2>/dev/null && rclone version 2>/dev/null | head -1 || echo 'NOT INSTALLED'"),
            ("mc (MinIO Client)", "/usr/local/bin/mc --version 2>/dev/null | head -1 || echo 'NOT INSTALLED'"),
            ("GPG", "which gpg 2>/dev/null && gpg --version 2>/dev/null | head -1 || echo 'NOT INSTALLED'"),
            ("Backup Directory", "ls -la /opt/fyona/backups/ 2>/dev/null || echo 'NO BACKUP DIRECTORY'"),
            ("Project Root", "ls -la /opt/fyona/ 2>/dev/null || echo 'NOT FOUND'"),
            ("Backend Scripts", "ls -la /opt/fyona/backend/scripts/*.sh 2>/dev/null || echo 'Scripts not found'"),
        ]
        
        for title, cmd in sections:
            print(f"\n--- {title} ---")
            run_safe(cmd)
        
        # Check PostgreSQL config
        print("\n--- PostgreSQL WAL Configuration ---")
        run_safe("docker exec fyona-db psql -U fyona -d fyona_erp -c \"SHOW wal_level;\" 2>/dev/null || echo 'Cannot query PostgreSQL'")
        run_safe("docker exec fyona-db psql -U fyona -d fyona_erp -c \"SHOW archive_mode;\" 2>/dev/null || echo 'Cannot query PostgreSQL'")
        run_safe("docker exec fyona-db psql -U fyona -d fyona_erp -c \"SHOW archive_command;\" 2>/dev/null || echo 'Cannot query PostgreSQL'")
        
        # Check WAL mount
        print("\n--- WAL Archive Mount ---")
        run_safe("docker exec fyona-db sh -c 'test -d /var/lib/postgresql/wal_archive && echo MOUNTED || echo NOT_MOUNTED'")
        
        # Check rclone config
        print("\n--- rclone Configuration ---")
        run_safe("rclone listremotes 2>/dev/null || echo 'No rclone remotes'")
        
        # Check mc alias
        print("\n--- mc Configuration ---")
        run_safe("/usr/local/bin/mc alias list 2>/dev/null || echo 'No mc aliases'")
        
        # Check encryption key
        print("\n--- Encryption Key ---")
        run_safe("test -f /opt/fyona/.backup-encryption-key && echo 'EXISTS' || echo 'NOT CONFIGURED'")
        
        print("\n" + "=" * 60)
        print("AUDIT COMPLETE")
        print("=" * 60)
    
    elif sys.argv[1] == "run":
        cmd = " ".join(sys.argv[2:])
        code, out, err = run(cmd, timeout=120)
        if out:
            sys.stdout.buffer.write((out + "\n").encode('utf-8', errors='replace'))
            sys.stdout.buffer.flush()
        if err:
            sys.stdout.buffer.write((f"STDERR: {err}\n").encode('utf-8', errors='replace'))
            sys.stdout.buffer.flush()
        sys.exit(code)
    
    elif sys.argv[1] == "upload":
        if len(sys.argv) < 4:
            print("Usage: upload <local_path> <remote_path>")
            sys.exit(1)
        if upload(sys.argv[2], sys.argv[3]):
            print(f"Uploaded: {sys.argv[2]} -> {sys.argv[3]}")
        else:
            print("Upload failed!")
            sys.exit(1)
    
    elif sys.argv[1] == "download":
        if len(sys.argv) < 4:
            print("Usage: download <remote_path> <local_path>")
            sys.exit(1)
        if download(sys.argv[2], sys.argv[3]):
            print(f"Downloaded: {sys.argv[2]} -> {sys.argv[3]}")
        else:
            print("Download failed!")
            sys.exit(1)
    
    else:
        print(f"Unknown command: {sys.argv[1]}")
        sys.exit(1)
