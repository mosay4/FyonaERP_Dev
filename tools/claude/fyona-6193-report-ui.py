"""Drive the real Business «التقارير» UI on the private QA emulator clone.

Phases:
  online1 — dashboard → hub → five report cards with their real motion scenes,
            cancel one entry scene back to the hub, reopen it, switch period.
  offline — with the QA relay down, open reports straight from the device
            ledger (no network, no spinner hang).
  online2 — relaunch the app and reopen a report with retained data.

Only uiautomator dumps and taps; the app, its data and the subscription gate
are never modified.
"""

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB, SERIAL, EVIDENCE, PHASE = sys.argv[1:5]
adb = [ADB, "-s", SERIAL]
pkg = "com.fyona.erp.fyona_flutter.directorypilot"

CARDS = {
    "sales": "المبيعات والمشتريات",
    "money": "الفلوس والحسابات",
    "inventory": "المخزون",
    "debts": "الديون",
    "overview": "نظرة شاملة",
}
SCENES = {
    "sales": "نجمع مبيعاتك...",
    "money": "نتتبع حركة الفلوس...",
    "inventory": "نعدّ البضاعة...",
    "debts": "نراجع الديون...",
    "overview": "نجمع كل الصورة...",
}
HUB = "كيف شغلك؟"
HUB_SIGNS = (
    HUB,
    "كم بعت؟",
    "كم بعت وكم اشتريت وكم دُفع",
    "كل الشغل في صفحة واحدة",
    "قيمة البضاعة والنواقص والحركة",
    "دخل الحسابات وخرجها وأرصدتها",
    "لك عند العملاء وعليك للموردين",
)


def in_hub(text):
    return any(sign in text for sign in HUB_SIGNS)
DEVICE_SOURCE = "تُقرأ التقارير من دفتر هذا الفرع على الجهاز."
PROCESSING = "جارٍ الحساب الدقيق..."


def labels(node):
    return [line for value in (node.get("text", ""), node.get("content-desc", ""))
            for line in value.replace("\u200f", "").replace("\u200e", "").splitlines()]


def screen_text(root):
    return " ".join(label for node in root.iter("node") for label in labels(node))


def adb_run(args, timeout=60):
    for attempt in range(3):
        try:
            return subprocess.run([*adb, *args], timeout=timeout,
                                  capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            time.sleep(3)
    return None


def dump():
    for _ in range(3):
        try:
            run = subprocess.run([*adb, "exec-out", "uiautomator", "dump", "/dev/tty"],
                                 capture_output=True, text=True, timeout=45)
            match = re.search(r"<\?xml .*?</hierarchy>", run.stdout, re.S)
            if match:
                return ET.fromstring(match[0]), match[0]
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1)
    return None, ""


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    return (x1 + x2) // 2, (y1 + y2) // 2


