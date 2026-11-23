#!/usr/bin/env bash
set -euo pipefail

project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${XDG_CONFIG_HOME:-$HOME/.config}/fyona-erp/backend"
if [[ ! -f "$runtime/.env" ]]; then
  printf 'Missing local backend configuration: %s/.env\n' "$runtime" >&2
  exit 1
fi

# The isolated CWD keeps Pydantic away from the archive's .env/.sara.env.
cd "$runtime"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
export AWS_EC2_METADATA_DISABLED=true
exec "$project/backend/.venv/bin/python" -m uvicorn app.main:app \
  --app-dir "$project/backend" --host 127.0.0.1 --port 8001 "$@"
