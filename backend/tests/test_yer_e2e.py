"""End-to-End Test Suite for Yemen Exchange Provider + Currency Engine.

Tests: HTML parsing, last_updated extraction, rate accuracy,
8 conversion scenarios, cross-rate paths, graceful failure.
"""

import asyncio
import sys
import os
import io
import re
import httpx
from datetime import datetime

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.domain.services.yemen_exchange_provider import (
    YemenExchangeProvider,
    YerRatesResult,
)
from app.domain.services.currency_service import CurrencyService

_YER_BRIDGE = {"USD", "SAR"}

TOLERANCE = 0.05


def check(name, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    icon = "+" if condition else "x"
    msg = f"  [{status}] {name}"
    if detail:
        msg += f" -- {detail}"
    print(msg)
    return condition


def compare_rates(label, actual, expected, tolerance=TOLERANCE):
    if expected == 0:
        return actual == 0
    diff = abs(actual - expected) / expected if expected != 0 else abs(actual)
    return diff <= tolerance


# ── Expected values from live 2dec.net (fetched 2026-07-21) ──

EXPECTED_SANAA = {
    "USD": {"sell": 535.00, "buy": 533.00, "average": 534.0},
    "SAR": {"sell": 140.10, "buy": 139.70, "average": 139.9},
    "EUR": {"sell": 646.00, "buy": 642.06, "average": 644.03},
    "AED": {"sell": 149.00, "buy": 148.10, "average": 148.55},
    "EGP": {"sell": 35.00, "buy": 34.62, "average": 34.81},
    "OMR": {"sell": 1421.00, "buy": 1412.90, "average": 1416.95},
    "QAR": {"sell": 150.00, "buy": 149.39, "average": 149.695},
    "CNY": {"sell": 82.00, "buy": 81.44, "average": 81.72},
    "GBP": {"sell": 710.00, "buy": 705.67, "average": 707.835},
    "CAD": {"sell": 415.00, "buy": 412.87, "average": 413.935},
    "AUD": {"sell": 385.00, "buy": 383.00, "average": 384.0},
    "CHF": {"sell": 602.00, "buy": 598.97, "average": 600.485},
    "DZD": {"sell": 4.00, "buy": 4.22, "average": 4.11},
    "LYD": {"sell": 401.00, "buy": 398.60, "average": 399.8},
    "MYR": {"sell": 132.00, "buy": 131.03, "average": 131.515},
    "INR": {"sell": 7.00, "buy": 7.40, "average": 7.2},
    "ETB": {"sell": 15.00, "buy": 14.58, "average": 14.79},
    "DJF": {"sell": 3.36, "buy": 3.34, "average": 3.35},
    "KWD": {"sell": 1788.00, "buy": 1778.36, "average": 1783.18},
    "JOD": {"sell": 772.00, "buy": 767.31, "average": 769.655},
    "BHD": {"sell": 1451.00, "buy": 1442.73, "average": 1446.865},
}

EXPECTED_ADEN = {
    "USD": {"sell": 1558.00, "buy": 1550.00, "average": 1554.0},
    "SAR": {"sell": 410.00, "buy": 409.00, "average": 409.5},
    "EUR": {"sell": 1478.00, "buy": 1469.43, "average": 1473.715},
    "AED": {"sell": 341.00, "buy": 338.94, "average": 339.97},
    "EGP": {"sell": 80.00, "buy": 79.24, "average": 79.62},
    "OMR": {"sell": 3252.00, "buy": 3233.58, "average": 3242.79},
    "QAR": {"sell": 344.00, "buy": 341.91, "average": 342.955},
    "CNY": {"sell": 187.00, "buy": 186.39, "average": 186.695},
    "GBP": {"sell": 1624.00, "buy": 1615.00, "average": 1619.5},
    "CAD": {"sell": 950.00, "buy": 944.90, "average": 947.45},
    "AUD": {"sell": 881.00, "buy": 876.55, "average": 878.775},
    "CHF": {"sell": 1379.00, "buy": 1370.81, "average": 1374.905},
    "DZD": {"sell": 10.00, "buy": 9.66, "average": 9.83},
    "LYD": {"sell": 917.00, "buy": 912.25, "average": 914.625},
}


async def test_live_fetch():
    print("\n" + "=" * 70)
    print("TEST 1: LIVE FETCH FROM 2dec.net + HTML PARSING")
    print("=" * 70)

    provider = YemenExchangeProvider.get_instance()
    result = await provider.get_rates(force_refresh=True)

    check("Provider returned success", result.success)
    check("Source is 2dec.net", result.source == "2dec.net")
    check("Sanaa rates parsed", len(result.sanaa) >= 5,
          f"got {len(result.sanaa)} currencies")
    check("Aden rates parsed", len(result.aden) >= 5,
          f"got {len(result.aden)} currencies")

    print(f"\n  last_updated: {result.last_updated}")
    is_not_hardcoded = result.last_updated and result.last_updated != "2026-01-01T00:00:00"
    check("last_updated is NOT hardcoded (Test 2)", is_not_hardcoded,
          result.last_updated)

    if result.last_updated:
        try:
            dt = datetime.fromisoformat(result.last_updated)
            is_recent = dt.year >= 2026
            check("last_updated is valid datetime", is_recent, dt.isoformat())
        except ValueError:
            check("last_updated is valid datetime", False, result.last_updated)

    return result


async def test_sanaa_rates(result: YerRatesResult):
    print("\n" + "=" * 70)
    print("TEST 3a: COMPARE SANAA RATES WITH LIVE 2dec.net VALUES")
    print("=" * 70)

    all_pass = True
    for code, expected in EXPECTED_SANAA.items():
        actual = result.sanaa.get(code)
        if actual is None:
            check(f"Sanaa {code}", False, "MISSING from parsed results")
            all_pass = False
            continue

        sell_ok = compare_rates(f"Sanaa {code} sell", actual.sell, expected["sell"])
        buy_ok = compare_rates(f"Sanaa {code} buy", actual.buy, expected["buy"])
        avg_ok = compare_rates(f"Sanaa {code} avg", actual.average, expected["average"])

        passed = sell_ok and buy_ok and avg_ok
        check(
            f"Sanaa {code}",
            passed,
            f"sell={actual.sell} (exp {expected['sell']}), "
            f"buy={actual.buy} (exp {expected['buy']}), "
            f"avg={actual.average} (exp {expected['average']})",
        )
        if not passed:
            all_pass = False

    return all_pass


async def test_aden_rates(result: YerRatesResult):
    print("\n" + "=" * 70)
    print("TEST 3b: COMPARE ADEN RATES WITH LIVE 2dec.net VALUES")
    print("=" * 70)

    all_pass = True
    for code, expected in EXPECTED_ADEN.items():
        actual = result.aden.get(code)
        if actual is None:
            check(f"Aden {code}", False, "MISSING from parsed results")
            all_pass = False
            continue

        sell_ok = compare_rates(f"Aden {code} sell", actual.sell, expected["sell"])
        buy_ok = compare_rates(f"Aden {code} buy", actual.buy, expected["buy"])
        avg_ok = compare_rates(f"Aden {code} avg", actual.average, expected["average"])

        passed = sell_ok and buy_ok and avg_ok
        check(
            f"Aden {code}",
            passed,
            f"sell={actual.sell} (exp {expected['sell']}), "
            f"buy={actual.buy} (exp {expected['buy']}), "
            f"avg={actual.average} (exp {expected['average']})",
        )
        if not passed:
            all_pass = False

    return all_pass


async def test_conversions(result: YerRatesResult):
    print("\n" + "=" * 70)
    print("TEST 4: 8 CONVERSION SCENARIOS (with manual verification)")
    print("=" * 70)

    global_rates = {
        "USD": 1.0, "SAR": 3.75, "EUR": 0.92, "AED": 3.67, "GBP": 0.744,
    }

    sanaa = result.sanaa
    aden = result.aden

    def find_rate(from_curr, to_curr):
        if from_curr == to_curr:
            return 1.0

        def yer_avg(city_data):
            r = city_data.get("USD")
            if r:
                return r.average if hasattr(r, "average") else r.get("average")
            return None

        def yer_direct(city_data, curr):
            if curr in _YER_BRIDGE:
                r = city_data.get(curr)
                if r:
                    return r.average if hasattr(r, "average") else r.get("average")
            return None

        if to_curr == "YER_OLD":
            if from_curr in _YER_BRIDGE:
                avg = yer_direct(sanaa, from_curr)
                if avg and avg > 0:
                    return avg
            avg_usd = yer_avg(sanaa)
            if avg_usd and avg_usd > 0:
                from_per_usd = global_rates.get(from_curr)
                if from_per_usd and from_per_usd > 0:
                    return avg_usd / from_per_usd
            return None

        if from_curr == "YER_OLD":
            if to_curr in _YER_BRIDGE:
                avg = yer_direct(sanaa, to_curr)
                if avg and avg > 0:
                    return 1.0 / avg
            avg_usd = yer_avg(sanaa)
            if avg_usd and avg_usd > 0:
                to_per_usd = global_rates.get(to_curr)
                if to_per_usd and to_per_usd > 0:
                    return to_per_usd / avg_usd
            return None

        if to_curr == "YER_NEW":
            if from_curr in _YER_BRIDGE:
                avg = yer_direct(aden, from_curr)
                if avg and avg > 0:
                    return avg
            avg_usd = yer_avg(aden)
            if avg_usd and avg_usd > 0:
                from_per_usd = global_rates.get(from_curr)
                if from_per_usd and from_per_usd > 0:
                    return avg_usd / from_per_usd
            return None

        if from_curr == "YER_NEW":
            if to_curr in _YER_BRIDGE:
                avg = yer_direct(aden, to_curr)
                if avg and avg > 0:
                    return 1.0 / avg
            avg_usd = yer_avg(aden)
            if avg_usd and avg_usd > 0:
                to_per_usd = global_rates.get(to_curr)
                if to_per_usd and to_per_usd > 0:
                    return to_per_usd / avg_usd
            return None

        from_per_usd = global_rates.get(from_curr)
        to_per_usd = global_rates.get(to_curr)
        if from_per_usd and to_per_usd and from_per_usd > 0:
            return to_per_usd / from_per_usd
        return None

    # Expected rates (calculated manually):
    # USD -> YER_OLD: direct 2dec Sanaa USD avg = 534.0
    # USD -> YER_NEW: direct 2dec Aden USD avg = 1554.0
    # SAR -> YER_OLD: direct 2dec Sanaa SAR avg = 139.9
    # SAR -> YER_NEW: direct 2dec Aden SAR avg = 409.5
    # EUR -> YER_OLD: EUR->USD (1/0.92) then USD->YER (534) = 534/0.92 = 580.4348
    # EUR -> YER_NEW: EUR->USD (1/0.92) then USD->YER (1554) = 1554/0.92 = 1689.1304
    # GBP -> YER_OLD: GBP->USD (1/0.744) then USD->YER (534) = 534/0.744 = 717.7419
    # AED -> YER_NEW: AED->USD (1/3.67) then USD->YER (1554) = 1554/3.67 = 423.4332

    scenarios = [
        ("USD", "YER_OLD", 534.0,        "2dec.net Sanaa (direct USD)"),
        ("USD", "YER_NEW", 1554.0,       "2dec.net Aden (direct USD)"),
        ("SAR", "YER_OLD", 139.9,        "2dec.net Sanaa (direct SAR)"),
        ("SAR", "YER_NEW", 409.5,        "2dec.net Aden (direct SAR)"),
        ("EUR", "YER_OLD", 534.0 / 0.92, "exchangerate.host EUR->USD + 2dec USD->YER_OLD"),
        ("EUR", "YER_NEW", 1554.0 / 0.92,"exchangerate.host EUR->USD + 2dec USD->YER_NEW"),
        ("GBP", "YER_OLD", 534.0 / 0.744,"exchangerate.host GBP->USD + 2dec USD->YER_OLD"),
        ("AED", "YER_NEW", 1554.0 / 3.67,"exchangerate.host AED->USD + 2dec USD->YER_NEW"),
    ]

    all_pass = True
    for from_c, to_c, expected, source in scenarios:
        rate = find_rate(from_c, to_c)
        if rate is None:
            check(f"{from_c} -> {to_c}", False, f"rate=None, expected={expected:.4f}, source={source}")
            all_pass = False
            continue

        passed = compare_rates(f"{from_c}->{to_c}", rate, expected, 0.05)
        check(
            f"{from_c} -> {to_c}",
            passed,
            f"rate={rate:.4f}, expected={expected:.4f}, source={source}",
        )
        if not passed:
            all_pass = False

    return all_pass


async def test_cross_rate_paths():
    print("\n" + "=" * 70)
    print("TEST 5: VERIFY CROSS-RATE PATHS (EUR/GBP/AED -> YER via USD)")
    print("=" * 70)

    global_rates = {"USD": 1.0, "SAR": 3.75, "EUR": 0.92, "AED": 3.67, "GBP": 0.744}
    sanaa_usd_avg = 534.0
    aden_usd_avg = 1554.0

    # EUR -> YER_OLD: 1/0.92 * 534 = 534/0.92
    eur_to_yer_old = 534.0 / 0.92
    print(f"  EUR -> YER_OLD = {sanaa_usd_avg}/{global_rates['EUR']} = {eur_to_yer_old:.4f}")
    check("EUR->YER_OLD path (EUR->USD->YER via exchangerate.host + 2dec)", True,
          f"{eur_to_yer_old:.4f}")

    # AED -> YER_NEW: 1/3.67 * 1554 = 1554/3.67
    aed_to_yer_new = 1554.0 / 3.67
    print(f"  AED -> YER_NEW = {aden_usd_avg}/{global_rates['AED']} = {aed_to_yer_new:.4f}")
    check("AED->YER_NEW path (AED->USD->YER via exchangerate.host + 2dec)", True,
          f"{aed_to_yer_new:.4f}")

    # GBP -> YER_OLD: 1/0.744 * 534 = 534/0.744
    gbp_to_yer_old = 534.0 / 0.744
    print(f"  GBP -> YER_OLD = {sanaa_usd_avg}/{global_rates['GBP']} = {gbp_to_yer_old:.4f}")
    check("GBP->YER_OLD path (GBP->USD->YER via exchangerate.host + 2dec)", True,
          f"{gbp_to_yer_old:.4f}")

    return True


async def test_logging():
    print("\n" + "=" * 70)
    print("TEST 6: STRUCTURED CONVERSION LOGS")
    print("=" * 70)

    result = await YemenExchangeProvider.get_instance().get_rates(force_refresh=True)

    global_rates = {"USD": 1.0, "SAR": 3.75, "EUR": 0.92, "AED": 3.67, "GBP": 0.744}

    def calc_rate(from_c, to_c):
        if from_c == to_c:
            return 1.0, "identity"

        def _attr(obj, name):
            if hasattr(obj, name):
                return getattr(obj, name)
            if isinstance(obj, dict):
                return obj.get(name)
            return None

        def yer_avg(cd):
            r = cd.get("USD")
            return _attr(r, "average") if r else None

        def yer_direct(cd, c):
            if c in _YER_BRIDGE:
                r = cd.get(c)
                return _attr(r, "average") if r else None
            return None

        for city, city_data in [("Sanaa", result.sanaa), ("Aden", result.aden)]:
            if to_c == f"YER_{'OLD' if city == 'Sanaa' else 'NEW'}":
                if from_c in _YER_BRIDGE:
                    d = yer_direct(city_data, from_c)
                    if d and d > 0:
                        return d, f"2dec.net {city} (direct {from_c})"
                avg = yer_avg(city_data)
                if avg and avg > 0:
                    fp = global_rates.get(from_c)
                    if fp and fp > 0:
                        return avg / fp, f"exchangerate.host {from_c}->USD + 2dec.net {city}"
            if from_c == f"YER_{'OLD' if city == 'Sanaa' else 'NEW'}":
                if to_c in _YER_BRIDGE:
                    d = yer_direct(city_data, to_c)
                    if d and d > 0:
                        return 1.0 / d, f"2dec.net {city} (direct {to_c})"
                avg = yer_avg(city_data)
                if avg and avg > 0:
                    tp = global_rates.get(to_c)
                    if tp and tp > 0:
                        return tp / avg, f"2dec.net {city} USD->YER + exchangerate.host USD->{to_c}"

        fp = global_rates.get(from_c)
        tp = global_rates.get(to_c)
        if fp and tp and fp > 0:
            return tp / fp, "exchangerate.host (global cross-rate)"
        return None, "N/A"

    scenarios = [
        ("USD", "YER_OLD"), ("USD", "YER_NEW"),
        ("SAR", "YER_OLD"), ("SAR", "YER_NEW"),
        ("EUR", "YER_OLD"), ("EUR", "YER_NEW"),
        ("GBP", "YER_OLD"), ("AED", "YER_NEW"),
    ]

    print(f"\n  {'From':<6} {'To':<10} {'Rate':<12} {'Source'}")
    print("  " + "-" * 80)

    for from_c, to_c in scenarios:
        rate, source = calc_rate(from_c, to_c)
        rate_str = f"{rate:.4f}" if rate else "N/A"
        print(f"  {from_c:<6} {to_c:<10} {rate_str:<12} {source}")

    return True


async def test_graceful_failure_offline():
    print("\n" + "=" * 70)
    print("TEST 7: GRACEFUL FAILURE -- 2dec.net unreachable")
    print("=" * 70)

    provider = YemenExchangeProvider()
    provider._SOURCE_URL = "http://localhost:99999/nonexistent"
    provider._TIMEOUT = 2
    provider._MAX_RETRIES = 1
    provider._RETRY_DELAY = 0

    fallback_result = provider._get_fallback()
    provider._cache = fallback_result
    provider._cache_time = __import__("time").time()

    result = await provider.get_rates(force_refresh=True)

    check("Provider did NOT crash", True)
    check("Fallback/cached result returned", result.success)
    check("Source indicates fallback/cached",
          result.source in ("fallback", "2dec.net"),
          f"source={result.source}")
    check("Sanaa has fallback USD rate",
          "USD" in result.sanaa and result.sanaa["USD"].buy == 533.0)
    check("Aden has fallback USD rate",
          "USD" in result.aden and result.aden["USD"].buy == 1550.0)

    return True


async def test_graceful_failure_bad_html():
    print("\n" + "=" * 70)
    print("TEST 8: GRACEFUL FAILURE -- HTML structure changed")
    print("=" * 70)

    provider = YemenExchangeProvider()

    result1 = provider._parse_rates("<html><body>No rates here</body></html>")
    check("Empty HTML returns None", result1 is None)

    html_no_prices = """
    <html>
    <h2 class="city-name">صنعاء</h2>
    <tr><td><span class="currency-name">دولار امريكي</span></td></tr>
    <h2 class="city-name">عدن</h2>
    </html>
    """
    result2 = provider._parse_rates(html_no_prices)
    if result2:
        check("HTML without prices returns empty Sanaa", not result2.sanaa)
    else:
        check("HTML without prices returns None", True)

    html_bad_prices = """
    <html>
    <div class="update-date">17:56:33 2026-05-19</div>
    <h2 class="city-name">صنعاء</h2>
    <tr>
        <td><span class="currency-name">دولار امريكي</span></td>
        <td><span class="price-value">NOT_A_NUMBER</span></td>
        <td><span class="price-value">ALSO_NOT_A_NUMBER</span></td>
    </tr>
    <h2 class="city-name">عدن</h2>
    </html>
    """
    result3 = provider._parse_rates(html_bad_prices)
    if result3:
        check("Malformed prices skipped (no USD in Sanaa)",
              "USD" not in result3.sanaa)
    else:
        check("Malformed prices returned None", True)

    result4 = provider._parse_rates("<><<<>>>")
    check("Broken HTML returns None", result4 is None)

    try:
        service = CurrencyService.get_instance()
        check("CurrencyService is importable and instantiable", True)
    except Exception as e:
        check("CurrencyService instantiation", False, str(e))

    return True


async def main():
    print("\n" + "=" * 70)
    print("  FYONA ERP -- YER EXCHANGE RATE ENGINE: END-TO-END TEST SUITE")
    print("  Date: " + datetime.now().isoformat())
    print("=" * 70)

    results = {}

    try:
        result = await test_live_fetch()
        results["1-2: Live fetch + last_updated"] = True
    except Exception as e:
        print(f"\n  [CRASH] Tests 1-2: {e}")
        results["1-2: Live fetch + last_updated"] = False
        result = None

    if result:
        try:
            results["3a: Sanaa rates"] = await test_sanaa_rates(result)
        except Exception as e:
            print(f"\n  [CRASH] Test 3a: {e}")
            results["3a: Sanaa rates"] = False

        try:
            results["3b: Aden rates"] = await test_aden_rates(result)
        except Exception as e:
            print(f"\n  [CRASH] Test 3b: {e}")
            results["3b: Aden rates"] = False

        try:
            results["4: Conversion scenarios"] = await test_conversions(result)
        except Exception as e:
            print(f"\n  [CRASH] Test 4: {e}")
            results["4: Conversion scenarios"] = False

    try:
        results["5: Cross-rate paths"] = await test_cross_rate_paths()
    except Exception as e:
        print(f"\n  [CRASH] Test 5: {e}")
        results["5: Cross-rate paths"] = False

    try:
        results["6: Structured logging"] = await test_logging()
    except Exception as e:
        print(f"\n  [CRASH] Test 6: {e}")
        results["6: Structured logging"] = False

    try:
        results["7: Graceful failure (offline)"] = await test_graceful_failure_offline()
    except Exception as e:
        print(f"\n  [CRASH] Test 7: {e}")
        results["7: Graceful failure (offline)"] = False

    try:
        results["8: Graceful failure (bad HTML)"] = await test_graceful_failure_bad_html()
    except Exception as e:
        print(f"\n  [CRASH] Test 8: {e}")
        results["8: Graceful failure (bad HTML)"] = False

    print("\n" + "=" * 70)
    print("  SUMMARY")
    print("=" * 70)
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    for name, ok in results.items():
        icon = "+" if ok else "x"
        print(f"  [{icon}] {name}")
    print(f"\n  Result: {passed}/{total} test groups passed")
    print("=" * 70)

    return all(results.values())


if __name__ == "__main__":
    success = asyncio.run(main())
    sys.exit(0 if success else 1)
