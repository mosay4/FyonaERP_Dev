from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from subprocess import CompletedProcess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from relay_directory_pilot_otp import deliver_signup_otp, send_handoff, signup_otp
from send_directory_pilot_login import private_sender


class DirectoryPilotOtpTest(unittest.TestCase):
    def test_accepts_only_fresh_signup_for_the_configured_alias(self):
        invited = "signup-" + "a" * 24 + "@example.test"
        now = datetime.now(timezone.utc)
        messages = [
            ("wrong", "someone@example.test", now),
            ("old", invited, now - timedelta(minutes=10)),
            ("reset", invited, now),
            ("new", invited, now),
        ]
        paths = []

        def hit(path):
            paths.append(path)
            if path == "/api/v1/messages":
                return {"messages": [
                    {"ID": key, "Subject": "رمز التحقق الخاص بك — Fyona ERP",
                     "To": [{"Address": address}], "Created": time.isoformat()}
                    for key, address, time in messages
                ]}
            return {"Text": "رمز التحقق الخاص بك هو: 123456 (صالح لمدة 10 دقائق)",
                    "HTML": "لإعادة التعيين" if path.endswith("/reset") else "للتسجيل"}

        self.assertEqual(signup_otp(hit, invited), ("new", "123456"))
        self.assertEqual(paths, ["/api/v1/messages", "/api/v1/message/reset",
                                 "/api/v1/message/new"])

    def test_reserves_before_send_and_does_not_repeat_ambiguous_delivery(self):
        invited = "signup-" + "b" * 24 + "@example.test"

        def hit(path):
            if path == "/api/v1/messages":
                return {"messages": [{
                    "ID": "pending", "Subject": "رمز التحقق",
                    "To": [{"Address": invited}],
                    "Created": datetime.now(timezone.utc).isoformat(),
                }]}
            return {"Text": "رمز التحقق الخاص بك هو: 123456", "HTML": "للتسجيل"}

        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = []

            def send(method, **_params):
                self.assertTrue((directory / "pending").is_file())
                calls.append(method)
                raise OSError("timed out")

            with patch("builtins.print"):
                self.assertIsNone(deliver_signup_otp(send, hit, invited, directory))
                self.assertIsNone(deliver_signup_otp(send, hit, invited, directory))
            self.assertEqual(calls, ["sendMessage"])
            self.assertEqual((directory / "pending").read_text(), "unconfirmed\n")

    def test_handoff_is_one_group_and_keeps_invite_out_of_files(self):
        invited = "signup-" + "c" * 24 + "@example.test"
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            apk, guide, receipt = [directory / name for name in ("qa.apk", "qa.txt", "sent.log")]
            apk.write_bytes(b"test APK")
            guide.write_text("تعليمات المعمل")
            calls = []

            def send(method, *, documents, media):
                calls.append(method)
                self.assertEqual(documents, (apk, guide))
                entries = json.loads(media)
                self.assertEqual([doc["media"] for doc in entries],
                                 ["attach://document0", "attach://document1"])
                self.assertIn(invited, entries[1]["caption"])
                self.assertNotIn(invited, guide.read_text())
                return [
                    {"media_group_id": "probe-group", "document": {"file_name": path.name},
                     "message_id": i + 1}
                    for i, path in enumerate(documents)
                ]

            with patch("builtins.print"):
                send_handoff(send, invited, apk, guide, receipt)
            self.assertIn("qa.apk; Telegram message_id=1", receipt.read_text())
            self.assertIn("qa.txt; Telegram message_id=2", receipt.read_text())
            self.assertNotIn(invited, receipt.read_text())
            with self.assertRaises(FileExistsError):
                send_handoff(send, invited, apk, guide, receipt)
            self.assertEqual(calls, ["sendMediaGroup"])

    def test_document_upload_is_bound_to_the_verified_chat(self):
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            config = directory / "telegram.json"
            token = "123:fake_token"
            config.write_text(json.dumps({"bot_token": token, "chat_id": 42}))
            config.chmod(0o600)
            chat = {"type": "private", "id": 42}
            upload = [{"chat": chat}, {"chat": chat}]

            def curl(argv, *, input, **_params):
                self.assertNotIn(token, " ".join(argv))
                options = [(field, json.loads(value)) for field, value in
                           (line.split(" = ", 1) for line in input.splitlines())]
                if options[0][1].endswith("/getChat"):
                    self.assertIn(("data", "chat_id=42"), options)
                    result = chat
                else:
                    self.assertTrue(options[0][1].endswith("/sendMediaGroup"))
                    self.assertIn(("form-string", "chat_id=42"), options)
                    self.assertIn(("form-string", 'media=[{"caption":"نبذة"}]'), options)
                    filenames = [suffix for key, value in options if key == "form"
                                 for suffix in (value.split(";")[-1],)]
                    self.assertEqual(filenames, ['filename="qa.apk"', 'filename="qa.txt"'])
                    result = upload
                return CompletedProcess(argv, 0, json.dumps({"ok": True, "result": result}))

            with patch("send_directory_pilot_login.subprocess.run", side_effect=curl):
                post = private_sender(config)
                self.assertEqual(post(
                    "sendMediaGroup", media='[{"caption":"نبذة"}]', chat_id=100,
                    documents=(directory / "qa.apk", directory / "qa.txt"),
                ), upload)


if __name__ == "__main__":
    unittest.main()
