"""Relay only the delivery invite's fresh signup OTP to the existing private chat."""

import argparse
from base64 import b64encode
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import time
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

from send_directory_pilot_login import private_sender
from verify_directory_pilot_http import NoRedirect


RUN = Path("/var/lib/private/fyona-directory-qa-enroll/run")
RELAY_WINDOW = timedelta(minutes=8)


def mailbox(root):
    values = json.loads((root / "mailpit-access.json").read_text())
    base = urlsplit(values["base"])
    if (base.scheme, base.netloc, base.path, base.query, base.fragment) != (
        "http", f"127.0.0.1:{base.port}", "", "", ""
    ) or not base.port:
        raise ValueError("Not the local test mailbox")
    credentials = b64encode(f"{values['user']}:{values['password']}".encode()).decode()
    opener = build_opener(NoRedirect(), ProxyHandler({}))

    def hit(path):
        req = Request(base.geturl() + path, headers={"Authorization": "Basic " + credentials})
        with opener.open(req, timeout=5) as response:
            return json.load(response)

    return hit, values["test_address"]


def signup_otp(hit, email):
    messages = hit("/api/v1/messages")["messages"]
    if not messages:
        return None
    for m in messages:
        if (not str(m.get("Subject", "")).startswith("رمز التحقق") or
            [t["Address"].lower() for t in m.get("To", [])] != [email]):
            continue
        msg_id = m["ID"]
        if not re.fullmatch(r"[\w-]{1,128}", msg_id):
            raise ValueError("Unexpected mail ID")
        sent_at = datetime.fromisoformat(m["Created"])
        age = datetime.now(timezone.utc) - sent_at
        if not timedelta(0) <= age < RELAY_WINDOW:
            continue
        message = hit(f"/api/v1/message/{msg_id}")
        if "للتسجيل" not in message.get("HTML", ""):
            continue
        text = message["Text"]
        code = re.search(r"هو:\s*(\d{6})(?!\d)", text)
        if code:
            return msg_id, code[1]
    return None


def signup_invite_text(email):
    return ("بريد معمل فيونا — المرحلة الأولى فقط\n\n"
            f"البريد: <code>{email}</code>\n\n"
            "من نسخة الاختبار اختر «إنشاء حساب» واستخدم هذا البريد فقط، "
            "مع كلمة مرور جديدة خاصة بالمعمل. رمز التحقق يوصلك هنا في هذه المحادثة "
            "الخاصة، وليس إلى بريدك الحقيقي. لا تستخدم Google أو حساب الإنتاج.")


def send_invite(post, email):
    reply = post("sendMessage", parse_mode="HTML", disable_web_page_preview="true",
                 text=signup_invite_text(email))
    print(f"QA signup invite; Telegram message_id={reply['message_id']}", flush=True)


def send_handoff(post, email, apk, guide, log):
    if (apk.suffix, guide.suffix) != (".apk", ".txt") or any(
        not path.is_file() or not 0 < path.stat().st_size <= 50_000_000
        for path in (apk, guide)
    ):
        raise ValueError("Expected one uploadable APK and one Arabic TXT guide.")
    media = [
        {"type": "document", "media": "attach://document0",
         "caption": "فيونا ERP — المرحلة الأولى فقط. ثبّت APK المعمل جنب التطبيق الأصلي."},
        {"type": "document", "media": "attach://document1", "parse_mode": "HTML",
         "caption": signup_invite_text(email)},
    ]
    # Telegram accepts document groups. The invite stays in the private
    # caption, not in either file, and we don't upload an isolated APK first.
    with log.open("x") as receipt:
        receipt.write("Attempted single Telegram document group.\n")
        receipt.flush()
        messages = post("sendMediaGroup", documents=(apk, guide),
                        media=json.dumps(media, ensure_ascii=False))
        if len(messages) != 2 or not messages[0].get("media_group_id") or len({
            msg["media_group_id"] for msg in messages
        }) != 1:
            raise ValueError("Telegram did not confirm the full document group.")
        files = {msg["document"]["file_name"]: msg["message_id"] for msg in messages}
        if set(files) != {apk.name, guide.name} or not all(
            type(msg_id) is int and msg_id > 0 for msg_id in files.values()
        ):
            raise ValueError("Telegram did not confirm both handoff files.")
        for path in (apk, guide):
            line = f"Sent {path.name}; Telegram message_id={files[path.name]}"
            receipt.write(line + "\n")
            print(line, flush=True)


