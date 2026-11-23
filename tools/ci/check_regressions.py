"""Fail CI on any test failure that is not a known, pre-existing one.

Usage: flutter test --machine ... | python tools/ci/check_regressions.py
Known failures (pre-existing in the original project, outside the Business
work) are listed in tools/ci/known_failures.txt as "<file>: <test name>".
A newly passing known failure is reported so it can be removed from the list.
"""
import json
import sys
from pathlib import Path

known = {line.strip() for line in Path(__file__).with_name("known_failures.txt")
         .read_text(encoding="utf-8").splitlines() if line.strip()}
root = str(Path.cwd()) + "/"
tests, suites, failed, passed = {}, {}, set(), set()
for raw in sys.stdin:
    try:
        event = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(event, dict):
        continue
    kind = event.get("type")
    if kind == "suite":
        suites[event["suite"]["id"]] = event["suite"]["path"].replace("\\", "/").replace(root, "")
    elif kind == "testStart":
        t = event["test"]
        tests[t["id"]] = f'{suites.get(t["suiteID"], "?")}: {t["name"]}'
    elif kind == "testDone" and not event.get("hidden") and not event.get("skipped"):
        name = tests.get(event["testID"], "?")
        (failed if event["result"] != "success" else passed).add(name)
    elif kind == "error":
        failed.add(tests.get(event["testID"], "?"))
new = sorted(f for f in failed if f not in known)
fixed = sorted(k for k in known if k in passed)
print(f"passed={len(passed)} failed={len(failed)} known={len(known)}")
for name in fixed:
    print(f"::notice::Known failure now passes (remove from known_failures.txt): {name}")
for name in new:
    print(f"::error::New test failure: {name}")
if not passed:
    print("::error::No test results (the test run crashed)")
sys.exit(1 if new or not passed else 0)
