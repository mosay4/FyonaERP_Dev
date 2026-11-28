"""Send a FYONA development report or APK using the private local config."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


def send(path: Path, caption: str) -> None:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    config = config_home / "fyona-erp" / "telegram.json"
    if config.stat().st_mode & 0o077:
        raise ValueError("Telegram config must be private (chmod 600).")
    credentials = json.loads(config.read_text(encoding="utf-8"))
    token = credentials["bot_token"]
    chat_id = str(credentials["chat_id"])
    if not re.fullmatch(r"\d+:[A-Za-z0-9_-]+", token) or not re.fullmatch(r"-?\d+", chat_id):
        raise ValueError("Invalid Telegram credentials format.")
    if path.name.startswith(".") or path.suffix.lower() not in {".txt", ".apk", ".db", ".zip"}:
        raise ValueError("Only .txt reports, .apk builds and .db/.zip test files are accepted.")
    if path.stat().st_size > 50_000_000:
        raise ValueError("File exceeds the 50 MB Telegram Bot API upload limit.")
    filename = re.sub(r"[^a-zA-Z0-9_.-]", "_", path.name)
    quoted_path = str(path.resolve()).replace("\\", "\\\\").replace('"', '\\"')
    # Send the token through stdin rather than exposing it in process arguments.
    # IPv4 avoids the unreachable Telegram IPv6 address on this build host.
    response = subprocess.run(
        [
            "curl", "-q", "-4", "--silent", "--show-error", "--connect-timeout", "10",
            "--max-time", "180", "--config", "-",
            "--form-string", f"chat_id={chat_id}",
            "--form-string", f"caption={caption}",
            "--form", f'document=@"{quoted_path}";filename="{filename}"',
        ],
        input=f'url="https://api.telegram.org/bot{token}/sendDocument"\n',
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if response.returncode:
        raise ValueError(f"Telegram transfer failed (curl {response.returncode}); delivery was not confirmed.")
    try:
        result = json.loads(response.stdout)
    except ValueError:
        raise ValueError("Telegram returned a response that could not be read.") from None
    if not result.get("ok"):
        description = str(result.get("description", "")).replace(token, "[redacted]")
        raise ValueError(f"Telegram did not confirm delivery: {description}")
    print(f"Sent {filename}; Telegram message_id={result['result']['message_id']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    parser.add_argument("--caption", default="FYONA ERP")
    options = parser.parse_args()
    try:
        send(options.file, options.caption)
    except (OSError, KeyError, ValueError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
