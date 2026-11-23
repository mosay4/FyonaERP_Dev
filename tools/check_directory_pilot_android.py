"""ADB UI smoke of the dedicated laboratory APK (single QA emulator only)."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
import xml.etree.ElementTree as ET


PACKAGE = "com.fyona.erp.fyona_flutter.directorypilot"
QA_HTTPS = "https://qa.fyonacompany.com:18443/api/v1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("prior", type=Path, nargs="?")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--resume-offline", action="store_true")
    mode.add_argument("--resume-connected", action="store_true")
    mode.add_argument("--resume-after-offline", action="store_true",
                      help="Finish online search, encryption, and isolation on the same installed APK")
    mode.add_argument("--upgrade", action="store_true", help="Check a replaced APK without clearing its QA session")
    mode.add_argument("--upgrade-details", action="store_true",
                      help="Check the pre-update cards on a private clone of the QA emulator")
    mode.add_argument("--business-scenarios", action="store_true",
                      help="Use the fresh account and branches from the loopback Business lab")
    args = parser.parse_args()
    fixture_path, output_path, resume = args.fixture, args.output, args.prior
    if args.business_scenarios:
        if (set(socket.if_nameindex()) != {(1, "lo")}
                or str(fixture_path) != os.getenv("FYONA_QA_SCENARIO_FIXTURE")):
            parser.error("Use only the private Business delivery lab")
        fixture = json.loads(fixture_path.read_text())
        assert fixture["base"] == "http://127.0.0.1:18083/api/v1"
    elif args.upgrade_details:
        host_network = os.environ.get("FYONA_QA_HOST_NETNS", "")
        if not host_network or os.readlink("/proc/self/ns/net") == host_network:
            parser.error("Use the update-test network namespace, never the host ADB server")
        # This probe must reuse the emulator's session. It does not even
        # access the test login fixture or any private live QA directory.
        fixture = {"base": QA_HTTPS}
    else:
        assert fixture_path.with_name("ready").exists()
        fixture = json.loads(fixture_path.read_text())
    assert fixture["base"] in {"http://127.0.0.1:18083/api/v1", QA_HTTPS}
    enroll = fixture["base"] == QA_HTTPS
    if (args.resume_offline or args.resume_connected or args.resume_after_offline
        or args.upgrade or args.upgrade_details) and (
        not enroll or resume is None
    ):
        parser.error("Resuming requires prior evidence for the HTTPS QA APK")
    saved_offline = args.resume_offline and (resume / "offline-local.txt").is_file()
    user = None if args.upgrade_details else (
        fixture["actors"]["owner"] if args.business_scenarios else
        json.loads(fixture_path.with_name("enrollment-probe.json").read_text()) if enroll else fixture["owner"])
    assert user is None or user["email"].endswith("@example.test")
    output_path.mkdir(exist_ok=False)
    adb = [os.environ["ADB"], "-s", "emulator-5574" if enroll else "emulator-5572"]
    tag = time.strftime("%H%M%S", time.gmtime())
    online = [(kind, f"QA Online {label} {tag}") for kind, label in
              (("العملاء", "Customer"), ("الموردين", "Supplier"))]
    offline = [(kind, name.replace("Online", "Offline")) for kind, name in online]

    def run(*args, timeout=45):
        p = subprocess.run([*adb, *args], text=True, capture_output=True, timeout=timeout)
        if p.returncode:
            raise RuntimeError(f"adb operation failed ({args[0]})")
        return p.stdout

    def shell(*args):
        return run("shell", *args)

    def tree():
        result = run("exec-out", "uiautomator", "dump", "/dev/tty", timeout=48)
        match = re.search(r"<\?xml .*?</hierarchy>", result, re.S)
        if match is None:
            raise RuntimeError("Android accessibility tree unavailable")
        return ET.fromstring(match[0])

    def labels(node):
        return [line for value in (node.get("text", ""), node.get("content-desc", ""))
                for line in value.replace("\u200f", "").replace("\u200e", "").splitlines()]

    def nodes(predicate, limit=80, what="edit fields"):
        deadline = time.monotonic() + limit
        latest = None
        while time.monotonic() < deadline:
            try:
                latest = tree()
                if any("isn't responding" in value for node in latest.iter("node")
                       for value in labels(node)):
                    wait = next((node for node in latest.iter("node") if "Wait" in labels(node)), None)
                    if wait is not None:
                        tap(wait)
                        continue
                result = [x for x in latest.iter("node") if predicate(x)]
                if result:
                    return result
            except (RuntimeError, ET.ParseError, subprocess.TimeoutExpired):
                pass
            time.sleep(.5)
        if latest is not None:
            # Keep app text for debugging, not credential-field contents.
            for node in latest.iter("node"):
                if node.get("class", "").endswith("EditText"):
                    node.set("text", "")
                    node.set("content-desc", "")
                else:
                    for k in ("text", "content-desc"):
                        value = node.get(k, "")
                        if "@example.test" in value:
                            node.set(k, re.sub(r"[\w.+-]+@example\.test", "[test invite]", value))
            ET.ElementTree(latest).write(output_path / "last-ui.xml", encoding="utf-8")
        raise RuntimeError(f"Android screen did not reach expected state: {what}")

    def text(label, limit=110):
        return nodes(lambda x: label in labels(x), limit=limit, what=label)[0]

    def visible_nodes():
        return nodes(lambda _: True, what="accessible window")

    def field_list():
        return nodes(lambda n: n.get("class", "").endswith("EditText"))

    def dismiss_keyboard():
        state = shell("dumpsys", "input_method")
        if re.search(r"\bmInputShown=true\b", state):
            shell("input", "keyevent", "4")

    def tap(node):
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
        shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))

    def compact_action_near(heading, side):
        screen = visible_nodes()
        main = next((n for n in screen if heading in labels(n)), None)
        if main is None and heading in {"القسم الشخصي", "قسم الأعمال"}:
            # Android 9's accessibility bridge can omit the outer header
            # when a nested GoRouter navigator owns semantics. Tap its actual
            # RTL menu icon, at the right edge just above the dashboard body.
            root = screen[0]
            _, _, width, _ = map(int, re.findall(r"\d+", root.get("bounds")))
            body = next(n for n in screen
                        if n.get("class") == "android.widget.ScrollView")
            _, top, _, _ = map(int, re.findall(r"\d+", body.get("bounds")))
            shell("input", "tap", str(width - 30), str(top - 22))
            return
        if main is None:
            raise RuntimeError(f"Missing toolbar heading {heading}")
        _, y, _, z = map(int, re.findall(r"\d+", main.get("bounds")))
        middle = (y + z) // 2
        candidates = []
        for n in screen:
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", n.get("bounds")))
            if (n.get("clickable") == "true" and y1 <= middle <= y2
                    and 20 <= x2 - x1 <= 144 and y2 - y1 <= 135):
                candidates.append((x1, n))
        if not candidates:
            raise RuntimeError(f"No {side} action near heading {heading}")
        tap(sorted(candidates, key=lambda pair: pair[0])[0 if side == "left" else -1][1])

    def dialog_add(kind, value):
        # Existing AppBar + action is unlabeled. Pick the small clickable
        # toolbar control in the page header, not the shared shell header.
        heading = text(kind)
        screen = visible_nodes()
        _, top, _, bottom = map(int, re.findall(r"\d+", heading.get("bounds")))
        matches = []
        for n in screen:
            left, y1, right, y2 = map(int, re.findall(r"\d+", n.get("bounds")))
            if (n.get("clickable") == "true" and not any(labels(n))
                    and y1 <= top <= bottom <= y2
                    and 22 <= right - left <= 116 and y2 - y1 <= 112):
                matches.append((left, n))
        if not matches:
            raise RuntimeError("Could not locate add action in the existing AppBar")
        tap(min(matches, key=lambda pair: pair[0])[1])
        title = text("إضافة عميل" if kind == "العملاء" else "إضافة مورد")
        _, _, _, title_bottom = map(int, re.findall(r"\d+", title.get("bounds")))
        fill(next(n for n in field_list() if
                  int(re.findall(r"\d+", n.get("bounds"))[1]) >= title_bottom), value)
        dismiss_keyboard()
        tap(text("حفظ"))
        card = nodes(lambda n: value in labels(n) and
                     not n.get("class", "").endswith("EditText"), what=value)
        assert len(card) == 1, f"Expected one saved {kind} card"

    def home():
        result = shell("am", "start", "-n",
                       PACKAGE + "/com.fyona.erp.fyona_flutter.MainActivity")
        assert "Error" not in result, "The QA app did not start"

    def set_airplane(enabled):
        shell("settings", "put", "global", "airplane_mode_on", str(int(enabled)))
        action = ["am", "broadcast", "-a", "android.intent.action.AIRPLANE_MODE",
                  "--ez", "state", str(enabled).lower()]
        if (enroll or args.business_scenarios) and shell("getprop", "ro.build.type").strip() == "userdebug":
            # Android's protected broadcast; use only on our AOSP emulator.
            shell("su", "0", *action)
        else:
            shell(*action)

    def assert_offline():
        assert shell("settings", "get", "global", "airplane_mode_on").strip() == "1"
        state = shell("dumpsys", "connectivity")
        assert re.search(r"^\s*Active default network:\s+none\s*$", state, re.M | re.I), \
            "Android still has an active default network"

    def is_field(node):
        return node.get("class", "").endswith("EditText")

    def card(value):
        return nodes(lambda n: value in labels(n) and not is_field(n), what=value)

    def search(value, excluded):
        assert len(card(value)) == 1
        assert len(card(excluded)) == 1
        query = value.removeprefix("QA ")
        fill(field_list()[0], query)
        dismiss_keyboard()
        nodes(lambda n: is_field(n) and n.get("text") == query, what="directory search text")
        visible = visible_nodes()
        displayed = [n for n in visible if not is_field(n)]
        assert sum(value in labels(n) for n in displayed) == 1
        assert not any(excluded in labels(n) for n in displayed), "Search did not filter the list"

    def saved_name(mode, party):
        pattern = re.compile(rf"QA {mode} {party} \d{{6}}")
        visible = nodes(lambda n: not is_field(n) and any(pattern.fullmatch(s) for s in labels(n)),
                        what=f"previously saved {mode} {party} card")
        return max(s for node in visible for s in labels(node) if pattern.fullmatch(s))

    def select_branch(wanted, current=None):
        drawer = lambda n: "إدارة الفروع" in labels(n)
        if not any(drawer(n) for n in visible_nodes()):
            compact_action_near("قسم الأعمال", "right")
        headings = (current,) if current else (other, "منظمة Original Signup Probe",
                     "Original Signup Probe", "الرئيسي", "جميع الفروع", branch)
        if args.business_scenarios and not current:
            profile = fixture["actors"]["owner"]["profile"]
            headings += (profile["organization_name"], profile["full_name"])
        deadline = time.monotonic() + 80
        while True:
            visible = nodes(lambda n: any(h in labels(n) for h in headings),
                            what="drawer branch picker")
            heading = next(h for h in headings if any(h in labels(n) for n in visible))
            if heading == wanted:
                # It's already selected. Dismiss the RTL drawer via its
                # scrim, not system Back (the router can consume it).
                menu = nodes(drawer, limit=15, what="visible branch drawer")[0]
                left, top, right, bottom = map(int, re.findall(r"\d+", menu.get("bounds")))
                assert 0 < left < right / 2
                shell("input", "tap", str(left // 2), str((top + bottom) // 2))
                text("فاتورة بيع")
                return
            try:
                compact_action_near(heading, "left")
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        tap(text(wanted))
        text("فاتورة بيع")

    def ensure_business():
        def is_dashboard(node):
            return any(heading in labels(node) for heading in ("فاتورة بيع", "صافي الثروة"))

        visible = nodes(is_dashboard, limit=110, what="authenticated dashboard")
        if not any("فاتورة بيع" in labels(n) for n in visible):
            compact_action_near("القسم الشخصي", "right")
            tap(text("الانتقال إلى قسم الأعمال"))
        text("فاتورة بيع")

    def report(label, content):
        (output_path / f"{label}.txt").write_text(content + "\n")
        print(content, flush=True)

    def wait_online():
        until = time.monotonic() + 60
        while not re.search(r"^\s*Active default network:\s+\d+\s*$",
                            shell("dumpsys", "connectivity"), re.M):
            if time.monotonic() >= until:
                raise RuntimeError("Android's network did not resume")
            time.sleep(2)

    def check_cipher_header():
        root = f"/data/user/0/{PACKAGE}"
        paths = shell("su", "0", "find", root, "-type", "f", "-name", "*.sqlite").splitlines()
        files = [path for path in paths if re.fullmatch(
            re.escape(root) + r"/[\w./-]+/business_directory_v1/[a-f0-9]+\.sqlite", path
        )]
        assert files, "No directory database on this QA emulator"
        for path in files:
            header = subprocess.check_output(
                [*adb, "exec-out", "su", "0", "head", "-c", "16", path], timeout=40,
            )
            assert len(header) == 16 and not header.startswith(b"SQLite format 3")
        report("cipher-header", "Installed Android QA: the directory database file has no plaintext SQLite header.")

    def open_list(label):
        for _ in range(3):
            if not any("فاتورة بيع" in labels(n) for n in visible_nodes()):
                shell("input", "keyevent", "4")
                text("فاتورة بيع")
            tap(text(label))
            try:
                nodes(is_field, limit=12, what=f"{label} search")
                text(label, limit=12)
                return
            except RuntimeError:
                pass
        raise RuntimeError(f"Could not open the {label} directory, which needs its heading and search field")

    def opening_debt(who, value, *, create):
        # Exercise the actual save button, not an inserted test ledger row.
        text("فاتورة بيع")
        tap(text("الديون"))
        tap(text("ديون العملاء"))
        if create:
            tap(text("إضافة دين جديد"))
            title = text("إضافة عميل جديد")
            _, _, _, boundary = map(int, re.findall(r"\d+", title.get("bounds")))

            def visible_fields():
                return [n for n in field_list()
                        if int(re.findall(r"\d+", n.get("bounds"))[1]) >= boundary]

            fill(visible_fields()[0], who)
            dismiss_keyboard()
            fill(visible_fields()[-1], value)
            dismiss_keyboard()
            tap(text("حفظ"))
        tap(card(who)[0])
        text("مجموعات الديون")
        arabic_digits = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹٫٬", "01234567890123456789.,")
        nodes(lambda node: any(value in label.translate(arabic_digits).replace(",", "")
                               for label in labels(node)), what="opening-debt amount")
        for _ in range(3):
            shell("input", "keyevent", "4")
        text("فاتورة بيع")

    def verify_connected(online_names, offline_names, *, reload=True):
        (output_path / "device-records.json").write_text(
            json.dumps([*online_names, *(name for _, name in offline_names)]) + "\n"
        )
        # Cold offline entry can leave the existing branch picker unloaded
        # after reconnecting. Launch once online without touching app data.
        if reload:
            shell("am", "force-stop", PACKAGE)
            home()
            ensure_business()
        select_branch(other)
        for (label, absent), previous in zip(offline_names, online_names):
            open_list(label)
            text("Unchanged connected directory")
            assert not any(set(labels(n)) & {absent, previous} for n in visible_nodes())
            shell("input", "keyevent", "4")
        report("connected-isolation", "Android QA: the connected branch lists its server records, not either local name.")

    def fill(field, value):
        tap(field)
        assert re.fullmatch(r"[\w@.!\- ]+", value)
        nodes(lambda node: node.get("focused") == "true" and
              node.get("class", "").endswith("EditText"), what="focused input")
        # Feed the synthetic password through stdin rather than a diagnostic
        # command line; still use the emulator's real keyboard input.
        result = subprocess.run(
            [*adb, "shell"], input=f"input text '{value.replace(' ', '%s')}'\nexit\n",
            text=True, capture_output=True, timeout=45,
        )
        if result.returncode:
            raise RuntimeError("Android keyboard input did not complete")

    assert shell("getprop", "sys.boot_completed").strip() == "1"
    branch = (fixture["branch"]["name"] if args.business_scenarios else
              "Offline Pilot QA" if enroll else "فرع تجربة الدليل")
    other = (fixture["sibling"]["name"] if args.business_scenarios else
             "Connected Branch QA" if enroll else "فرع اختبار الأعمال المتصلة")
    if args.business_scenarios:
        assert run("emu", "avd", "name").splitlines()[0] == "FYONA_Business_Loopback"
    if enroll or args.business_scenarios:
        if enroll:
            assert run("emu", "avd", "name").splitlines()[0] == "FYONA_Phase_One_AOSP"
        line = shell("pm", "path", PACKAGE).strip()
        assert re.fullmatch(rf"package:/data/app/{re.escape(PACKAGE)}-[\w=-]+/base.apk", line)
        digest = run("shell", "sha256sum", line.removeprefix("package:"), timeout=120).split()[0]
        assert re.fullmatch(r"[a-f0-9]{64}", digest)
        (output_path / "apk.sha256").write_text(digest + "\n")
        if args.resume_offline or args.resume_connected or args.resume_after_offline:
            assert (resume / "apk.sha256").read_text().strip() == digest
            for step in ("app-start", "login", "online-local"):
                assert (resume / f"{step}.txt").read_text().strip()
        if args.upgrade or args.upgrade_details:
            assert (resume / "apk.sha256").read_text().strip() != digest
            assert (resume / "rest-after-device.txt").stat().st_size > 0
    shell("input", "keyevent", "KEYCODE_WAKEUP")
    shell("wm", "dismiss-keyguard")
    if not enroll:
        run("reverse", "tcp:18083", "tcp:18083")
    # Avoid scripted taps being swallowed by the emulator's timeout.
    if not args.upgrade_details:
        shell("svc", "power", "stayon", "true")
        shell("settings", "put", "secure", "show_ime_with_hard_keyboard", "0")
    if args.upgrade_details:
        records = json.loads((resume / "device-records.json").read_text())
        assert len(records) == 4
        assert all(re.fullmatch(r"QA (Online|Offline) (Customer|Supplier) \d{6}", name)
                   for name in records)

        def open_saved_details(mode_, label, party):
            name, = [name for name in records if name.startswith(f"QA {mode_} {party} ")]
            open_list(label)
            tap(card(name)[0])
            text("تاريخ الإضافة", limit=60)
            text(name)
            text("مجموعات الديون")
            assert not any({"العميل غير موجود", "المورد غير موجود"}.intersection(labels(n))
                           for n in visible_nodes())
            shell("input", "keyevent", "4")
            text(label)
            shell("input", "keyevent", "4")
            text("فاتورة بيع")

        kinds = (("العملاء", "Customer"), ("الموردين", "Supplier"))
        wait_online()
        home()
        ensure_business()
        select_branch(other)
        open_list("العملاء")
        text("Unchanged connected directory")
        assert not any(set(labels(n)).intersection(records) for n in visible_nodes())
        shell("input", "keyevent", "4")
        report("login", "Upgraded QA app reused the original test session and read the sibling branch over HTTPS.")
        select_branch(branch, current=other)
        for label, party in kinds:
            open_saved_details("Online", label, party)
        report("details-online", "Both existing cards opened their original full details over the upgraded release while online.")
        check_cipher_header()
        try:
            shell("svc", "wifi", "disable")
            shell("svc", "data", "disable")
            set_airplane(True)
            assert_offline()
            shell("am", "force-stop", PACKAGE)
            home()
            ensure_business()
            for label, party in kinds:
                open_saved_details("Offline", label, party)
            assert_offline()
            report("details-offline", "Both existing cards opened their original full details after a cold restart in airplane mode.")
        finally:
            set_airplane(False)
            shell("svc", "wifi", "enable")
            shell("svc", "data", "enable")
        return
    if args.resume_after_offline:
        # The earlier job was stopped only after recording both offline search
        # results. Bind that evidence to the installed APK before continuing.
        for step in ("app-start", "login", "preserved-data", "online-local",
                     "offline-local", "offline-restart"):
            result = (resume / f"{step}.txt").read_text().strip()
            assert result
            report(step, result)
        check_cipher_header()
        if shell("settings", "get", "global", "airplane_mode_on").strip() == "1":
            set_airplane(False)
        shell("svc", "wifi", "enable")
        shell("svc", "data", "enable")
        wait_online()
        home()
        ensure_business()
        select_branch(branch)
        online_names, offline_names = [], []
        for label, party in (("العملاء", "Customer"), ("الموردين", "Supplier")):
            open_list(label)
            value = saved_name("Online", party)
            excluded = saved_name("Offline", party)
            search(value, excluded)
            online_names.append(value)
            offline_names.append((label, excluded))
            shell("input", "keyevent", "4")
        tags = {name.split()[-1] for name in [*online_names, *(n for _, n in offline_names)]}
        assert len(tags) == 1, "Online recheck picked unrelated probe records"
        # The full run stamps every record just before it records its APK hash.
        tag = tags.pop()
        stamped = time.gmtime((resume / "apk.sha256").stat().st_mtime)
        seconds = lambda t: int(t[:2]) * 3600 + int(t[2:4]) * 60 + int(t[4:])
        assert (seconds(time.strftime("%H%M%S", stamped)) - seconds(tag)) % 86400 <= 180
        report("online-search", "Android QA: search filters both local lists with network restored.")
        verify_connected(online_names, offline_names, reload=False)
        return

    if args.resume_connected:
        wait_online()
        for step in ("app-start", "login", "online-local", "offline-local",
                     "offline-restart", "online-search"):
            result = (resume / f"{step}.txt").read_text().strip()
            assert result
            report(step, result)
        home()
        online_names, offline_names = [], []
        for label, party in (("العملاء", "Customer"), ("الموردين", "Supplier")):
            open_list(label)
            online_names.append(saved_name("Online", party))
            offline_names.append((label, saved_name("Offline", party)))
            shell("input", "keyevent", "4")
        for records in (online_names, [name for _, name in offline_names]):
            assert len({name.split()[-1] for name in records}) == 1, "Mixed probe runs"
        verify_connected(online_names, offline_names)
        return

    if not args.resume_offline:
        home()
    if args.upgrade:
        wait_online()
        ensure_business()
        report("app-start", "Android QA: the newly installed release APK cold-started.")
        select_branch(other)
        open_list("العملاء")
        text("Unchanged connected directory")
        shell("input", "keyevent", "4")
        report("login", "Android QA: the update retained the QA session and could read its connected branch over HTTPS.")
    elif not args.resume_offline and resume is None:
        fields = field_list()
        assert len(fields) >= 2
        report("app-start", "Android QA release APK launched and showed the login form.")
        for i, key in enumerate(("email", "password")):
            fill(fields[i] if i == 0 else field_list()[i], user[key])
        dismiss_keyboard()
        entered = field_list()
        assert entered[0].get("text") == user["email"], "Email input was not entered"
        assert len(entered[1].get("text", "")) > 0, "Password input was not entered"
        tap(text("تسجيل الدخول"))
        if enroll or args.business_scenarios:
            ensure_business()
        text("فاتورة بيع")
        report("login", "Android QA authenticated against the private test API.")
    elif not args.resume_offline:
        if not any("إدارة الفروع" in labels(n) for n in visible_nodes()):
            text("فاتورة بيع")
        for step in ("app-start", "login"):
            report(step, (resume / (step + ".txt")).read_text().strip())

    if not args.resume_offline:
        select_branch(branch, current=other if args.upgrade else None)
        old_names = set(json.loads((resume / "device-records.json").read_text())) if args.upgrade else set()
        if args.upgrade:
            assert len(old_names) == 4
        for (label, value), seed in zip(online, ("عميل تجريبي", "مورد تجريبي")):
            open_list(label)
            if not enroll and not args.business_scenarios:
                text(seed)
            if args.upgrade:
                party = value.split()[2]
                previous = [name for name in old_names if
                            re.fullmatch(rf"QA (Online|Offline) {party} \d{{6}}", name)]
                assert len(previous) == 2
                for name in previous:
                    assert len(card(name)) == 1
            dialog_add(label, value)
            shell("input", "keyevent", "4")
        if args.upgrade:
            report("preserved-data", "Android QA: all four saved on-device records from the previous APK survived the update.")
        report("online-local", "Android QA: online additions to both local lists.")

    observed_online = []
    observed_offline = []
    opening_name, opening_amount = f"QA Opening {tag}", "125.75"
    try:
        if not enroll:
            run("reverse", "--remove", "tcp:18083")
        shell("svc", "wifi", "disable")
        shell("svc", "data", "disable")
        set_airplane(True)
        assert_offline()
        if args.resume_offline:
            shell("am", "force-stop", PACKAGE)
            home()
            text("فاتورة بيع")
            for step in ("app-start", "login"):
                report(step, (resume / f"{step}.txt").read_text().strip())
        for (label, value), (_, seed) in zip(offline, online):
            open_list(label)
            if args.resume_offline:
                seed = saved_name("Online", seed.split()[2])
            assert len(card(seed)) == 1
            observed_online.append(seed)
            if saved_offline:
                value = saved_name("Offline", value.split()[2])
                assert len(card(value)) == 1
            else:
                dialog_add(label, value)
            observed_offline.append((label, value))
            shell("input", "keyevent", "4")
        for records in (observed_online, [name for _, name in observed_offline]):
            assert len({name.split()[-1] for name in records}) == 1, "Mixed probe runs"
        if args.resume_offline:
            report("online-local", (resume / "online-local.txt").read_text().strip())
        report("offline-local", (resume / "offline-local.txt").read_text().strip() if saved_offline else
               "Android QA: listed and added to both lists in airplane mode.")
        if args.business_scenarios:
            opening_debt(opening_name, opening_amount, create=True)
            report("offline-money-save", "Saved 125.75 through the existing customer debt form in airplane mode.")
        shell("am", "force-stop", PACKAGE)
        assert_offline()
        home()
        for (label, value), absent in zip(observed_offline, observed_online):
            open_list(label)
            search(value, absent)
            shell("input", "keyevent", "4")
        if args.business_scenarios:
            opening_debt(opening_name, opening_amount, create=False)
            report("offline-money-reopen", "The exact opening amount 125.75 survived an offline app restart.")
        assert_offline()
        report("offline-restart", "Android QA: both lists retained searchable records after force-stop and offline restart.")
    finally:
        set_airplane(False)
        shell("svc", "wifi", "enable")
        shell("svc", "data", "enable")
        if not enroll:
            run("reverse", "tcp:18083", "tcp:18083")

    if enroll or args.business_scenarios:
        if args.upgrade or args.business_scenarios:
            check_cipher_header()
        wait_online()
        for (label, absent), value in zip(observed_offline, observed_online):
            open_list(label)
            search(value, absent)
            shell("input", "keyevent", "4")
        report("online-search", "Android QA: search filters both local lists with network restored.")
        verify_connected(observed_online, observed_offline)


if __name__ == "__main__":
    os.umask(0o077)
    main()