def deliver_signup_otp(post, hit, email, receipt_dir, *, probe=False):
    otp = signup_otp(hit, email)
    if not otp:
        return None
    msg_id, code = otp
    try:
        receipt = (receipt_dir / msg_id).open("x")
    except FileExistsError:
        return None
    # Reserve the mail before making an external request. If delivery is
    # ambiguous it is not safe to resend; the tester can request a fresh OTP.
    with receipt:
        try:
            heading = ("فحص داخلي لرمز معمل فيونا (مو دعوتك)" if probe
                       else "رمز فيونا لمعمل الاختبار")
            reply = post(
                "sendMessage", parse_mode="HTML",
                text=f"{heading}: <code>{code}</code>\n"
                     "استخدمه في شاشة رمز التحقق فقط. لا تشاركه.",
            )
            message_id = reply["message_id"]
            if type(message_id) is not int or message_id <= 0:
                raise ValueError("Unconfirmed Telegram receipt")
        except (OSError, ValueError, KeyError, TypeError):
            receipt.write("unconfirmed\n")
            print("QA signup OTP delivery was not confirmed.", flush=True)
            return None
        receipt.write(f"{message_id}\n")
    print(f"QA signup OTP relayed; Telegram message_id={message_id}", flush=True)
    return message_id


def relay(post, hit, email, receipt_dir):
    receipt_dir.mkdir(exist_ok=True)
    hit("/api/v1/messages")  # Prove access to the private mailbox before readiness.
    ready = receipt_dir / "relay-ready"
    ready.touch()
    print("Verified private Telegram destination and started QA signup relay.", flush=True)
    try:
        while True:
            try:
                deliver_signup_otp(post, hit, email, receipt_dir)
            except (OSError, ValueError, KeyError, TypeError):
                # Mailpit is local but can restart; keep using the same opener.
                pass
            time.sleep(5)
    finally:
        ready.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("invite", "relay"))
    parser.add_argument("--receipts", type=Path)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--guide", type=Path)
    parser.add_argument("--handoff-log", type=Path)
    args = parser.parse_args()
    handoff = (args.apk, args.guide, args.handoff_log)
    if any(handoff) and (not all(handoff) or args.action != "invite"):
        parser.error("--apk, --guide, and --handoff-log must be used together with invite")
    if args.action == "relay":
        if args.receipts is None:
            raise ValueError("Missing private receipt directory")
        (args.receipts / "relay-ready").unlink(missing_ok=True)
    credentials_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if args.action == "relay" and credentials_dir:
        credentials = Path(credentials_dir)
        mailbox_root = credentials
        post = private_sender(credentials / "telegram.json")
    else:
        if not (RUN / "ready").is_file():
            raise ValueError("Signup QA is not ready")
        mailbox_root = RUN
        post = private_sender()
    # Reuse the opener, including its CA context, for every poll. Creating a
    # fresh opener per tick exhausted the transient service's memory limit.
    hit, email = mailbox(mailbox_root)
    if not re.fullmatch(r"signup-[a-f0-9]{24}@example\.test", email):
        raise ValueError("Invalid lab address")
    if all(handoff):
        send_handoff(post, email, *handoff)
    elif args.action == "invite":
        send_invite(post, email)
    else:
        relay(post, hit, email, args.receipts)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        reason = str(exc) if type(exc) in (ValueError, RuntimeError) else type(exc).__name__
        raise SystemExit(f"QA invitation/relay stopped: {reason}") from None