def _input(args):
    # Input events are never retried: a timed-out tap/key may still have been
    # delivered, and a duplicate Back would pop an extra route.
    try:
        subprocess.run([*adb, "shell", *args], timeout=60,
                       capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        pass


def tap(x, y):
    _input(["input", "tap", str(x), str(y)])


def key(code):
    _input(["input", "keyevent", code])


def screenshot(tag):
    with open(f"{EVIDENCE}/report-ui-{PHASE}-{tag}.png", "wb") as out:
        try:
            subprocess.run([*adb, "exec-out", "screencap", "-p"], stdout=out,
                           timeout=45, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            pass


def save(tag, xml):
    with open(f"{EVIDENCE}/report-ui-{PHASE}-{tag}.xml", "w", encoding="utf-8") as out:
        out.write(xml)


def note(message):
    with open(f"{EVIDENCE}/report-ui-{PHASE}.txt", "a", encoding="utf-8") as out:
        out.write(message + "\n")
    print(f"[{PHASE}] {message}", flush=True)


def find_nodes(root, needle):
    return [node for node in root.iter("node") if any(needle in label for label in labels(node))]


_anr_strikes = [0]


def handle_anr(root):
    _anr_strikes[0] += 1
    # Dismiss with "Wait" like the proven update-gate smoke; only recycle the
    # stuck owner after repeated strikes.
    want = "Close app" if _anr_strikes[0] % 4 == 0 else "Wait"
    for node in root.iter("node"):
        if want in labels(node):
            tap(*center(node))
            break
    else:
        for node in root.iter("node"):
            if "Wait" in labels(node) or "Close app" in labels(node):
                tap(*center(node))
                break
    time.sleep(4)


def ensure_app():
    run = adb_run(["shell", "pidof", pkg], timeout=25)
    if run is not None and run.stdout.strip():
        return
    adb_run(["shell", "am", "start", "-n",
             f"{pkg}/com.fyona.erp.fyona_flutter.MainActivity"])


def wait_for(predicate, seconds, label):
    deadline = time.monotonic() + seconds
    last, xml = "", ""
    while time.monotonic() < deadline:
        root, xml = dump()
        if root is not None:
            text = screen_text(root)
            last = text
            if "isn't responding" in text:
                handle_anr(root)
                continue
            hit = predicate(root, text)
            if hit:
                return root, xml, text
        time.sleep(3)
    save("stuck", xml)
    raise SystemExit(f"[{PHASE}] {label}: not reached; last screen: {last[:1500]}")


def wait_gone(needle, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        root, xml = dump()
        if root is not None and not any(needle in line for line in screen_text(root).split(" ")):
            if needle not in screen_text(root):
                return root, xml
        time.sleep(1)
    raise SystemExit(f"[{PHASE}] {label}: '{needle}' never left the screen")


def _area(node):
    x1, y1, x2, y2 = bounds_of(node)
    return (x2 - x1) * (y2 - y1)


def tap_label(root, needle):
    matches = find_nodes(root, needle)
    assert matches, f"no node labelled {needle!r}"
    # Merged semantics nodes can span the whole screen; tap the most precise
    # (smallest) node carrying the label — the control itself.
    tap(*center(min(matches, key=_area)))


def scroll_top():
    root, xml = dump()
    for _ in range(5):
        if root is not None and (
                HUB in screen_text(root) or DEVICE_SOURCE in screen_text(root)):
            return root, xml
        _input(["input", "swipe", "270", "300", "270", "720", "300"])
        time.sleep(1)
        root, xml = dump()
    return root, xml


def go_hub():
    root, xml, text = wait_for(lambda r, t: in_hub(t), 120, "reports hub")
    return root, xml


def open_card(kind, *, cancel=False, period=None, type_chip=False):
    root, _ = go_hub()
    if period:
        root, _ = scroll_top()
        tap_label(root, period)
        time.sleep(1)
        root, _ = go_hub()
    title = CARDS[kind]
    # Scroll the hub until the whole card is on screen above the bottom nav;
    # a partially visible card would tap the nav bar instead of opening.
    opened = None
    for _ in range(8):
        visible = [
            node for node in find_nodes(root, title)
            if 40 < bounds_of(node)[1] and bounds_of(node)[3] < 830
        ]
        if visible:
            tap(*center(min(visible, key=_area)))
            opened = probe(lambda r, t: "عرض التقرير" in t, 15)
            if opened:
                break
        _input(["input", "swipe", "270", "700", "270", "300", "400"])
        time.sleep(1)
        root, xml = dump()
    assert opened, f"{kind}: the report card did not open its confirmation dialog"
    root, xml, text = opened
    save(f"{kind}-dialog", xml)
    # Run the cinematic at full duration: the emulator's animation scales are
    # zeroed elsewhere to keep System UI responsive, and Flutter treats that
    # as reduced motion.
    for scale in ("window_animation_scale", "transition_animation_scale",
                  "animator_duration_scale"):
        adb_run(["shell", "settings", "put", "global", scale, "1"])
    time.sleep(1.5)  # let the metrics change reach the app before the scene
    tap_label(root, "عرض التقرير")
    scene_seen = False
    if cancel:
        # Cancel mid-flight: the entry scene must return to the hub, never
        # strand the user on a half-generated page.
        time.sleep(0.6)
        screenshot(f"{kind}-cancel-scene")
        key("KEYCODE_BACK")
        root, xml, text = wait_for(
            lambda r, t: in_hub(t), 60, "hub after scene cancel",
        )
        save(f"{kind}-cancel-back", xml)
        note(f"{kind}: cancelling the entry scene returns to the reports hub")
        for scale in ("window_animation_scale", "transition_animation_scale",
                      "animator_duration_scale"):
            adb_run(["shell", "settings", "put", "global", scale, "0"])
        return
    start = time.monotonic()
    for shot in range(6):
        screenshot(f"{kind}-scene-{shot}")
        root, xml = dump()
        if root is not None:
            text = screen_text(root)
            if SCENES[kind] in text or PROCESSING in text:
                save(f"{kind}-scene", xml)
                scene_seen = True
                note(f"{kind}: motion scene «{SCENES[kind]}» captured while the report was prepared")
                break
            if (title in text and "عرض التقرير" not in text
                    and "إلغاء" not in text and not in_hub(text)):
                break
        if time.monotonic() - start > 6:
            break
        time.sleep(0.3)
    if not scene_seen:
        note(f"{kind}: the motion scene completed before the accessibility dump; screenshots saved")
    root, xml, text = wait_for(
        lambda r, t: SCENES[kind] not in t and PROCESSING not in t
            and title in t and "عرض التقرير" not in t and not in_hub(t),
        90, f"{kind} report page",
    )
    save(f"{kind}-report", xml)
    note(f"{kind}: report page rendered from the device ledger")
    for scale in ("window_animation_scale", "transition_animation_scale",
                  "animator_duration_scale"):
        adb_run(["shell", "settings", "put", "global", scale, "0"])
    if type_chip:
        for chip in ("حساب توفير", "حساب جاري"):
            matches = find_nodes(root, chip)
            if matches:
                tap(*center(matches[-1]))
                time.sleep(1.5)
                root, xml, text = dump()
                save(f"{kind}-type-chip", xml)
                note(f"{kind}: account-type switched with the «{chip}» chip")
                break
    key("KEYCODE_BACK")
    root, xml, text = wait_for(lambda r, t: in_hub(t), 45, "hub after report")
    save(f"{kind}-back", xml)


def probe(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        root, xml = dump()
        if root is not None:
            text = screen_text(root)
            if "isn't responding" in text:
                handle_anr(root)
                continue
            if predicate(root, text):
                return root, xml, text
        time.sleep(2)
    return None


def open_drawer():
    # The header menu is a bare painter without accessibility semantics, so
    # open the drawer the way a finger does: drag from the screen edge.
    def opened(r, t):
        return ("الانتقال إلى" in t or "إدارة الفروع" in t
                or any(label.startswith("فرع ") for n in r.iter("node")
                       for label in labels(n)))

    for side, swipe in (("right", ("538", "500", "120", "500")),
                        ("left", ("2", "500", "420", "500"))):
        _input(["input", "swipe", *swipe, "400"])
        hit = probe(opened, 25)
        if hit:
            DRAWER_SIDE[0] = side
            return hit
    for side, x in (("right", "515"), ("left", "25")):
        tap(x, 30)
        hit = probe(opened, 15)
        if hit:
            DRAWER_SIDE[0] = side
            return hit
    raise SystemExit("[report] the side drawer could not be opened")


def bounds_of(node):
    return tuple(map(int, re.findall(r"\d+", node.get("bounds"))))


DRAWER_SIDE = [None]


def close_drawer():
    # The shell intercepts Back (PopScope), so dismiss the drawer by tapping
    # its scrim — computed from the drawer row's own bounds so the tap can
    # never land on a drawer item.
    root, xml = dump()
    row = None
    if root is not None:
        row = next((n for n in root.iter("node")
                    if any("الانتقال إلى" in label for label in labels(n))), None)
    if row is not None:
        x1, _, x2, _ = bounds_of(row)
        if x1 >= 30:
            x = str(max(15, x1 // 2))
        elif x2 <= 510:
            x = str(min(525, (x2 + 540) // 2))
        else:
            x = "45"
    else:
        x = "45"
    tap(x, 520)
    return probe(lambda r, t: "فاتورة بيع" in t or in_hub(t), 15)


def select_branch(target="فرع تجربة الدليل"):
    # The drawer carries the branch switcher. The device ledger reports read
    # only the registered writer branch, so select it explicitly.
    root, xml, text = open_drawer()
    save("drawer-branch", xml)
    others = "فرع اختبار الأعمال المتصلة"
    if target in text and others not in text:
        # The drawer header already names the target as the current branch.
        close_drawer()
        return root, xml, text
    headers = [n for n in root.iter("node")
               if any(label.startswith("فرع ") for label in labels(n))]
    if not headers:
        headers = [n for n in root.iter("node")
                   if any("الفروع" in label for label in labels(n))]
    if not headers:
        close_drawer()
        return root, xml
    node = headers[0]
    _, y1, _, y2 = bounds_of(node)
    middle = (y1 + y2) // 2
    buttons = []
    for other in root.iter("node"):
        x, top, right, bottom = bounds_of(other)
        if (other.get("clickable") == "true" and top <= middle <= bottom
                and 20 <= right - x <= 144 and bottom - top <= 135):
            buttons.append((x, other))
    if not buttons:
        close_drawer()
        return root, xml
    tap(*center(min(buttons, key=lambda item: item[0])[1]))
    # The picker lists every branch; the drawer header alone already names one.
    root, xml, text = wait_for(
        lambda r, t: target in t and others in t, 45, "branch picker",
    )
    save("branch-picker", xml)
    tap_label(root, target)
    return root, xml, text


def launch():
    adb_run(["shell", "am", "force-stop", pkg])
    adb_run(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
    adb_run(["shell", "wm", "dismiss-keyguard"])
    adb_run(["shell", "am", "start", "-n", f"{pkg}/com.fyona.erp.fyona_flutter.MainActivity"])
    root, xml, text = wait_for(
        lambda r, t: "فاتورة بيع" in t or "صافي الثروة" in t, 480, "user home",
    )
    save("home", xml)
    if "فاتورة بيع" not in text:
        # The app lands on the user's home; the Business section is entered
        # from the drawer switcher, exactly as the app's own navigation does.
        root, xml, text = open_drawer()
        save("drawer", xml)
        tap_label(root, "الانتقال إلى قسم الأعمال")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            root, xml, text = wait_for(
                lambda r, t: "فاتورة بيع" in t or any(
                    n.get("clickable") == "true" and any(
                        label.startswith("فرع") and len(label) < 40
                        for label in labels(n))
                    for n in r.iter("node")),
                60, "business dashboard or branch picker",
            )
            if "فاتورة بيع" in text:
                break
            preferred = find_nodes(root, "فرع تجربة الدليل")
            picks = preferred or [
                n for n in root.iter("node") if n.get("clickable") == "true" and any(
                    label.startswith("فرع") and len(label) < 40 for label in labels(n))
            ]
            if picks:
                tap(*center(picks[-1]))
            time.sleep(2)
    save("dashboard", xml)
    note("entered «قسم الأعمال» from the app's own drawer switch")
    select_branch()
    root, xml, text = probe(lambda r, t: "فاتورة بيع" in t or in_hub(t), 20) or (None, "", "")
    if root is None or "إدارة الفروع" in text or "الانتقال إلى" in text:
        root, xml, text = close_drawer() or (None, "", "")
    root, xml, text = wait_for(
        lambda r, t: "فاتورة بيع" in t or in_hub(t), 120, "after branch selection",
    )
    save("branch-selected", xml)
    for _ in range(8):
        matches = find_nodes(root, "التقارير")
        if matches:
            break
        adb_run(["shell", "input", "swipe", "270", "700", "270", "300", "400"])
        time.sleep(1)
        root, xml, text = wait_for(
            lambda r, t: "فاتورة بيع" in t or "صافي الثروة" in t or "التقارير" in t,
            60, "reports tile",
        )
    tap_label(root, "التقارير")
    root, xml, text = wait_for(lambda r, t: HUB in t and DEVICE_SOURCE in t, 120, "reports hub")
    save("hub", xml)
    note("opened «كيف شغلك؟» on «فرع تجربة الدليل»; the device ledger source notice is shown")


if PHASE == "online1":
    launch()
    open_card("sales", cancel=True)
    open_card("sales")
    open_card("money")
    open_card("inventory")
    open_card("debts")
    open_card("overview", period="هذا الأسبوع")
    note("period switched to «هذا الأسبوع» before opening the overview report")
elif PHASE == "offline":
    root, _ = go_hub()
    open_card("overview")
    open_card("debts")
    note("both reports rendered with the QA relay down: device ledger only, no network")
elif PHASE == "online2":
    launch()
    open_card("sales")

    def with_retry(kind, **kwargs):
        for attempt in range(2):
            try:
                open_card(kind, **kwargs)
                return
            except SystemExit:
                if attempt == 1:
                    raise
                note(f"{kind}: transient navigation loss; retrying the card once")
                go_hub()

    with_retry("money", type_chip=True)
    note("cold restart kept the retained session and saved device data")
else:
    raise SystemExit(f"unknown phase {PHASE}")
print(f"[{PHASE}] done", flush=True)
