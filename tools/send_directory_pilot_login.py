"""Send the isolated Phase 1 login to the configured private Telegram chat."""

import html
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode


def private_sender(config=None):
    if config is None:
        home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        config = home / "fyona-erp" / "telegram.json"
    managed_credentials = os.environ.get("CREDENTIALS_DIRECTORY", "")
    from_service = (managed_credentials.startswith("/run/credentials/")
                    and config.parent == Path(managed_credentials))
    if not from_service and config.stat().st_mode & 0o077:
        raise ValueError("Telegram config must be private.")
    credentials = json.loads(config.read_text())
    token, chat_id = credentials["bot_token"], str(credentials["chat_id"])
    if not re.fullmatch(r"\d+:[A-Za-z0-9_-]+", token) or not re.fullmatch(r"\d+", chat_id):
        raise ValueError("Expected the existing private Telegram destination.")

    def post(method, *, documents=(), **params):
        fields = {**params, "chat_id": chat_id}
        curl_config = f'url = "https://api.telegram.org/bot{token}/{method}"\n'
        deadline = "20"
        if documents:
            if method != "sendMediaGroup" or len(documents) != 2:
                raise ValueError("Expected one APK and one guide in the same Telegram handoff.")
            for name, value in fields.items():
                curl_config += f"form-string = {json.dumps(f'{name}={value}', ensure_ascii=False)}\n"
            for index, path in enumerate(documents):
                source = str(path.resolve()).replace("\\", "\\\\").replace('"', '\\"')
                filename = path.name
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", filename):
                    raise ValueError("Unsafe Telegram attachment filename.")
                form = f'document{index}=@"{source}";filename="{filename}"'
                curl_config += f"form = {json.dumps(form, ensure_ascii=False)}\n"
            deadline = "240"
        else:
            curl_config += f'data = "{urlencode(fields)}"\n'
        response = subprocess.run(
            ["curl", "-q", "-4", "--noproxy", "*", "-sS", "--connect-timeout", "10",
             "--max-time", deadline, "--config", "-"],
            input=curl_config,
            text=True,
            capture_output=True,
        )
        if response.returncode:
            raise ValueError(f"Telegram {method} transfer was not confirmed (curl {response.returncode}).")
        reply = json.loads(response.stdout)
        if not reply.get("ok"):
            status = reply.get("error_code")
            raise ValueError(f"Telegram rejected {method} ({status if isinstance(status, int) else 'unknown status'}).")
        result = reply["result"]
        if method in {"sendMessage", "sendMediaGroup"}:
            messages = (result,) if method == "sendMessage" else result
            if not messages or any(
                m["chat"]["type"] != "private" or str(m["chat"]["id"]) != chat_id
                for m in messages
            ):
                raise ValueError(f"Did not confirm {method} for the configured private chat.")
        return result

    chat = post("getChat")
    if chat["type"] != "private" or str(chat["id"]) != chat_id:
        raise ValueError("Refusing to share a login outside the configured private chat.")
    return post


def main():
    run_dir = Path("/var/lib/private/fyona-directory-qa-api/run")
    if not (run_dir / "ready").is_file():
        raise ValueError("The Phase 1 QA fixture is not ready.")
    fixture = json.loads((run_dir / "fixture.json").read_text())
    if fixture["base"] != "https://qa.fyonacompany.com:18443/api/v1":
        raise ValueError("Refusing to share any non-QA fixture.")
    owner = fixture["owner"]
    if owner["email"] != "directory-owner@example.test":
        raise ValueError("Refusing to share a non-synthetic login.")
    post = private_sender()
    message = post(
        "sendMessage",
        parse_mode="HTML",
        text="بيانات دخول معمل فيونا — المرحلة الأولى فقط\n\n"
             f"البريد: <code>{html.escape(owner['email'])}</code>\n"
             f"كلمة المرور: <code>{html.escape(owner['password'])}</code>\n\n"
             "سجّل أول مرة والنت شغّال، واختر «فرع تجربة الدليل». "
             "هذا حساب وهمي مؤقت، مو حساب الإنتاج.",
    )
    print(f"Sent the synthetic login separately; Telegram message_id={message['message_id']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError) as exc:
        raise SystemExit(f"Private QA login not confirmed ({type(exc).__name__}).") from None
