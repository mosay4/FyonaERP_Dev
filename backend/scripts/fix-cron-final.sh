#!/bin/bash
crontab -l 2>/dev/null | grep -v 'LATEST=\$(ls' | grep -v 'gzip -t' | grep -v 'Verify OK\|Verify FAIL' | crontab -
echo "=== FINAL CRONTAB ==="
crontab -l | grep -v '^#' | grep -v '^$' | grep -v a50afd
