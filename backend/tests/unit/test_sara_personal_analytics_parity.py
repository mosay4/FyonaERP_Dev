"""Parity source for the Dart port (lib/features/personal/domain/services/
personal_analytics.dart).

Until Stage 6 this test ran the server's build_financial_analytics over the
Personal tables on the shared fixture (test/fixtures/personal_analytics_parity.json).
That server code is gone (Personal data lives only on the devices); the
expected outputs it produced stay frozen in the fixture and the Dart test
keeps checking the phone against them. What the server still shares with
the phone is checked here: the period windows (resolve_period, in the user's
timezone) and the conversion block shape.
"""
import json
from datetime import datetime
from pathlib import Path

FIXTURE = Path(__file__).resolve().parents[3] / "test" / "fixtures" / "personal_analytics_parity.json"


def test_fixture_keeps_the_frozen_expected_outputs():
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert data["cases"], "parity cases must stay"
    for case in data["cases"]:
        expected = case["expected"]
        assert set(expected) >= {"meta", "facts", "comparisons", "detections",
                                 "details", "missing", "conversion"}, case["name"]


def test_server_period_windows_match_the_fixture():
    from app.domain.services.sara_analytics import resolve_period

    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for case in data["cases"]:
        meta = case["expected"]["meta"]
        start, end, prev_start, prev_end, label = resolve_period(
            case["period"], now=datetime.fromisoformat(case["now"]), tz=case["tz"])
        assert label == meta["period"], case["name"]
        assert start.isoformat() == meta["period_start"], case["name"]
        assert end.isoformat() == meta["period_end"], case["name"]
        assert prev_start.isoformat() == meta["prev_start"], case["name"]
        assert prev_end.isoformat() == meta["prev_end"], case["name"]
